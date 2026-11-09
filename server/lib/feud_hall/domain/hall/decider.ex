defmodule FeudHall.Domain.Hall.Decider do
  @moduledoc """
  Pure command decisions for the hall.

  Every decision validates the payload structurally, checks the actor's
  authority against current state, and either rejects with a typed reason
  (no events) or returns the complete batch of resolved facts. Entity IDs are
  derived from the command ID, so a decision is deterministic and a retried
  command cannot mint a second order or batch.

  Kitchen progress (`start_preparation`, `complete_preparation`, `serve_tray`,
  `serve_dessert`) is decided here as ordinary commands from the
  `{:system, :kitchen}` capability. The workforce milestone will drive them
  from staff coverage; they never bypass work time, freshness, or the gate.
  """

  alias FeudHall.Domain.{Clock, Content, Inventory, Money, Random, Substitution}
  alias FeudHall.Domain.Hall.{Admission, Advance, Evolver, Settlement}

  @max_qty 1_000_000
  @max_price 1_000_000

  @max_seed 18_446_744_073_709_551_615

  def decide(nil, {:initialize_hall, %{hall_id: hall_id, catalog: catalog} = p}, %{actor: {:system, :admin}})
      when is_binary(hall_id) do
    case Content.validate(catalog) do
      :ok -> initialize_events(hall_id, catalog, Map.get(p, :seed, catalog.rules.seed))
      {:error, problems} -> {:error, {:invalid_content, problems}}
    end
  end

  def decide(nil, _command, _ctx), do: {:error, :hall_not_initialized}
  def decide(_state, {:initialize_hall, _}, _ctx), do: {:error, :already_initialized}

  def decide(state, {:advance_clock, %{to_service_ms: to}}, %{actor: {:system, :scheduler}})
      when is_integer(to) do
    target = Clock.hall_at_service(to)
    if target < state.now, do: {:error, :clock_cannot_move_backwards}, else: {:ok, Advance.run(state, target)}
  end

  def decide(state, {:create_restaurant, p}, %{actor: {kind, owner}} = ctx) when kind in [:principal, :npc] do
    catalog = state.catalog

    starter =
      catalog.recipes |> Map.values() |> Enum.find(&(&1.starter and &1.cuisine == Map.get(p, :cuisine)))

    cond do
      not (id?(p[:restaurant_id]) and id?(p[:stall_id]) and name?(p[:name])) -> {:error, :invalid_payload}
      Map.has_key?(state.owners, {kind, owner}) -> {:error, :venture_already_active}
      Map.has_key?(state.restaurants, p.restaurant_id) -> {:error, :duplicate_restaurant}
      not Map.has_key?(state.layout, p.stall_id) -> {:error, :unknown_slot}
      Map.has_key?(state.stalls, p.stall_id) -> {:error, :stall_taken}
      starter == nil -> {:error, :unknown_cuisine}
      true -> {:ok, create_restaurant_events(p, kind, owner, starter, catalog, ctx)}
    end
  end

  def decide(state, {:open_stall, %{stall_id: s}}, ctx) do
    with {:ok, _stall} <- owned_stall(state, s, ctx) do
      {:ok, [%{type: :stall_opened, stall_id: s}]}
    end
  end

  def decide(state, {:close_stall, %{stall_id: s}}, ctx) do
    with {:ok, _stall} <- owned_stall(state, s, ctx) do
      state1 = Evolver.evolve(state, %{type: :stall_closed, stall_id: s})

      withdrawn =
        state.visits
        |> Map.values()
        |> Enum.filter(&(&1.stall == s and &1.status == :active and &1.dessert == :offered))
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&Settlement.finalize_event(state1, &1, :dessert_offer_withdrawn))

      {:ok, [%{type: :stall_closed, stall_id: s} | withdrawn]}
    end
  end

  def decide(state, {:unlock_recipe, %{restaurant_id: r, recipe_id: id}}, ctx) do
    with {:ok, restaurant} <- owned_restaurant(state, r, ctx),
         {:ok, recipe} <- fetch(state.catalog.recipes, id, :unknown_recipe),
         :ok <- ensure(recipe.cuisine == restaurant.cuisine, :wrong_cuisine),
         :ok <- ensure(id not in restaurant.unlocked, :already_unlocked),
         :ok <- ensure(restaurant.ledger.cash >= recipe.unlock_cost, :insufficient_cash) do
      {:ok, [%{type: :recipe_unlocked, restaurant_id: r, recipe_id: id, cost: recipe.unlock_cost}]}
    end
  end

  def decide(state, {:set_menu_price, %{restaurant_id: r, recipe_id: id, price: price}}, ctx) do
    with {:ok, restaurant} <- owned_restaurant(state, r, ctx),
         :ok <- ensure(id in restaurant.unlocked, :recipe_locked),
         :ok <- ensure(is_integer(price) and price > 0 and price <= @max_price, :invalid_price) do
      {:ok, [%{type: :menu_price_set, restaurant_id: r, recipe_id: id, price: price}]}
    end
  end

  def decide(state, {:remove_menu_item, %{restaurant_id: r, recipe_id: id}}, ctx) do
    with {:ok, restaurant} <- owned_restaurant(state, r, ctx),
         :ok <- ensure(Map.has_key?(restaurant.menu, id), :not_on_menu) do
      {:ok, [%{type: :menu_item_removed, restaurant_id: r, recipe_id: id}]}
    end
  end

  def decide(state, {:set_substitution_policy, p}, ctx) do
    with {:ok, _restaurant} <- owned_restaurant(state, p[:restaurant_id], ctx),
         {:ok, recipe} <- fetch(state.catalog.recipes, p[:recipe_id], :unknown_recipe),
         {:ok, line} <- find_line(recipe, p[:line_id]),
         :ok <- ensure(p[:policy] in Substitution.policies(), :invalid_policy),
         :ok <- ensure(line.substitute != nil or p.policy == :primary_only, :no_approved_substitute) do
      {:ok,
       [
         %{
           type: :substitution_policy_set,
           restaurant_id: p.restaurant_id,
           recipe_id: p.recipe_id,
           line_id: p.line_id,
           policy: p.policy
         }
       ]}
    end
  end

  # Direct wholesale fill at the catalog base price. This is a seam for the
  # batched scarcity-priced market (milestone 2), which will produce the same
  # stock_purchased facts from cleared fills.
  def decide(state, {:purchase_stock, p}, ctx) do
    catalog = state.catalog

    with {:ok, restaurant} <- owned_restaurant(state, p[:restaurant_id], ctx),
         {:ok, product} <- fetch(catalog.products, p[:product], :unknown_product),
         :ok <- ensure(is_integer(p[:qty]) and p.qty > 0 and p.qty <= @max_qty, :invalid_quantity),
         :ok <- ensure(is_integer(p[:max_price_per_kunit]), :invalid_price_limit),
         :ok <- ensure(product.base_price_per_kunit <= p.max_price_per_kunit, :price_above_limit),
         cost = Money.ceil_div(p.qty * product.base_price_per_kunit, 1000),
         :ok <- ensure(restaurant.ledger.cash >= cost, :insufficient_cash),
         used = Inventory.storage_used(restaurant.batches, catalog),
         needed = Inventory.storage_for(catalog, product.id, p.qty),
         :ok <- ensure(used + needed <= catalog.rules.storage_capacity, :insufficient_storage) do
      {:ok,
       [
         %{
           type: :stock_purchased,
           restaurant_id: restaurant.id,
           batch_id: "B:" <> ctx.command_id,
           product: product.id,
           product_version: product.version,
           qty: p.qty,
           cost: cost,
           expires_at: state.now + product.shelf_life_ms
         }
       ]}
    end
  end

  def decide(state, {:grant_allowance, %{principal: who, amount: amount}}, %{actor: {:system, :visitor_fund}} = ctx) do
    rules = state.catalog.rules

    cond do
      not id?(who) -> {:error, :invalid_payload}
      not (is_integer(amount) and amount > 0 and amount <= rules.max_allowance_grant) -> {:error, :invalid_amount}
      amount > state.visitor_fund -> {:error, :visitor_fund_exhausted}
      true -> {:ok, [%{type: :allowance_granted, principal: who, slice_id: "S:" <> ctx.command_id, amount: amount}]}
    end
  end

  def decide(state, {:admit_visit, p}, ctx), do: admit_visit(state, p, ctx)

  def decide(state, {:cancel_tray, %{tray_id: t}}, %{actor: {:principal, who}}) do
    with {:ok, tray, visit} <- active_tray(state, t),
         :ok <- ensure(visit.source == :guest and visit.principal == who, :forbidden),
         :ok <- ensure(Enum.all?(tray.components, &(state.orders[&1].status == :reserved)), :preparation_started) do
      {:ok, Settlement.cancel_tray(state, tray, :guest_cancelled)}
    end
  end

  def decide(state, {:start_preparation, %{order_id: o}}, %{actor: {:system, :kitchen}}) do
    with {:ok, order} <- live_order(state, o),
         :ok <- ensure(order.status == :reserved, :invalid_order_state),
         :ok <- ensure(state.access == :open, :hall_cleaning) do
      restaurant = state.restaurants[state.visits[order.visit].restaurant]
      recipe = state.catalog.recipes[order.recipe_id]

      consumed =
        Enum.map(order.reservations, fn claim ->
          batch = restaurant.batches[claim.batch_id]
          %{batch_id: claim.batch_id, qty: claim.qty, cost: Inventory.consumption_cost(batch, claim.qty)}
        end)

      {:ok,
       [
         %{
           type: :preparation_started,
           order_id: o,
           consumed: consumed,
           ready_not_before: state.now + recipe.prep_ms + recipe.finish_ms
         }
       ]}
    end
  end

  def decide(state, {:complete_preparation, %{order_id: o}}, %{actor: {:system, :kitchen}}) do
    with {:ok, order} <- live_order(state, o),
         :ok <- ensure(order.status == :preparing, :invalid_order_state),
         :ok <- ensure(state.now >= order.ready_not_before, :work_incomplete) do
      recipe = state.catalog.recipes[order.recipe_id]
      {:ok, [%{type: :preparation_completed, order_id: o, expires_at: state.now + recipe.holding_ms}]}
    end
  end

  def decide(state, {:serve_tray, %{tray_id: t}}, %{actor: {:system, :kitchen}}) do
    with {:ok, tray, _visit} <- active_tray(state, t),
         :ok <- ensure(state.access == :open, :hall_cleaning),
         :ok <- ensure(state.now <= tray.deadline, :deadline_passed),
         :ok <- ensure(Enum.all?(tray.components, &servable?(state, &1)), :tray_not_ready) do
      {:ok, Settlement.serve_tray(state, tray)}
    end
  end

  def decide(state, {:accept_dessert, p}, ctx), do: accept_dessert(state, p, ctx)

  def decide(state, {:decline_dessert, %{visit_id: v}}, ctx) do
    with {:ok, visit} <- diner_visit(state, v, ctx),
         :ok <- ensure(visit.dessert == :offered, :no_dessert_offer) do
      declined = %{type: :dessert_declined, visit_id: v}
      state1 = Evolver.evolve(state, declined)
      {:ok, [declined, Settlement.finalize_event(state1, state1.visits[v], :completed)]}
    end
  end

  def decide(state, {:cancel_dessert, %{visit_id: v}}, %{actor: {:principal, _}} = ctx) do
    with {:ok, visit} <- diner_visit(state, v, ctx),
         :ok <- ensure(visit.source == :guest, :forbidden),
         {:ok, order} <- fetch(state.orders, visit.dessert_order, :no_dessert_order),
         :ok <- ensure(order.status == :reserved, :preparation_started) do
      {:ok, Settlement.cancel_dessert(state, order, :guest_cancelled)}
    end
  end

  def decide(state, {:serve_dessert, %{order_id: o}}, %{actor: {:system, :kitchen}}) do
    with {:ok, order} <- live_order(state, o),
         :ok <- ensure(order.kind == :dessert, :not_a_dessert),
         :ok <- ensure(state.access == :open, :hall_cleaning),
         :ok <- ensure(state.now <= order.deadline, :deadline_passed),
         :ok <- ensure(servable?(state, o), :not_ready) do
      {:ok, Settlement.serve_dessert(state, order)}
    end
  end

  def decide(_state, {kind, _payload}, _ctx) when is_atom(kind), do: {:error, :unauthorized_or_malformed}
  def decide(_state, _command, _ctx), do: {:error, :malformed_command}

  # -- visits -----------------------------------------------------------------

  defp admit_visit(state, p, ctx) do
    with {:ok, source, principal, budget} <- visit_source(p, ctx) do
      Admission.admit(
        state,
        %{
          source: source,
          principal: principal,
          budget: budget,
          stall_id: p[:stall_id],
          main: p[:main],
          drink: p[:drink],
          profile_id: p[:profile_id],
          confirmed: p[:confirmed],
          deadline_cap: nil
        },
        ctx.command_id
      )
    end
  end

  defp visit_source(%{source: :guest}, %{actor: {:principal, who}}), do: {:ok, :guest, who, nil}

  defp visit_source(%{source: :simulated, diner_id: d, budget: b}, %{actor: {:system, :demand}})
       when is_binary(d) and is_integer(b) and b > 0 and b <= @max_price,
       do: {:ok, :simulated, "diner:" <> d, b}

  defp visit_source(_p, _ctx), do: {:error, :forbidden}

  defp accept_dessert(state, %{visit_id: v} = p, ctx) do
    with {:ok, visit} <- diner_visit(state, v, ctx) do
      Admission.accept_dessert(state, visit, p[:confirmed], ctx.command_id)
    end
  end

  defp accept_dessert(_state, _p, _ctx), do: {:error, :invalid_payload}

  # -- lookups and guards -------------------------------------------------------

  defp initialize_events(_hall_id, _catalog, seed) when not (is_integer(seed) and seed >= 0 and seed <= @max_seed),
    do: {:error, :invalid_payload}

  defp initialize_events(hall_id, catalog, seed) do
    market = catalog.rules.market
    floor_equivalents_millis = catalog.rules.demand.equivalent_floor_millis

    # Opening stock is the per-equivalent target at the demand floor, within the replenishment cap.
    stock =
      Map.new(market.target_stock_per_equivalent, fn {product, per_equivalent} ->
        {product, min(div(per_equivalent * floor_equivalents_millis, 1_000), market.replenish_cap[product])}
      end)

    {:ok,
     [
       %{
         type: :hall_initialized,
         hall_id: hall_id,
         content_hash: Content.hash(catalog),
         catalog: catalog,
         visitor_fund: catalog.rules.visitor_fund,
         layout: Map.new(catalog.layout, &{&1.slot_id, &1.tier}),
         seed: seed,
         market: %{stock: stock},
         demand: %{rng: Random.new(Random.derive(seed, "demand"))}
       }
     ]}
  end

  defp create_restaurant_events(p, owner_kind, owner, starter, catalog, _ctx) do
    [
      %{
        type: :restaurant_created,
        restaurant_id: p.restaurant_id,
        owner_kind: owner_kind,
        owner: owner,
        name: p.name,
        cuisine: starter.cuisine,
        starter_recipe: starter.id,
        stall_id: p.stall_id
      },
      %{type: :starter_grant_issued, restaurant_id: p.restaurant_id, amount: catalog.rules.starter_grant},
      %{type: :menu_price_set, restaurant_id: p.restaurant_id, recipe_id: starter.id, price: starter.suggested_price}
    ]
  end

  defp owned_restaurant(state, r, %{actor: {kind, who}}) when kind in [:principal, :npc] do
    case state.restaurants[r] do
      nil -> {:error, :unknown_restaurant}
      %{owner_kind: ^kind, owner: ^who} = restaurant -> {:ok, restaurant}
      _ -> {:error, :forbidden}
    end
  end

  defp owned_restaurant(_state, _r, _ctx), do: {:error, :forbidden}

  defp owned_stall(state, s, ctx) do
    with {:ok, stall} <- fetch(state.stalls, s, :unknown_stall),
         {:ok, _} <- owned_restaurant(state, stall.restaurant, ctx) do
      {:ok, stall}
    end
  end

  defp diner_visit(state, v, ctx) do
    case {state.visits[v], ctx.actor} do
      {nil, _} -> {:error, :unknown_visit}
      {%{status: :finalized}, _} -> {:error, :visit_finalized}
      {%{source: :guest, principal: who} = visit, {:principal, who}} -> {:ok, visit}
      {%{source: :simulated} = visit, {:system, :demand}} -> {:ok, visit}
      _ -> {:error, :forbidden}
    end
  end

  defp active_tray(state, t) do
    case state.trays[t] do
      nil -> {:error, :unknown_tray}
      %{status: :accepted} = tray -> {:ok, tray, state.visits[tray.visit]}
      _ -> {:error, :tray_settled}
    end
  end

  defp live_order(state, o) do
    case state.orders[o] do
      nil -> {:error, :unknown_order}
      %{status: s} when s in [:served, :cancelled] -> {:error, :order_settled}
      order -> {:ok, order}
    end
  end

  defp servable?(state, order_id) do
    order = state.orders[order_id]
    order.status == :ready and state.now < order.ready_expires_at
  end

  defp find_line(recipe, line_id) do
    case Enum.find(recipe.lines, &(&1.line_id == line_id)) do
      nil -> {:error, :unknown_line}
      line -> {:ok, line}
    end
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(_, reason), do: {:error, reason}

  defp id?(value), do: is_binary(value) and byte_size(value) in 1..64 and String.printable?(value)

  defp name?(value),
    do: is_binary(value) and String.length(value) in 1..40 and String.printable?(value) and byte_size(value) <= 160

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} when value != nil -> {:ok, value}
      _ -> {:error, reason}
    end
  end
end
