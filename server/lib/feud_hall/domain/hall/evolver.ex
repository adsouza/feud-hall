defmodule FeudHall.Domain.Hall.Evolver do
  @moduledoc """
  Pure event application for the hall.

  Evolution applies recorded facts only: allocations, costs, prices, quality,
  carbohydrate amounts, and deadlines were resolved by the decider and are
  never recomputed here, so replay cannot drift with new content or rules.

  Fact ownership inside the hall boundary:

  * hall: clock, cleaning gate, visitor fund, seed
  * NPC operator: planning slot and random stream (`npcs`); its restaurant
    is an ordinary restaurant
  * wholesale market: stock, pending purchase requests, batch number, and the
    next clearing instant (see `FeudHall.Domain.Market`)
  * restaurant: cash/ledger, warehouse batches, unlocks, menu, policies;
    its stall's mode and counter handover
  * customer visit: requirement bundle, carbohydrate commitments, course slots,
    finalization
  * tray / component order: bill, reservations, work stage (see
    `FeudHall.Domain.Kitchen`), funding; `order_seq` numbers accepted orders
  * dining wallet: funded credit slices and their spending reservations

  Live state holds only unfinished work. A visit's single `visit_finalized`
  retires the visit, its tray and its orders from `visits`, `trays` and
  `orders` in that same transition: by then every reservation, funding slice,
  counter claim and cost of the visit has settled (the events that settle
  them precede finalization), and the ledger, stats and day counters already
  hold their effects. The finished facts stay in the log and its projections.

  Ledger accounts per restaurant are signed so the trial balance
  `cash + raw + wip + cost_of_sales + waste + capex == capital + revenue`
  holds after every event.
  """

  alias FeudHall.Domain.{Demand, Inventory, Market, Random}

  alias FeudHall.Domain.Hall.{CounterPlay, Management, SimulationUpgrade}

  @ledger %{cash: 0, raw: 0, wip: 0, cost_of_sales: 0, waste: 0, capex: 0, capital: 0, revenue: 0}

  def ledger_accounts, do: [:operating_cost | Map.keys(@ledger)]

  def evolve(nil, %{type: :hall_initialized} = e) do
    # Events recorded before the shared simulation carry no layout, seed, market, or demand.
    seed = Map.get(e, :seed, 0)
    market = Map.get(e, :market, %{})
    demand = Demand.new(e.catalog, Map.get(e, :demand, %{rng: Random.new(Random.derive(seed, "demand"))}))

    %{
      hall_id: e.hall_id,
      content_hash: e.content_hash,
      catalog: e.catalog,
      seed: seed,
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
      order_seq: 0,
      wallets: %{},
      active_visits: %{},
      stats: %{
        arrivals: 0,
        served_mains: 0,
        served_drinks: 0,
        served_desserts: 0,
        finalized_visits: 0,
        arrivals_simulated: 0,
        admitted_simulated: 0,
        left_simulated: %{}
      }
    }
  end

  # `operating`, when present, is the list recorded for the interval; without it
  # the interval credits the last recorded list (empty until one is recorded,
  # so events written before the list existed observe nothing).
  def evolve(state, %{type: :clock_advanced, to: to} = e) when to >= state.now do
    state =
      FeudHall.Domain.Hall.Population.observe(state, to - state.now, Map.get(e, :operating, state.demand.operating))

    state = FeudHall.Domain.Hall.Progression.observe_interval(state, to)
    state = Management.accrue(state, to - state.now)
    state = update_in(state, [:demand], &Demand.observe_interval(&1, e, to - state.now))
    %{state | now: to}
  end

  def evolve(state, %{type: :hall_catalog_expanded} = event),
    do: FeudHall.Domain.Hall.CatalogExpansion.evolve(state, event)

  def evolve(state, %{type: :hall_rules_retuned} = event), do: FeudHall.Domain.Hall.Retune.evolve(state, event)

  def evolve(state, %{type: :hall_simulation_upgraded} = event), do: SimulationUpgrade.evolve(state, event)

  def evolve(state, %{type: :day_closed} = e) do
    state = Map.update!(state, :demand, &Demand.close(&1, e, state.catalog))
    state |> update_in([:market, :stock], &add_stock(&1, e.replenishment)) |> Management.reset_allowances()
  end

  # A simulated arrival: the recorded draws and PRNG continuation are taken as
  # they are (replay never draws), and the arrival is counted. An admitted
  # arrival's visit follows in the same batch.
  def evolve(state, %{type: :diner_arrived} = e) do
    state
    |> Map.update!(:demand, &Demand.arrive(&1, e))
    |> Map.update!(:stats, fn stats ->
      stats = %{stats | arrivals_simulated: stats.arrivals_simulated + 1}

      case e.outcome do
        :admitted -> %{stats | admitted_simulated: stats.admitted_simulated + 1}
        :left -> %{stats | left_simulated: Map.update(stats.left_simulated, e.reason, 1, &(&1 + 1))}
      end
    end)
  end

  def evolve(state, %{type: :hall_resumed, recovery_id: id}), do: %{state | last_recovery_id: id}

  def evolve(state, %{type: :hall_cleaning_started}), do: CounterPlay.clean(%{state | access: :cleaning})
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
      mode: :closed,
      counter: nil
    })
    |> put_npc(e)
  end

  # A planning slot taken: the plan's actions follow as their own events.
  def evolve(state, %{type: :npc_planned} = e) do
    update_in(state, [:npcs, e.operator], &%{&1 | next_slot_at: e.next_slot_at, rng: e.rng})
  end

  def evolve(state, %{type: :starter_grant_issued, restaurant_id: r, amount: a}),
    do: post(state, r, cash: a, capital: a)

  def evolve(state, %{type: :stall_opened, stall_id: s}),
    do: state |> put_in([:stalls, s, :mode], :open) |> Management.opening_requested(s, true)

  def evolve(state, %{type: :stall_closed, stall_id: s} = event),
    do:
      state
      |> put_in([:stalls, s, :mode], :closed)
      |> CounterPlay.clear_location(s)
      |> Management.opening_requested(s, Map.get(event, :preserve_opening, false))

  def evolve(state, %{type: :recipe_unlocked} = e) do
    state
    |> update_in([:restaurants, e.restaurant_id, :unlocked], &(&1 ++ [e.recipe_id]))
    |> post(e.restaurant_id, cash: -e.cost, capex: e.cost)
  end

  def evolve(state, %{type: :menu_price_set, stall_id: sid} = e),
    do: put_menu_override(state, sid, e.recipe_id, e.price)

  def evolve(state, %{type: :menu_item_removed, stall_id: sid} = e),
    do: put_menu_override(state, sid, e.recipe_id, nil)

  def evolve(state, %{type: :menu_price_set} = e),
    do: put_in(state, [:restaurants, e.restaurant_id, :menu, e.recipe_id], e.price)

  def evolve(state, %{type: :menu_item_removed} = e),
    do: update_in(state, [:restaurants, e.restaurant_id, :menu], &Map.delete(&1, e.recipe_id))

  def evolve(state, %{type: :substitution_policy_set} = e) do
    update_in(state, [:restaurants, e.restaurant_id, :policies], fn policies ->
      Map.update(policies, e.recipe_id, %{e.line_id => e.policy}, &Map.put(&1, e.line_id, e.policy))
    end)
  end

  # Milestone 1 instant purchase, kept for historical replay.
  def evolve(state, %{type: :stock_purchased} = e), do: receive_stock(state, e)

  def evolve(state, %{type: :purchase_requested} = e) do
    request =
      e
      |> Map.take([:restaurant_id, :product, :qty, :max_price_per_kunit, :automated])
      |> Map.put(:submitted_at, state.now)

    Map.update!(state, :market, &Market.put_request(&1, e.request_id, request))
  end

  def evolve(state, %{type: :purchase_request_cancelled, request_id: id}) do
    Map.update!(state, :market, fn market ->
      %{restaurant_id: r, product: p} = Map.fetch!(market.requests, id)
      %{market | requests: Map.delete(market.requests, id), by_key: Map.delete(market.by_key, {r, p})}
    end)
  end

  # Every pending request is settled by the clearing: filled, unfilled, or both.
  # The next clearing instant is recorded; clearings written before it was fall
  # back to the hall's (fixed) catalog interval.
  def evolve(state, %{type: :market_cleared} = e) do
    state = Enum.reduce(e.fills, state, &receive_stock(&2, &1))

    Map.update!(state, :market, fn market ->
      %{
        market
        | stock: Market.stock_after(market, e),
          requests: %{},
          by_key: %{},
          batch: e.batch + 1,
          next_clear_at: Map.get_lazy(e, :next_clear_at, fn -> market.next_clear_at + clear_interval(state.catalog) end)
      }
    end)
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
      # Drawn for simulated arrivals; guests decide on dessert themselves.
      dessert_appetite?: Map.get(e, :dessert_appetite?, false)
    }

    state = put_in(state, [:visits, e.visit_id], visit)
    state = update_in(state, [:stats, :arrivals], &(&1 + 1))
    state = update_in(state, [:demand], &Demand.count_admitted/1)

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
      # Trays accepted before the automatic kitchen carry no estimate.
      estimated_completion: Map.get(e, :estimated_completion),
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

  def evolve(state, %{type: :stage_started, stage: :prep} = e) do
    state
    |> consume(e.order_id, e.consumed)
    |> update_in([:orders, e.order_id], &%{&1 | status: :prep, stage_done_at: e.done_at})
  end

  def evolve(state, %{type: :stage_started, stage: :finish} = e),
    do: update_in(state, [:orders, e.order_id], &%{&1 | status: :finish, stage_done_at: e.done_at})

  def evolve(state, %{type: :stage_completed, stage: :prep} = e),
    do:
      update_in(state, [:orders, e.order_id], &%{&1 | status: :queued_finish, stage_done_at: nil, queued_at: state.now})

  def evolve(state, %{type: :stage_completed, stage: :finish} = e) do
    update_in(state, [:orders, e.order_id], fn o ->
      %{o | status: :ready, stage_done_at: nil, ready_at: state.now, ready_expires_at: e.expires_at}
    end)
  end

  def evolve(state, %{type: :handover_started, item: item} = e) do
    counter = Map.merge(%{item: counter_item(item), done_at: e.done_at}, Map.take(e, [:shift_id]))
    state |> CounterPlay.consume(e) |> put_in([:stalls, e.stall_id, :counter], counter)
  end

  # Milestone 1 kitchen commands, kept for historical replay: the combined
  # preparation occupies the finishing stage until `ready_not_before`.
  def evolve(state, %{type: :preparation_started} = e) do
    state
    |> consume(e.order_id, e.consumed)
    |> update_in([:orders, e.order_id], &%{&1 | status: :finish, stage_done_at: e.ready_not_before})
  end

  def evolve(state, %{type: :preparation_completed} = e) do
    update_in(state, [:orders, e.order_id], fn o ->
      %{o | status: :ready, stage_done_at: nil, ready_at: state.now, ready_expires_at: e.expires_at}
    end)
  end

  def evolve(state, %{type: :tray_served} = e) do
    tray = state.trays[e.tray_id]

    state =
      Enum.reduce(e.components, state, fn c, acc ->
        acc
        |> serve_order(tray.restaurant, tray.visit, c)
        |> count_served(acc.orders[c.order_id].kind)
      end)

    state
    |> put_in([:trays, e.tray_id, :status], :served)
    |> Management.record_sale(tray.restaurant, state.visits[tray.visit].source)
    |> FeudHall.Domain.Hall.Progression.track_activity(tray.restaurant, state.now)
    |> update_in([:demand], &Demand.count_tray_served/1)
    |> release_counter(tray.stall, {:tray, e.tray_id})
  end

  def evolve(state, %{type: :tray_cancelled} = e) do
    tray = state.trays[e.tray_id]

    state =
      Enum.reduce(e.components, state, &cancel_order(&2, tray.restaurant, tray.visit, &1, e.reason))

    state
    |> put_in([:trays, e.tray_id, :status], :cancelled)
    |> release_counter(tray.stall, {:tray, e.tray_id})
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
      deadline: e.deadline,
      estimated_completion: Map.get(e, :estimated_completion)
    })
  end

  def evolve(state, %{type: :dessert_served} = e) do
    visit = state.visits[state.orders[e.order_id].visit]

    state
    |> serve_order(visit.restaurant, visit.id, e)
    |> count_served(:dessert)
    |> release_counter(visit.stall, {:dessert, e.order_id})
  end

  def evolve(state, %{type: :dessert_cancelled} = e) do
    visit = state.visits[state.orders[e.order_id].visit]

    state
    |> cancel_order(visit.restaurant, visit.id, e, e.reason)
    |> release_counter(visit.stall, {:dessert, e.order_id})
  end

  # The visit's one finalized outcome: its counts are taken, then it retires.
  def evolve(state, %{type: :visit_finalized} = e) do
    visit = state.visits[e.visit_id]

    state
    |> update_in([:active_visits], fn active ->
      if Map.get(active, visit.principal) == e.visit_id, do: Map.delete(active, visit.principal), else: active
    end)
    |> update_in([:stats, :finalized_visits], &(&1 + 1))
    |> update_in([:demand], &Demand.count_finalized(&1, e))
    |> FeudHall.Domain.Hall.Recognition.observe(visit, e)
    |> retire_visit(visit)
  end

  # -- helpers -------------------------------------------------------------

  # Removes a finalized visit with its tray and every order it holds (tray
  # components and dessert). Nothing live refers to them any more: their
  # reservations, funding, counter claims and costs settled before
  # finalization, and the finalization event records their outcomes.
  def evolve(state, %{type: type} = event)
      when type in [:npc_population_changed, :npc_retirement_scheduled, :npc_retirement_finished],
      do: FeudHall.Domain.Hall.Population.evolve(state, event)

  def evolve(state, %{type: type} = event) when type in [:award_reviewed, :milestone_earned],
    do: FeudHall.Domain.Hall.Recognition.evolve(state, event)

  def evolve(state, %{type: type} = event) when type in [:location_equipped, :equipment_salvaged],
    do: FeudHall.Domain.Hall.Equipment.evolve(state, event)

  def evolve(state, %{type: type} = event)
      when type in [:visitor_play_enabled, :counter_staging_started, :counter_staging_completed, :staging_yielded],
      do: CounterPlay.evolve(state, event)

  @progression_events ~w(location_added location_refitted location_released distress_started distress_cleared venture_activity_recorded
                          stock_salvaged business_bankrupted)a
  def evolve(state, %{type: type} = event) when type in @progression_events,
    do: FeudHall.Domain.Hall.Progression.evolve(state, event)

  @management_events ~w(stall_opening_queued business_day_reviewed restock_policy_set pricing_policy_set restock_budget_reserved pricing_policy_applied
    visitor_allowance_claimed management_started stall_leased staff_condition_changed worker_hired worker_scheduled worker_dismissed stall_draft_reserved stall_draft_released waitlist_joined waitlist_left staff_schedule_set helper_offer_policy_set
    owner_presence_recorded unattended_policy_set operating_costs_charged helper_shift_started helper_shift_ended helper_presence_recorded
    helper_selection_opened helper_choice_selected helper_selection_closed helper_task_completed management_hour_closed management_resumed)a

  def evolve(state, %{type: type} = event) when type in @management_events, do: Management.evolve(state, event)

  defp retire_visit(state, visit) do
    tray = visit.tray && state.trays[visit.tray]
    order_ids = if(tray, do: tray.components, else: []) ++ List.wrap(visit.dessert_order)

    %{
      state
      | visits: Map.delete(state.visits, visit.id),
        trays: if(tray, do: Map.delete(state.trays, tray.id), else: state.trays),
        orders: Map.drop(state.orders, order_ids)
    }
  end

  # An NPC operator's planning record is recorded with its restaurant.
  defp put_npc(state, %{owner_kind: :npc, npc: npc} = e) do
    record = %{restaurant_id: e.restaurant_id, profile_id: npc.profile_id, next_slot_at: npc.next_slot_at, rng: npc.rng}
    put_in(state, [:npcs, e.owner], record)
  end

  defp put_npc(state, _e), do: state

  # A new order joins its stall's prep queue. Its stage durations are bound
  # from the accepted quote; events written before they were recorded fall
  # back to the hall's (fixed) catalog recipe.
  defp accept_order(state, c, e) do
    recipe = state.catalog.recipes[c.recipe_id]

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
      estimated_completion: Map.get(e, :estimated_completion),
      consumed_cost: 0,
      prep_ms: Map.get(c, :prep_ms, recipe.prep_ms),
      finish_ms: Map.get(c, :finish_ms, recipe.finish_ms),
      seq: state.order_seq,
      queued_at: state.now,
      stage_done_at: nil,
      ready_at: nil,
      ready_expires_at: nil,
      cancel_reason: nil,
      status: :queued_prep
    }

    rid = e.restaurant_id
    carbs = c.carbs_mg || 0

    state
    |> put_in([:orders, c.order_id], order)
    |> Map.update!(:order_seq, &(&1 + 1))
    |> update_in([:restaurants, rid, :batches], &Inventory.adjust_reserved(&1, c.reservations, 1))
    |> reserve_funding(e.visit_id, c.funding, c.price)
    |> update_in([:visits, e.visit_id, :carbs_reserved], &(&1 + carbs))
  end

  # Moves an order's reserved units into work in progress at their recorded cost.
  defp consume(state, order_id, consumed) do
    rid = state.visits[state.orders[order_id].visit].restaurant
    consumed_cost = consumed |> Enum.map(& &1.cost) |> Enum.sum()

    state
    |> update_in([:restaurants, rid, :batches], fn batches ->
      batches = Enum.reduce(consumed, batches, &consume_batch(&2, &1))
      batches |> Enum.reject(fn {_, b} -> b.qty == 0 end) |> Map.new()
    end)
    |> post(rid, raw: -consumed_cost, wip: consumed_cost)
    |> update_in([:orders, order_id], &%{&1 | reservations: [], consumed_cost: consumed_cost})
  end

  # A purchased or filled lot enters the warehouse at its recorded cost.
  defp put_menu_override(state, sid, recipe_id, value) do
    update_in(state.stalls[sid], fn stall ->
      Map.update(stall, :menu_overrides, %{recipe_id => value}, &Map.put(&1, recipe_id, value))
    end)
  end

  defp receive_stock(state, e) do
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

  defp counter_item(%{kind: :tray, id: id}), do: {:tray, id}
  defp counter_item(%{kind: :dessert, id: id}), do: {:dessert, id}

  # A settled item leaves the counter if it was being handed over.
  defp release_counter(state, stall_id, item) do
    case state.stalls[stall_id] do
      %{counter: %{item: ^item}} -> put_in(state, [:stalls, stall_id, :counter], nil)
      _ -> state
    end
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
    |> update_in([:orders, c.order_id], fn order ->
      order = %{order | status: :served}
      if Map.has_key?(state, :progression), do: Map.put(order, :served_at, state.now), else: order
    end)
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

  defp add_stock(stock, additions),
    do: Enum.reduce(additions, stock, fn {product, qty}, acc -> Map.update(acc, product, qty, &(&1 + qty)) end)

  defp clear_interval(catalog), do: get_in(catalog, [:rules, :market, :clear_every_hall_ms]) || 0

  defp post(state, rid, postings) do
    update_in(state, [:restaurants, rid, :ledger], fn ledger ->
      Enum.reduce(postings, ledger, fn {account, amount}, acc -> Map.update!(acc, account, &(&1 + amount)) end)
    end)
  end
end
