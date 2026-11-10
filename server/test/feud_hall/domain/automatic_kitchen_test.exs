defmodule FeudHall.Domain.AutomaticKitchenTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.{Clock, Hall, Inventory, Kitchen}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.{EventCodec, InMemoryEventStore}
  alias FeudHall.Oracle

  @min Clock.minute()
  @stall "s001"
  @three Clock.cleaning_start_of(0)
  @five Clock.cleaning_end_of(0)
  # A stocked world starts at the first market clearing, where its stock was filled.
  @t0 SliceCatalog.rules().market.clear_every_hall_ms

  # Each event paired with the hall time at which it was recorded.
  defp timeline(events) do
    {_, acc} =
      Enum.reduce(events, {0, []}, fn
        %{type: :clock_advanced, to: to}, {_, acc} -> {to, acc}
        e, {now, acc} -> {now, [{now, e} | acc]}
      end)

    Enum.reverse(acc)
  end

  defp served_at(events, tray_id), do: for({t, %{type: :tray_served, tray_id: ^tray_id}} <- timeline(events), do: t)

  defp dessert_served_at(events, order_id),
    do: for({t, %{type: :dessert_served, order_id: ^order_id}} <- timeline(events), do: t)

  defp with_rules(fun), do: update_in(SliceCatalog.catalog(), [:rules], fun)

  test "a tray is served exactly at its estimated completion with no commands after acceptance" do
    w = stocked_world() |> simulated_visit("d1", "bean_tacos")
    {state, _} = w
    tray = state.trays[tray_id("visit-d1")]
    # Empty kitchen: prep 1 + finish 3 + handover 4 game minutes.
    assert tray.estimated_completion == state.now + 8 * @min

    {before, _} = advance_hall(w, tray.estimated_completion - Clock.ratio())
    assert before.trays[tray.id].status == :accepted

    {state, events} = advance_hall(w, tray.estimated_completion)
    assert state.trays[tray.id].status == :served
    assert served_at(events, tray.id) == [tray.estimated_completion]
    assert state.stalls[@stall].counter == nil

    [main] = tray.components

    kitchen =
      for {t, e} <- timeline(events), e.type in [:stage_started, :stage_completed, :handover_started], do: {t, e}

    assert [
             {@t0, %{type: :stage_started, order_id: ^main, stage: :prep, consumed: [_ | _], done_at: d1}},
             {t1, %{type: :stage_completed, order_id: ^main, stage: :prep}},
             {t1, %{type: :stage_started, order_id: ^main, stage: :finish, done_at: d2}},
             {t2, %{type: :stage_completed, order_id: ^main, stage: :finish, expires_at: expires}},
             {t2, %{type: :handover_started, stall_id: @stall, done_at: d3}}
           ] = kitchen

    assert {d1, t1, d2, t2, d3} == {@t0 + 1 * @min, @t0 + 1 * @min, @t0 + 4 * @min, @t0 + 4 * @min, @t0 + 8 * @min}
    assert expires == @t0 + 4 * @min + state.catalog.recipes["bean_tacos"].holding_ms
    Oracle.assert_settled!(state, events)

    # Every new kitchen event survives the JSON codec.
    for e <- events, do: assert({:ok, ^e} = e |> EventCodec.encode!() |> EventCodec.decode())
  end

  test "the removed kitchen commands are unknown and the kitchen capability is gone" do
    {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())
    init = {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}}
    {:accepted, _, rt} = Workflow.execute(rt, %{command_id: "init", actor: {:system, :admin}, command: init})

    for {kind, payload} <- [
          start_preparation: %{order_id: "O:x:main"},
          complete_preparation: %{order_id: "O:x:main"},
          serve_tray: %{tray_id: "T:x"},
          serve_dessert: %{order_id: "O:x:dessert"}
        ],
        actor <- [{:system, :kitchen}, {:system, :scheduler}, {:principal, "alice"}] do
      envelope = %{command_id: "k-#{kind}", actor: actor, command: {kind, payload}}
      assert {:error, :unknown_command, _} = Workflow.execute(rt, envelope)
    end

    envelope = %{command_id: "k", actor: {:system, :kitchen}, command: {:advance_clock, %{to_service_ms: 1}}}
    assert {:error, :unauthenticated, _} = Workflow.execute(rt, envelope)

    # The pure decider no longer knows them either.
    {state, _} = stocked_world() |> simulated_visit("d1", "bean_tacos")

    assert {:error, :unauthorized_or_malformed} =
             Hall.decide(state, {:serve_tray, %{tray_id: tray_id("visit-d1")}}, ctx({:system, :kitchen}, "s"))
  end

  test "two prep stations, one finisher and one counter serve four trays exactly as estimated" do
    w = stocked_world() |> simulated_visit("t1", "bean_tacos") |> simulated_visit("t2", "bean_tacos")
    w = advance_hall(w, @t0 + 2 * @min)
    w = w |> simulated_visit("t3", "bean_tacos", "horchata") |> simulated_visit("t4", "bean_tacos")
    {accepted, _} = w

    ids = Enum.map(~w(t1 t2 t3 t4), &tray_id("visit-" <> &1))
    estimates = Enum.map(ids, &accepted.trays[&1].estimated_completion)

    # Prep runs two at a time; the single finisher serialises t1, t2, t3's main and
    # drink, then t4; the counter hands over in ready order four minutes each.
    assert estimates == Enum.map([8, 12, 16, 20], &(@t0 + &1 * @min))

    {state, events} = advance_hall(w, @t0 + 30 * @min)
    assert Enum.map(ids, &served_at(events, &1)) == Enum.map(estimates, &[&1])

    # The estimate the quote saw is the shared FIFO rule the dispatch followed.
    {fresh, _} = stocked_world()
    assert Kitchen.estimate(fresh, @stall, [%{prep_ms: @min, finish_ms: 3 * @min}], 0).earliest_completion == 8 * @min
    Oracle.assert_settled!(state, events)
  end

  test "a component ready at the same instant it expires is not served" do
    # The drink is ready at 5 min and the counter finishes at 9; a four-minute
    # holding life makes it expire exactly as the handover would complete.
    catalog = put_in(SliceCatalog.catalog(), [:recipes, "horchata", :holding_ms], 4 * @min)
    w = stocked_world(catalog: catalog) |> simulated_visit("d1", "bean_tacos", "horchata")
    {state, _} = w
    tray = state.trays[tray_id("visit-d1")]
    assert tray.estimated_completion == @t0 + 9 * @min

    {state, events} = advance_hall(w, @t0 + 9 * @min)
    assert state.trays[tray.id].status == :cancelled
    [_main, drink] = tray.components
    assert state.orders[drink].cancel_reason == :ready_food_expired
    assert served_at(events, tray.id) == []
    assert state.stalls[@stall].counter == nil
    Oracle.assert_settled!(state, events)

    # One more tick of holding life and the same tray is served.
    fresher = put_in(SliceCatalog.catalog(), [:recipes, "horchata", :holding_ms], 4 * @min + 1)

    {state, events} =
      stocked_world(catalog: fresher) |> simulated_visit("d1", "bean_tacos", "horchata") |> advance_hall(@t0 + 9 * @min)

    assert served_at(events, tray.id) == [@t0 + 9 * @min]
    Oracle.assert_settled!(state, events)
  end

  test "service exactly at the tray deadline wins; a deadline before handover cancels at the deadline" do
    catalog = with_rules(&%{&1 | service_window_ms: 8 * @min})
    w = stocked_world(catalog: catalog) |> simulated_visit("d1", "bean_tacos")
    {state, log} = w
    tray = state.trays[tray_id("visit-d1")]
    assert tray.deadline == tray.estimated_completion

    {served, events} = advance_hall(w, tray.deadline)
    assert served.trays[tray.id].status == :served
    assert served_at(events, tray.id) == [tray.deadline]

    # A deadline one tick before the handover completes (not reachable through a
    # quote) is missed at the deadline itself, mid-handover, releasing the counter.
    early = tray.deadline - Clock.ratio()
    [main] = tray.components
    state = state |> put_in([:trays, tray.id, :deadline], early) |> put_in([:orders, main, :deadline], early)
    {late, events} = advance_hall({state, log}, tray.deadline)
    assert late.trays[tray.id].status == :cancelled
    assert late.visits[visit_id("visit-d1")].outcome.reason == :main_failed

    assert [{^early, %{type: :tray_cancelled, reason: :deadline_missed}}] =
             for({t, %{type: :tray_cancelled}} = te <- timeline(events), do: {t, elem(te, 1)})

    assert late.stalls[@stall].counter == nil
    assert late.restaurants["r1"].ledger.waste > 0
    Oracle.assert_settled!(late, events)
  end

  test "work in progress at 03:00 is cancelled with its consumed cost as waste" do
    w = stocked_world() |> advance_hall(@three - 14 * @min)
    w = w |> simulated_visit("held", "bean_tacos", "horchata") |> simulated_visit("waiting", "chicken_tacos")
    # Quotes finish before 03:00; slow the counter afterwards so both trays are
    # still in the kitchen at the cutoff (one in handover, one waiting ready).
    {state, log} = w
    w = {put_in(state, [:catalog, :rules, :handover_ms], 30 * @min), log}
    w = advance_hall(w, @three - Clock.ratio())
    {before, _} = w
    ledger = before.restaurants["r1"].ledger
    assert ledger.wip > 0
    assert %{item: {:tray, _}} = before.stalls[@stall].counter

    {state, events} = advance_hall(w, @five + 10 * @min)

    for id <- ~w(visit-held visit-waiting) do
      assert state.visits[visit_id(id)].outcome.reason == :cleaning
      assert state.trays[tray_id(id)].status == :cancelled
    end

    {after_cleaning, _} = advance_hall(w, @three)
    assert after_cleaning.restaurants["r1"].ledger.wip == 0
    assert after_cleaning.restaurants["r1"].ledger.waste == ledger.waste + ledger.wip
    assert after_cleaning.stalls[@stall].counter == nil
    Oracle.assert_settled!(state, events)
  end

  test "a handover due exactly at 03:00 is cancelled by the cutoff, not served" do
    w = stocked_world() |> advance_hall(@three - 14 * @min)
    w = simulated_visit(w, "edge", "bean_tacos")
    {state, log} = w
    # Ready at four minutes (one prep, three finish); the handover then takes
    # exactly as long as is left until the cutoff.
    ready = state.now + 4 * @min
    w = {put_in(state, [:catalog, :rules, :handover_ms], @three - ready), log}

    {mid, _} = advance_hall(w, @three - Clock.ratio())
    assert %{item: {:tray, _}, done_at: @three} = mid.stalls[@stall].counter

    {state, events} = advance_hall(w, @three)
    assert served_at(events, tray_id("visit-edge")) == []
    assert state.trays[tray_id("visit-edge")].status == :cancelled
    assert state.visits[visit_id("visit-edge")].outcome.reason == :cleaning
    assert state.stalls[@stall].counter == nil
    Oracle.assert_settled!(state, events)
  end

  test "a stage never runs on more stations than the stall has" do
    %{prep_stations: prep_n, finish_stations: finish_n} = SliceCatalog.rules().kitchen
    assert {prep_n, finish_n} == {2, 1}

    w = Enum.reduce(~w(c1 c2 c3), stocked_world(), &simulated_visit(&2, &1, "bean_tacos"))
    count = fn state, status -> Enum.count(state.orders, fn {_id, o} -> o.status == status end) end

    # Three accepted mains at once: two occupy the prep stations, one waits.
    {started, _} = advance_hall(w, @t0 + Clock.ratio())
    assert {count.(started, :prep), count.(started, :queued_prep)} == {prep_n, 1}

    # Prep (one minute) hands two to the finisher, which takes one; the third is in prep.
    {finishing, _} = advance_hall(w, @t0 + @min + Clock.ratio())
    assert {count.(finishing, :finish), count.(finishing, :queued_finish)} == {finish_n, 1}
    assert count.(finishing, :prep) == 1
  end

  test "dispatch waits for the 05:00 reopening and runs at that instant" do
    # Cleaning cancels all customer work, so a waiting item during cleaning is
    # hand-built: a ready tray (deadline and holding life past 05:00) with a
    # free counter, put back into a hall that is already cleaning.
    w = stocked_world() |> advance_hall(@three - 20 * @min) |> simulated_visit("d1", "bean_tacos")
    {accepted, _} = w
    tid = tray_id("visit-d1")
    [main] = accepted.trays[tid].components
    w = advance_hall(w, @three + @min)
    {cleaning, log} = w
    assert cleaning.access == :cleaning
    late = @five + 30 * @min

    cleaning =
      cleaning
      |> put_in([:trays, tid], %{accepted.trays[tid] | deadline: late})
      |> put_in([:visits, visit_id("visit-d1")], accepted.visits[visit_id("visit-d1")])
      |> put_in([:orders, main], %{
        accepted.orders[main]
        | status: :ready,
          reservations: [],
          ready_at: cleaning.now,
          ready_expires_at: late,
          deadline: late
      })

    assert Kitchen.next_start(cleaning, @stall) == {:handover, {:tray, tid}}

    {_, events} = advance_hall({cleaning, log}, @five - Clock.ratio())
    assert Enum.drop(events, length(log)) |> Enum.filter(&(&1.type in [:stage_started, :handover_started])) == []

    {reopened, events} = advance_hall({cleaning, log}, @five)
    tail = Enum.drop(events, length(log))
    # 05:00 is also a market clearing instant: reopening (class 5), clearing (7), then dispatch (9).
    assert [:clock_advanced, :hall_cleaning_ended, :market_cleared, :handover_started] =
             tail |> Enum.take(-4) |> Enum.map(& &1.type)

    assert %{type: :clock_advanced, to: @five} = Enum.at(tail, -4)
    assert [@five] = for({t, %{type: :handover_started}} <- timeline(events), t >= @three, do: t)
    assert reopened.stalls[@stall].counter.done_at == @five + reopened.catalog.rules.handover_ms
  end

  test "menu edits and closing the stall leave an accepted tray's bill and service unchanged" do
    w = stocked_world() |> simulated_visit("d1", "bean_tacos", "horchata")
    {state, _} = w
    tray = state.trays[tray_id("visit-d1")]
    bill = Map.new(tray.components, &{&1, Map.take(state.orders[&1], [:price, :recipe_id, :lines, :quality])})

    w =
      w
      |> run!({:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 2_000}}, owner(), "price")
      |> run!({:remove_menu_item, %{restaurant_id: "r1", recipe_id: "horchata"}}, owner(), "remove")
      |> run!({:close_stall, %{stall_id: @stall}}, owner(), "close")

    {closed, _} = w
    assert closed.trays[tray.id].components == tray.components
    assert Map.new(tray.components, &{&1, Map.take(closed.orders[&1], [:price, :recipe_id, :lines, :quality])}) == bill

    # A closed stall takes no new order but keeps working off accepted ones.
    assert reject!(w, {:admit_visit, sim_payload("d2")}, {:system, :demand}, "visit-d2") == :stall_not_accepting_orders

    {state, events} = advance_hall(w, tray.estimated_completion)
    assert served_at(events, tray.id) == [tray.estimated_completion]
    assert state.restaurants["r1"].ledger.revenue == 900 + 350
    Oracle.assert_settled!(state, events)
  end

  test "drinks and mains share the stage queues and a dessert uses the counter after the main trays" do
    w =
      stocked_world()
      |> simulated_visit("a", "bean_tacos", "horchata", "unrestricted", 10_000, true)
      |> simulated_visit("b", "bean_tacos")

    {state, _} = w
    [main_a, drink_a] = state.trays[tray_id("visit-a")].components
    [main_b] = state.trays[tray_id("visit-b")].components

    w = advance_hall(w, @t0 + 9 * @min)
    {state, events} = w

    finishes = for {t, %{type: :stage_started, stage: :finish, order_id: o}} <- timeline(events), do: {o, t}
    # One finisher, FIFO by prep completion then acceptance: a's main, a's drink, then b's main.
    assert finishes == [{main_a, @t0 + 1 * @min}, {drink_a, @t0 + 4 * @min}, {main_b, @t0 + 5 * @min}]
    assert served_at(events, tray_id("visit-a")) == [@t0 + 9 * @min]

    vid = visit_id("visit-a")
    # a's appetite accepted the dessert in the service batch.
    assert state.visits[vid].dessert == :accepted
    # b's tray took the counter at 9 min; the dessert is ready at 12 but waits until 13.
    handover_done = @t0 + 13 * @min
    assert %{item: {:tray, "T:visit-b"}, done_at: ^handover_done} = state.stalls[@stall].counter

    dessert = state.orders[state.visits[vid].dessert_order]
    assert dessert.estimated_completion == @t0 + 17 * @min

    {state, events} = advance_hall(w, @t0 + 20 * @min)
    assert served_at(events, tray_id("visit-b")) == [@t0 + 13 * @min]
    assert dessert_served_at(events, dessert.id) == [@t0 + 17 * @min]
    assert state.visits[vid].outcome.reason == :completed
    Oracle.assert_settled!(state, events)
  end

  test "history recorded before the automatic kitchen still replays" do
    {state, log} = stocked_world() |> simulated_visit("d1", "bean_tacos")
    [main] = state.trays[tray_id("visit-d1")].components

    old_accept =
      log
      |> List.last()
      |> Map.delete(:estimated_completion)
      |> Map.update!(:components, fn cs -> Enum.map(cs, &Map.drop(&1, [:prep_ms, :finish_ms])) end)

    batches = state.restaurants["r1"].batches

    consumed =
      for claim <- state.orders[main].reservations,
          do: Map.put(claim, :cost, Inventory.consumption_cost(batches[claim.batch_id], claim.qty))

    history =
      Enum.drop(log, -1) ++
        [
          old_accept,
          %{type: :preparation_started, order_id: main, consumed: consumed, ready_not_before: @t0 + 4 * @min},
          %{type: :clock_advanced, to: @t0 + 4 * @min},
          %{type: :preparation_completed, order_id: main, expires_at: @t0 + 24 * @min}
        ]

    started = Hall.replay(Enum.drop(history, -2))
    consumed_cost = consumed |> Enum.map(& &1.cost) |> Enum.sum()
    assert consumed_cost > 0
    assert started.restaurants["r1"].ledger.wip == consumed_cost
    assert started.restaurants["r1"].ledger.raw == state.restaurants["r1"].ledger.raw - consumed_cost
    assert started.orders[main].reservations == []
    Oracle.assert_settled!(started, history |> Enum.drop(-2))

    replayed = Hall.replay(history)
    assert replayed.trays[tray_id("visit-d1")].estimated_completion == nil
    assert replayed.orders[main].prep_ms == state.catalog.recipes["bean_tacos"].prep_ms
    assert replayed.orders[main].status == :ready
    assert replayed.orders[main].ready_expires_at == @t0 + 24 * @min
  end

  defp sim_payload(id),
    do: %{
      source: :simulated,
      diner_id: id,
      budget: 10_000,
      stall_id: @stall,
      main: "bean_tacos",
      drink: nil,
      profile_id: "unrestricted"
    }
end
