defmodule FeudHall.Domain.InvariantsTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Demand, Hall, Hall.Invariants, Inventory, Market}

  # A hall with an accepted, still-reserved tray (two components claiming stock).
  defp reserved_world do
    {state, _} = simulated_visit(stocked_world(), "d1", "bean_tacos", "horchata")
    state
  end

  defp reserved_order(state) do
    state.orders |> Map.values() |> Enum.find(&(&1.status == :queued_prep and &1.reservations != []))
  end

  test "an uninitialised hall and consistent halls pass" do
    assert Invariants.check(nil) == :ok
    assert Invariants.check(elem(stocked_world(), 0)) == :ok
    assert Invariants.check(reserved_world()) == :ok
  end

  test "a broken trial balance is reported per restaurant" do
    state = update_in(reserved_world(), [:restaurants, "r1", :ledger, :cash], &(&1 + 1))
    assert Invariants.check(state) == {:error, [{"r1", :trial_balance}]}
  end

  test "batch reservations must stay within quantity and match the reserved orders' claims" do
    state = reserved_world()
    %{reservations: [%{batch_id: batch_id} | _]} = reserved_order(state)

    stranded = update_in(state, [:restaurants, "r1", :batches, batch_id, :reserved], &(&1 + 1))
    assert {:error, [{"r1", {:stranded_reservation, ^batch_id}}]} = Invariants.check(stranded)

    qty = state.restaurants["r1"].batches[batch_id].qty
    over = put_in(stranded, [:restaurants, "r1", :batches, batch_id, :reserved], qty + 1)
    assert {:error, problems} = Invariants.check(over)
    assert {"r1", {:reservation_out_of_range, batch_id}} in problems
  end

  test "a claim on a batch the restaurant no longer holds is reported" do
    state = reserved_world()
    %{reservations: [%{batch_id: batch_id} | _]} = reserved_order(state)
    state = update_in(state, [:restaurants, "r1", :batches], &Map.delete(&1, batch_id))
    assert {:error, problems} = Invariants.check(state)
    assert {"r1", {:claim_on_missing_batch, batch_id}} in problems
  end

  test "every tray component must exist" do
    state = reserved_world()
    [tray_id] = Map.keys(state.trays)
    [order_id | _] = state.trays[tray_id].components
    {order, state} = pop_in(state, [:orders, order_id])
    assert order
    assert {:error, problems} = Invariants.check(state)
    assert {:missing_tray_component, tray_id, order_id} in problems
  end

  test "every order names an existing visit, and each visit's tray and dessert orders name it back" do
    {state, _} = stocked_world() |> simulated_visit("d1", "bean_tacos") |> simulated_visit("d2", "bean_tacos")
    assert Invariants.check(state) == :ok
    [d1_order] = state.trays[tray_id("visit-d1")].components
    [d2_order] = state.trays[tray_id("visit-d2")].components

    orphan = put_in(state, [:orders, d1_order, :visit], "V:nobody")
    assert {:error, problems} = Invariants.check(orphan)
    assert {:order_without_visit, d1_order} in problems

    # One order replaced by another visit's: the tray's visit no longer owns its component.
    moved = put_in(state, [:orders, d1_order, :visit], visit_id("visit-d2"))
    assert {:error, problems} = Invariants.check(moved)
    assert {:visit_order_mismatch, visit_id("visit-d1"), d1_order} in problems

    # A dessert slot naming another visit's order.
    borrowed = put_in(state, [:visits, visit_id("visit-d2"), :dessert_order], d1_order)
    assert {:error, problems} = Invariants.check(borrowed)
    assert {:visit_order_mismatch, visit_id("visit-d2"), d1_order} in problems
    refute {:visit_order_mismatch, visit_id("visit-d2"), d2_order} in problems
  end

  describe "live state holds only unfinished work" do
    # Both trays accepted together: d1's is handed over 4..8 and accepts its dessert, d2's
    # 8..12 and finalizes, so at 12 d1's dessert is still in the kitchen (live).
    setup do
      w = stocked_world(arrivals: false)
      w = simulated_visit(w, "d1", "bean_tacos", nil, "unrestricted", 10_000, true)
      w = simulated_visit(w, "d2", "bean_tacos")
      {before_d2, _} = w = serve_tray(w, tray_id("visit-d1"))
      {state, _} = serve_tray(w, tray_id("visit-d2"))
      %{state: state, before_d2: before_d2}
    end

    test "a live served main with its dessert open passes; the finalized visit is gone", %{state: state} do
      assert Invariants.check(state) == :ok
      assert Map.keys(state.visits) == [visit_id("visit-d1")]
      assert state.trays[tray_id("visit-d1")].status == :served
      assert %{arrivals: 2, finalized_visits: 1} = state.stats
    end

    test "a finalized visit kept in state breaks the visit count", %{state: state, before_d2: before} do
      kept = put_in(state, [:visits, visit_id("visit-d2")], before.visits[visit_id("visit-d2")])
      assert Invariants.check(kept) == {:error, [{:visit_count_mismatch, 2, 3}]}

      lost = update_in(state, [:visits], &Map.delete(&1, visit_id("visit-d1")))
      assert {:visit_count_mismatch, 2, 1} in problems_of(Invariants.check(lost))
    end

    test "a finalized visit's tray or orders kept in state are reported", %{state: state, before_d2: before} do
      tid = tray_id("visit-d2")
      [main] = before.trays[tid].components

      kept =
        state
        |> put_in([:trays, tid], %{before.trays[tid] | status: :served})
        |> put_in([:orders, main], %{before.orders[main] | status: :served, reservations: []})

      assert {:error, problems} = Invariants.check(kept)
      assert {:tray_without_visit, tid} in problems
      assert {:settled_tray_retained, tid} in problems
      assert {:order_without_visit, main} in problems
    end

    test "cancelled work, a served dessert, or a served tray with no open dessert is reported", %{state: state} do
      vid = visit_id("visit-d1")
      tid = tray_id("visit-d1")
      [main] = state.trays[tid].components
      dessert = state.visits[vid].dessert_order

      cancelled_tray = put_in(state, [:trays, tid, :status], :cancelled)
      assert {:settled_tray_retained, tid} in problems_of(Invariants.check(cancelled_tray))

      cancelled_main = put_in(state, [:orders, main, :status], :cancelled)
      assert {:settled_order_retained, main} in problems_of(Invariants.check(cancelled_main))

      served_dessert = put_in(state, [:orders, dessert], %{state.orders[dessert] | status: :served, reservations: []})
      assert {:settled_order_retained, dessert} in problems_of(Invariants.check(served_dessert))

      declined = put_in(state, [:visits, vid, :dessert], :declined)
      assert {:settled_tray_retained, tid} in problems_of(Invariants.check(declined))

      other_tray = put_in(state, [:visits, vid, :tray], "T:other")
      assert {:tray_without_visit, tid} in problems_of(Invariants.check(other_tray))
    end

    test "the order counter lies above every live order's sequence number", %{state: state} do
      top = state.orders |> Map.values() |> Enum.map(& &1.seq) |> Enum.max()
      assert state.order_seq > top

      assert Invariants.check(%{state | order_seq: top}) == {:error, [{:order_seq_behind, top}]}
      assert Invariants.check(Map.delete(state, :order_seq)) == {:error, [{:order_seq_behind, nil}]}
    end
  end

  test "restaurant cash never goes negative" do
    state = reserved_world()
    cash = state.restaurants["r1"].ledger.cash
    assert cash > 0

    # The trial balance still holds: the missing cash is booked as waste.
    negative =
      update_in(state, [:restaurants, "r1", :ledger], fn l -> %{l | cash: -1, waste: l.waste + cash + 1} end)

    assert Invariants.check(negative) == {:error, [{"r1", :negative_cash}]}
  end

  test "on-hand stock never exceeds the storage capacity" do
    state = reserved_world()
    used = Inventory.storage_used(state.restaurants["r1"].batches, state.catalog)
    assert used > 0
    assert Invariants.check(put_in(state, [:catalog, :rules, :storage_capacity], used)) == :ok

    assert Invariants.check(put_in(state, [:catalog, :rules, :storage_capacity], used - 1)) ==
             {:error, [{"r1", :storage_over_capacity}]}
  end

  test "an NPC must own the restaurant its record names and hold a 64-bit random state" do
    {state, _} =
      run!(
        stocked_world(arrivals: false, stock: %{}),
        {:create_restaurant, %{restaurant_id: "npc-budget", stall_id: "s041", name: "NPC budget", cuisine: "mexican"}},
        {:npc, "budget"},
        "npc:budget:create"
      )

    assert Invariants.check(state) == :ok

    assert Invariants.check(put_in(state, [:npcs, "budget", :rng], -1)) == {:error, [{:bad_npc_rng, "budget"}]}

    assert Invariants.check(put_in(state, [:npcs, "budget", :restaurant_id], "r1")) ==
             {:error, [{:npc_without_restaurant, "budget"}]}
  end

  test "hall access must match the cleaning calendar" do
    state = elem(stocked_world(arrivals: false), 0)
    refute Clock.cleaning?(state.now)
    assert Invariants.check(%{state | access: :cleaning}) == {:error, [{:access_gate_mismatch, state.now}]}

    # Jump the clock (keeping the next market clearing ahead of it; a quiet hall schedules no arrival).
    three = Clock.cleaning_start_of(0)

    cleaning = %{
      state
      | now: three,
        market: %{state.market | next_clear_at: three + Clock.minute()}
    }

    assert Invariants.check(cleaning) == {:error, [{:access_gate_mismatch, cleaning.now}]}
    assert Invariants.check(%{cleaning | access: :cleaning}) == :ok
  end

  describe "market" do
    defp pending_world do
      request = %{restaurant_id: "r1", product: "rice_long", qty: 10, max_price_per_kunit: 1_000}
      {state, _} = run!(stocked_world(), {:submit_purchase_request, request}, owner(), "buy")
      state
    end

    test "a hall with a pending request passes" do
      assert map_size(pending_world().market.requests) == 1
      assert Invariants.check(pending_world()) == :ok
    end

    test "pending requests and their index must agree" do
      state = pending_world()

      unindexed = put_in(state, [:market, :by_key], %{})
      assert Invariants.check(unindexed) == {:error, [{:unindexed_purchase_request, "PR:buy"}]}

      dangling = put_in(state, [:market, :requests], %{})
      assert Invariants.check(dangling) == {:error, [{:dangling_request_index, "PR:buy"}]}

      wrong_key = put_in(state, [:market, :by_key], %{{"r1", "sugar"} => "PR:buy"})
      assert {:error, problems} = Invariants.check(wrong_key)
      assert {:dangling_request_index, "PR:buy"} in problems
      assert {:unindexed_purchase_request, "PR:buy"} in problems
    end

    test "a request must name an existing restaurant, stock stays non-negative, and clearing stays due" do
      state = pending_world()

      orphan = update_in(state, [:restaurants], &Map.delete(&1, "r1"))
      assert {:error, problems} = Invariants.check(orphan)
      assert {:request_for_unknown_restaurant, "PR:buy"} in problems

      negative = put_in(state, [:market, :stock, "sugar"], -1)
      assert Invariants.check(negative) == {:error, [{:negative_market_stock, "sugar"}]}

      overdue = put_in(state, [:market, :next_clear_at], state.now)
      assert Invariants.check(overdue) == {:error, [{:market_clearing_overdue, state.now}]}
    end
  end

  # --- arrival stream, day boundary, schedules ------------------------------------

  describe "demand" do
    defp quiet_state, do: elem(stocked_world(arrivals: false), 0)

    test "every PRNG state must be an integer in 0..2^64-1" do
      state = quiet_state()
      assert Invariants.check(state) == :ok

      for bad <- [-1, 0x1_0000_0000_0000_0000, nil, 1.5, "7"] do
        assert {:error, problems} = Invariants.check(put_in(state, [:demand, :rng], bad))
        assert {:bad_demand_rng, bad} in problems
      end

      assert Invariants.check(put_in(state, [:demand, :rng], 0xFFFF_FFFF_FFFF_FFFF)) == :ok
    end

    test "the recorded next arrival must be the one the accumulator implies" do
      state = quiet_state()
      assert state.demand.next_arrival_at == Demand.next_arrival_at(state.demand)

      # A busy hall: a stale schedule that is still in the future disagrees with its accumulator.
      busy = elem(stocked_world(), 0)
      assert busy.demand.next_arrival_at == Demand.next_arrival_at(busy.demand)
      assert Invariants.check(busy) == :ok

      wrong = put_in(busy, [:demand, :next_arrival_at], busy.demand.next_arrival_at + 1)
      assert {:error, problems} = Invariants.check(wrong)
      assert {:arrival_schedule_mismatch, busy.demand.next_arrival_at + 1, busy.demand.next_arrival_at} in problems

      gone = put_in(busy, [:demand, :next_arrival_at], nil)
      assert {:error, [{:arrival_schedule_mismatch, nil, _}]} = Invariants.check(gone)
    end

    test "more arrivals in the day than the quota allows is reported" do
      state = quiet_state()
      quota = Enum.sum(state.demand.hour_quotas_millis)
      too_many = div(quota + state.demand.acc_millis, 1000) + 1
      assert {:error, problems} = Invariants.check(put_in(state, [:demand, :arrival_seq], too_many))
      assert {:arrivals_beyond_quota, too_many} in problems
    end

    test "the arrival accumulator carries less than one arrival" do
      state = quiet_state()
      assert {:error, problems} = Invariants.check(put_in(state, [:demand, :acc_millis], 1_000))
      assert {:arrival_accumulator_out_of_range, 1_000} in problems
      assert {:error, problems} = Invariants.check(put_in(state, [:demand, :acc_millis], -1))
      assert {:arrival_accumulator_out_of_range, -1} in problems
    end

    test "the next arrival must lie after the clock" do
      state = elem(stocked_world(), 0)
      assert {:error, problems} = Invariants.check(put_in(state, [:demand, :next_arrival_at], state.now))
      assert {:arrival_overdue, state.now} in problems
    end

    test "the last recorded operating list names existing restaurants, once each" do
      {state, _} = stocked_world() |> advance_hall(Clock.hour())
      assert state.demand.operating == ["r1"]
      assert Invariants.check(state) == :ok
      assert Invariants.check(put_in(state, [:demand, :operating], [])) == :ok

      # `Demand.operating/1` lists restaurants in stall order: npc-budget (s041) after r1 (s001).
      {state, _} =
        run!(
          {state, []},
          {:create_restaurant, %{restaurant_id: "npc-budget", stall_id: "s041", name: "NPC", cuisine: "mexican"}},
          {:npc, "budget"},
          "npc:budget:create"
        )

      assert Invariants.check(put_in(state, [:demand, :operating], ["r1", "npc-budget"])) == :ok

      for bad <- [["ghost"], ["r1", "r1"], nil] do
        assert Invariants.check(put_in(state, [:demand, :operating], bad)) == {:error, [:bad_operating_record]}
      end
    end

    test "the next midnight must lie after the clock" do
      state = quiet_state()
      overdue = put_in(state, [:demand, :next_day_at], state.now)
      assert {:error, problems} = Invariants.check(overdue)
      assert {:day_close_overdue, state.now} in problems

      # A hall recorded without demand rules never closes a day.
      no_rules = update_in(overdue, [:catalog, :rules], &Map.delete(&1, :demand))
      refute {:day_close_overdue, state.now} in problems_of(Invariants.check(no_rules))
    end

    test "simulated arrival counts must add up and stay within the day's and the hall's visits" do
      state = quiet_state()

      extra = update_in(state, [:stats, :arrivals_simulated], &(&1 + 1))
      assert {:error, [{:simulated_stats_mismatch, 1, 0}]} = Invariants.check(extra)

      left = put_in(state, [:stats, :left_simulated], %{no_compatible_main: 2})
      assert {:error, [{:simulated_stats_mismatch, 0, 2}]} = Invariants.check(left)

      consistent_left =
        state |> put_in([:stats, :arrivals_simulated], 2) |> put_in([:stats, :left_simulated], %{wait_too_long: 2})

      assert Invariants.check(consistent_left) == :ok

      seq = put_in(state, [:demand, :arrival_seq], 3)
      assert {:arrival_seq_beyond_stats, 3} in problems_of(Invariants.check(seq))

      admitted = state |> put_in([:stats, :arrivals_simulated], 1) |> put_in([:stats, :admitted_simulated], 1)
      assert {:error, [{:admitted_beyond_visits, 1, 0}]} = Invariants.check(admitted)
    end

    test "a missing simulated count is reported as a mismatch rather than raising" do
      state = quiet_state()

      no_admitted =
        state |> put_in([:stats, :arrivals_simulated], 1) |> update_in([:stats], &Map.delete(&1, :admitted_simulated))

      assert {:error, [{:simulated_stats_mismatch, 1, 0}]} = Invariants.check(no_admitted)

      no_arrivals =
        state
        |> put_in([:stats, :left_simulated], %{wait_too_long: 2})
        |> update_in([:stats], &Map.delete(&1, :arrivals_simulated))

      assert {:error, [{:simulated_stats_mismatch, 0, 2}]} = Invariants.check(no_arrivals)

      # Control: with both counts missing and nothing left, the counts still add up.
      both = update_in(state, [:stats], &Map.drop(&1, [:arrivals_simulated, :admitted_simulated]))
      assert Invariants.check(both) == :ok
    end

    test "a day closed without its arrivals is loud at recovery" do
      {state, log} = stocked_world() |> advance_hall(Clock.day() + 24)
      assert Enum.any?(log, &(&1.type == :diner_arrived))
      assert Enum.any?(log, &(&1.type == :day_closed))
      assert Invariants.check(state) == :ok
      assert Hall.replay(log) == state

      # Unreleased branch data: the midnight was recorded but the day's arrivals were not.
      stripped = Enum.reject(log, &(&1.type == :diner_arrived))
      assert {:error, problems} = stripped |> Hall.replay() |> Invariants.check()
      assert Enum.any?(problems, &match?({:arrival_accumulator_out_of_range, n} when n >= 1_000, &1))
    end

    test "the market's clearing and the day boundary share one 'enabled' predicate with the advance" do
      assert Market.clearing?(%{rules: %{market: %{clear_every_hall_ms: 240_000}}})

      for off <- [0, -5, nil, 1.5, "240000"] do
        refute Market.clearing?(%{rules: %{market: %{clear_every_hall_ms: off}}})
      end

      refute Market.clearing?(%{rules: %{}})

      state = quiet_state()
      # A clearing interval that is not a positive integer disables clearing for the advance and the check alike.
      odd = put_in(state, [:catalog, :rules, :market, :clear_every_hall_ms], "240000")
      overdue = put_in(odd, [:market, :next_clear_at], odd.now)
      assert Invariants.check(overdue) == :ok
      assert Enum.filter(Hall.Advance.run(overdue, overdue.now + 24_000), &(&1.type == :market_cleared)) == []
    end
  end

  describe "NPC planning slots" do
    defp npc_world do
      run!(
        stocked_world(arrivals: false, stock: %{}),
        {:create_restaurant, %{restaurant_id: "npc-budget", stall_id: "s041", name: "NPC budget", cuisine: "mexican"}},
        {:npc, "budget"},
        "npc:budget:create"
      )
    end

    test "a slot must be a positive whole game hour" do
      {state, _} = npc_world()
      assert Invariants.check(state) == :ok

      for bad <- [nil, -3_600_000, 0, 1_000, 1.5, "3600000"] do
        assert {:error, problems} = Invariants.check(put_in(state, [:npcs, "budget", :next_slot_at], bad))
        assert {:bad_npc_slot, "budget"} in problems
      end
    end

    test "a slot reached but not yet planned is legitimate: planning may lag the clock" do
      {state, _} = npc_world() |> advance_hall(2 * Clock.hour() + 24_000)
      assert state.npcs["budget"].next_slot_at == Clock.hour()
      assert Invariants.check(state) == :ok
    end
  end

  # --- kitchen: stages and counter -------------------------------------------------

  describe "kitchen" do
    # Hall time of the next kitchen boundary after `now`, or nil.
    defp kitchen_world(until?) do
      {state, _} = world = simulated_visit(stocked_world(arrivals: false), "k1", "bean_tacos", "horchata")
      step(world, state.now, until?, 0)
    end

    defp step({state, _} = world, _t, until?, n) do
      cond do
        until?.(state) -> world
        n > 200 -> flunk("kitchen never reached the wanted state")
        true -> step(advance_hall(world, state.now + Clock.ratio() * 1_000), state.now, until?, n + 1)
      end
    end

    defp in_status?(status), do: fn state -> Enum.any?(Map.values(state.orders), &(&1.status == status)) end
    defp order_in(state, status), do: state.orders |> Map.values() |> Enum.find(&(&1.status == status))

    test "valid kitchen states pass at every stage" do
      for status <- [:prep, :finish, :ready] do
        {state, _} = kitchen_world(in_status?(status))
        assert order_in(state, status)
        assert Invariants.check(state) == :ok
      end

      {state, _} = kitchen_world(fn state -> Enum.any?(Map.values(state.stalls), & &1.counter) end)
      assert Invariants.check(state) == :ok
    end

    test "stations in use never exceed the stall's capacity" do
      for {status, key} <- [prep: :prep_stations, finish: :finish_stations] do
        {state, _} = kitchen_world(in_status?(status))
        over = put_in(state, [:catalog, :rules, :kitchen, key], 0)
        assert {:error, problems} = Invariants.check(over)
        assert {:stage_over_capacity, "s001", status} in problems
      end
    end

    test "an order in a station has a deadline that is not in the past" do
      {state, _} = kitchen_world(in_status?(:prep))
      order = order_in(state, :prep)
      assert order.stage_done_at > state.now

      none = put_in(state, [:orders, order.id, :stage_done_at], nil)
      assert {:error, problems} = Invariants.check(none)
      assert {:stage_deadline_missing, order.id} in problems

      late = put_in(state, [:orders, order.id, :stage_done_at], state.now - 1)
      assert {:error, problems} = Invariants.check(late)
      assert {:stage_overdue, order.id} in problems
    end

    test "a counter holds an existing, fully ready item that is not overdue and sits on one counter" do
      {state, _} = kitchen_world(fn state -> Enum.any?(Map.values(state.stalls), & &1.counter) end)
      %{counter: %{item: {:tray, tray_id} = item} = counter} = state.stalls["s001"]

      missing = put_in(state, [:stalls, "s001", :counter, :item], {:tray, "T:nope"})
      assert {:error, problems} = Invariants.check(missing)
      assert {:counter_item_missing, "s001"} in problems

      missing_dessert = put_in(state, [:stalls, "s001", :counter, :item], {:dessert, "DS:nope"})
      assert {:counter_item_missing, "s001"} in problems_of(Invariants.check(missing_dessert))

      [first | _] = state.trays[tray_id].components
      unfinished = put_in(state, [:orders, first, :status], :finish)
      assert {:counter_item_not_ready, "s001"} in problems_of(Invariants.check(unfinished))

      # A dessert on the counter must be ready too (an order copied as a dessert stands in for one).
      dessert = %{state.orders[first] | id: "DS:k1", kind: :dessert, tray: nil}

      on_counter = fn status ->
        state
        |> put_in([:orders, "DS:k1"], %{dessert | status: status})
        |> put_in([:stalls, "s001", :counter, :item], {:dessert, "DS:k1"})
      end

      refute {:counter_item_not_ready, "s001"} in problems_of(Invariants.check(on_counter.(:ready)))
      assert {:counter_item_not_ready, "s001"} in problems_of(Invariants.check(on_counter.(:finish)))
      assert {:counter_item_not_ready, "s001"} in problems_of(Invariants.check(on_counter.(:queued_prep)))

      overdue = put_in(state, [:stalls, "s001", :counter, :done_at], state.now - 1)
      assert {:counter_overdue, "s001"} in problems_of(Invariants.check(overdue))

      twice =
        put_in(state, [:stalls, "s002"], %{id: "s002", restaurant: "r1", tier: nil, mode: :closed, counter: counter})

      assert {:item_on_two_counters, item} in problems_of(Invariants.check(twice))
    end
  end

  defp problems_of(:ok), do: []
  defp problems_of({:error, problems}), do: problems
end
