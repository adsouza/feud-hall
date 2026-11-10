defmodule FeudHall.Domain.ArrivalsTest do
  @moduledoc """
  Seeded simulated arrivals inside the clock advance (boundary class 8): the
  daily quota split, the cumulative arrival schedule, the draws, choice and
  admission through the shared path, and their accounting and replay.
  """

  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Choice, Clock, Demand, Dietary, Hall, Offers}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.{Admission, Advance, Invariants}
  alias FeudHall.Infrastructure.EventCodec
  alias FeudHall.Oracle

  @min Clock.minute()
  @hour Clock.hour()
  @day Clock.day()
  # A stocked world starts at the first market clearing, where its stock was filled.
  @t0 SliceCatalog.rules().market.clear_every_hall_ms

  defp empty_hall(catalog \\ SliceCatalog.catalog()),
    do: run!({nil, []}, {:initialize_hall, %{hall_id: "hall-1", catalog: catalog}}, {:system, :admin}, "init")

  # `{at, event}` for every `diner_arrived`, timed by the clock it was recorded at.
  defp arrivals(events) do
    {_now, timed} =
      Enum.reduce(events, {0, []}, fn
        %{type: :clock_advanced, to: to}, {_now, acc} -> {to, acc}
        %{type: :diner_arrived} = e, {now, acc} -> {now, [{now, e} | acc]}
        _e, acc -> acc
      end)

    Enum.reverse(timed)
  end

  defp non_clock(events), do: Enum.reject(events, &(&1.type == :clock_advanced))

  # The 24 hourly weights with `map`'s hours set, all others zero.
  defp weights(map), do: for(h <- 0..23, do: Map.get(map, h, 0))

  defp curve(catalog, weights, per_equivalent) do
    catalog
    |> put_in([:rules, :demand, :hourly_weights], weights)
    |> put_in([:rules, :demand, :arrivals_per_equivalent], per_equivalent)
  end

  # Advances in steps of `step` hall ms, ending exactly on `to`.
  defp step_to({state, _} = world, to, step) do
    if state.now >= to,
      do: world,
      else: world |> advance_hall(min(state.now + step, to)) |> step_to(to, step)
  end

  # Independent schedule: the instant at which the `k`-th arrival (1-based)
  # after `start` falls, given the carried milli-arrivals and the day's quotas.
  # An arrival falls at the start of the hall millisecond during which the
  # accumulator reaches the next whole arrival.
  defp expected_at(start, carried, quotas, k) do
    need = 1000 * k - carried

    {h, before} =
      quotas
      |> Enum.scan(&(&1 + &2))
      |> Enum.find_index(&(&1 >= need))
      |> then(fn h -> {h, if(h == 0, do: 0, else: Enum.sum(Enum.take(quotas, h)))} end)

    q = Enum.at(quotas, h)
    start + h * @hour + div((need - before) * @hour + q - 1, q) - 1
  end

  describe "daily quotas" do
    test "the day's milli-arrivals split by hourly weight with largest remainders, ties by hour" do
      rules = %{arrivals_per_equivalent: 10, hourly_weights: weights(%{0 => 1, 1 => 1, 2 => 1})}
      assert Demand.hour_quotas(rules, 1) == weights(%{0 => 4, 1 => 3, 2 => 3})

      shipped = SliceCatalog.rules().demand
      quotas = Demand.hour_quotas(shipped, 3_000)
      total = Enum.sum(shipped.hourly_weights)

      assert length(quotas) == 24
      assert Enum.sum(quotas) == 90 * 3_000

      for {q, w} <- Enum.zip(quotas, shipped.hourly_weights) do
        assert (q - div(270_000 * w, total)) in [0, 1]
        if w == 0, do: assert(q == 0)
      end
    end

    test "day 0 quotas are fixed at initialization from the floor scale, and each midnight records the next day's" do
      {state, _} = empty_hall()
      rules = state.catalog.rules.demand

      assert state.demand.hour_quotas_millis == Demand.hour_quotas(rules, rules.equivalent_floor_millis)
      assert %{acc_millis: 0, acc_at: 0, arrival_seq: 0} = state.demand

      {state, events} = advance_hall({state, []}, @day)
      assert [%{hour_quotas_millis: quotas, scale_millis: scale}] = Enum.filter(events, &(&1.type == :day_closed))
      assert quotas == Demand.hour_quotas(rules, scale)
      assert state.demand.hour_quotas_millis == quotas
      assert %{acc_at: @day, arrival_seq: 0} = state.demand
    end
  end

  describe "the arrival schedule" do
    test "a day at scale 3000 brings exactly 90 * 3 = 270 arrivals, none in hours 3 and 4" do
      {state, events} = empty_hall() |> advance_hall(@day)
      timed = arrivals(events)
      quotas = Demand.hour_quotas(SliceCatalog.rules().demand, 3_000)

      assert length(timed) == 270
      assert Enum.all?(timed, fn {at, _} -> at < @day end)
      assert Enum.filter(timed, fn {at, _} -> Clock.time_of_day(at) in (3 * @hour)..(5 * @hour - 1) end) == []
      assert Enum.map(timed, &elem(&1, 0)) == Enum.map(1..270, &expected_at(0, 0, quotas, &1))

      # An empty hall: every diner leaves without a draw for a stall.
      assert Enum.all?(timed, fn {_, e} -> e.outcome == :left and e.reason == :no_open_stall end)
      assert Enum.map(timed, fn {_, e} -> e.arrival_id end) == Enum.map(0..269, &"A0-#{&1}")
      # Nothing carried into day 1: 270,000 milli-arrivals is whole.
      assert %{acc_millis: 0, arrival_seq: 0} = state.demand
    end

    test "1-minute, 17-minute and single advances over a day record identical events" do
      world = stocked_world()
      to = elem(world, 0).now + @day

      {single, single_log} = advance_hall(world, to)
      {minutes, minutes_log} = step_to(world, to, @min)
      {seventeens, seventeens_log} = step_to(world, to, 17 * @min)

      assert non_clock(minutes_log) == non_clock(single_log)
      assert non_clock(seventeens_log) == non_clock(single_log)
      assert minutes == single and seventeens == single

      outcomes = single_log |> arrivals() |> Enum.map(fn {_, e} -> e.outcome end) |> Enum.frequencies()
      assert Map.get(outcomes, :admitted, 0) > 0 and Map.get(outcomes, :left, 0) > 0
    end

    test "cuts exactly at and just before each arrival equal one advance" do
      {start, _} = stocked_world()
      to = start.now + 12 * @hour

      # Cut at a - 1 and at a (the boundary equals the target) for the first eight arrivals.
      {cut, cut_log} =
        Enum.reduce(1..8, {start, []}, fn _, {s, log} ->
          a = s.demand.next_arrival_at

          Enum.reduce([a - 1, a], {s, log}, fn t, {s, log} ->
            events = Advance.run(s, t)
            {Hall.replay(events, s), log ++ events}
          end)
        end)

      assert cut.now < to
      events = Advance.run(cut, to)
      cut = Hall.replay(events, cut)
      single_log = Advance.run(start, to)

      assert non_clock(cut_log ++ events) == non_clock(single_log)
      assert cut == Hall.replay(single_log, start)
      assert Enum.any?(single_log, &match?(%{type: :diner_arrived, outcome: :admitted}, &1))
      assert Enum.any?(single_log, &(&1.type == :stage_started))
    end

    test "two complete game days in one advance equal the same span in many small advances" do
      world = stocked_world()
      to = elem(world, 0).now + 2 * @day

      {single, single_log} = advance_hall(world, to)
      {small, small_log} = step_to(world, to, 7 * @min)

      assert non_clock(small_log) == non_clock(single_log)
      assert small == single
      assert length(Enum.filter(single_log, &(&1.type == :day_closed))) == 2
      assert length(arrivals(single_log)) >= 2 * 270
      Oracle.assert_settled!(single, single_log)
    end
  end

  describe "cleaning, reopening and midnight (Review Focus 2)" do
    test "nothing is due at 03:00 or during cleaning, and the reopening brings no surge" do
      # One whole arrival in hour 2 and two in hour 5: hour 2's arrival is
      # completed exactly as the hour ends, so an end-of-hour crossing would
      # fall at exactly 03:00. It belongs to hour 2's last millisecond.
      catalog = curve(SliceCatalog.catalog(), weights(%{2 => 1, 5 => 2}), 1)
      {state, events} = empty_hall(catalog) |> advance_hall(Clock.cleaning_start_of(0))

      assert state.demand.hour_quotas_millis == weights(%{2 => 1_000, 5 => 2_000})
      assert [{at, _}] = arrivals(events)
      assert at == 3 * @hour - 1
      # Advancing to exactly 03:00 starts cleaning and no one arrives at that instant.
      assert Enum.any?(events, &(&1.type == :hall_cleaning_started))

      {_state, rest} = advance_hall({state, []}, Clock.cleaning_end_of(0) + @hour)
      times = for {at, _} <- arrivals(rest), do: at

      # Nothing accrued during cleaning; hour 5's first arrival is half way through it.
      assert times == [5 * @hour + 30 * @min - 1, 6 * @hour - 1]
    end

    test "the midnight forecast applies before an arrival due exactly at 00:00, which belongs to the new day" do
      # Hour 0 accrues one milli-arrival per hall millisecond and hour 23 leaves
      # 999 behind, so day 1's first millisecond completes an arrival.
      catalog =
        SliceCatalog.catalog()
        |> curve(weights(%{0 => 3_600_000, 23 => 999}), 3_600_999)
        |> put_in([:rules, :demand, :equivalent_floor_millis], 1)

      {state, events} = empty_hall(catalog) |> advance_hall(@day)

      day0 = Enum.filter(arrivals(events), fn {at, _} -> at < @day end)
      assert length(day0) == 3_600
      assert List.last(day0) |> elem(0) == @hour - 1
      [closed] = Enum.filter(events, &(&1.type == :day_closed))
      assert closed.summary.arrivals == 3_600
      # The day carried 999 into day 1, whose first millisecond completed A1-0.
      assert %{acc_millis: 999, acc_at: @day, arrival_seq: 1} = state.demand

      at_midnight = events |> Enum.drop_while(&(&1.type != :day_closed)) |> non_clock()
      # Scheduling order at 00:00: the forecast, the market clearing, then the arrival.
      assert [%{type: :day_closed}, %{type: :market_cleared}, %{type: :diner_arrived, arrival_id: "A1-0"} | _] =
               at_midnight

      assert {@day, %{arrival_id: "A1-0"}} = List.last(arrivals(events))
      assert state.demand.today.arrivals == 1
      assert state.demand.next_arrival_at == @day + 1_000
    end

    test "Demand.next_arrival_at carries the remainder into the new day's quotas" do
      demand = %{hour_quotas_millis: weights(%{1 => 2_000}), acc_millis: 600, acc_at: @day, arrival_seq: 0}
      # 400 more milli-arrivals at 2,000 per hour: 12 minutes into hour 1; the next 1,000 take 30 more.
      assert Demand.next_arrival_at(demand) == @day + @hour + 12 * @min - 1
      assert Demand.next_arrival_at(%{demand | arrival_seq: 1}) == @day + @hour + 42 * @min - 1
      # 2,600 in all: nothing more is scheduled until the next midnight records new quotas.
      assert Demand.next_arrival_at(%{demand | arrival_seq: 2}) == nil
      assert Demand.next_arrival_at(%{demand | hour_quotas_millis: []}) == nil
    end
  end

  describe "a simulated diner" do
    # One unrestricted diner per day at 00:59:59.999 whose patience (17 hall
    # minutes, inside the shipped 5-40 minute ranges) is exactly the quoted
    # wait for chicken tacos with a ten-minute preparation.
    defp patient_catalog do
      catalog = SliceCatalog.catalog()

      segments =
        Enum.map(catalog.rules.demand.segments, fn s ->
          %{
            s
            | budget: [5_000, 5_000],
              patience_hall_ms: [17 * @min, 17 * @min],
              drink_attach_permille: 0,
              leave_weight: 0,
              main_preference: Map.put(s.main_preference, "chicken_tacos", 1_000_000_000)
          }
        end)

      catalog
      |> curve(weights(%{0 => 1, 1 => 2}), 1)
      |> put_in([:rules, :demand, :segments], segments)
      |> put_in([:rules, :demand, :profile_mix], %{"unrestricted" => 1})
      |> put_in([:recipes, "chicken_tacos", :prep_ms], 10 * @min)
    end

    test "patience caps the tray deadline, and a slower queue than quoted abandons it scored 0" do
      arrival = @hour - 1
      world = stocked_world(catalog: patient_catalog()) |> advance_hall(ceil_to_tick(arrival + 8 * @min))
      {state, events} = world

      assert [{^arrival, %{arrival_id: "A0-0", outcome: :admitted, patience_hall_ms: patience}}] = arrivals(events)
      assert patience == 17 * @min
      tray = state.trays["T:A0-0"]
      # Quoted: 10 min prep + 3 min finish + 4 min handover, exactly the patience.
      assert tray.estimated_completion == arrival + 17 * @min
      assert tray.deadline == arrival + patience
      assert tray.deadline < arrival + state.catalog.rules.service_window_ms

      # A short-prep tray accepted later takes the finishing station first.
      {state, events} =
        world |> simulated_visit("late", "bean_tacos") |> advance_hall(ceil_to_tick(arrival + 20 * @min))

      assert %{type: :tray_cancelled, reason: :deadline_missed} =
               Enum.find(events, &(&1.type == :tray_cancelled and &1.tray_id == "T:A0-0"))

      assert %{reason: :main_failed, score: 0} = visit_outcome({state, events}, "V:A0-0")
      refute Map.has_key?(state.visits, "V:A0-0")
      Oracle.assert_settled!(state, events)
    end

    test "an admitted arrival is bound to exactly the quote and pick Choice saw" do
      {_state, events} = stocked_world() |> advance_hall(@t0 + 3 * @hour)

      index = Enum.find_index(events, &match?(%{type: :diner_arrived, outcome: :admitted}, &1))
      assert index != nil
      {before, [arrived, admitted, accepted | _]} = Enum.split(events, index)
      seen = Hall.replay(before)

      segment = Enum.find(seen.catalog.rules.demand.segments, &(&1.id == arrived.segment))
      {:ok, requirement} = Dietary.requirement(seen.catalog, arrived.profile_id)

      diner = %{
        segment: segment,
        budget: arrived.budget,
        requirement: requirement,
        patience_hall_ms: arrived.patience_hall_ms,
        drink?: arrived.drink?
      }

      # The recorded draws are the demand stream's, and choosing from them gives the recorded pick and rng.
      {draw, rng} = Demand.draw_diner(seen.catalog, seen.demand.rng)

      assert Map.take(draw, [:budget, :patience_hall_ms, :profile_id, :drink?, :dessert_appetite?]) ==
               Map.take(arrived, [:budget, :patience_hall_ms, :profile_id, :drink?, :dessert_appetite?])

      main = Enum.find(accepted.components, &(&1.kind == :main)).recipe_id
      drink = Enum.find_value(accepted.components, &(&1.kind == :drink && &1.recipe_id))
      assert Choice.choose(seen, diner, rng) == {{:stall, accepted.stall_id, main, drink}, arrived.rng}

      blank = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
      {:ok, quote} = Offers.quote_tray(seen, accepted.stall_id, main, drink, blank)
      keys = [:kind, :recipe_id, :recipe_version, :price, :lines, :penalty, :quality, :carbs_mg, :prep_ms, :finish_ms]
      assert Enum.map(accepted.components, &Map.take(&1, keys)) == Enum.map(quote.components, &Map.take(&1, keys))
      assert accepted.estimated_completion == quote.earliest_completion

      assert accepted.deadline ==
               Enum.min([quote.deadline, seen.now + arrived.patience_hall_ms, Clock.service_cutoff(seen.now)])

      assert %{source: :simulated, principal: "diner:D0-" <> _, budget: budget} = admitted
      assert budget == arrived.budget
      assert admitted.dessert_appetite? == arrived.dessert_appetite?
    end
  end

  describe "patience and collisions" do
    test "with shipped segments, patience binds below the 45-minute service window" do
      {state, events} = stocked_world() |> advance_hall(@t0 + @day)
      window = state.catalog.rules.service_window_ms
      # Finished trays have left state; each one's bound deadline is in its acceptance.
      deadlines = for %{type: :tray_accepted} = e <- events, into: %{}, do: {e.tray_id, e.deadline}

      bound =
        for {at, %{outcome: :admitted} = e} <- arrivals(events),
            deadline = deadlines["T:" <> e.arrival_id],
            do: {deadline, Enum.min([at + e.patience_hall_ms, at + window, Clock.service_cutoff(at)])}

      assert bound != []
      assert Enum.all?(bound, fn {deadline, expected} -> deadline == expected end)
      assert Enum.any?(arrivals(events), fn {_, e} -> e.patience_hall_ms < window end)

      assert Enum.any?(arrivals(events), fn {at, e} ->
               e.outcome == :admitted and deadlines["T:" <> e.arrival_id] == at + e.patience_hall_ms and
                 e.patience_hall_ms < window
             end)
    end

    # The application boundary refuses the arrival shape as a command ID for every actor; the
    # domain itself refuses only an ID a live visit or tray holds.
    test "an arrival whose IDs a live visit already holds is recorded as having left, not admitted twice" do
      # A fixture command under the first arrival's entity ID holds V:A0-0 and T:A0-0.
      {state, log} =
        stocked_world(catalog: patient_catalog())
        |> run!(
          {:admit_visit,
           %{
             source: :simulated,
             diner_id: "x",
             budget: 5_000,
             stall_id: "s001",
             main: "bean_tacos",
             profile_id: "unrestricted"
           }},
          {:system, :demand},
          "A0-0"
        )

      # Keep that visit live until the arrival: a long preparation, and a deadline after it.
      [main] = state.trays["T:A0-0"].components
      late = 3 * @hour

      world =
        {state
         |> put_in([:orders, main, :prep_ms], 2 * @hour)
         |> put_in([:orders, main, :deadline], late)
         |> put_in([:trays, "T:A0-0", :deadline], late), log}

      {before, _} = world
      taken = before.visits["V:A0-0"]
      {state, events} = advance_hall(world, ceil_to_tick(@hour))

      assert [{_, %{arrival_id: "A0-0", outcome: :left, reason: :admission_failed}}] = arrivals(events)
      assert state.visits["V:A0-0"].principal == taken.principal
      assert state.stats.left_simulated == %{admission_failed: 1}
      Oracle.assert_settled!(state, events)
    end

    test "Admission refuses an entity ID whose visit or tray already exists" do
      {state, _} = stocked_world(arrivals: false) |> simulated_visit("d1", "bean_tacos")

      request = %{
        source: :simulated,
        principal: "diner:other",
        budget: 5_000,
        stall_id: "s001",
        main: "bean_tacos",
        drink: nil,
        profile_id: "unrestricted",
        confirmed: nil,
        deadline_cap: nil
      }

      assert {:error, :visit_id_taken} = Admission.admit(state, request, "visit-d1")
      assert {:ok, _} = Admission.admit(state, request, "visit-d2")
    end
  end

  describe "accounting and replay" do
    setup do
      {state, events} = stocked_world() |> advance_hall(@t0 + @day)
      %{state: state, events: events}
    end

    test "arrivals partition into admitted and left, per source and in the day summary", %{state: s, events: events} do
      timed = arrivals(events)
      admitted = Enum.count(timed, fn {_, e} -> e.outcome == :admitted end)
      left = for {_, %{outcome: :left, reason: r}} <- timed, reduce: %{}, do: (acc -> Map.update(acc, r, 1, &(&1 + 1)))

      assert %{arrivals_simulated: n, admitted_simulated: ^admitted, left_simulated: ^left} = s.stats
      assert n == length(timed) and n == admitted + Enum.sum(Map.values(left))
      assert admitted > 0 and left != %{}

      # Each admitted arrival opened its visit, recording the dessert appetite drawn; a visit
      # still live remembers it.
      admissions = for %{type: :visit_admitted} = e <- events, into: %{}, do: {e.visit_id, e}

      for {_, %{outcome: :admitted} = e} <- timed do
        assert %{source: :simulated, dessert_appetite?: appetite} = admissions["V:" <> e.arrival_id]
        assert appetite == e.dessert_appetite?

        case s.visits["V:" <> e.arrival_id] do
          nil -> assert visit_outcome({s, events}, "V:" <> e.arrival_id)
          visit -> assert visit.dessert_appetite? == e.dessert_appetite?
        end
      end

      [closed] = Enum.filter(events, &(&1.type == :day_closed))
      day0 = Enum.filter(timed, fn {at, _} -> at < @day end)
      assert closed.summary.arrivals == length(day0)
      assert closed.summary.admitted == Enum.count(day0, fn {_, e} -> e.outcome == :admitted end)

      Oracle.assert_settled!(s, events)
      assert Invariants.check(s) == :ok
    end

    test "the oracle notices a miscounted arrival", %{state: s, events: events} do
      broken = update_in(s, [:stats, :arrivals_simulated], &(&1 + 1))
      assert :simulated_arrival_count in Oracle.violations(broken, events)
    end

    test "replay reproduces the state from the recorded draws without drawing", %{state: s, events: events} do
      assert Hall.replay(events) == s
      assert s.demand.rng == events |> Enum.filter(&(&1.type == :diner_arrived)) |> List.last() |> Map.get(:rng)

      # Replay takes the continuation from the event, so a different recorded value is what it keeps.
      index = Enum.find_index(Enum.reverse(events), &(&1.type == :diner_arrived))
      position = length(events) - 1 - index
      tampered = List.update_at(events, position, &%{&1 | rng: 12_345})
      assert Hall.replay(tampered).demand.rng == 12_345
    end

    test "every event round-trips through the codec", %{events: events} do
      assert Enum.any?(events, &(&1.type == :diner_arrived))

      for e <- events do
        assert {:ok, ^e} = e |> EventCodec.encode!() |> EventCodec.decode()
      end
    end

    test "recovery rejects an overdue arrival or an accumulator out of range", %{state: s} do
      assert {:error, problems} = Invariants.check(put_in(s, [:demand, :next_arrival_at], s.now))
      assert {:arrival_overdue, s.now} in problems

      assert {:error, problems} = Invariants.check(put_in(s, [:demand, :acc_millis], 1_000))
      assert {:arrival_accumulator_out_of_range, 1_000} in problems
    end
  end

  describe "fixtures" do
    test "a quiet catalog brings no simulated diners" do
      {state, events} = empty_hall(quiet_catalog()) |> advance_hall(@day)
      assert arrivals(events) == []
      assert state.demand.next_arrival_at == nil
      assert state.stats.arrivals_simulated == 0
    end
  end
end
