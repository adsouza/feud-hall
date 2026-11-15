System.put_env("CUSTOMER_SIM_NO_MAIN", "1")
Code.require_file("../../../scripts/customer_sim.exs", __DIR__)

defmodule FeudHall.CustomerSimTest do
  use ExUnit.Case, async: false

  alias FeudHall.Application.Management
  alias FeudHall.CustomerSim.{CLI, Hall, Stats}
  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}
  alias FeudHall.Domain.Hall.Rooms
  alias FeudHall.Infrastructure.HallAuthority

  @seed 20_261_109

  defp sample(day, hour, stalls, fields \\ %{}) do
    day |> Stats.blank_observation(hour) |> Map.merge(%{stalls: stalls}) |> Map.merge(fields)
  end

  defp stall(waiting, busy?), do: %{waiting: waiting, cooking: if(busy?, do: 1, else: 0), handover: false, open: true}

  # `values` gives one sample each for the reference stall "ref" in `hour` of day 1.
  defp feed(stats, hour, values) do
    Enum.reduce(values, stats, fn {waiting, busy?}, acc ->
      Stats.add(acc, sample(1, hour, %{"ref" => stall(waiting, busy?)}))
    end)
  end

  defp row(verdict, check), do: Enum.find(verdict, &(&1.check == check)) || flunk("no #{check} in #{inspect(verdict)}")

  defp run!(opts) do
    defaults = %{run: :b, tuning: Tuning.of(LaunchCatalog.catalog()), via: :init, days: 0, seed: @seed}
    assert {:ok, result} = Hall.run(Map.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(result.authority), do: GenServer.stop(result.authority) end)
    result
  end

  test "Stats averages waiting over time and counts busy share" do
    stats = Stats.new(%{measured_days: 1, reference: "ref"})

    stats =
      Enum.reduce([{2, 1, false}, {4, 0, true}, {4, 0, false}, {2, 1, false}], stats, fn {w, c, h}, acc ->
        Stats.add(acc, sample(1, 12, %{"ref" => %{waiting: w, cooking: c, handover: h, open: true}}))
      end)

    hour = Stats.stall_hour(stats, 1, 12, "ref")
    assert hour.samples == 4
    assert hour.waiting == 3.0
    assert hour.busy == 0.75
    assert hour.cooking == 0.5
    assert hour.handover == 0.25
  end

  test "the verdict applies the spec's bounds" do
    base = Stats.new(%{measured_days: 1, reference: "ref"})
    # 2.4 = (2 + 2 + 3 + 2 + 3) / 5
    low = feed(base, 12, [{2, true}, {2, true}, {3, true}, {2, true}, {3, true}])
    assert %{value: 2.4, low: 2.5, high: 4.5, pass: false} = row(Stats.verdict(:a, low), "A ref waiting 12:00-13:00")

    for {values, pass} <- [
          {[{2, true}, {3, true}], true},
          {[{4, true}, {5, true}], true},
          {[{4, true}, {5, true}, {5, true}, {4, true}, {5, true}], false}
        ] do
      stats = feed(base, 12, values)
      assert row(Stats.verdict(:a, stats), "A ref waiting 12:00-13:00").pass == pass, inspect(values)
    end

    busy = fn n -> feed(base, 19, for(i <- 1..1000, do: {3, i <= n})) end

    assert %{value: 0.85, low: 0.85, high: nil, pass: true} =
             row(Stats.verdict(:a, busy.(850)), "A ref busy 19:00-20:00")

    assert %{value: 0.849, pass: false} = row(Stats.verdict(:a, busy.(849)), "A ref busy 19:00-20:00")

    left = fn nothing, other ->
      Stats.add(base, sample(1, 12, %{}, %{left_on_arrival: %{nothing_available: nothing, nothing_affordable: other}}))
    end

    assert %{value: 0.25, low: nil, high: 0.25, pass: true} =
             row(Stats.verdict(:b, left.(25, 75)), "B nothing_available share of left on arrival")

    assert %{value: 0.26, pass: false} =
             row(Stats.verdict(:b, left.(26, 74)), "B nothing_available share of left on arrival")

    # The mid-morning window is hour 10 alone: hour 9 samples do not count.
    morning = base |> feed(9, [{0, false}, {0, false}]) |> feed(10, [{1, true}])
    assert %{value: 1.0, low: 0.5, high: 2, pass: true} = row(Stats.verdict(:a, morning), "A ref waiting 10:00-11:00")
    refute Enum.any?(Stats.verdict(:a, morning), &(&1.check == "A ref waiting 09:00-11:00"))
    afternoon = feed(base, 14, [{0, false}]) |> feed(17, [{9, true}])
    assert %{value: +0.0, pass: false} = row(Stats.verdict(:a, afternoon), "A ref waiting 14:00-17:00")
  end

  test "the open-during-checked-hours row fails on any closed checked hour" do
    base = Stats.new(%{measured_days: 1, reference: "ref"})
    open = fn stats, hour, open? -> Stats.add(stats, sample(1, hour, %{"ref" => %{stall(1, true) | open: open?}})) end
    all_open = Enum.reduce([10, 12, 14, 15, 16, 19], base, &open.(&2, &1, true))
    assert %{value: 1.0, low: 0.99, pass: true} = row(Stats.verdict(:a, all_open), "A ref open during checked hours")
    one_closed = Enum.reduce([10, 12, 14, 15, 16], base, &open.(&2, &1, true)) |> open.(19, false)

    assert %{pass: false, hours: %{19 => +0.0, 12 => 1.0}} =
             row(Stats.verdict(:a, one_closed), "A ref open during checked hours")
  end

  test "the owner-stall mean rush rows are reported without a bound and leave the reference rows alone" do
    one = Stats.new(%{measured_days: 1, reference: "ref"})
    two = Stats.new(%{measured_days: 1, reference: "ref", owners: ["ref", "extra"]})

    feed_both = fn stats, hour ->
      Stats.add(stats, sample(1, hour, %{"ref" => stall(2, true), "extra" => stall(5, true), "npc" => stall(6, true)}))
    end

    for hour <- [12, 19], label = "#{hour}:00-#{hour + 1}:00" do
      with_extra = Stats.verdict(:a, feed_both.(two, hour))
      # (2 + 5) / 2: the computer-run stall is not an owner stall.
      assert %{value: 3.5, low: nil, high: nil, pass: true} = row(with_extra, "A owner stalls mean waiting #{label}")
      assert %{value: 2.0, low: 2.5, high: 4.5, pass: false} = row(with_extra, "A ref waiting #{label}")

      alone = Stats.verdict(:a, feed_both.(one, hour))
      assert %{value: 2.0, pass: true} = row(alone, "A owner stalls mean waiting #{label}")
    end

    # A wildly out-of-range mean still passes: the row is reported, never judged.
    crowded = Stats.add(two, sample(1, 12, %{"ref" => stall(6, true), "extra" => stall(6, true)}))
    assert row(Stats.verdict(:a, crowded), "A owner stalls mean waiting 12:00-13:00").pass
    refute Enum.any?(Stats.verdict(:b, crowded), &(&1.check =~ "owner stalls"))
  end

  test "profit charges arrears, carries the distressed flag and lists warnings" do
    midnight = fn stats, day, cash, arrears, revenue ->
      Stats.add(stats, sample(day, 0, %{}, %{ledger: %{"r" => %{cash: cash, revenue: revenue, arrears: arrears}}}))
    end

    stats =
      %{measured_days: 1}
      |> Stats.new()
      |> midnight.(1, 1_000, 0, 5_000)
      |> Stats.add(sample(1, 14, %{}, %{distressed: ["r"]}))
      |> midnight.(2, 700, 250, 5_000)

    assert %{profit: -550, cash_change: -300, arrears_change: 250, distressed: true} = Stats.profit(stats, 1)["r"]
    # No events recorded: the 250 newly in arrears is explained, the 300 that left cash is not.
    assert [{:profit_unexplained, %{day: 1, restaurant: "r", remainder: -300}}] = Stats.inconsistencies(stats)

    # 300 left cash: 50 of purchases and 250 of rent and wages paid; another 250 went into arrears.
    stats = Stats.put_accounts(stats, %{{1, "r"} => %{purchases: 50, rent_and_wages_paid: 250}})

    assert %{revenue: 0, purchases: 50, rent_and_wages_charged: 500, other: 0, remainder: 0, unreadable: 0} =
             Stats.profit(stats, 1)["r"]

    assert Stats.inconsistencies(stats) == []
    [day1] = Enum.filter(Stats.summary(stats).days, &(&1.day == 1))
    assert %{profit: -550, distressed: true} = day1.profit["r"]
    assert Stats.warnings(stats) == [%{restaurant: "r", distressed_days: [1], arrears_at_end: 250}]

    # An unreadable event turns a mismatch into a printed remainder instead of a failure.
    unreadable = Stats.put_accounts(stats, %{{1, :any} => %{unreadable: 1}})
    assert %{unreadable: 1, remainder: -300} = Stats.profit(unreadable, 1)["r"]
    assert Stats.inconsistencies(unreadable) == []
  end

  @tag timeout: 180_000
  test "two run A executions with a measured day give byte-identical JSON" do
    args = %{run: :a, tuning: :current, via: :init, days: 1, seed: @seed, set: []}
    first = run!(%{run: :a, days: 1})
    second = run!(%{run: :a, days: 1})
    assert first.problems == []
    json = CLI.json(first, args)
    assert json == CLI.json(second, args)
    assert length(Jason.decode!(json)["summary"]["hours"]) == 24
  end

  @tag timeout: 180_000
  test "a run is deterministic and acts only through commands" do
    first = run!(%{})
    second = run!(%{})
    args = %{run: :b, tuning: :current, via: :init, days: 0, seed: @seed, set: []}
    assert CLI.json(first, args) == CLI.json(second, args)

    {store_mod, store} = HallAuthority.store(first.authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    events = Enum.sum(for batch <- batches, do: length(batch.events) + length(batch.control_events))
    assert events > 1_000

    receipts =
      for batch <- batches do
        assert {:ok, receipt} = store_mod.receipt(store, batch.command_id)
        receipt.event_count
      end

    assert Enum.sum(receipts) == events
  end

  @tag timeout: 180_000
  test "run A's reference stall is a standard spot in room 1, open 10:00 to 20:00 by default, with three staff" do
    result = run!(%{run: :a})
    state = HallAuthority.state(result.authority).hall
    sid = result.reference.stall_id
    assert state.layout[sid] == :standard
    assert Rooms.room(state, sid) == 1
    lease = state.management.leases[sid]
    assert {lease.start_hour, lease.end_hour} == {10, 20}
    assert result.hours == {10, 20}
    assert map_size(lease.workers) == 3
    assert lease.unattended
    restaurant = state.restaurants[state.stalls[sid].restaurant]
    assert restaurant.owner_kind == :principal
    [{recipe_id, price}] = Map.to_list(restaurant.menu)
    recipe = state.catalog.recipes[recipe_id]
    assert recipe.starter and recipe.kind == :main and recipe.cuisine == result.reference.cuisine
    assert price == recipe.suggested_price
    npc_cuisines = for {_, %{owner_kind: :npc, cuisine: c}} <- state.restaurants, do: c
    refute result.reference.cuisine in npc_cuisines
    assert map_size(state.stalls) == 4
    assert Stats.day_served(result.stats, 0) > 0
  end

  defp starter(cuisine, price, kind \\ :main),
    do:
      {"#{cuisine}_starter",
       %{id: "#{cuisine}_starter", cuisine: cuisine, starter: true, kind: kind, suggested_price: price}}

  defp reference_state(prices, taken) do
    %{
      catalog: %{recipes: Map.new(prices, fn {cuisine, price} -> starter(cuisine, price) end)},
      restaurants: Map.new(taken, &{"r-" <> &1, %{cuisine: &1}})
    }
  end

  test "the default reference cuisine has the median starter price among unused cuisines" do
    # Odd count: the middle price.
    odd = reference_state(%{"a" => 1200, "b" => 900, "c" => 950, "taken" => 100}, ["taken"])
    assert Hall.reference_cuisine(odd) == "c"

    # Even count: the lower of the two middle prices (900, 950, 1000, 1200 -> 950).
    even = reference_state(%{"a" => 1200, "b" => 900, "c" => 950, "d" => 1000}, [])
    assert Hall.reference_cuisine(even) == "c"

    # Several cuisines at the median price: the first by cuisine ID, wherever the middle index falls.
    tied = reference_state(%{"z" => 800, "y" => 950, "m" => 950, "b" => 950, "a" => 1300}, [])
    assert Hall.reference_cuisine(tied) == "b"

    # A cuisine whose starter is not a main does not count.
    drinks = put_in(odd.catalog.recipes["x_starter"], elem(starter("x", 950, :drink), 1))
    assert Hall.reference_cuisine(drinks) == "c"
  end

  test "an override must be an unused cuisine with a starter main" do
    state = reference_state(%{"a" => 1200, "b" => 900, "c" => 950}, ["b"])
    assert Hall.reference_cuisine(state, nil) == Hall.reference_cuisine(state)
    assert Hall.reference_cuisine(state, "a") == "a"
    assert catch_throw(Hall.reference_cuisine(state, "b")) == {:refused, "reference-cuisine", {:cuisine_taken, "b"}}

    assert catch_throw(Hall.reference_cuisine(state, "nope")) ==
             {:refused, "reference-cuisine", {:unknown_cuisine, "nope"}}
  end

  test "--cuisine is parsed for run A and refused when unknown or for run B" do
    assert {:ok, %{cuisine: nil}} = CLI.parse(~w(--run a))
    assert {:ok, %{cuisine: "coast_salish"}} = CLI.parse(~w(--run a --cuisine coast_salish))
    assert {:error, message} = CLI.parse(~w(--run a --cuisine atlantis))
    assert message =~ "--cuisine"
    assert {:error, _} = CLI.parse(~w(--run b --cuisine coast_salish))
  end

  test "--extra-stalls is parsed for run A, 0 to 8, and refused otherwise" do
    assert {:ok, %{extra_stalls: 0}} = CLI.parse(~w(--run a))
    assert {:ok, %{extra_stalls: 2}} = CLI.parse(~w(--run a --extra-stalls 2))
    assert {:ok, %{extra_stalls: 8}} = CLI.parse(~w(--run a --extra-stalls 8))
    assert {:ok, %{extra_stalls: 0}} = CLI.parse(~w(--run b --extra-stalls 0))
    assert {:error, message} = CLI.parse(~w(--run a --extra-stalls 9))
    assert message =~ "--extra-stalls must be 0..8"
    assert {:error, _} = CLI.parse(~w(--run a --extra-stalls -1))
    assert {:error, message} = CLI.parse(~w(--run b --extra-stalls 1))
    assert message =~ "run a only"
  end

  test "extra owners take unused cuisines by distance of the starter price from the median, never the reference's" do
    # Unused prices 800, 900, 950, 1000, 1300: the median is 950 ("c").
    state =
      reference_state(%{"a" => 1300, "b" => 900, "c" => 950, "d" => 1000, "e" => 800, "taken" => 950}, ["taken"])

    assert Hall.reference_cuisine(state) == "c"
    # Distances: b 50, d 50 (the lower price first), e 150, a 350.
    assert Hall.extra_cuisines(state, "c", 0) == []
    assert Hall.extra_cuisines(state, "c", 3) == ["b", "d", "e"]
    assert Hall.extra_cuisines(state, "c", 4) == ["b", "d", "e", "a"]
    # With another reference the median cuisine itself comes first.
    assert Hall.extra_cuisines(state, "a", 2) == ["c", "b"]

    assert catch_throw(Hall.extra_cuisines(state, "c", 5)) ==
             {:refused, "extra-stalls", {:no_unused_cuisine, %{wanted: 5, available: 4}}}
  end

  @tag timeout: 180_000
  test "--extra-stalls 2 adds two more owners like the reference, each on its own cuisine, through commands only" do
    result = run!(%{run: :a, days: 1, extra_stalls: 2})
    assert result.problems == []
    state = HallAuthority.state(result.authority).hall

    assert map_size(state.restaurants) == 6
    assert Enum.count(state.restaurants, fn {_, r} -> r.owner_kind == :npc end) == 3
    assert [%{restaurant_id: "reference"} = reference, extra1, extra2] = result.owners
    assert reference == result.reference
    assert [extra1.restaurant_id, extra2.restaurant_id] == ["extra-1", "extra-2"]

    npc_cuisines = for {_, %{owner_kind: :npc, cuisine: c}} <- state.restaurants, do: c

    unused =
      for {_, %{starter: true, kind: :main} = recipe} <- LaunchCatalog.catalog().recipes,
          recipe.cuisine not in npc_cuisines,
          do: {recipe.suggested_price, recipe.cuisine}

    expected =
      unused
      |> Enum.reject(fn {_price, cuisine} -> cuisine == reference.cuisine end)
      |> Enum.sort_by(fn {price, cuisine} -> {abs(price - reference.price), price, cuisine} end)
      |> Enum.take(2)
      |> Enum.map(&elem(&1, 1))

    assert [extra1.cuisine, extra2.cuisine] == expected
    assert length(Enum.uniq([reference.cuisine | expected] ++ npc_cuisines)) == 6

    for owner <- result.owners do
      sid = owner.stall_id
      assert state.layout[sid] == :standard
      assert Rooms.open?(state, sid)
      lease = state.management.leases[sid]
      assert {lease.start_hour, lease.end_hour} == {10, 20}
      assert map_size(lease.workers) == 3
      assert lease.unattended
      restaurant = state.restaurants[owner.restaurant_id]
      assert restaurant.owner_kind == :principal
      assert restaurant.cuisine == owner.cuisine
      [{recipe_id, price}] = Map.to_list(restaurant.menu)
      recipe = state.catalog.recipes[recipe_id]
      assert recipe.starter and recipe.kind == :main and recipe.cuisine == owner.cuisine
      assert price == recipe.suggested_price
      assert Enum.map(owner.restock, & &1.product) == recipe.lines |> Enum.map(& &1.product) |> Enum.sort()
      assert result.stats.stalls[sid].npc == false
    end

    assert length(Enum.uniq(Enum.map(result.owners, & &1.stall_id))) == 3

    # Nothing reached the hall except through a command: every committed batch has a receipt
    # that accounts for its events, and each owner's set-up is among them under its own device.
    {store_mod, store} = HallAuthority.store(result.authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    events = Enum.sum(for batch <- batches, do: length(batch.events) + length(batch.control_events))

    receipts =
      for batch <- batches do
        assert {:ok, receipt} = store_mod.receipt(store, batch.command_id)
        receipt.event_count
      end

    assert Enum.sum(receipts) == events
    ids = MapSet.new(batches, & &1.command_id)

    for device <- ["reference-owner", "extra-owner-1", "extra-owner-2"],
        step <- ~w(register reserve create staff open) do
      assert MapSet.member?(ids, "#{device}:#{step}"), "#{device}:#{step}"
    end

    # The scale a measured day's arrivals used is the one its opening midnight recorded:
    # the day before's equivalents, or the floor of three when they are fewer.
    closed = for batch <- batches, %{type: :day_closed} = e <- batch.events, do: e
    assert [%{day: 0} = warm_up, %{day: 1} = day1] = closed
    assert warm_up.scale_millis == max(warm_up.equivalents_millis, 3_000)
    assert day1.scale_millis == max(day1.equivalents_millis, 3_000)

    args = %{run: :a, tuning: :current, via: :init, days: 1, seed: @seed, set: [], extra_stalls: 2}
    json = Jason.decode!(CLI.json(result, args))
    assert [day0, measured] = json["summary"]["days"]
    assert day0["equivalents_millis"] == warm_up.equivalents_millis
    assert measured["arrival_scale_millis"] == warm_up.scale_millis
    assert measured["equivalents_millis"] == day1.equivalents_millis
    # 90 arrivals per equivalent at today's values: the day's arrivals follow the recorded scale.
    assert_in_delta measured["arrivals"], 90 * warm_up.scale_millis / 1_000, 1
    assert length(json["owners"]) == 3
    assert length(json["checked_hours"]) == 6
    # An owner stall's short count covers the measured days only, like the verdict's row
    # (the reference is short for its first hour of the warm-up day), and no computer-run stall has one.
    by_stall = Map.new(json["checked_hours"], &{&1["stall"], &1})
    short_row = row(Stats.verdict(:a, result.stats), "A ref open instants short of an ingredient")
    assert by_stall[reference.stall_id]["short"] == short_row.value
    assert Enum.count(json["checked_hours"], &(&1["short"] == nil)) == 3
    assert Stats.summary(result.stats).days |> hd() |> Map.fetch!(:reference_short_samples) > 0

    for row <- json["checked_hours"], key <- ~w(waiting_12 waiting_19 busy_12 busy_19 waiting_10 waiting_14_17) do
      assert is_number(row[key]), "#{row["stall"]} #{key}"
    end

    assert [%{"hour" => 12} = noon, %{"hour" => 19}] = json["rush_hours"]
    assert_in_delta noon["arrivals_per_open_stall"], noon["arrivals_per_day"] / noon["open_stalls"], 0.01
  end

  @tag timeout: 180_000
  test "with enough owner stalls the hall passes three equivalents and the next day's scale follows them" do
    result = run!(%{run: :a, days: 0, extra_stalls: 4})
    {store_mod, store} = HallAuthority.store(result.authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    assert [%{day: 0} = warm_up] = for(batch <- batches, %{type: :day_closed} = e <- batch.events, do: e)
    assert warm_up.equivalents_millis > 3_000
    assert warm_up.scale_millis == warm_up.equivalents_millis
    assert HallAuthority.state(result.authority).hall.demand.supply_scale_millis == warm_up.scale_millis
  end

  @tag timeout: 180_000
  test "run A's default reference sells the median-priced unused starter; --cuisine overrides it" do
    result = run!(%{run: :a})
    state = HallAuthority.state(result.authority).hall
    npc_cuisines = for {_, %{owner_kind: :npc, cuisine: c}} <- state.restaurants, do: c

    unused =
      for {_, %{starter: true, kind: :main} = recipe} <- LaunchCatalog.catalog().recipes,
          recipe.cuisine not in npc_cuisines,
          do: {recipe.suggested_price, recipe.cuisine}

    prices = unused |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    median = Enum.at(prices, div(length(prices) - 1, 2))
    assert rem(length(prices), 2) == 0
    assert Enum.count(prices, &(&1 < median)) < div(length(prices), 2)
    assert Enum.count(prices, &(&1 <= median)) >= div(length(prices), 2)

    assert result.reference.price == median

    assert result.reference.cuisine ==
             unused |> Enum.filter(&(elem(&1, 0) == median)) |> Enum.map(&elem(&1, 1)) |> Enum.min()

    assert state.catalog.recipes[result.reference.recipe].suggested_price == median

    args = %{run: :a, tuning: :current, via: :init, days: 0, seed: @seed, set: []}
    json = Jason.decode!(CLI.json(result, args))
    assert json["reference"]["cuisine"] == result.reference.cuisine
    assert json["reference"]["price"] == median
    assert json["reference"]["recipe"] == result.reference.recipe

    salmon = run!(%{run: :a, cuisine: "coast_salish"})
    assert %{cuisine: "coast_salish", recipe: "roasted_salmon", price: 1220} = salmon.reference

    [taken | _] = Enum.sort(npc_cuisines)
    defaults = %{run: :a, tuning: Tuning.of(LaunchCatalog.catalog()), via: :init, days: 0, seed: @seed}

    assert {:error, {:refused, "reference-cuisine", {:cuisine_taken, ^taken}}} =
             Hall.run(Map.put(defaults, :cuisine, taken))
  end

  @tag timeout: 180_000
  test "--hours 9-21 closes the reference at 19:00; the default keeps it open through every checked hour" do
    long = run!(%{run: :a, days: 1, hours: {9, 21}})
    long_row = row(Stats.verdict(:a, long.stats), "A ref open during checked hours")
    assert %{pass: false} = long_row
    assert long_row.hours[19] == 0.0
    assert long_row.hours[12] == 1.0
    assert {:reference_closed_in_checked_hours, _} = List.keyfind(long.problems, :reference_closed_in_checked_hours, 0)

    default = run!(%{run: :a, days: 1})
    assert %{pass: true, value: 1.0} = row(Stats.verdict(:a, default.stats), "A ref open during checked hours")
    assert default.problems == []
    sid = default.reference.stall_id
    {store_mod, store} = HallAuthority.store(default.authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    # Before 20:00: the staff reach ten working hours exactly at closing, which closes nothing.
    day1_until_20 = Clock.day()..(Clock.day() + 20 * Clock.hour() - 1)

    breaks =
      for batch <- batches,
          batch.hall_ms in day1_until_20,
          %{type: :staff_condition_changed, stall_id: ^sid, condition: :protective_break} <- batch.events,
          do: batch.hall_ms

    assert breaks == []
    long_sid = long.reference.stall_id
    {long_mod, long_store} = HallAuthority.store(long.authority)
    {:ok, long_batches} = long_mod.read_from(long_store, 0)

    long_breaks =
      for batch <- long_batches,
          batch.hall_ms in day1_until_20,
          %{type: :staff_condition_changed, stall_id: ^long_sid, condition: :protective_break} <- batch.events,
          do: batch.hall_ms

    assert (Clock.day() + 19 * Clock.hour()) in long_breaks
  end

  @tag timeout: 180_000
  test "the view's waiting and the sampled waiting agree" do
    parent = self()
    instants = MapSet.new(for i <- 0..19, do: 10 * 150 + i * 75)

    observer = fn tick, authority ->
      if MapSet.member?(instants, tick) do
        state = HallAuthority.state(authority).hall
        {:ok, view} = HallAuthority.management_view(authority, "observer-device")
        {observation, _} = Stats.observe(state, Stats.counters(), nil)
        send(parent, {:compared, tick, view.hall.stalls, Management.queue_activity(state), observation.stalls})
      end
    end

    _ = run!(%{run: :a, observer: observer})

    compared =
      for _ <- 1..20 do
        assert_received {:compared, _tick, view_stalls, activity, sampled}
        assert map_size(sampled) == length(view_stalls)

        for stall <- view_stalls do
          assert stall.activity.waiting == activity[stall.stall_id].waiting
          assert stall.activity.waiting == sampled[stall.stall_id].waiting
          assert stall.activity.cooking == sampled[stall.stall_id].cooking
          assert stall.activity.handover == sampled[stall.stall_id].handover
          stall.activity.waiting
        end
      end

    assert compared |> List.flatten() |> Enum.any?(&(&1 > 0))
  end

  @tag timeout: 180_000
  test "--via retune reaches the same rules as --via init by the first measured midnight" do
    {:ok, tuning} = CLI.tuning("current", ["version=2", "demand.arrivals_per_equivalent=120"])
    init = run!(%{tuning: tuning, via: :init})
    retune = run!(%{tuning: tuning, via: :retune})
    init_state = HallAuthority.state(init.authority).hall
    retune_state = HallAuthority.state(retune.authority).hall
    assert init_state.now == Clock.day()
    assert retune_state.now == Clock.day()
    assert Tuning.of(init_state.catalog) == tuning
    assert Tuning.of(retune_state.catalog) == tuning
    assert init_state.demand.hour_quotas_millis == retune_state.demand.hour_quotas_millis

    default =
      FeudHall.Domain.Demand.hour_quotas(LaunchCatalog.catalog().rules.demand, init_state.demand.supply_scale_millis)

    refute init_state.demand.hour_quotas_millis == default
  end
end
