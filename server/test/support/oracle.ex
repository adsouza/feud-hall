defmodule FeudHall.Oracle do
  @moduledoc """
  Test-only independent settled-state and accounting oracle.

  It recomputes resource and value totals from batches, orders, wallets, and
  the raw event stream, instead of trusting the ledger or calling the
  implementation's own helpers. Each check returns a list of violations so a
  property failure names the broken invariant.
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
      visits(state) ++ wallets(state) ++ kitchens(state) ++ hall(state, events) ++ market(state, events)
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
    my_orders = state.orders |> Map.values() |> Enum.filter(&(state.visits[&1.visit].restaurant == rid))

    raw_from_batches = r.batches |> Map.values() |> Enum.map(& &1.cost) |> Enum.sum()

    wip_from_orders =
      my_orders |> Enum.filter(&(&1.status in @consumed)) |> Enum.map(& &1.consumed_cost) |> Enum.sum()

    t = event_totals(events, rid, state)

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

  # Totals read directly from facts, never from derived state.
  defp event_totals(events, rid, state) do
    zero = %{granted: 0, purchased: 0, unlocked: 0, revenue: 0, served_cost: 0, waste: 0}

    Enum.reduce(events, zero, fn e, t ->
      case e do
        %{type: :starter_grant_issued, restaurant_id: ^rid, amount: a} -> %{t | granted: t.granted + a}
        %{type: :stock_purchased, restaurant_id: ^rid, cost: c} -> %{t | purchased: t.purchased + c}
        %{type: :market_cleared, fills: fs} -> %{t | purchased: t.purchased + fill_cost(fs, rid)}
        %{type: :recipe_unlocked, restaurant_id: ^rid, cost: c} -> %{t | unlocked: t.unlocked + c}
        %{type: :stock_spoiled, restaurant_id: ^rid, cost: c} -> %{t | waste: t.waste + c}
        %{type: :tray_served, components: cs} -> sum_served(t, cs, rid, state)
        %{type: :dessert_served} = c -> sum_served(t, [c], rid, state)
        %{type: :tray_cancelled, components: cs} -> sum_waste(t, cs, rid, state)
        %{type: :dessert_cancelled} = c -> sum_waste(t, [c], rid, state)
        _ -> t
      end
    end)
  end

  defp fill_cost(fills, rid), do: fills |> Enum.filter(&(&1.restaurant_id == rid)) |> Enum.map(& &1.cost) |> Enum.sum()

  defp mine?(state, order_id, rid), do: state.visits[state.orders[order_id].visit].restaurant == rid

  defp sum_served(t, cs, rid, state) do
    Enum.reduce(cs, t, fn c, t ->
      if mine?(state, c.order_id, rid),
        do: %{t | revenue: t.revenue + c.price, served_cost: t.served_cost + c.cost},
        else: t
    end)
  end

  defp sum_waste(t, cs, rid, state) do
    Enum.reduce(cs, t, fn c, t ->
      if mine?(state, c.order_id, rid), do: %{t | waste: t.waste + c.waste_cost}, else: t
    end)
  end

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
        {state.access == :open or o.status in [:served, :cancelled], {:active_order_during_cleaning, oid}}
      ]
      |> failures()
    end)
  end

  defp tray_consistent?(%{status: :accepted}, o), do: o.status in @live
  defp tray_consistent?(%{status: :served}, o), do: o.status == :served
  defp tray_consistent?(%{status: :cancelled}, o), do: o.status == :cancelled

  defp visits(state) do
    by_visit = state.orders |> Map.values() |> Enum.group_by(& &1.visit)

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
        {v.status != :finalized or (active == [] and v.dessert != :offered), {:finalized_with_open_work, vid}},
        {v.status == :finalized or active != [] or v.dessert == :offered, {:stranded_active_visit, vid}},
        {v.dessert != :offered or state.access == :open, {:offer_during_cleaning, vid}},
        {v.source != :simulated or v.budget_committed <= v.budget, {:over_budget, vid}},
        {v.source != :simulated or
           v.budget_committed == os |> Enum.reject(&(&1.status == :cancelled)) |> Enum.map(& &1.price) |> Enum.sum(),
         {:budget_commitment_mismatch, vid}},
        {v.source != :guest or v.status == :finalized or state.active_visits[v.principal] == vid,
         {:untracked_active_guest_visit, vid}},
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
    by_stall = state.orders |> Map.values() |> Enum.group_by(&state.visits[&1.visit].stall)

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

  defp item_of(%{kind: :dessert, id: id}), do: {:dessert, id}
  defp item_of(%{tray: tray}), do: {:tray, tray}

  defp hall(state, events) do
    granted = for(%{type: :allowance_granted, amount: a} <- events, do: a) |> Enum.sum()
    initial = state.catalog.rules.visitor_fund
    served_mains = Enum.count(state.orders, fn {_, o} -> o.kind == :main and o.status == :served end)
    finalized = Enum.count(state.visits, fn {_, v} -> v.status == :finalized end)
    finalize_events = Enum.count(events, &(&1.type == :visit_finalized))

    [
      # The event-sourced gate must agree with the calendar definition.
      {state.access == :cleaning == FeudHall.Domain.Clock.cleaning?(state.now), {:access_gate_mismatch, state.now}},
      {state.visitor_fund + granted == initial, :visitor_fund_not_conserved},
      {state.stats.arrivals == map_size(state.visits), :arrival_count},
      {state.stats.served_mains == served_mains, :served_main_count},
      {state.stats.finalized_visits == finalized, :finalized_count},
      {finalize_events == finalized, :visit_finalized_more_than_once}
    ]
    |> failures()
  end

  # Market conservation, replayed from the facts alone: the opening stock, plus
  # every midnight replenishment, less every fill in order (never driving a
  # product below zero), is the market's
  # stock now. Pending requests are those submitted and neither replaced,
  # cancelled, nor settled by a later clearing; each clearing settles exactly
  # the requests pending at it, and fill + unfilled = requested for each.
  # Only checked over a log that starts at genesis.
  defp market(state, [%{type: :hall_initialized} = genesis | _] = events) do
    opening = get_in(genesis, [:market, :stock]) || %{}

    {stock, pending, problems} =
      Enum.reduce(events, {opening, %{}, []}, fn e, {stock, pending, problems} ->
        case e do
          %{type: :purchase_requested} ->
            pending = pending |> Map.delete(e.replaces) |> Map.put(e.request_id, e.qty)
            {stock, pending, problems}

          %{type: :purchase_request_cancelled, request_id: id} ->
            {stock, Map.delete(pending, id), problems}

          %{type: :day_closed, replenishment: added} ->
            stock = Enum.reduce(added, stock, fn {product, qty}, s -> Map.update(s, product, qty, &(&1 + qty)) end)
            {stock, pending, problems}

          %{type: :market_cleared, fills: fills, unfilled: unfilled} ->
            stock = Enum.reduce(fills, stock, fn f, s -> Map.update(s, f.product, -f.qty, &(&1 - f.qty)) end)

            settled =
              Enum.reduce(fills ++ unfilled, %{}, fn x, acc -> Map.update(acc, x.request_id, x.qty, &(&1 + x.qty)) end)

            new =
              [
                {Enum.all?(stock, fn {_, q} -> q >= 0 end), {:market_oversold, e.batch}},
                {Enum.all?(Map.keys(settled), &Map.has_key?(pending, &1)), {:settled_unknown_request, e.batch}},
                {Enum.all?(pending, fn {id, q} -> Map.get(settled, id, 0) == q end),
                 {:request_not_settled_exactly, e.batch}}
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

    pending_check =
      if Enum.sort(Map.keys(pending)) == Enum.sort(Map.keys(state.market.requests)),
        do: [],
        else: [:pending_requests_mismatch]

    problems ++ conservation ++ pending_check
  end

  defp market(_state, _events), do: []

  defp failures(checks), do: for({false, problem} <- checks, do: problem)
end
