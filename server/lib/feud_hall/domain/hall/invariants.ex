defmodule FeudHall.Domain.Hall.Invariants do
  @moduledoc """
  Pure consistency checks a recovered hall state must pass before the
  authority adopts it and accepts new work.

  These are a small production subset of the test oracle: they read only the
  state (not the event history), so they also catch a damaged snapshot whose
  checksum is intact. Checked:

    * each restaurant's trial balance
      (`cash + raw + wip + cost_of_sales + waste + capex == capital + revenue`),
      its cash is never negative, and its on-hand stock fits its storage
      capacity (`Inventory.storage_used/2`);
    * each warehouse batch's reservation stays within `0..qty` and equals the
      claims of the restaurant's still-reserved orders, and no claim names a
      batch the restaurant no longer holds;
    * every tray component names an existing order; every order names an
      existing visit, and each visit's tray components and dessert order name
      that visit (an order replaced under a reused ID breaks this);
    * the access gate matches the cleaning calendar (`Clock.cleaning?/1`);
    * the market's pending purchase requests and their `{restaurant, product}`
      index agree, each names an existing restaurant, market stock is never
      negative, and the next clearing lies after the clock;
    * the arrival accumulator: the PRNG state is a 64-bit integer, the carried
      remainder is less than one arrival, the day's arrivals do not exceed its
      accumulated quota, the recorded next arrival is the one the accumulator
      implies and lies after the clock, and the next midnight lies after it;
      the last recorded operating list is a list of distinct existing
      restaurant IDs;
    * simulated arrival counts: `arrivals_simulated` is the admitted plus the
      left arrivals, the day's `arrival_seq` does not exceed it, and the
      admitted ones do not exceed the hall's simulated visits;
    * each NPC operator owns the restaurant its record names, its PRNG state is
      a 64-bit integer, and its next planning slot is a positive whole game
      hour. A slot already reached is legitimate (planning lags the clock after
      a crash or a planner that gave up on the slot), so it is not an error;
    * kitchen, for halls whose catalog has kitchen rules: stations in use never
      exceed a stall's capacity, an order at a station has an integer finish
      time not before the clock, and a stall's counter holds an existing tray
      or dessert whose components are all ready, finishing no earlier than the
      clock, on no other counter.

  Problems are terms naming the broken invariant: `{restaurant_id, problem}`
  for restaurant checks (`:trial_balance`, `:negative_cash`,
  `:storage_over_capacity`, and the batch problems),
  `{:missing_tray_component, tray_id, order_id}`,
  `{:order_without_visit, order_id}`, `{:visit_order_mismatch, visit_id, order_id}`,
  `{:access_gate_mismatch, hall_ms}`, `{:unindexed_purchase_request, id}`,
  `{:dangling_request_index, id}`, `{:request_for_unknown_restaurant, id}`,
  `{:negative_market_stock, product}`, `{:market_clearing_overdue, at}`,
  `{:bad_demand_rng, rng}`, `{:arrival_accumulator_out_of_range, acc_millis}`,
  `{:arrivals_beyond_quota, seq}`, `{:arrival_overdue, at}`,
  `{:arrival_schedule_mismatch, recorded, implied}`, `{:day_close_overdue, at}`,
  `:bad_operating_record`,
  `{:simulated_stats_mismatch, arrivals, admitted_plus_left}`,
  `{:arrival_seq_beyond_stats, seq}`, `{:admitted_beyond_visits, admitted, visits}`,
  `{:npc_without_restaurant, operator}`, `{:bad_npc_rng, operator}`,
  `{:bad_npc_slot, operator}`, `{:stage_over_capacity, stall_id, :prep | :finish}`,
  `{:stage_deadline_missing, order_id}`, `{:stage_overdue, order_id}`,
  `{:counter_item_missing, stall_id}`, `{:counter_item_not_ready, stall_id}`,
  `{:counter_overdue, stall_id}`, and `{:item_on_two_counters, item}`.
  """

  alias FeudHall.Domain.{Clock, Demand, Inventory, Market}

  @spec check(map() | nil) :: :ok | {:error, [term()]}
  def check(nil), do: :ok

  def check(state) do
    case restaurants(state) ++
           trays(state) ++
           orders(state) ++
           access(state) ++ market(state) ++ arrivals(state) ++ stats(state) ++ npcs(state) ++ kitchen(state) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp restaurants(state) do
    claims = claims_by_restaurant(state)

    state.restaurants
    |> Enum.sort()
    |> Enum.flat_map(fn {rid, r} ->
      l = r.ledger
      reserved = Map.get(claims, rid, %{})

      balance = [
        {l.cash + l.raw + l.wip + l.cost_of_sales + l.waste + l.capex == l.capital + l.revenue, :trial_balance},
        {l.cash >= 0, :negative_cash},
        {Inventory.storage_used(r.batches, state.catalog) <= state.catalog.rules.storage_capacity,
         :storage_over_capacity}
      ]

      batches =
        r.batches
        |> Enum.sort()
        |> Enum.flat_map(fn {bid, b} ->
          [
            {b.reserved >= 0 and b.reserved <= b.qty, {:reservation_out_of_range, bid}},
            {b.reserved == Map.get(reserved, bid, 0), {:stranded_reservation, bid}}
          ]
        end)

      orphans =
        for {bid, _} <- Enum.sort(reserved),
            not Map.has_key?(r.batches, bid),
            do: {false, {:claim_on_missing_batch, bid}}

      for {false, problem} <- balance ++ batches ++ orphans, do: {rid, problem}
    end)
  end

  # Units claimed per restaurant and batch by orders that still hold reservations.
  defp claims_by_restaurant(state) do
    state.orders
    |> Map.values()
    |> Enum.filter(&(&1.status == :queued_prep))
    |> Enum.reduce(%{}, fn order, acc ->
      rid = state.visits |> Map.get(order.visit, %{}) |> Map.get(:restaurant)

      Enum.reduce(order.reservations, acc, fn %{batch_id: bid, qty: qty}, acc ->
        Map.update(acc, rid, %{bid => qty}, &Map.update(&1, bid, qty, fn held -> held + qty end))
      end)
    end)
  end

  defp trays(state) do
    for {tid, tray} <- Enum.sort(state.trays),
        oid <- tray.components,
        not Map.has_key?(state.orders, oid),
        do: {:missing_tray_component, tid, oid}
  end

  # Orders and visits agree on ownership both ways.
  defp orders(state) do
    orphans =
      for {oid, o} <- Enum.sort(state.orders),
          not Map.has_key?(state.visits, o.visit),
          do: {:order_without_visit, oid}

    mismatched =
      for {vid, v} <- Enum.sort(state.visits),
          oid <- visit_orders(state, v),
          match?(%{visit: other} when other != vid, Map.get(state.orders, oid)),
          do: {:visit_order_mismatch, vid, oid}

    orphans ++ mismatched
  end

  defp visit_orders(state, visit) do
    tray = if visit.tray, do: state.trays |> Map.get(visit.tray, %{components: []}) |> Map.get(:components), else: []
    tray ++ List.wrap(visit.dessert_order)
  end

  # Pending requests and their one-per-key index agree, each names an existing
  # restaurant (clearing funds it from that restaurant), stock is never
  # negative, and the next clearing is still ahead of the clock.
  defp market(%{market: market} = state) do
    indexed =
      for {id, r} <- Enum.sort(market.requests),
          Map.get(market.by_key, {r.restaurant_id, r.product}) != id,
          do: {:unindexed_purchase_request, id}

    dangling =
      for {{r, p}, id} <- Enum.sort(market.by_key),
          not match?(%{restaurant_id: ^r, product: ^p}, Map.get(market.requests, id)),
          do: {:dangling_request_index, id}

    orphaned =
      for {id, r} <- Enum.sort(market.requests),
          not Map.has_key?(state.restaurants, r.restaurant_id),
          do: {:request_for_unknown_restaurant, id}

    negative = for {product, qty} <- Enum.sort(market.stock), qty < 0, do: {:negative_market_stock, product}

    overdue =
      if clears?(state) and market.next_clear_at <= state.now,
        do: [{:market_clearing_overdue, market.next_clear_at}],
        else: []

    indexed ++ dangling ++ orphaned ++ negative ++ overdue
  end

  # States recorded before the arrival stream carry no accumulator.
  defp arrivals(%{demand: %{acc_millis: acc, arrival_seq: seq, hour_quotas_millis: quotas} = demand} = state) do
    rng = demand.rng
    at = Map.get(demand, :next_arrival_at)
    implied = Demand.next_arrival_at(demand)

    [
      {prng?(rng), {:bad_demand_rng, rng}},
      {is_integer(acc) and acc >= 0 and acc < 1000, {:arrival_accumulator_out_of_range, acc}},
      {is_integer(seq) and seq >= 0 and 1000 * seq <= acc + Enum.sum(quotas), {:arrivals_beyond_quota, seq}},
      {at == nil or at > state.now, {:arrival_overdue, at}},
      {at == implied, {:arrival_schedule_mismatch, at, implied}},
      {not Demand.closes_days?(state.catalog) or demand.next_day_at > state.now,
       {:day_close_overdue, demand.next_day_at}},
      {operating_record?(state, Map.get(demand, :operating)), :bad_operating_record}
    ]
    |> problems()
  end

  defp arrivals(_state), do: []

  # The last recorded operating list: distinct, existing restaurant IDs (in the
  # stall order `Demand.operating/1` lists them, so no order is required here).
  defp operating_record?(state, operating) do
    is_list(operating) and operating == Enum.uniq(operating) and
      Enum.all?(operating, &Map.has_key?(state.restaurants, &1))
  end

  # Simulated arrivals are counted both in the cumulative stats and in the day's sequence.
  defp stats(%{stats: stats, demand: demand, visits: visits}) do
    # A missing count reads as zero, so a damaged state reports a mismatch rather than raising.
    arrived = Map.get(stats, :arrivals_simulated, 0)
    admitted = Map.get(stats, :admitted_simulated, 0)
    left = stats |> Map.get(:left_simulated, %{}) |> Map.values() |> Enum.sum()
    simulated_visits = Enum.count(visits, fn {_id, v} -> v.source == :simulated end)

    [
      {arrived == admitted + left, {:simulated_stats_mismatch, arrived, admitted + left}},
      {Map.get(demand, :arrival_seq, 0) <= arrived, {:arrival_seq_beyond_stats, demand.arrival_seq}},
      {admitted <= simulated_visits, {:admitted_beyond_visits, admitted, simulated_visits}}
    ]
    |> problems()
  end

  defp stats(_state), do: []

  defp prng?(rng), do: is_integer(rng) and rng >= 0 and rng < 0x1_0000_0000_0000_0000

  defp problems(checks), do: for({false, problem} <- checks, do: problem)

  # A planning slot may lie in the past (a plan not yet committed is due), so only its form is checked.
  defp npcs(state) do
    state
    |> Map.get(:npcs, %{})
    |> Enum.sort()
    |> Enum.flat_map(fn {op, npc} ->
      slot = npc.next_slot_at

      problems([
        {state.owners[{:npc, op}] == npc.restaurant_id and Map.has_key?(state.restaurants, npc.restaurant_id),
         {:npc_without_restaurant, op}},
        {prng?(npc.rng), {:bad_npc_rng, op}},
        {is_integer(slot) and slot > 0 and rem(slot, Clock.hour()) == 0, {:bad_npc_slot, op}}
      ])
    end)
  end

  # Halls recorded before the automatic kitchen carry no kitchen rules and no stage bookkeeping.
  defp kitchen(%{catalog: %{rules: %{kitchen: %{prep_stations: prep_n, finish_stations: finish_n}}}} = state) do
    stationed = Enum.filter(Map.values(state.orders), &(&1.status in [:prep, :finish]))
    by_stall = Enum.group_by(stationed, &get_in(state, [:visits, &1.visit, :stall]))

    capacity =
      for {sid, orders} <- Enum.sort(by_stall),
          {stage, limit} <- [prep: prep_n, finish: finish_n],
          Enum.count(orders, &(&1.status == stage)) > limit,
          do: {:stage_over_capacity, sid, stage}

    deadlines =
      stationed
      |> Enum.sort_by(& &1.id)
      |> Enum.flat_map(fn o ->
        cond do
          not is_integer(o.stage_done_at) -> [{:stage_deadline_missing, o.id}]
          o.stage_done_at < state.now -> [{:stage_overdue, o.id}]
          true -> []
        end
      end)

    capacity ++ deadlines ++ counters(state)
  end

  defp kitchen(_state), do: []

  defp counters(state) do
    held = for {sid, %{counter: %{} = counter}} <- Enum.sort(state.stalls), do: {sid, counter}

    items =
      Enum.flat_map(held, fn {sid, counter} ->
        problems([
          {item_exists?(state, counter.item), {:counter_item_missing, sid}},
          {not item_exists?(state, counter.item) or item_ready?(state, counter.item), {:counter_item_not_ready, sid}},
          {is_integer(counter.done_at) and counter.done_at >= state.now, {:counter_overdue, sid}}
        ])
      end)

    twice =
      held
      |> Enum.frequencies_by(fn {_sid, counter} -> counter.item end)
      |> Enum.sort()
      |> Enum.flat_map(fn {item, n} -> if n > 1, do: [{:item_on_two_counters, item}], else: [] end)

    items ++ twice
  end

  defp item_exists?(state, {:tray, id}), do: Map.has_key?(state.trays, id)
  defp item_exists?(state, {:dessert, id}), do: match?(%{kind: :dessert}, Map.get(state.orders, id))
  defp item_exists?(_state, _other), do: false

  defp item_ready?(state, {:tray, id}),
    do: Enum.all?(state.trays[id].components, &(get_in(state, [:orders, &1, :status]) == :ready))

  defp item_ready?(state, {:dessert, id}), do: state.orders[id].status == :ready

  defp clears?(state), do: Market.clearing?(state.catalog)

  defp access(state) do
    if state.access == :cleaning == Clock.cleaning?(state.now),
      do: [],
      else: [{:access_gate_mismatch, state.now}]
  end
end
