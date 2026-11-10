defmodule FeudHall.Domain.Hall.Decider do
  @moduledoc """
  Pure command decisions for the hall.

  Every decision validates the payload structurally, checks the actor's
  authority against current state, and either rejects with a typed reason
  (no events) or returns the complete batch of resolved facts. Entity IDs are
  derived from the command ID, so a decision is deterministic and a retried
  command cannot mint a second order or batch.

  Kitchen progress is not a command: stage starts and completions, counter
  handover, and service are clock boundaries decided by
  `FeudHall.Domain.Hall.Advance`.
  """

  alias FeudHall.Domain.{Clock, Content, Random, Substitution}
  alias FeudHall.Domain.Hall.{Admission, Advance, Evolver, Settlement}

  @max_qty 1_000_000
  @max_price 1_000_000
  # Purchase price limits are compared, never multiplied; the bound keeps them small integers.
  @max_price_limit 1_000_000_000

  @max_seed 18_446_744_073_709_551_615

  # The owner commands an NPC plan may contain; anything else is refused inside the plan.
  @plan_actions ~w(open_stall close_stall unlock_recipe set_menu_price remove_menu_item set_substitution_policy
                   submit_purchase_request cancel_purchase_request)a
  @max_plan_actions 256

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

  def decide(state, {:create_restaurant, p}, %{actor: {kind, owner}}) when kind in [:principal, :npc] do
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
      true -> {:ok, create_restaurant_events(state, p, kind, owner, starter)}
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

  # A pending wholesale purchase, cleared with every other pending request at
  # the next market clearing (`FeudHall.Domain.Market`). No cash or storage is
  # held now: funding is decided at clearing. One request per restaurant and
  # product: a new one replaces the pending one.
  def decide(state, {:submit_purchase_request, p}, ctx) do
    with {:ok, restaurant} <- owned_restaurant(state, p[:restaurant_id], ctx),
         {:ok, product} <- fetch(state.catalog.products, p[:product], :unknown_product),
         :ok <- ensure(is_integer(p[:qty]) and p.qty > 0 and p.qty <= @max_qty, :invalid_quantity),
         limit = p[:max_price_per_kunit],
         :ok <- ensure(is_integer(limit) and limit > 0 and limit <= @max_price_limit, :invalid_price_limit) do
      {:ok,
       [
         %{
           type: :purchase_requested,
           request_id: "PR:" <> ctx.command_id,
           restaurant_id: restaurant.id,
           product: product.id,
           qty: p.qty,
           max_price_per_kunit: limit,
           replaces: Map.get(state.market.by_key, {restaurant.id, product.id})
         }
       ]}
    end
  end

  def decide(state, {:cancel_purchase_request, p}, ctx) do
    with {:ok, restaurant} <- owned_restaurant(state, p[:restaurant_id], ctx),
         {:ok, request_id} <- fetch(state.market.by_key, {restaurant.id, p[:product]}, :no_pending_request) do
      {:ok, [%{type: :purchase_request_cancelled, request_id: request_id}]}
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

  # One NPC planning slot: the planner's owner commands, decided in order by
  # the same rules as a human owner's, as one atomic batch. Each action sees
  # the state the earlier accepted actions produced and is authorised as the
  # NPC for its own restaurant; a refused action contributes only its reason.
  def decide(state, {:npc_plan, %{operator: op, slot: slot, actions: actions, rng: rng}}, %{actor: {:npc, op}} = ctx)
      when is_binary(op) and is_integer(slot) and is_list(actions) do
    latest = div(state.now, Clock.hour()) * Clock.hour()

    with {:ok, npc} <- fetch(state.npcs, op, :unknown_npc),
         :ok <- ensure(ctx.command_id == npc_plan_id(op, slot), :invalid_command_id),
         :ok <- ensure(slot >= npc.next_slot_at, :slot_already_planned),
         :ok <- ensure(slot <= latest, :slot_not_reached),
         :ok <- ensure(slot == latest, :stale_slot),
         :ok <- ensure(length(actions) <= @max_plan_actions, :too_many_actions),
         :ok <- ensure(is_integer(rng) and rng >= 0 and rng <= @max_seed, :invalid_payload) do
      {:ok, npc_plan_events(state, op, slot, actions, rng, ctx)}
    end
  end

  def decide(state, {:admit_visit, p}, ctx), do: admit_visit(state, p, ctx)

  def decide(state, {:cancel_tray, %{tray_id: t}}, %{actor: {:principal, who}}) do
    with {:ok, tray, visit} <- active_tray(state, t),
         :ok <- ensure(visit.source == :guest and visit.principal == who, :forbidden),
         :ok <- ensure(Enum.all?(tray.components, &(state.orders[&1].status == :queued_prep)), :preparation_started) do
      {:ok, Settlement.cancel_tray(state, tray, :guest_cancelled)}
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
         :ok <- ensure(order.status == :queued_prep, :preparation_started) do
      {:ok, Settlement.cancel_dessert(state, order, :guest_cancelled)}
    end
  end

  def decide(_state, {kind, _payload}, _ctx) when is_atom(kind), do: {:error, :unauthorized_or_malformed}
  def decide(_state, _command, _ctx), do: {:error, :malformed_command}

  # -- NPC plans ----------------------------------------------------------------

  @doc "The command ID of an NPC's plan for a slot; its actions use `<id>:<index>`."
  def npc_plan_id(operator, slot), do: "npc:#{operator}:#{slot}"

  defp npc_plan_events(state, op, slot, actions, rng, ctx) do
    {outcomes, events, _state} =
      actions
      |> Enum.with_index()
      |> Enum.reduce({[], [], state}, fn {action, i}, {outcomes, events, current} ->
        sub = %{ctx | command_id: "#{ctx.command_id}:#{i}"}

        case plan_action(current, action, sub) do
          {:ok, new} ->
            {[%{action: elem(action, 0), result: :accepted} | outcomes], [new | events],
             Enum.reduce(new, current, &Evolver.evolve(&2, &1))}

          {:error, reason} ->
            outcome = %{action: action_kind(action), result: :rejected, reason: reason_code(reason)}
            {[outcome | outcomes], events, current}
        end
      end)

    planned = %{
      type: :npc_planned,
      operator: op,
      slot: slot,
      next_slot_at: slot + Clock.hour(),
      rng: rng,
      outcomes: Enum.reverse(outcomes)
    }

    [planned | events |> Enum.reverse() |> Enum.concat()]
  end

  defp plan_action(state, {kind, payload} = action, ctx) when kind in @plan_actions and is_map(payload),
    do: decide(state, action, ctx)

  defp plan_action(_state, {kind, _payload}, _ctx) when kind in @plan_actions, do: {:error, :malformed_action}

  defp plan_action(_state, {kind, _payload}, _ctx) when is_atom(kind), do: {:error, :action_not_allowed}
  defp plan_action(_state, _action, _ctx), do: {:error, :malformed_action}

  # Recorded in the event: only the owner command names, so a stray atom never reaches the log.
  defp action_kind({kind, _}) when kind in @plan_actions, do: kind
  defp action_kind(_action), do: :other

  defp reason_code(reason) when is_atom(reason), do: reason
  defp reason_code(_reason), do: :unrecognised_reason

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
          dessert_appetite?: p[:dessert_appetite?],
          deadline_cap: nil
        },
        ctx.command_id
      )
    end
  end

  defp visit_source(%{source: :guest}, %{actor: {:principal, who}}), do: {:ok, :guest, who, nil}

  # Simulated diners arrive inside the clock advance (`Advance`, class 8); the
  # authority never issues this command. It remains a test-fixture path that
  # admits through the same `Admission.admit/3`.
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

  defp create_restaurant_events(state, p, owner_kind, owner, starter) do
    catalog = state.catalog

    created = %{
      type: :restaurant_created,
      restaurant_id: p.restaurant_id,
      owner_kind: owner_kind,
      owner: owner,
      name: p.name,
      cuisine: starter.cuisine,
      starter_recipe: starter.id,
      stall_id: p.stall_id
    }

    [
      if(owner_kind == :npc, do: Map.put(created, :npc, npc_operator(state, owner)), else: created),
      %{type: :starter_grant_issued, restaurant_id: p.restaurant_id, amount: catalog.rules.starter_grant},
      %{type: :menu_price_set, restaurant_id: p.restaurant_id, recipe_id: starter.id, price: starter.suggested_price}
    ]
  end

  # An NPC operator's planning record: its profile is its operator ID (Ruling R4), its first
  # planning slot the next hour boundary strictly after now, and its own random stream.
  defp npc_operator(state, operator) do
    %{
      profile_id: operator,
      next_slot_at: (div(state.now, Clock.hour()) + 1) * Clock.hour(),
      rng: Random.new(Random.derive(state.seed, "npc:" <> operator))
    }
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
