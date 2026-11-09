defmodule FeudHall.Domain.Hall.Evolver do
  @moduledoc """
  Pure event application for the hall.

  Evolution applies recorded facts only: allocations, costs, prices, quality,
  carbohydrate amounts, and deadlines were resolved by the decider and are
  never recomputed here, so replay cannot drift with new content or rules.

  Fact ownership inside the hall boundary:

  * hall: clock, cleaning gate, visitor fund
  * restaurant: cash/ledger, warehouse batches, unlocks, menu, policies
  * customer visit: requirement bundle, carbohydrate commitments, course slots,
    finalization
  * tray / component order: bill, reservations, production state, funding
  * dining wallet: funded credit slices and their spending reservations

  Ledger accounts per restaurant are signed so the trial balance
  `cash + raw + wip + cost_of_sales + waste + capex == capital + revenue`
  holds after every event.
  """

  alias FeudHall.Domain.{Inventory, Random}

  @ledger %{cash: 0, raw: 0, wip: 0, cost_of_sales: 0, waste: 0, capex: 0, capital: 0, revenue: 0}

  def ledger_accounts, do: Map.keys(@ledger)

  def evolve(nil, %{type: :hall_initialized} = e) do
    # Events recorded before the shared simulation carry no layout, seed, market, or demand.
    seed = Map.get(e, :seed, 0)
    market = Map.get(e, :market, %{})
    demand = Map.get(e, :demand, %{rng: Random.new(Random.derive(seed, "demand"))})

    %{
      hall_id: e.hall_id,
      content_hash: e.content_hash,
      catalog: e.catalog,
      now: 0,
      access: :open,
      visitor_fund: e.visitor_fund,
      last_recovery_id: nil,
      restaurants: %{},
      owners: %{},
      stalls: %{},
      layout: Map.get(e, :layout, %{}),
      market: %{
        stock: Map.get(market, :stock, %{}),
        requests: %{},
        by_key: %{},
        batch: 0,
        next_clear_at: clear_interval(e.catalog)
      },
      demand: demand,
      npcs: %{},
      visits: %{},
      trays: %{},
      orders: %{},
      wallets: %{},
      active_visits: %{},
      stats: %{arrivals: 0, served_mains: 0, served_drinks: 0, served_desserts: 0, finalized_visits: 0}
    }
  end

  def evolve(state, %{type: :clock_advanced, to: to}) when to >= state.now, do: %{state | now: to}

  def evolve(state, %{type: :hall_resumed, recovery_id: id}), do: %{state | last_recovery_id: id}

  def evolve(state, %{type: :hall_cleaning_started}), do: %{state | access: :cleaning}
  def evolve(state, %{type: :hall_cleaning_ended}), do: %{state | access: :open}

  def evolve(state, %{type: :restaurant_created} = e) do
    restaurant = %{
      id: e.restaurant_id,
      # Events written before NPC operators existed carry no kind: principal-owned.
      owner_kind: Map.get(e, :owner_kind, :principal),
      owner: e.owner,
      name: e.name,
      cuisine: e.cuisine,
      unlocked: [e.starter_recipe],
      menu: %{},
      policies: %{},
      batches: %{},
      ledger: @ledger
    }

    state
    |> put_in([:restaurants, e.restaurant_id], restaurant)
    |> put_in([:owners, {Map.get(e, :owner_kind, :principal), e.owner}], e.restaurant_id)
    |> put_in([:stalls, e.stall_id], %{
      id: e.stall_id,
      restaurant: e.restaurant_id,
      tier: Map.get(state.layout, e.stall_id),
      mode: :closed
    })
  end

  def evolve(state, %{type: :starter_grant_issued, restaurant_id: r, amount: a}),
    do: post(state, r, cash: a, capital: a)

  def evolve(state, %{type: :stall_opened, stall_id: s}), do: put_in(state, [:stalls, s, :mode], :open)
  def evolve(state, %{type: :stall_closed, stall_id: s}), do: put_in(state, [:stalls, s, :mode], :closed)

  def evolve(state, %{type: :recipe_unlocked} = e) do
    state
    |> update_in([:restaurants, e.restaurant_id, :unlocked], &(&1 ++ [e.recipe_id]))
    |> post(e.restaurant_id, cash: -e.cost, capex: e.cost)
  end

  def evolve(state, %{type: :menu_price_set} = e),
    do: put_in(state, [:restaurants, e.restaurant_id, :menu, e.recipe_id], e.price)

  def evolve(state, %{type: :menu_item_removed} = e),
    do: update_in(state, [:restaurants, e.restaurant_id, :menu], &Map.delete(&1, e.recipe_id))

  def evolve(state, %{type: :substitution_policy_set} = e) do
    update_in(state, [:restaurants, e.restaurant_id, :policies], fn policies ->
      Map.update(policies, e.recipe_id, %{e.line_id => e.policy}, &Map.put(&1, e.line_id, e.policy))
    end)
  end

  def evolve(state, %{type: :stock_purchased} = e) do
    batch = %{
      id: e.batch_id,
      product: e.product,
      product_version: e.product_version,
      qty: e.qty,
      reserved: 0,
      cost: e.cost,
      expires_at: e.expires_at
    }

    state
    |> put_in([:restaurants, e.restaurant_id, :batches, e.batch_id], batch)
    |> post(e.restaurant_id, cash: -e.cost, raw: e.cost)
  end

  def evolve(state, %{type: :stock_spoiled} = e) do
    state
    |> update_in([:restaurants, e.restaurant_id, :batches], &Map.delete(&1, e.batch_id))
    |> post(e.restaurant_id, raw: -e.cost, waste: e.cost)
  end

  def evolve(state, %{type: :allowance_granted} = e) do
    slice = %{source: :allowance, amount: e.amount, reserved: 0}

    state
    |> Map.update!(:visitor_fund, &(&1 - e.amount))
    |> update_in([:wallets], fn wallets ->
      wallet = Map.get(wallets, e.principal, %{slices: %{}})
      Map.put(wallets, e.principal, put_in(wallet, [:slices, e.slice_id], slice))
    end)
  end

  def evolve(state, %{type: :visit_admitted} = e) do
    visit = %{
      id: e.visit_id,
      source: e.source,
      principal: e.principal,
      restaurant: e.restaurant_id,
      stall: e.stall_id,
      requirement: e.requirement,
      budget: e.budget,
      budget_committed: 0,
      carbs_reserved: 0,
      carbs_served: 0,
      tray: nil,
      drink_selected: false,
      dessert: :none,
      dessert_offer_deadline: nil,
      dessert_order: nil,
      status: :active,
      outcome: nil
    }

    state = put_in(state, [:visits, e.visit_id], visit)
    state = update_in(state, [:stats, :arrivals], &(&1 + 1))

    if e.source == :guest,
      do: put_in(state, [:active_visits, e.principal], e.visit_id),
      else: state
  end

  def evolve(state, %{type: :tray_accepted} = e) do
    tray = %{
      id: e.tray_id,
      visit: e.visit_id,
      restaurant: e.restaurant_id,
      stall: e.stall_id,
      components: Enum.map(e.components, & &1.order_id),
      deadline: e.deadline,
      status: :accepted
    }

    state =
      state
      |> put_in([:trays, e.tray_id], tray)
      |> update_in([:visits, e.visit_id], fn v ->
        %{v | tray: e.tray_id, drink_selected: Enum.any?(e.components, &(&1.kind == :drink))}
      end)

    Enum.reduce(e.components, state, &accept_order(&2, &1, e))
  end

  def evolve(state, %{type: :reservation_replaced} = e) do
    rid = state.visits[state.orders[e.order_id].visit].restaurant

    state
    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, e.released, -1))
    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, e.claimed, 1))
    |> update_in([:orders, e.order_id, :reservations], fn claims ->
      merge_claims(subtract_claims(claims, e.released), e.claimed)
    end)
  end

  def evolve(state, %{type: :preparation_started} = e) do
    order = state.orders[e.order_id]
    rid = state.visits[order.visit].restaurant
    consumed_cost = e.consumed |> Enum.map(& &1.cost) |> Enum.sum()

    state
    |> update_in([:restaurants, rid, :batches], fn batches ->
      batches = Enum.reduce(e.consumed, batches, &consume_batch(&2, &1))
      batches |> Enum.reject(fn {_, b} -> b.qty == 0 end) |> Map.new()
    end)
    |> post(rid, raw: -consumed_cost, wip: consumed_cost)
    |> update_in([:orders, e.order_id], fn o ->
      %{o | status: :preparing, reservations: [], consumed_cost: consumed_cost, ready_not_before: e.ready_not_before}
    end)
  end

  def evolve(state, %{type: :preparation_completed} = e) do
    update_in(state, [:orders, e.order_id], &%{&1 | status: :ready, ready_expires_at: e.expires_at})
  end

  def evolve(state, %{type: :tray_served} = e) do
    tray = state.trays[e.tray_id]

    state =
      Enum.reduce(e.components, state, fn c, acc ->
        acc
        |> serve_order(tray.restaurant, tray.visit, c)
        |> count_served(acc.orders[c.order_id].kind)
      end)

    put_in(state, [:trays, e.tray_id, :status], :served)
  end

  def evolve(state, %{type: :tray_cancelled} = e) do
    tray = state.trays[e.tray_id]

    state =
      Enum.reduce(e.components, state, &cancel_order(&2, tray.restaurant, tray.visit, &1, e.reason))

    put_in(state, [:trays, e.tray_id, :status], :cancelled)
  end

  def evolve(state, %{type: :dessert_offered} = e) do
    update_in(state, [:visits, e.visit_id], &%{&1 | dessert: :offered, dessert_offer_deadline: e.deadline})
  end

  def evolve(state, %{type: :dessert_declined} = e) do
    update_in(state, [:visits, e.visit_id], &%{&1 | dessert: :declined, dessert_offer_deadline: nil})
  end

  def evolve(state, %{type: :dessert_accepted} = e) do
    visit = state.visits[e.visit_id]

    state
    |> update_in([:visits, e.visit_id], fn v ->
      %{v | dessert: :accepted, dessert_offer_deadline: nil, dessert_order: e.order.order_id}
    end)
    |> accept_order(e.order, %{
      visit_id: e.visit_id,
      restaurant_id: visit.restaurant,
      tray_id: nil,
      deadline: e.deadline
    })
  end

  def evolve(state, %{type: :dessert_served} = e) do
    visit = state.visits[state.orders[e.order_id].visit]

    state
    |> serve_order(visit.restaurant, visit.id, e)
    |> count_served(:dessert)
  end

  def evolve(state, %{type: :dessert_cancelled} = e) do
    visit = state.visits[state.orders[e.order_id].visit]
    cancel_order(state, visit.restaurant, visit.id, e, e.reason)
  end

  def evolve(state, %{type: :visit_finalized} = e) do
    visit = state.visits[e.visit_id]
    outcome = Map.take(e, [:reason, :components, :score, :competitive])

    state
    |> update_in([:visits, e.visit_id], fn v ->
      dessert = if v.dessert == :offered, do: :expired, else: v.dessert
      %{v | status: :finalized, outcome: outcome, dessert: dessert, dessert_offer_deadline: nil}
    end)
    |> update_in([:active_visits], fn active ->
      if Map.get(active, visit.principal) == e.visit_id, do: Map.delete(active, visit.principal), else: active
    end)
    |> update_in([:stats, :finalized_visits], &(&1 + 1))
  end

  # -- helpers -------------------------------------------------------------

  defp accept_order(state, c, e) do
    order = %{
      id: c.order_id,
      visit: e.visit_id,
      tray: Map.get(e, :tray_id),
      kind: c.kind,
      recipe_id: c.recipe_id,
      recipe_version: c.recipe_version,
      price: c.price,
      lines: c.lines,
      penalty: c.penalty,
      quality: c.quality,
      reservations: c.reservations,
      funding: c.funding,
      carbs_mg: c.carbs_mg,
      deadline: e.deadline,
      consumed_cost: 0,
      ready_not_before: nil,
      ready_expires_at: nil,
      cancel_reason: nil,
      status: :reserved
    }

    rid = e.restaurant_id
    carbs = c.carbs_mg || 0

    state
    |> put_in([:orders, c.order_id], order)
    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, c.reservations, 1))
    |> reserve_funding(e.visit_id, c.funding, c.price)
    |> update_in([:visits, e.visit_id, :carbs_reserved], &(&1 + carbs))
  end

  defp reserve_funding(state, visit_id, funding, price) do
    visit = state.visits[visit_id]

    case visit.source do
      :guest -> adjust_slices(state, visit.principal, funding, fn s, a -> %{s | reserved: s.reserved + a} end)
      :simulated -> update_in(state, [:visits, visit_id, :budget_committed], &(&1 + price))
    end
  end

  defp serve_order(state, rid, visit_id, c) do
    order = state.orders[c.order_id]
    visit = state.visits[visit_id]
    carbs = order.carbs_mg || 0

    state =
      case visit.source do
        :guest ->
          adjust_slices(state, visit.principal, order.funding, fn s, a ->
            %{s | reserved: s.reserved - a, amount: s.amount - a}
          end)

        :simulated ->
          state
      end

    state
    |> post(rid, cash: order.price, revenue: order.price, wip: -order.consumed_cost, cost_of_sales: order.consumed_cost)
    |> update_in([:orders, c.order_id], &%{&1 | status: :served})
    |> update_in([:visits, visit_id], fn v ->
      %{v | carbs_reserved: v.carbs_reserved - carbs, carbs_served: v.carbs_served + carbs}
    end)
  end

  defp cancel_order(state, rid, visit_id, c, reason) do
    order = state.orders[c.order_id]
    visit = state.visits[visit_id]
    carbs = order.carbs_mg || 0

    state =
      case visit.source do
        :guest ->
          adjust_slices(state, visit.principal, order.funding, fn s, a -> %{s | reserved: s.reserved - a} end)

        :simulated ->
          update_in(state, [:visits, visit_id, :budget_committed], &(&1 - order.price))
      end

    state
    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, order.reservations, -1))
    |> post(rid, wip: -order.consumed_cost, waste: order.consumed_cost)
    |> update_in([:orders, c.order_id], &%{&1 | status: :cancelled, reservations: [], cancel_reason: reason})
    |> update_in([:visits, visit_id, :carbs_reserved], &(&1 - carbs))
  end

  defp count_served(state, :main), do: update_in(state, [:stats, :served_mains], &(&1 + 1))
  defp count_served(state, :drink), do: update_in(state, [:stats, :served_drinks], &(&1 + 1))
  defp count_served(state, :dessert), do: update_in(state, [:stats, :served_desserts], &(&1 + 1))

  defp adjust_slices(state, principal, funding, fun) do
    update_in(state, [:wallets, principal, :slices], fn slices ->
      Enum.reduce(funding, slices, fn %{slice_id: id, amount: a}, acc -> Map.update!(acc, id, &fun.(&1, a)) end)
    end)
  end

  defp consume_batch(batches, %{batch_id: id, qty: q, cost: c}) do
    Map.update!(batches, id, fn b -> %{b | qty: b.qty - q, reserved: b.reserved - q, cost: b.cost - c} end)
  end

  defp subtract_claims(claims, released) do
    Enum.flat_map(claims, fn claim ->
      case Enum.find(released, &(&1.batch_id == claim.batch_id)) do
        nil -> [claim]
        %{qty: q} when q >= claim.qty -> []
        %{qty: q} -> [%{claim | qty: claim.qty - q}]
      end
    end)
  end

  defp merge_claims(claims, added) do
    Enum.reduce(added, claims, fn a, acc ->
      if Enum.any?(acc, &(&1.batch_id == a.batch_id)),
        do: Enum.map(acc, &if(&1.batch_id == a.batch_id, do: %{&1 | qty: &1.qty + a.qty}, else: &1)),
        else: acc ++ [a]
    end)
  end

  defp clear_interval(catalog), do: get_in(catalog, [:rules, :market, :clear_every_hall_ms]) || 0

  defp post(state, rid, postings) do
    update_in(state, [:restaurants, rid, :ledger], fn ledger ->
      Enum.reduce(postings, ledger, fn {account, amount}, acc -> Map.update!(acc, account, &(&1 + amount)) end)
    end)
  end
end
