defmodule FeudHall.Domain.RetentionTest do
  @moduledoc """
  Finished work leaves live hall state: a visit's single finalization removes
  the visit, its tray and its orders in the same transition, so state and
  advance cost are bounded by live work, not by history. The facts stay in
  the log (and in the ledger, stats and day counters they already updated).
  """

  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.{Clock, Hall, Kitchen, Offers}
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Infrastructure.{InMemoryEventStore, Snapshot}
  alias FeudHall.Oracle

  @min Clock.minute()
  @hour Clock.hour()
  @three 3 * @hour

  # The visit, its tray and every order its finalization names are gone from live state,
  # and both checkers accept the state.
  defp assert_retired!({state, log} = world, vid) do
    assert %{components: components} = visit_outcome(world, vid), "#{vid} was not finalized"
    assert Enum.count(log, &match?(%{type: :visit_finalized, visit_id: ^vid}, &1)) == 1
    refute Map.has_key?(state.visits, vid)
    refute Enum.any?(state.trays, fn {_, t} -> t.visit == vid end)
    refute Enum.any?(state.orders, fn {_, o} -> o.visit == vid end)
    for %{order_id: oid} <- components, do: refute(Map.has_key?(state.orders, oid))
    refute Enum.any?(Map.values(state.active_visits), &(&1 == vid))
    assert Invariants.check(state) == :ok
    Oracle.assert_settled!(state, log)
    world
  end

  defp guest_served(w, id) do
    w |> grant("gina", 2_500, "grant-" <> id) |> guest_visit("gina", id, "bean_tacos") |> serve_tray(tray_id(id))
  end

  describe "every finalization retires its visit, tray and orders" do
    setup do
      %{world: stocked_world(arrivals: false)}
    end

    test "simulated diner served, dessert declined at service", %{world: w} do
      w = w |> simulated_visit("d1", "bean_tacos") |> serve_tray(tray_id("visit-d1"))
      {state, _} = assert_retired!(w, visit_id("visit-d1"))

      assert %{reason: :completed, score: 10_000, competitive: true} = visit_outcome(w, visit_id("visit-d1"))
      assert state.restaurants["r1"].ledger.revenue == 900
      assert %{arrivals: 1, served_mains: 1, finalized_visits: 1} = state.stats
      assert %{admitted: 1, trays_served: 1, left: %{}} = state.demand.today
    end

    test "guest served and completed by declining the offered dessert", %{world: w} do
      w = guest_served(w, "g1")
      assert elem(w, 0).visits[visit_id("g1")].dessert == :offered
      w = run!(w, {:decline_dessert, %{visit_id: visit_id("g1")}}, {:principal, "gina"}, "decline")
      {state, _} = assert_retired!(w, visit_id("g1"))

      assert %{reason: :completed, score: 10_000, competitive: false} = visit_outcome(w, visit_id("g1"))
      assert state.active_visits == %{}
      assert state.restaurants["r1"].ledger.revenue == 900
      # The served course was paid from the wallet; nothing stays reserved.
      assert [%{amount: 1_600, reserved: 0}] = Map.values(state.wallets["gina"].slices)
    end

    test "guest dessert offer expiring", %{world: w} do
      w = guest_served(w, "g1")
      deadline = elem(w, 0).visits[visit_id("g1")].dessert_offer_deadline
      w = advance_hall(w, ceil_to_tick(deadline))
      assert_retired!(w, visit_id("g1"))
      assert %{reason: :dessert_offer_expired} = visit_outcome(w, visit_id("g1"))
    end

    test "guest cancelling before preparation", %{world: w} do
      w = w |> grant("gina", 2_500, "grant") |> guest_visit("gina", "g1", "bean_tacos", "horchata")
      w = run!(w, {:cancel_tray, %{tray_id: tray_id("g1")}}, {:principal, "gina"}, "cancel")
      {state, _} = assert_retired!(w, visit_id("g1"))

      assert %{reason: :guest_cancelled, score: nil} = visit_outcome(w, visit_id("g1"))
      assert tray_status(w, tray_id("g1")) == :cancelled
      assert state.demand.today.left == %{guest_cancelled: 1}
      assert [%{amount: 2_500, reserved: 0}] = Map.values(state.wallets["gina"].slices)
    end

    test "a missed tray deadline", %{world: w} do
      {state, log} = simulated_visit(w, "d1", "bean_tacos")
      tray = state.trays[tray_id("visit-d1")]
      early = tray.estimated_completion - 2 * @min
      [main] = tray.components
      state = state |> put_in([:trays, tray.id, :deadline], early) |> put_in([:orders, main, :deadline], early)
      w = advance_hall({state, log}, ceil_to_tick(tray.estimated_completion))
      {state, _} = assert_retired!(w, visit_id("visit-d1"))

      assert %{reason: :main_failed, score: 0} = visit_outcome(w, visit_id("visit-d1"))
      assert order_cancel_reason(w, main) == :deadline_missed
      assert state.restaurants["r1"].ledger.waste > 0
      assert state.stalls["s001"].counter == nil
    end

    test "the 03:00 cleaning cutoff", %{world: w} do
      {state, log} = w |> advance_hall(@three - 14 * @min) |> simulated_visit("late", "bean_tacos", "horchata")
      # The quote finishes before 03:00; a slower counter afterwards keeps the tray in the kitchen.
      w = advance_hall({put_in(state, [:catalog, :rules, :handover_ms], 30 * @min), log}, @three + @min)
      {state, _} = assert_retired!(w, visit_id("visit-late"))

      assert %{reason: :cleaning, score: nil, competitive: false} = visit_outcome(w, visit_id("visit-late"))
      assert state.restaurants["r1"].ledger.wip == 0
      assert {state.visits, state.trays, state.orders} == {%{}, %{}, %{}}
    end

    test "a dessert served after the main", %{world: w} do
      w = w |> simulated_visit("d1", "bean_tacos", "horchata", "unrestricted", 10_000, true)
      w = serve_tray(w, tray_id("visit-d1"))
      dessert = elem(w, 0).visits[visit_id("visit-d1")].dessert_order
      w = serve_dessert(w, dessert)
      {state, _} = assert_retired!(w, visit_id("visit-d1"))

      assert %{reason: :completed, score: 10_000} = outcome = visit_outcome(w, visit_id("visit-d1"))
      assert Enum.map(outcome.components, & &1.kind) == [:main, :drink, :dessert]
      assert %{served_mains: 1, served_drinks: 1, served_desserts: 1, finalized_visits: 1} = state.stats
    end

    test "a guest cancelling an accepted dessert", %{world: w} do
      w = guest_served(w, "g1")
      {state, _} = w
      {:ok, quote} = Offers.quote_dessert(state, state.visits[visit_id("g1")])
      confirmed = Offers.terms(quote)
      w = run!(w, {:accept_dessert, %{visit_id: visit_id("g1"), confirmed: confirmed}}, {:principal, "gina"}, "d")
      w = run!(w, {:cancel_dessert, %{visit_id: visit_id("g1")}}, {:principal, "gina"}, "d-cancel")
      assert_retired!(w, visit_id("g1"))
      assert %{reason: :dessert_cancelled, score: 10_000} = visit_outcome(w, visit_id("g1"))
    end
  end

  test "a served main with a dessert still in the kitchen stays live until the dessert settles" do
    w = stocked_world(arrivals: false) |> simulated_visit("d1", "bean_tacos", nil, "unrestricted", 10_000, true)
    w = serve_tray(w, tray_id("visit-d1"))
    {state, _} = w
    vid = visit_id("visit-d1")

    assert visit_outcome(w, vid) == nil
    assert %{dessert: :accepted, dessert_order: dessert} = state.visits[vid]
    assert state.trays[tray_id("visit-d1")].status == :served
    [main] = state.trays[tray_id("visit-d1")].components
    assert state.orders[main].status == :served
    assert state.orders[dessert].status in Kitchen.stages()
    assert Invariants.check(state) == :ok

    w = serve_dessert(w, dessert)
    assert_retired!(w, vid)
  end

  # The oracle checks finished visits from the events and live entities against them.
  test "the oracle notices retained or lost visits and finalizations that break the lifecycle" do
    w = stocked_world(arrivals: false) |> simulated_visit("d1", "bean_tacos")
    {before, _} = w
    {state, log} = serve_tray(w, tray_id("visit-d1"))
    vid = visit_id("visit-d1")
    assert Oracle.violations(state, log) == []

    retained = put_in(state, [:visits, vid], before.visits[vid])
    assert [:live_visit_count, :live_visits_mismatch] -- Oracle.violations(retained, log) == []

    tid = tray_id("visit-d1")
    tray_kept = put_in(state, [:trays, tid], %{before.trays[tid] | status: :served})
    assert :live_trays_mismatch in Oracle.violations(tray_kept, log)

    # A log whose finalization precedes the service it depends on, or repeats.
    at = Enum.find_index(log, &match?(%{type: :tray_served, tray_id: ^tid}, &1))
    [served, %{type: :dessert_declined} = declined, %{type: :visit_finalized} = finalized] = Enum.slice(log, at, 3)

    early = (log -- [served, declined, finalized]) ++ [finalized, served, declined]
    assert {:finalized_with_open_work, vid} in Oracle.violations(state, early)

    twice = log ++ [finalized]
    assert :visit_finalized_more_than_once in Oracle.violations(state, twice)
  end

  test "FIFO survives retirement: sequence numbers are never reused" do
    w = stocked_world(arrivals: false)
    w = w |> simulated_visit("a", "bean_tacos") |> simulated_visit("b", "bean_tacos")
    {state, _} = w
    [a] = state.trays[tray_id("visit-a")].components
    [b] = state.trays[tray_id("visit-b")].components
    assert {state.orders[a].seq, state.orders[b].seq} == {0, 1}

    # One finishing station: A is handed over first and retires while B is still in the kitchen.
    w = serve_tray(w, tray_id("visit-a"))
    {state, _} = w
    refute Map.has_key?(state.orders, a)
    assert state.orders[b].status in Kitchen.stages()
    assert Kitchen.next_seq(state) == state.order_seq
    assert state.order_seq == 2

    w = simulated_visit(w, "c", "bean_tacos")
    {state, _} = w
    [c] = state.trays[tray_id("visit-c")].components
    # A map-size sequence would have given C the number B holds.
    assert state.orders[c].seq == 2
    assert {state.orders[b].queued_at, state.orders[b].seq} < {state.orders[c].queued_at, state.orders[c].seq}

    w = serve_tray(w, tray_id("visit-b"))
    w = serve_tray(w, tray_id("visit-c"))
    {state, log} = w
    assert {state.visits, state.trays, state.orders} == {%{}, %{}, %{}}
    assert state.order_seq == 3
    Oracle.assert_settled!(state, log)
  end

  describe "a retired entity's ID cannot be reused through the application boundary" do
    defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

    defp execute!(rt, id, actor, command) do
      assert {:accepted, _, rt} = Workflow.execute(rt, env(id, actor, command))
      rt
    end

    defp workflow_world do
      {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())

      [arrivals: false]
      |> stocked_world_steps()
      |> Enum.reduce(rt, fn step, rt ->
        {command, actor, id} = step.(rt.state)
        execute!(rt, id, actor, command)
      end)
    end

    defp advance_to(rt, hall_ms) do
      ms = div(ceil_to_tick(hall_ms), Clock.ratio())
      execute!(rt, "adv-#{ms}", {:system, :scheduler}, {:advance_clock, %{to_service_ms: ms}})
    end

    test "per ID family: client command IDs, arrivals and simulated desserts" do
      rt =
        execute!(
          workflow_world(),
          "grant",
          {:system, :visitor_fund},
          {:grant_allowance, %{principal: "gina", amount: 2_500}}
        )

      state = rt.state
      {:ok, requirement} = FeudHall.Domain.Dietary.requirement(state.catalog, "unrestricted")
      blank = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
      {:ok, quote} = Offers.quote_tray(state, "s001", "bean_tacos", nil, blank)

      admit =
        {:admit_visit,
         %{
           source: :guest,
           stall_id: "s001",
           main: "bean_tacos",
           profile_id: "unrestricted",
           confirmed: Offers.terms(quote)
         }}

      rt = execute!(rt, "g1", {:principal, "gina"}, admit)
      rt = advance_to(rt, rt.state.trays["T:g1"].estimated_completion)
      rt = execute!(rt, "g1-decline", {:principal, "gina"}, {:decline_dessert, %{visit_id: "V:g1"}})
      refute Map.has_key?(rt.state.visits, "V:g1")
      refute Map.has_key?(rt.state.trays, "T:g1")
      refute Map.has_key?(rt.state.orders, "O:g1:main")

      # Client command IDs: the receipt binds "g1" for good. The same request returns the
      # original receipt; any other request under it is a conflict, never a new visit.
      assert {:replayed, %{outcome: :accepted}, rt} = Workflow.execute(rt, env("g1", {:principal, "gina"}, admit))
      other = put_in(admit, [Access.elem(1), :main], "chicken_tacos")
      assert {:error, :command_id_conflict, rt} = Workflow.execute(rt, env("g1", {:principal, "gina"}, other))
      refute Map.has_key?(rt.state.visits, "V:g1")

      # Arrivals (`A<day>-<seq>`) and simulated desserts (`DS:<visit>`) are minted by the clock
      # advance itself, so no actor, system ones included, may use them as command IDs.
      simulated =
        {:admit_visit, %{source: :simulated, diner_id: "x", budget: 5_000, stall_id: "s001", main: "bean_tacos"}}

      for {id, actor, command} <- [
            {"A0-0", {:system, :demand}, simulated},
            {"A3-17", {:system, :scheduler}, {:advance_clock, %{to_service_ms: 1}}},
            {"DS:V:A0-0", {:system, :demand}, {:accept_dessert, %{visit_id: "V:A0-0"}}},
            {"DS:x", {:system, :admin}, {:advance_clock, %{to_service_ms: 1}}}
          ] do
        assert {:error, :reserved_command_id, _} = Workflow.execute(rt, env(id, actor, command))
      end
    end

    test "the domain itself guards only live entities: uniqueness over history is the boundary's" do
      w = stocked_world(arrivals: false) |> simulated_visit("d1", "bean_tacos")
      {state, _} = w

      request =
        {:admit_visit,
         %{
           source: :simulated,
           diner_id: "y",
           budget: 5_000,
           stall_id: "s001",
           main: "bean_tacos",
           profile_id: "unrestricted"
         }}

      assert {:error, :visit_id_taken} = Hall.decide(state, request, ctx({:system, :demand}, "visit-d1"))

      {state, _} = serve_tray(w, tray_id("visit-d1"))

      assert {:ok, [%{type: :visit_admitted, visit_id: "V:visit-d1"} | _]} =
               Hall.decide(state, request, ctx({:system, :demand}, "visit-d1"))
    end
  end
end

defmodule FeudHall.Domain.RetentionHistoryTest do
  @moduledoc """
  A hall with the arrival stream on over five game days: live state stays
  bounded by live work while finished visits accumulate in the log, and
  replay from genesis or a mid-day snapshot matches the live run.
  """

  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Hall}
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Infrastructure.Snapshot
  alias FeudHall.Oracle

  @min Clock.minute()
  @hour Clock.hour()
  @day Clock.day()

  @step 20 * @min

  setup_all do
    # Restock alice's stall after each day's 05:00 reopening so diners keep being served, then
    # advance in 20-minute steps to 23:00, sampling live sizes after every step.
    acc = %{samples: [], noon_bytes: [], mid: nil}

    {world, acc} =
      Enum.reduce(0..4, {stocked_world(), acc}, fn day, {w, acc} ->
        w = w |> advance_hall(day * @day + 5 * @hour + @step) |> restock()
        sample_through(w, day * @day + 23 * @hour, acc)
      end)

    Map.put(acc, :world, world)
  end

  # Requests the restock and lets the next clearing fill what the market can spare.
  defp restock({state, _} = w) do
    default_stock()
    |> Enum.sort()
    |> Enum.reduce(w, fn {product, qty}, w ->
      request = %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}
      run!(w, {:submit_purchase_request, request}, owner(), "restock-#{product}-#{state.now}")
    end)
    |> to_clearing()
  end

  # Records live sizes after each step, the state's binary size at each 13:00, and the world
  # at the first step after day 0 with work in the kitchen (a batch boundary).
  defp sample_through({state, log} = w, to, acc) do
    acc = %{
      acc
      | samples: [{state.now, map_size(state.visits), map_size(state.trays), map_size(state.orders)} | acc.samples]
    }

    acc =
      if rem(state.now, @day) == 13 * @hour,
        do: %{acc | noon_bytes: acc.noon_bytes ++ [byte_size(:erlang.term_to_binary(state))]},
        else: acc

    acc =
      if acc.mid == nil and state.now > @day and map_size(state.orders) > 0,
        do: %{acc | mid: {state, length(log)}},
        else: acc

    if state.now >= to,
      do: {w, acc},
      else: sample_through(advance_hall(w, min((div(state.now, @step) + 1) * @step, to)), to, acc)
  end

  test "live state stays bounded by live work while finished visits accumulate in the log",
       %{world: {state, log}, samples: samples, noon_bytes: noon_bytes} do
    limit = state.catalog.rules.kitchen.queue_limit

    # Non-vacuous: hundreds of visits finished, on every day.
    finalized_by_day =
      log
      |> Enum.reduce({0, %{}}, fn
        %{type: :clock_advanced, to: to}, {_now, acc} -> {to, acc}
        %{type: :visit_finalized}, {now, acc} -> {now, Map.update(acc, Clock.day_of(now), 1, &(&1 + 1))}
        _e, acc -> acc
      end)
      |> elem(1)

    assert Enum.all?(0..4, &(Map.get(finalized_by_day, &1, 0) >= 30)), inspect(finalized_by_day)
    assert state.stats.finalized_visits >= 150

    # One stall: fewer than `queue_limit` unserved trays plus their dessert visits.
    for {at, visits, trays, orders} <- samples do
      assert visits <= 2 * limit and trays <= 2 * limit and orders <= 4 * limit,
             "at #{at}: #{visits}/#{trays}/#{orders}"
    end

    [day0 | rest] = noon_bytes
    assert length(rest) == 4
    assert Enum.all?(rest, &(&1 <= 2 * day0)), inspect([day0 | rest])

    # Every visit, tray and order ID is unique over the whole history.
    for type <- [:visit_admitted, :tray_accepted] do
      key = if type == :visit_admitted, do: :visit_id, else: :tray_id
      ids = for %{type: ^type} = e <- log, do: Map.fetch!(e, key)
      assert ids == Enum.uniq(ids)
    end

    order_ids =
      Enum.flat_map(log, fn
        %{type: :tray_accepted, components: cs} -> Enum.map(cs, & &1.order_id)
        %{type: :dessert_accepted, order: o} -> [o.order_id]
        _ -> []
      end)

    assert order_ids == Enum.uniq(order_ids)
    assert state.order_seq == length(order_ids)

    assert Invariants.check(state) == :ok
    Oracle.assert_settled!(state, log)
  end

  test "genesis and snapshot-tail replay equal the live state, and a mid-day snapshot resumes identically",
       %{world: {state, log}, mid: {live_mid, cut}} do
    assert Hall.replay(log) == state

    {head, tail} = Enum.split(log, cut)
    assert Hall.replay(head) == live_mid
    assert map_size(live_mid.orders) > 0

    # Through the snapshot codec, as recovery would load it.
    snapshot = Snapshot.take(%{hall: live_mid, control: nil}, cut)
    assert {:ok, %{state: %{hall: mid}}} = Snapshot.load(snapshot)
    assert mid == live_mid
    assert Hall.replay(tail, mid) == state

    # The live run's next step from 13:00 was the advance to 13:20: deciding it from the
    # loaded snapshot records exactly the events the live run recorded.
    target = Clock.service_ms(mid.now + @step)
    {:ok, resumed} = Hall.decide(mid, {:advance_clock, %{to_service_ms: target}}, ctx({:system, :scheduler}, "t"))
    assert resumed != []
    assert Enum.take(tail, length(resumed)) == resumed
  end
end
