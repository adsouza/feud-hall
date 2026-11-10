defmodule FeudHall.Domain.DemandForecastTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures, except: [stocked_world: 0, stocked_world: 1]

  alias FeudHall.Domain.{Clock, Demand, Market}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.{Evolver, Invariants}
  alias FeudHall.Infrastructure.EventCodec
  alias FeudHall.Oracle

  @min Clock.minute()
  @hour Clock.hour()
  @day Clock.day()
  @floor SliceCatalog.rules().demand.equivalent_floor_millis
  @operating_hours SliceCatalog.rules().demand.operating_hours_ms
  # A stocked world starts at the first market clearing, where its stock was filled.
  @t0 SliceCatalog.rules().market.clear_every_hall_ms

  defp day_closed(events), do: Enum.filter(events, &(&1.type == :day_closed))

  # Observation and the forecast are counted exactly here, so no simulated
  # diner arrives (and buys stock) unless a test admits one.
  defp stocked_world(opts \\ []), do: FeudHall.Fixtures.stocked_world(Keyword.put(opts, :arrivals, false))

  # Ten times the stock per equivalent at a tenth of the floor: the same opening
  # stock, so a stocked world works, while one operating business can exceed the floor.
  defp low_floor_catalog do
    catalog = SliceCatalog.catalog()
    tenfold = fn map -> Map.new(map, fn {k, v} -> {k, v * 10} end) end

    catalog
    |> update_in([:rules, :market, :target_stock_per_equivalent], tenfold)
    |> update_in([:rules, :market, :replenish_cap], tenfold)
    |> put_in([:rules, :demand, :equivalent_floor_millis], div(@floor, 10))
  end

  # Advances in steps of `step` hall ms, ending exactly on `to`.
  defp step_to({state, _} = world, to, step) do
    if state.now >= to,
      do: world,
      else: world |> advance_hall(min(state.now + step, to)) |> step_to(to, step)
  end

  # alice's restaurant closes its stall at hall time `at`, observed from then to midnight.
  defp close_at(world, at) do
    world
    |> advance_hall(at)
    |> run!({:close_stall, %{stall_id: "s001"}}, owner(), "close")
    |> advance_hall(@day)
  end

  describe "business-equivalent observation" do
    test "a restaurant open for 11 of the 22 accessible hours is half an equivalent" do
      # Observed from the stocking at 00:04 to 03:00 and from 05:00 until it closes.
      closing = Clock.cleaning_end_of(0) + 11 * @hour - (Clock.cleaning_start_of(0) - @t0)
      {state, events} = stocked_world() |> close_at(closing)

      assert [%{day: 0, equivalents_millis: 500}] = day_closed(events)
      assert state.demand.observed_ms == %{}
    end

    test "cleaning hours never count, and an all-day business stays below one equivalent here" do
      {_state, events} = stocked_world() |> advance_hall(@day)

      accessible = @operating_hours - @t0
      assert [%{equivalents_millis: millis}] = day_closed(events)
      assert millis == div(accessible * 1000, @operating_hours)
      assert millis < 1000
    end

    test "clock_advanced records the operating list only when it changes; the evolver credits the last one" do
      world = stocked_world()
      # Stocking ran with no stock on hand: nothing operated, which is the initial recorded list.
      assert elem(world, 0).demand.operating == []

      {state, events} = world |> advance_hall(@t0 + 5 * @min)
      ticks = events |> Enum.drop(length(elem(world, 1))) |> Enum.filter(&(&1.type == :clock_advanced))
      # The first interval records the change; the later ones in the span (past a market clearing) do not.
      assert [%{operating: ["r1"]} | unchanged] = ticks
      assert unchanged != [] and Enum.all?(unchanged, &(not Map.has_key?(&1, :operating)))
      assert List.last(ticks).to == @t0 + 5 * @min
      assert state.demand.operating == ["r1"]
      assert state.demand.observed_ms == %{"r1" => 5 * @min}

      before = length(events)
      {state, events} = advance_hall({state, events}, @t0 + 10 * @min)
      later = Enum.drop(events, before)
      assert [_ | _] = ticks = Enum.filter(later, &(&1.type == :clock_advanced))
      refute Enum.any?(ticks, &Map.has_key?(&1, :operating))
      assert state.demand.observed_ms == %{"r1" => 10 * @min}
    end

    test "a clock_advanced recorded without the key credits the last recorded list" do
      {state, _} = stocked_world()
      next = Evolver.evolve(state, %{type: :clock_advanced, to: state.now + @min})

      # Nothing recorded yet (as for events written before the list existed): nothing observed.
      assert next.now == state.now + @min
      assert next.demand.observed_ms == state.demand.observed_ms

      recorded = Evolver.evolve(state, %{type: :clock_advanced, to: state.now + @min, operating: ["r1"]})
      assert recorded.demand.operating == ["r1"]
      after_ = Evolver.evolve(recorded, %{type: :clock_advanced, to: recorded.now + @min})
      assert after_.demand.observed_ms == %{"r1" => 2 * @min}
      assert after_.demand.operating == ["r1"]

      emptied = Evolver.evolve(after_, %{type: :clock_advanced, to: after_.now + @min, operating: []})

      assert Evolver.evolve(emptied, %{type: :clock_advanced, to: emptied.now + @min}).demand.observed_ms ==
               after_.demand.observed_ms
    end

    test "an idle day writes the operating list only at its changes" do
      {_state, events} = stocked_world() |> advance_hall(@t0 + @day)
      ticks = Enum.filter(events, &(&1.type == :clock_advanced))
      keyed = Enum.filter(ticks, &Map.has_key?(&1, :operating))

      assert length(ticks) > 300
      # Opened, closed for cleaning, reopened: three changes.
      assert Enum.map(keyed, & &1.operating) == [["r1"], [], ["r1"]]
    end

    test "a log that restates the list at every instant, as older releases wrote it, replays identically" do
      world = stocked_world() |> grant("g1", 2_000, "grant-g1") |> guest_visit("g1", "gv1", "chicken_tacos")
      {start, _} = world
      {final, log} = advance_hall(world, @t0 + @day)
      tail = Enum.drop(log, length(elem(world, 1)))

      {restated, _last} =
        Enum.map_reduce(tail, start.demand.operating, fn
          %{type: :clock_advanced} = e, last ->
            operating = Map.get(e, :operating, last)
            {Map.put(e, :operating, operating), operating}

          e, last ->
            {e, last}
        end)

      assert Enum.count(restated, &Map.has_key?(&1, :operating)) > Enum.count(tail, &Map.has_key?(&1, :operating))
      assert FeudHall.Domain.Hall.replay(restated, start) == final
      assert FeudHall.Domain.Hall.replay(tail, start) == final
    end

    test "observation stops while no main can be quoted and resumes on restock" do
      world = stocked_world(stock: %{}) |> advance_hall(120_000)
      {state, _} = world
      assert state.demand.observed_ms == %{}
      assert Demand.operating(state) == []

      # The request is filled at the clearing at @t0: nothing was observed before it.
      world = world |> stock(default_stock()) |> advance_hall(@t0 + @min)
      assert elem(world, 0).demand.observed_ms == %{"r1" => @min}
    end

    test "operating needs an open stall, open access, a free queue and a quotable main" do
      {state, _} = stocked_world()
      assert Demand.operating(state) == ["r1"]

      assert Demand.operating(put_in(state, [:stalls, "s001", :mode], :closed)) == []
      assert Demand.operating(%{state | access: :cleaning}) == []
      assert Demand.operating(put_in(state, [:restaurants, "r1", :batches], %{})) == []
      assert Demand.operating(put_in(state, [:restaurants, "r1", :menu], %{})) == []

      # One quotable main is enough; without its ingredients (and every substitute) none is.
      batches = state.restaurants["r1"].batches
      without = fn products -> Map.reject(batches, fn {_, b} -> b.product in products end) end
      only_beans = without.(["flour_tortilla", "queso_oaxaca", "chicken_thigh", "peppers", "rice_long"])
      assert Demand.operating(put_in(state, [:restaurants, "r1", :batches], only_beans)) == ["r1"]

      no_staple = without.(["corn_tortilla", "flour_tortilla"])
      assert Demand.operating(put_in(state, [:restaurants, "r1", :batches], no_staple)) == []
    end

    test "a full kitchen queue stops observation" do
      catalog = update_in(SliceCatalog.catalog(), [:rules, :kitchen, :queue_limit], fn _ -> 1 end)
      {state, _} = stocked_world(catalog: catalog) |> simulated_visit("d1", "chicken_tacos")

      assert Demand.operating(state) == []
    end

    test "every restaurant is capped at one equivalent and the sum is not double counted" do
      rules = SliceCatalog.rules().demand

      assert Demand.equivalents_millis(rules, %{"a" => @operating_hours, "b" => 3 * @operating_hours}) == 2000
      assert Demand.equivalents_millis(rules, %{"a" => div(@operating_hours, 4)}) == 250
      assert Demand.equivalents_millis(rules, %{}) == 0
    end
  end

  describe "the midnight forecast" do
    test "day_closed follows the clock to midnight and precedes the same-instant market clearing" do
      {_state, events} = stocked_world() |> advance_hall(@day)

      types = events |> Enum.take(-3) |> Enum.map(& &1.type)
      assert types == [:clock_advanced, :day_closed, :market_cleared]
      assert %{to: @day} = Enum.at(events, -3)
    end

    test "the scale floors at the content floor" do
      {state, events} = stocked_world() |> advance_hall(@day)

      assert [%{equivalents_millis: e, scale_millis: @floor}] = day_closed(events)
      assert e < @floor
      assert state.demand.supply_scale_millis == @floor
    end

    test "a new hall starts at the floor, and day 0 replenishes with it" do
      {genesis, _} = stocked_world()
      assert genesis.demand.supply_scale_millis == @floor

      {before, _} = world = stocked_world() |> advance_hall(@day - 24)
      {_state, events} = advance_hall(world, @day)
      closed = events |> day_closed() |> List.last()

      assert closed.replenishment == Market.replenish(before.catalog, before.market, @floor, 1)
    end

    test "the recorded replenishment names every product and tops each toward its own scaled target" do
      {before, _} = world = stocked_world() |> advance_hall(@day - 24)
      {_state, events} = advance_hall(world, @day)
      closed = events |> day_closed() |> List.last()
      market = before.catalog.rules.market

      assert closed.replenishment |> Map.keys() |> Enum.sort() == before.catalog.products |> Map.keys() |> Enum.sort()

      # One open restaurant keeps each product at its baseline cap.
      for {product, qty} <- closed.replenishment do
        target = div(market.target_stock_per_equivalent[product] * @floor, 1000)
        room = min(target, market.replenish_cap[product]) - Map.get(before.market.stock, product, 0)
        assert qty == max(0, room), "replenishment of #{product}"
      end
    end

    test "replenishment at midnight D uses the scale fixed at midnight D-1" do
      catalog = low_floor_catalog()
      floor = catalog.rules.demand.equivalent_floor_millis
      {_, _} = world = stocked_world(catalog: catalog) |> close_at(@day - 12 * @hour)
      {state0, events0} = world
      [first] = day_closed(events0)
      assert first.equivalents_millis > floor and first.scale_millis == first.equivalents_millis
      assert state0.demand.supply_scale_millis == first.scale_millis

      {before, _} = next = advance_hall(world, 2 * @day - 24)
      {state, events} = advance_hall(next, 2 * @day)
      [^first, second] = day_closed(events)

      assert second.replenishment == Market.replenish(catalog, before.market, first.scale_millis, 0)
      refute second.replenishment == Market.replenish(catalog, before.market, floor, 0)
      assert state.demand.supply_scale_millis == second.scale_millis
    end

    test "midnight caps deliveries using distinct open restaurants, even when out of stock" do
      world =
        Enum.reduce(2..4, stocked_world(stock: %{}), fn n, world ->
          stall = "s00#{n}"
          actor = if n == 4, do: {:npc, "npc-four"}, else: owner("owner-#{n}")
          restaurant = %{restaurant_id: "r#{n}", stall_id: stall, name: "Restaurant #{n}", cuisine: "mexican"}

          world
          |> run!({:create_restaurant, restaurant}, actor, "create-#{n}")
          |> run!({:open_stall, %{stall_id: stall}}, actor, "open-#{n}")
        end)

      {before, log} = advance_hall(world, @day - 24)
      assert Demand.operating(before) == []
      # Set a previously recorded forecast high enough for the cap to bind.
      before = put_in(before.demand.supply_scale_millis, 6_000)
      # Model a second stall for r1, since the slice has no expansion command.
      before = put_in(before.stalls["s005"], %{before.stalls["s001"] | id: "s005"})

      {state, events} = advance_hall({before, log}, @day)
      assert [%{replenishment: %{"onion" => 933}}] = day_closed(events)
      assert state.market.stock["onion"] == 2_133

      {state, events} =
        {before, log}
        |> run!({:close_stall, %{stall_id: "s004"}}, {:npc, "npc-four"}, "close-four")
        |> advance_hall(@day)

      assert [%{replenishment: %{"onion" => 400}}] = day_closed(events)
      assert state.market.stock["onion"] == 1_600
    end

    test "the evolver adds the recorded replenishment to market stock and resets the day" do
      {before, _} = world = stocked_world() |> advance_hall(@day - 24)
      {state, events} = advance_hall(world, @day)
      [closed] = day_closed(events)

      cleared = events |> Enum.filter(&(&1.type == :market_cleared)) |> List.last()
      expected = Market.stock_after(%{stock: add(before.market.stock, closed.replenishment)}, cleared)
      assert state.market.stock == expected
      assert state.demand.observed_ms == %{}
      assert state.demand.today == %{arrivals: 0, admitted: 0, left: %{}, trays_served: 0}
      assert Invariants.check(state) == :ok
      Oracle.assert_settled!(state, events)
    end

    test "the summary counts the day's visits, departures and served trays" do
      world =
        stocked_world()
        |> grant("g1", 2_000, "grant-g1")
        |> grant("g2", 2_000, "grant-g2")
        |> guest_visit("g1", "gv1", "chicken_tacos")
        |> guest_visit("g2", "gv2", "chicken_tacos")

      cancelled = run!(world, {:cancel_tray, %{tray_id: tray_id("gv2")}}, {:principal, "g2"}, "cancel-gv2")

      world =
        cancelled
        |> serve_tray(tray_id("gv1"))
        |> simulated_visit("d1", "vegetable_quesadilla")
        |> serve_tray(tray_id("visit-d1"))
        |> advance_hall(@day)

      {state, events} = world
      [closed] = day_closed(events)

      prices = Map.take(state.restaurants["r1"].menu, ["chicken_tacos", "vegetable_quesadilla"])

      assert %{
               day: 0,
               arrivals: 3,
               admitted: 3,
               left: %{guest_cancelled: 1},
               trays_served: 2,
               menu_prices_median: median
             } = closed.summary

      assert median == state.restaurants["r1"].menu
      assert Map.take(median, Map.keys(prices)) == prices
      assert List.last(state.demand.summaries) == closed.summary
    end

    test "a visit that was served but declined dessert is not counted as having left" do
      world = stocked_world() |> simulated_visit("d1", "chicken_tacos", nil, "unrestricted", 100_000)
      world = serve_tray(world, tray_id("visit-d1"))
      {_state, log} = world
      vid = visit_id("visit-d1")
      assert Enum.any?(log, &match?(%{type: :dessert_declined, visit_id: ^vid}, &1))

      {_state, events} = closed_world = advance_hall(world, @day)
      [closed] = day_closed(events)

      assert %{reason: :completed} = visit_outcome(closed_world, vid)
      assert closed.summary.left == %{}
      assert closed.summary.trays_served == 1
    end

    test "the hall keeps the last seven summaries" do
      {state, events} =
        Enum.reduce(1..9, stocked_world(), fn d, world -> advance_hall(world, d * @day) end)

      assert Enum.map(day_closed(events), & &1.day) == Enum.to_list(0..8)
      assert Enum.map(state.demand.summaries, & &1.day) == Enum.to_list(2..8)
    end

    test "even-count medians use integer floor division" do
      assert Demand.median([5, 1, 3]) == 3
      assert Demand.median([1, 3]) == 2
      assert Demand.median([1, 2]) == 1
      assert Demand.median([4, 1, 9, 2]) == 3
      assert Demand.median([7]) == 7
    end

    test "the day's events are identical whether time advances in 1, 7 or 60 minute steps" do
      base =
        stocked_world()
        |> grant("g1", 2_000, "grant-g1")
        |> guest_visit("g1", "gv1", "chicken_tacos")

      results =
        for step <- [1, 7, 60] do
          {state, log} = step_to(base, @day, step * @min)
          {state, day_closed(log), Enum.reject(log, &(&1.type == :clock_advanced))}
        end

      [{state1, closed1, rest1} | others] = results
      assert [%{summary: %{arrivals: 1, trays_served: 1}}] = closed1

      for {state, closed, rest} <- others do
        assert closed == closed1
        assert rest == rest1
        assert state.demand == state1.demand
      end
    end

    test "every new event survives the codec round trip" do
      {_state, log} =
        stocked_world()
        |> grant("g1", 2_000, "grant-g1")
        |> guest_visit("g1", "gv1", "chicken_tacos")
        |> step_to(@day, 60 * @min)

      events = Enum.filter(log, &(&1.type in [:day_closed, :clock_advanced]))
      assert Enum.any?(events, &(&1.type == :day_closed))

      for event <- events do
        assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
      end
    end
  end

  defp add(stock, additions), do: Enum.reduce(additions, stock, fn {p, q}, s -> Map.update(s, p, q, &(&1 + q)) end)
end
