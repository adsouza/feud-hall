defmodule FeudHall.Oracle do
  @moduledoc """
  Test-only independent settled-state and accounting oracle.

  It recomputes resource and value totals from batches, orders, wallets, and
  the raw event stream, instead of trusting the ledger or calling the
  implementation's own helpers. Each check returns a list of violations so a
  property failure names the broken invariant.

  It never calls the modules it checks (`Market`, `Demand`, `Choice`,
  `Kitchen`, `Planner`, the decider or the evolver); only the calendar
  (`Clock`) is shared. Live state holds only unfinished work (a visit, its
  tray and its orders leave it when the visit finalizes), so facts about
  finished visits are checked from the events alone. Checked: per-restaurant
  accounting (trial balance, cost classified once, cash/revenue/cost of sales
  from events), live order, visit and wallet consistency, station capacity
  and counter contents,
  stage queues (stage fields, FIFO by `{queued_at, seq}`, no idle station or
  counter while older work waits), the hall's counters and visitor fund, and,
  over a log starting at genesis: market conservation (opening stock +
  replenishments = fills + stock; every request settled exactly and filled
  within its limit; pending requests agree), arrival accounting by source
  (stream, command-admitted simulated, guest) and by leaving reason, and NPC
  planning-slot monotonicity, and visit lifecycles (each visit admitted once
  and finalized at most once, only after all its courses settled, with
  outcomes matching their settlement; the live visits, trays and orders are
  exactly those of unfinalized visits; served mains and finalizations agree
  with the stats).
  """

  @doc "All violations for a hall state and the events that produced it."
  def violations(nil, _events), do: []

  # Live work stages of a component order (then :served or :cancelled).
  @live [:queued_prep, :prep, :queued_finish, :finish, :ready]
  # Stages past the prep queue: their ingredients were consumed into work in progress.
  @consumed [:prep, :queued_finish, :finish, :ready]

  def violations(state, events) do
    Enum.flat_map(state.restaurants, fn {rid, r} -> restaurant(state, rid, r, events) end) ++
      orders(state) ++
      visits(state) ++
      wallets(state) ++
      kitchens(state) ++
      stage_queues(state) ++
      hall(state, events) ++
      market(state, events) ++ arrivals(state, events) ++ lifecycles(state, events) ++ npcs(state, events)
  end

  def assert_settled!(state, events) do
    case violations(state, events) do
      [] ->
        :ok

      problems ->
        raise ExUnit.AssertionError, message: "invariants violated:\n" <> Enum.map_join(problems, "\n", &inspect/1)
    end
  end

  defp restaurant(state, rid, r, events) do
    l = r.ledger
    my_orders = state.orders |> Map.values() |> Enum.filter(&(get_in(state, [:visits, &1.visit, :restaurant]) == rid))

    raw_from_batches = r.batches |> Map.values() |> Enum.map(& &1.cost) |> Enum.sum()

    wip_from_orders =
      my_orders |> Enum.filter(&(&1.status in @consumed)) |> Enum.map(& &1.consumed_cost) |> Enum.sum()

    t = event_totals(events, rid)

    reserved_by_batch =
      my_orders
      |> Enum.filter(&(&1.status == :queued_prep))
      |> Enum.flat_map(& &1.reservations)
      |> Enum.reduce(%{}, fn c, acc -> Map.update(acc, c.batch_id, c.qty, &(&1 + c.qty)) end)

    checks = [
      {l.cash + l.raw + l.wip + l.cost_of_sales + l.waste + l.capex == l.capital + l.revenue, :trial_balance},
      {l.cash >= 0, :negative_cash},
      {l.raw == raw_from_batches, {:raw_ledger_mismatch, l.raw, raw_from_batches}},
      {l.wip == wip_from_orders, {:wip_ledger_mismatch, l.wip, wip_from_orders}},
      # Every unit of purchase cost is classified exactly once.
      {t.purchased == raw_from_batches + wip_from_orders + t.served_cost + t.waste, {:cost_not_classified_once, t}},
      {l.cash == t.granted - t.purchased - t.unlocked + t.revenue, {:cash_from_events, l.cash, t}},
      {l.revenue == t.revenue, :revenue_from_events},
      {l.cost_of_sales == t.served_cost, :cost_of_sales_from_events}
    ]

    batch_checks =
      Enum.flat_map(r.batches, fn {bid, b} ->
        [
          {b.qty > 0, {:empty_batch_retained, bid}},
          {b.reserved >= 0 and b.reserved <= b.qty, {:reservation_out_of_range, bid}},
          {b.reserved == Map.get(reserved_by_batch, bid, 0), {:stranded_reservation, bid}},
          {b.cost >= 0, {:negative_batch_cost, bid}}
        ]
      end)

    orphan_claims =
      for {bid, _} <- reserved_by_batch, not Map.has_key?(r.batches, bid), do: {false, {:claim_on_missing_batch, bid}}

    for {false, problem} <- checks ++ batch_checks ++ orphan_claims, do: {rid, problem}
  end

  # Totals read directly from facts, never from derived state. Settled orders
  # may have left state with their visits, so each order's restaurant is the
  # one its acceptance recorded (a dessert's is its visit's).
  defp event_totals(events, rid) do
    zero = %{granted: 0, purchased: 0, unlocked: 0, revenue: 0, served_cost: 0, waste: 0}

    {t, _owners} =
      Enum.reduce(events, {zero, %{visits: %{}, orders: %{}}}, fn e, {t, owners} ->
        mine? = &(Map.get(owners.orders, &1.order_id) == rid)

        case e do
          %{type: :visit_admitted} -> {t, put_in(owners, [:visits, e.visit_id], e.restaurant_id)}
          %{type: :tray_accepted} -> {t, own(owners, e.components, e.restaurant_id)}
          %{type: :dessert_accepted} -> {t, own(owners, [e.order], owners.visits[e.visit_id])}
          %{type: :starter_grant_issued, restaurant_id: ^rid, amount: a} -> {%{t | granted: t.granted + a}, owners}
          %{type: :stock_purchased, restaurant_id: ^rid, cost: c} -> {%{t | purchased: t.purchased + c}, owners}
          %{type: :market_cleared, fills: fs} -> {%{t | purchased: t.purchased + fill_cost(fs, rid)}, owners}
          %{type: :recipe_unlocked, restaurant_id: ^rid, cost: c} -> {%{t | unlocked: t.unlocked + c}, owners}
          %{type: :stock_spoiled, restaurant_id: ^rid, cost: c} -> {%{t | waste: t.waste + c}, owners}
          %{type: :tray_served, components: cs} -> {sum_served(t, Enum.filter(cs, mine?)), owners}
          %{type: :dessert_served} = c -> {sum_served(t, Enum.filter([c], mine?)), owners}
          %{type: :tray_cancelled, components: cs} -> {sum_waste(t, Enum.filter(cs, mine?)), owners}
          %{type: :dessert_cancelled} = c -> {sum_waste(t, Enum.filter([c], mine?)), owners}
          _ -> {t, owners}
        end
      end)

    t
  end

  defp own(owners, components, rid),
    do: Enum.reduce(components, owners, &put_in(&2, [:orders, &1.order_id], rid))

  defp fill_cost(fills, rid), do: fills |> Enum.filter(&(&1.restaurant_id == rid)) |> Enum.map(& &1.cost) |> Enum.sum()

  defp sum_served(t, cs),
    do: Enum.reduce(cs, t, &%{&2 | revenue: &2.revenue + &1.price, served_cost: &2.served_cost + &1.cost})

  defp sum_waste(t, cs), do: Enum.reduce(cs, t, &%{&2 | waste: &2.waste + &1.waste_cost})

  defp orders(state) do
    Enum.flat_map(state.orders, fn {oid, o} ->
      tray = o.tray && state.trays[o.tray]

      [
        {o.status == :queued_prep or o.reservations == [], {:claims_after_preparation, oid}},
        {o.status != :queued_prep or o.consumed_cost == 0, {:cost_before_preparation, oid}},
        {o.status not in [:prep, :finish] or (is_integer(o.stage_done_at) and o.stage_done_at > state.now),
         {:stage_overdue, oid}},
        {o.status != :ready or (o.ready_at <= state.now and state.now < o.ready_expires_at), {:stale_ready_food, oid}},
        {tray == nil or tray_consistent?(tray, o), {:tray_component_mismatch, oid}},
        {o.kind != :dessert or o.tray == nil, {:dessert_in_tray, oid}},
        {o.kind == :dessert or o.tray != nil, {:course_outside_tray, oid}},
        {Map.has_key?(state.visits, o.visit), {:order_without_visit, oid}},
        {state.access == :open or o.status in [:served, :cancelled], {:active_order_during_cleaning, oid}}
      ]
      |> failures()
    end)
  end

  defp tray_consistent?(%{status: :accepted}, o), do: o.status in @live
  defp tray_consistent?(%{status: :served}, o), do: o.status == :served
  defp tray_consistent?(%{status: :cancelled}, o), do: o.status == :cancelled

  # Live visits only: a visit leaves state when it finalizes, so each one here
  # still has unfinished work (a live course or an open dessert offer).
  defp visits(state) do
    by_visit = state.orders |> Map.values() |> Enum.group_by(& &1.visit)

    held =
      for {who, vid} <- state.active_visits,
          not match?(%{source: :guest, principal: ^who}, Map.get(state.visits, vid)),
          do: {:dangling_active_visit, who}

    held ++
      Enum.flat_map(state.visits, fn {vid, v} ->
        os = Map.get(by_visit, vid, [])
        active = Enum.filter(os, &(&1.status in @live))
        served = Enum.filter(os, &(&1.status == :served))
        count = fn kind -> Enum.count(os, &(&1.kind == kind)) end
        carb = fn list -> list |> Enum.map(&(&1.carbs_mg || 0)) |> Enum.sum() end
        ceiling = v.requirement.carb_ceiling_mg

        [
          {count.(:main) == 1, {:main_count, vid}},
          {count.(:drink) <= 1, {:drink_count, vid}},
          {count.(:dessert) <= 1, {:dessert_count, vid}},
          {v.carbs_reserved == carb.(active), {:carbs_reserved_mismatch, vid}},
          {v.carbs_served == carb.(served), {:carbs_served_mismatch, vid}},
          {ceiling == nil or v.carbs_reserved + v.carbs_served <= ceiling, {:carb_ceiling_exceeded, vid}},
          {active != [] or v.dessert == :offered, {:stranded_active_visit, vid}},
          {v.dessert != :offered or state.access == :open, {:offer_during_cleaning, vid}},
          {v.source != :simulated or v.budget_committed <= v.budget, {:over_budget, vid}},
          {v.source != :simulated or
             v.budget_committed == os |> Enum.reject(&(&1.status == :cancelled)) |> Enum.map(& &1.price) |> Enum.sum(),
           {:budget_commitment_mismatch, vid}},
          {v.source != :guest or state.active_visits[v.principal] == vid, {:untracked_active_guest_visit, vid}},
          {v.dessert != :accepted or count.(:dessert) == 1, {:dessert_slot_mismatch, vid}}
        ]
        |> failures()
      end)
  end

  defp wallets(state) do
    by_slice =
      state.orders
      |> Map.values()
      |> Enum.filter(&(&1.status in @live))
      |> Enum.flat_map(& &1.funding)
      |> Enum.reduce(%{}, fn f, acc -> Map.update(acc, f.slice_id, f.amount, &(&1 + f.amount)) end)

    Enum.flat_map(state.wallets, fn {who, w} ->
      Enum.flat_map(w.slices, fn {sid, s} ->
        [
          {s.reserved >= 0 and s.reserved <= s.amount, {:slice_out_of_range, who, sid}},
          {s.reserved == Map.get(by_slice, sid, 0), {:slice_reservation_mismatch, who, sid}}
        ]
        |> failures()
      end)
    end)
  end

  # Station capacity per stall, and the counter holds one live item whose
  # components are all ready and whose handover is still running.
  defp kitchens(state) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    by_stall = state.orders |> Map.values() |> Enum.group_by(&get_in(state, [:visits, &1.visit, :stall]))

    Enum.flat_map(state.stalls, fn {sid, stall} ->
      os = Map.get(by_stall, sid, [])
      count = fn status -> Enum.count(os, &(&1.status == status)) end

      counter =
        case stall.counter do
          nil ->
            true

          %{item: item, done_at: done_at} ->
            items = Enum.filter(os, &(item_of(&1) == item))
            done_at > state.now and items != [] and Enum.all?(items, &(&1.status == :ready))
        end

      [
        {count.(:prep) <= prep_n, {:prep_over_capacity, sid}},
        {count.(:finish) <= finish_n, {:finish_over_capacity, sid}},
        {counter, {:bad_counter, sid}}
      ]
      |> failures()
    end)
  end

  # Stage queues, restated over order statuses (a live order's status is its
  # stage; queues are derived). Per stall, while customer access is open:
  #
  #   * stage fields fit the stage: waiting orders hold no station deadline,
  #     ready ones a ready time not after the clock, and no unready order has one;
  #   * FIFO: each station was given to the head of its queue by
  #     `{queued_at, seq}`, so every order at a station sorts before every order
  #     still waiting in that stage's queue (for finishing, `queued_at` is the
  #     prep completion);
  #   * no idle station while older work waits: work queued before the clock's
  #     current instant was seen by an advance, which starts it when a station
  #     is free, so such work means every station of its stage is busy;
  #   * likewise the counter takes an item that became ready before now.
  defp stage_queues(%{access: :open} = state) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    live = state.orders |> Map.values() |> Enum.filter(&(&1.status in @live))
    by_stall = Enum.group_by(live, &get_in(state, [:visits, &1.visit, :stall]))

    fields =
      Enum.flat_map(live, fn o ->
        failures([
          {o.status not in [:queued_prep, :queued_finish] or o.stage_done_at == nil, {:waiting_with_deadline, o.id}},
          {o.status == :ready == (o.ready_at != nil), {:ready_time_mismatch, o.id}},
          {o.ready_at == nil or o.ready_at <= state.now, {:ready_in_future, o.id}},
          {o.queued_at <= state.now, {:queued_in_future, o.id}}
        ])
      end)

    fields ++
      Enum.flat_map(by_stall, fn {sid, os} ->
        stage = fn status -> Enum.filter(os, &(&1.status == status)) end
        key = &{&1.queued_at, &1.seq}

        fifo = fn working, waiting ->
          working == [] or waiting == [] or
            Enum.max(Enum.map(working, key)) < Enum.min(Enum.map(waiting, key))
        end

        idle = fn waiting, working, n -> Enum.all?(waiting, &(&1.queued_at == state.now)) or length(working) == n end
        counter = state.stalls[sid].counter

        stale_ready =
          os
          |> Enum.group_by(&item_of/1)
          |> Enum.any?(fn {_item, cs} -> Enum.all?(cs, &(&1.status == :ready and &1.ready_at < state.now)) end)

        failures([
          {fifo.(stage.(:prep), stage.(:queued_prep)), {:prep_not_fifo, sid}},
          {fifo.(stage.(:finish), stage.(:queued_finish)), {:finish_not_fifo, sid}},
          {idle.(stage.(:queued_prep), stage.(:prep), prep_n), {:prep_station_idle, sid}},
          {idle.(stage.(:queued_finish), stage.(:finish), finish_n), {:finish_station_idle, sid}},
          {counter != nil or not stale_ready, {:counter_idle, sid}}
        ])
      end)
  end

  defp stage_queues(_state), do: []

  defp item_of(%{kind: :dessert, id: id}), do: {:dessert, id}
  defp item_of(%{tray: tray}), do: {:tray, tray}

  # The visit counts here read the state alone: every admitted visit is either
  # finalized or still live. Per-visit facts are checked from the events in
  # `lifecycles/2`.
  defp hall(state, events) do
    granted = for(%{type: :allowance_granted, amount: a} <- events, do: a) |> Enum.sum()
    initial = state.catalog.rules.visitor_fund

    [
      # The event-sourced gate must agree with the calendar definition.
      {state.access == :cleaning == FeudHall.Domain.Clock.cleaning?(state.now), {:access_gate_mismatch, state.now}},
      {state.visitor_fund + granted == initial, :visitor_fund_not_conserved},
      {state.stats.arrivals == state.stats.finalized_visits + map_size(state.visits), :live_visit_count}
    ]
    |> failures()
  end

  # Visit lifecycles, from the facts alone, over a log starting at genesis: each
  # visit ID is admitted once; courses are accepted, settled and offered only
  # while their visit is live, each order ID once; a visit finalizes once, only
  # after every course it accepted has settled, naming exactly those courses
  # with outcomes matching how each settled (served ones scored, cancelled ones
  # failed or exempt). The state's visits, trays and orders are exactly those
  # of the visits not yet finalized, and the hall's counts of admitted and
  # finalized visits and served mains agree with the facts.
  defp lifecycles(state, [%{type: :hall_initialized} | _] = events) do
    zero = %{visits: %{}, orders: %{}, trays: %{}, admitted: 0, finalized: 0, served_mains: 0, problems: []}

    t =
      Enum.reduce(events, zero, fn e, t ->
        case e do
          %{type: :visit_admitted, visit_id: vid} ->
            t
            |> check([{not Map.has_key?(t.visits, vid), {:visit_id_reused, vid}}])
            |> Map.update!(:visits, &Map.put(&1, vid, %{orders: [], tray: nil, finalized: false}))
            |> Map.update!(:admitted, &(&1 + 1))

          %{type: :tray_accepted, visit_id: vid} ->
            t
            |> accept(vid, e.components)
            |> put_in([:trays, e.tray_id], vid)
            |> update_in([:visits, vid], &(&1 && %{&1 | tray: e.tray_id}))

          %{type: :dessert_accepted, visit_id: vid} ->
            accept(t, vid, [e.order])

          %{type: :tray_served, components: cs} ->
            served_mains = Enum.count(cs, &(get_in(t, [:orders, &1.order_id, :kind]) == :main))
            %{settle(t, cs, :served) | served_mains: t.served_mains + served_mains}

          %{type: :dessert_served} ->
            settle(t, [e], :served)

          %{type: type} when type in [:tray_cancelled, :dessert_cancelled] ->
            settle(t, Map.get(e, :components, [e]), :cancelled)

          %{type: type, visit_id: vid} when type in [:dessert_offered, :dessert_declined] ->
            check(t, [{live_visit?(t, vid), {:work_after_finalization, vid}}])

          %{type: :visit_finalized, visit_id: vid} ->
            finalize(t, vid, e)

          _ ->
            t
        end
      end)

    live = for {vid, %{finalized: false}} <- t.visits, into: MapSet.new(), do: vid
    live_orders = for {oid, o} <- t.orders, MapSet.member?(live, o.visit), into: MapSet.new(), do: oid
    live_trays = for {tid, vid} <- t.trays, MapSet.member?(live, vid), into: MapSet.new(), do: tid
    keys = &(&1 |> Map.keys() |> MapSet.new())

    t.problems ++
      failures([
        {state.stats.arrivals == t.admitted, :arrival_count},
        {state.stats.finalized_visits == t.finalized, :finalized_count},
        {state.stats.served_mains == t.served_mains, :served_main_count},
        {keys.(state.visits) == live, :live_visits_mismatch},
        {keys.(state.trays) == live_trays, :live_trays_mismatch},
        {keys.(state.orders) == live_orders, :live_orders_mismatch}
      ])
  end

  defp lifecycles(_state, _events), do: []

  defp check(t, checks), do: %{t | problems: t.problems ++ failures(checks)}

  defp live_visit?(t, vid), do: match?(%{finalized: false}, t.visits[vid])

  defp accept(t, vid, components) do
    Enum.reduce(components, check(t, [{live_visit?(t, vid), {:work_after_finalization, vid}}]), fn c, t ->
      t
      |> check([{not Map.has_key?(t.orders, c.order_id), {:order_id_reused, c.order_id}}])
      |> put_in([:orders, c.order_id], %{visit: vid, kind: c.kind, settled: nil})
      |> update_in([:visits, vid], &(&1 && %{&1 | orders: &1.orders ++ [c.order_id]}))
    end)
  end

  defp settle(t, components, how) do
    Enum.reduce(components, t, fn %{order_id: oid}, t ->
      order = t.orders[oid]

      t
      |> check([
        {match?(%{settled: nil}, order), {:order_settled_twice, oid}},
        {order != nil and live_visit?(t, order.visit), {:settled_outside_live_visit, oid}}
      ])
      |> then(&if(order, do: put_in(&1, [:orders, oid, :settled], how), else: &1))
    end)
  end

  defp finalize(t, vid, e) do
    visit = t.visits[vid]
    orders = if visit, do: visit.orders, else: []
    settled = Enum.map(orders, &t.orders[&1].settled)

    outcomes_match? =
      Enum.map(e.components, & &1.order_id) == orders and
        Enum.all?(e.components, fn c ->
          t.orders[c.order_id].settled == :served == (c.outcome == :served)
        end)

    t
    |> check([
      {visit != nil, {:finalized_unknown_visit, vid}},
      {visit == nil or not visit.finalized, :visit_finalized_more_than_once},
      {Enum.all?(settled, &(&1 != nil)), {:finalized_with_open_work, vid}},
      {visit == nil or outcomes_match?, {:finalized_outcome_mismatch, vid}}
    ])
    |> then(&if(visit, do: put_in(&1, [:visits, vid, :finalized], true), else: &1))
    |> Map.update!(:finalized, &(&1 + 1))
  end

  # Market conservation, replayed from the facts alone: the opening stock, plus
  # every midnight replenishment, less every fill in order (never driving a
  # product below zero), is the market's stock now. Pending requests are
  # those submitted and neither replaced (a later request for the same
  # restaurant and product), cancelled, nor settled by a later clearing; each
  # clearing settles exactly the requests pending at it, fill + unfilled =
  # requested for each, and a fill is for its request's restaurant and
  # product at a recorded price within its limit. The requests still pending
  # match the market's by ID, restaurant, product, quantity, and limit.
  # Only checked over a log that starts at genesis; that genesis must carry
  # the opening stock.
  defp market(state, [%{type: :hall_initialized} = genesis | _] = events) do
    case get_in(genesis, [:market, :stock]) do
      %{} = opening -> market_from(state, opening, events)
      _ -> [:genesis_without_market_stock]
    end
  end

  defp market(_state, _events), do: []

  defp market_from(state, opening, events) do
    {stock, pending, problems} =
      Enum.reduce(events, {opening, %{}, []}, fn e, {stock, pending, problems} ->
        case e do
          %{type: :purchase_requested} ->
            key = {e.restaurant_id, e.product}
            replaced = Enum.find_value(pending, fn {id, r} -> if {r.restaurant_id, r.product} == key, do: id end)
            request = Map.take(e, [:restaurant_id, :product, :qty, :max_price_per_kunit])
            pending = pending |> Map.delete(replaced) |> Map.put(e.request_id, request)
            new = failures([{e.replaces == replaced, {:wrong_replaced_request, e.request_id}}])
            {stock, pending, problems ++ new}

          %{type: :purchase_request_cancelled, request_id: id} ->
            new = failures([{Map.has_key?(pending, id), {:cancelled_unknown_request, id}}])
            {stock, Map.delete(pending, id), problems ++ new}

          %{type: :day_closed, replenishment: added} ->
            stock = Enum.reduce(added, stock, fn {product, qty}, s -> Map.update(s, product, qty, &(&1 + qty)) end)
            {stock, pending, problems}

          %{type: :market_cleared, fills: fills, unfilled: unfilled} ->
            stock = Enum.reduce(fills, stock, fn f, s -> Map.update(s, f.product, -f.qty, &(&1 - f.qty)) end)

            settled =
              Enum.reduce(fills ++ unfilled, %{}, fn x, acc -> Map.update(acc, x.request_id, x.qty, &(&1 + x.qty)) end)

            fill_checks =
              Enum.map(fills, fn f ->
                r = pending[f.request_id]

                {r != nil and r.restaurant_id == f.restaurant_id and r.product == f.product and
                   Map.fetch!(e.prices, f.product) <= r.max_price_per_kunit, {:fill_outside_request, f.request_id}}
              end)

            new =
              [
                {Enum.all?(stock, fn {_, q} -> q >= 0 end), {:market_oversold, e.batch}},
                {Enum.all?(Map.keys(settled), &Map.has_key?(pending, &1)), {:settled_unknown_request, e.batch}},
                {Enum.all?(pending, fn {id, r} -> Map.get(settled, id, 0) == r.qty end),
                 {:request_not_settled_exactly, e.batch}}
                | fill_checks
              ]
              |> failures()

            {stock, %{}, problems ++ new}

          _ ->
            {stock, pending, problems}
        end
      end)

    conservation =
      for product <- Enum.uniq(Map.keys(stock) ++ Map.keys(state.market.stock)),
          Map.get(stock, product, 0) != Map.get(state.market.stock, product, 0),
          do: {:market_stock_not_conserved, product}

    held =
      Map.new(state.market.requests, fn {id, r} ->
        {id, Map.take(r, [:restaurant_id, :product, :qty, :max_price_per_kunit])}
      end)

    pending_check = if pending == held, do: [], else: [:pending_requests_mismatch]

    problems ++ conservation ++ pending_check
  end

  # Arrival accounting, counted from the facts alone, by source and by reason.
  # Every stream arrival either opened its visit (the next event admits
  # `"V:" <> arrival_id` as a simulated visit) or left with a reason; none fell
  # during cleaning. Admissions are split by source: stream arrivals,
  # simulated visits admitted by command, and guests. The hall's stats agree
  # with the facts per source (stream arrivals, stream admissions, leavers per
  # reason, and all visits) and partition the stream arrivals; each visit's
  # source matches its admission (for the visits still live). Only checked over
  # a log that starts at genesis.
  defp arrivals(state, [%{type: :hall_initialized} | _] = events) do
    zero = %{
      now: 0,
      arrivals: 0,
      left: %{},
      ids: MapSet.new(),
      admitted: %{},
      sources: %{},
      finalized: MapSet.new(),
      problems: []
    }

    t =
      events
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.reduce({zero, nil}, fn
        [%{type: :clock_advanced, to: to}, _next], {t, _arrival} ->
          {%{t | now: to}, nil}

        [%{type: :diner_arrived} = e, next], {t, _arrival} ->
          admitted? = e.outcome == :admitted

          checks = [
            {not MapSet.member?(t.ids, e.arrival_id), {:duplicate_arrival, e.arrival_id}},
            {not FeudHall.Domain.Clock.cleaning?(t.now), {:arrival_during_cleaning, e.arrival_id}},
            {admitted? == match?(%{type: :visit_admitted, source: :simulated}, next) and
               (not admitted? or next.visit_id == "V:" <> e.arrival_id), {:arrival_outcome_mismatch, e.arrival_id}},
            {admitted? or (e.outcome == :left and is_atom(e.reason) and e.reason != nil),
             {:arrival_without_reason, e.arrival_id}}
          ]

          left = if admitted?, do: t.left, else: Map.update(t.left, e.reason, 1, &(&1 + 1))

          t = %{
            t
            | arrivals: t.arrivals + 1,
              left: left,
              ids: MapSet.put(t.ids, e.arrival_id),
              problems: t.problems ++ failures(checks)
          }

          {t, if(admitted?, do: e.arrival_id)}

        [%{type: :visit_finalized, visit_id: vid}, _next], {t, _arrival} ->
          {%{t | finalized: MapSet.put(t.finalized, vid)}, nil}

        [%{type: :visit_admitted} = e, _next], {t, arrival} ->
          origin =
            cond do
              e.source == :guest -> :guest
              arrival != nil and e.visit_id == "V:" <> arrival -> :stream
              true -> :simulated_command
            end

          t = %{
            t
            | sources: Map.put(t.sources, e.visit_id, e.source),
              admitted: Map.update(t.admitted, origin, 1, &(&1 + 1))
          }

          {t, nil}

        _other, {t, _arrival} ->
          {t, nil}
      end)
      |> elem(0)

    # Finished visits have left state: the live ones carry the sources their
    # admissions recorded, and the recorded sources partition the admissions.
    visit_sources = Map.new(state.visits, fn {id, v} -> {id, v.source} end)
    live_sources = Map.drop(t.sources, MapSet.to_list(t.finalized))
    by_source = t.sources |> Map.values() |> Enum.frequencies()
    stats = state.stats
    admitted = fn origin -> Map.get(t.admitted, origin, 0) end

    t.problems ++
      failures([
        {stats.arrivals_simulated == t.arrivals, :simulated_arrival_count},
        {stats.admitted_simulated == admitted.(:stream), :simulated_admitted_count},
        {stats.left_simulated == t.left, :simulated_left_count},
        {stats.arrivals_simulated == stats.admitted_simulated + Enum.sum(Map.values(stats.left_simulated)),
         :simulated_stats_not_partitioned},
        {stats.arrivals == Enum.sum(Map.values(t.admitted)), :admission_count},
        {Map.get(by_source, :simulated, 0) == admitted.(:stream) + admitted.(:simulated_command),
         :simulated_visit_count},
        {Map.get(by_source, :guest, 0) == admitted.(:guest), :guest_visit_count},
        {visit_sources == live_sources, :visit_sources_mismatch}
      ])
  end

  defp arrivals(_state, _events), do: []

  # NPC planning slots, from the facts: each operator's restaurant was created
  # for it with a first slot on a whole hour; its plans are for strictly
  # increasing whole-hour slots, none before its next slot or after the clock
  # reached when it was planned, each moving the next slot one hour past it;
  # and the hall's record holds the last plan's next slot and PRNG state.
  defp npcs(state, [%{type: :hall_initialized} | _] = events) do
    hour = FeudHall.Domain.Clock.hour()

    {records, problems, _now} =
      Enum.reduce(events, {%{}, [], 0}, fn
        %{type: :clock_advanced, to: to}, {records, problems, _now} ->
          {records, problems, to}

        %{type: :restaurant_created, owner_kind: :npc, npc: npc} = e, {records, problems, now} ->
          record = %{restaurant_id: e.restaurant_id, next_slot_at: npc.next_slot_at, rng: npc.rng}

          new =
            failures([
              {not Map.has_key?(records, e.owner), {:npc_created_twice, e.owner}},
              {npc.next_slot_at > now and rem(npc.next_slot_at, hour) == 0, {:bad_first_npc_slot, e.owner}}
            ])

          {Map.put(records, e.owner, record), problems ++ new, now}

        %{type: :npc_planned, operator: op} = e, {records, problems, now} ->
          record = records[op]

          new =
            failures([
              {record != nil, {:plan_without_npc, op}},
              {record == nil or e.slot >= record.next_slot_at, {:npc_slot_not_monotonic, op, e.slot}},
              {rem(e.slot, hour) == 0 and e.slot <= now, {:npc_slot_out_of_range, op, e.slot}},
              {e.next_slot_at == e.slot + hour, {:npc_next_slot_mismatch, op, e.slot}}
            ])

          records =
            if record, do: Map.put(records, op, %{record | next_slot_at: e.next_slot_at, rng: e.rng}), else: records

          {records, problems ++ new, now}

        _other, acc ->
          acc
      end)

    held = Map.new(state.npcs, fn {op, npc} -> {op, Map.take(npc, [:restaurant_id, :next_slot_at, :rng])} end)
    problems ++ if(held == records, do: [], else: [:npc_records_mismatch])
  end

  defp npcs(_state, _events), do: []

  defp failures(checks), do: for({false, problem} <- checks, do: problem)
end
