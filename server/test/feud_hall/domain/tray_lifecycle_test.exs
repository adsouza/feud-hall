defmodule FeudHall.Domain.TrayLifecycleTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers}
  alias FeudHall.Oracle

  # Lifecycle counts are exact here: no simulated diner arrives unless admitted.
  setup do
    %{world: stocked_world(arrivals: false)}
  end

  test "main + drink tray settles jointly, offers dessert, and finalizes once with 4:1:2 weights", %{world: w} do
    w = simulated_visit(w, "d1", "bean_tacos", "horchata")
    {state, _events} = w
    tray = state.trays[tray_id("visit-d1")]
    assert length(tray.components) == 2

    # Two components, one queue place, one deadline.
    assert Enum.all?(tray.components, &(state.orders[&1].status == :queued_prep))

    w = serve_tray(w, tray.id)
    {state, events} = w
    Oracle.assert_settled!(state, events)

    visit = state.visits[visit_id("visit-d1")]
    assert visit.dessert == :offered
    assert state.stats.served_mains == 1
    assert state.stats.served_drinks == 1
    assert state.restaurants["r1"].ledger.revenue == 900 + 350

    w = run!(w, {:accept_dessert, %{visit_id: visit.id}}, {:system, :demand}, "dessert")
    {state, _} = w
    dessert = state.orders[state.visits[visit.id].dessert_order]
    w = serve_dessert(w, dessert.id)
    {state, events} = w
    Oracle.assert_settled!(state, events)

    final = state.visits[visit.id]
    assert final.status == :finalized
    assert final.outcome.reason == :completed
    assert Enum.map(final.outcome.components, & &1.weight) == [4, 1, 2]
    # All primary ingredients: every course scores 100.
    assert final.outcome.score == 10_000
    assert final.outcome.competitive
    # Optional items never count as another arrival or meal.
    assert state.stats.arrivals == 1
    assert state.stats.served_mains == 1
  end

  test "weights normalize over accepted components only", %{world: w} do
    w =
      run!(
        w,
        {:set_substitution_policy,
         %{restaurant_id: "r1", recipe_id: "bean_tacos", line_id: "tortilla", policy: :prefer_substitute}},
        owner(),
        "policy"
      )

    w = buy(w, "corn_tortilla_packaged", 10, "buy-pack")
    w = simulated_visit(w, "d2", "bean_tacos")
    {state, _} = w
    tray = state.trays[tray_id("visit-d2")]
    [main] = tray.components
    assert state.orders[main].quality == 97
    assert state.orders[main].penalty == 3

    w = serve_tray(w, tray.id)
    w = run!(w, {:decline_dessert, %{visit_id: visit_id("visit-d2")}}, {:system, :demand}, "decline")
    {state, events} = w
    outcome = state.visits[visit_id("visit-d2")].outcome
    # Main only: score is the main's quality; declining dessert carries no penalty.
    assert outcome.score == 9_700
    assert Enum.map(outcome.components, & &1.kind) == [:main]
    Oracle.assert_settled!(state, events)
  end

  test "guest stale terms reject the whole checkout without reservations; revised terms use a new ID", %{world: w} do
    w = grant(w, "gina", 2_000, "grant")
    {state, _} = w
    {:ok, req} = Dietary.requirement(state.catalog, "unrestricted")
    blank = %{requirement: req, carbs_reserved: 0, carbs_served: 0}
    {:ok, quote} = Offers.quote_tray(state, "s001", "bean_tacos", "horchata", blank)
    terms = Offers.terms(quote)

    w = run!(w, {:set_menu_price, %{restaurant_id: "r1", recipe_id: "horchata", price: 400}}, owner(), "raise")
    {state, _} = w

    payload = %{source: :guest, stall_id: "s001", main: "bean_tacos", drink: "horchata", profile_id: "unrestricted"}

    assert {:error, :stale_terms} =
             Hall.decide(state, {:admit_visit, Map.put(payload, :confirmed, terms)}, ctx({:principal, "gina"}, "c1"))

    # A longer deadline than offered is also stale.
    {:ok, fresh} = Offers.quote_tray(state, "s001", "bean_tacos", "horchata", blank)
    longer = %{Offers.terms(fresh) | deadline: fresh.deadline + 1}

    assert {:error, :stale_terms} =
             Hall.decide(state, {:admit_visit, Map.put(payload, :confirmed, longer)}, ctx({:principal, "gina"}, "c2"))

    w = run!(w, {:admit_visit, Map.put(payload, :confirmed, Offers.terms(fresh))}, {:principal, "gina"}, "c3")
    {state, events} = w
    tray = state.trays[tray_id("c3")]
    assert Enum.map(tray.components, &state.orders[&1].price) == [900, 400]
    assert state.wallets["gina"].slices |> Map.values() |> Enum.map(& &1.reserved) == [1_300]
    Oracle.assert_settled!(state, events)

    # One active visit per principal and hall.
    assert {:error, :visit_already_active} =
             Hall.decide(
               state,
               {:admit_visit, Map.put(payload, :confirmed, Offers.terms(fresh))},
               ctx({:principal, "gina"}, "c4")
             )
  end

  test "voluntary cancellation is free before preparation and refused after it starts", %{world: w} do
    w = grant(w, "gina", 2_000, "grant") |> guest_visit("gina", "g1", "bean_tacos", "horchata")
    {state, _} = w
    tray = state.trays[tray_id("g1")]

    # Another principal cannot cancel it.
    assert {:error, :forbidden} = Hall.decide(state, {:cancel_tray, %{tray_id: tray.id}}, ctx({:principal, "eve"}, "x"))

    {after_cancel, events} = run!(w, {:cancel_tray, %{tray_id: tray.id}}, {:principal, "gina"}, "cancel")
    Oracle.assert_settled!(after_cancel, events)
    assert after_cancel.wallets["gina"].slices |> Map.values() |> Enum.map(&{&1.amount, &1.reserved}) == [{2_000, 0}]
    assert after_cancel.visits[visit_id("g1")].outcome.reason == :guest_cancelled
    assert after_cancel.visits[visit_id("g1")].outcome.score == nil
    assert after_cancel.active_visits == %{}

    # Preparation starting (at the acceptance instant, on the next advance)
    # closes voluntary cancellation.
    {state, _} = advance_hall(w, state.now)
    assert Enum.all?(tray.components, &(state.orders[&1].status == :prep))

    assert {:error, :preparation_started} =
             Hall.decide(state, {:cancel_tray, %{tray_id: tray.id}}, ctx({:principal, "gina"}, "cancel2"))
  end

  test "dessert requires a served main, one slot, the same principal, and an open window", %{world: w} do
    w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "g1", "bean_tacos")
    {state, _} = w
    vid = visit_id("g1")

    assert {:error, :no_dessert_offer} =
             Hall.decide(state, {:accept_dessert, %{visit_id: vid}}, ctx({:principal, "gina"}, "d0"))

    w = serve_tray(w, tray_id("g1"))
    {state, _} = w
    assert state.visits[vid].dessert == :offered
    {:ok, quote} = Offers.quote_dessert(state, state.visits[vid])
    confirmed = Offers.terms(quote)

    assert {:error, :forbidden} =
             Hall.decide(
               state,
               {:accept_dessert, %{visit_id: vid, confirmed: confirmed}},
               ctx({:principal, "eve"}, "d1")
             )

    w = run!(w, {:accept_dessert, %{visit_id: vid, confirmed: confirmed}}, {:principal, "gina"}, "d2")
    {state, _} = w

    assert {:error, :no_dessert_offer} =
             Hall.decide(
               state,
               {:accept_dessert, %{visit_id: vid, confirmed: confirmed}},
               ctx({:principal, "gina"}, "d3")
             )

    # Cancelling the dessert finalizes the visit; the slot never reopens and the
    # served tray keeps its payment.
    {state, events} = run!(w, {:cancel_dessert, %{visit_id: vid}}, {:principal, "gina"}, "d4")
    Oracle.assert_settled!(state, events)
    assert state.visits[vid].status == :finalized
    assert state.visits[vid].outcome.score == 10_000
    assert state.restaurants["r1"].ledger.revenue == 900

    assert {:error, :visit_finalized} =
             Hall.decide(
               state,
               {:accept_dessert, %{visit_id: vid, confirmed: confirmed}},
               ctx({:principal, "gina"}, "d5")
             )
  end

  test "an unaccepted dessert offer times out after 30 available-service seconds", %{world: w} do
    w = simulated_visit(w, "d1", "bean_tacos")
    w = serve_tray(w, tray_id("visit-d1"))
    {state, _} = w
    vid = visit_id("visit-d1")
    deadline = state.visits[vid].dessert_offer_deadline
    assert deadline == state.now + Clock.service_duration(30_000)

    w = advance_hall(w, deadline - Clock.ratio())
    {state, _} = w
    assert state.visits[vid].dessert == :offered

    {state, events} = advance_hall(w, deadline)
    assert state.visits[vid].outcome.reason == :dessert_offer_expired
    assert state.visits[vid].outcome.score == 10_000
    Oracle.assert_settled!(state, events)
  end

  test "service wins an exact deadline tie; a deadline missed mid-handover cancels the tray as waste", %{world: w} do
    # A service window exactly as long as the work, so the deadline is the handover's end.
    rules = %{elem(w, 0).catalog.rules | service_window_ms: 8 * Clock.minute()}
    w = stocked_world(catalog: put_in(FeudHall.Domain.Content.SliceCatalog.catalog(), [:rules], rules))
    w = simulated_visit(w, "d1", "bean_tacos")
    {state, log} = w
    tray = state.trays[tray_id("visit-d1")]
    assert tray.deadline == tray.estimated_completion

    {before, _} = advance_hall(w, tray.deadline - Clock.ratio())
    assert before.trays[tray.id].status == :accepted
    {served, _} = advance_hall(w, tray.deadline)
    assert served.trays[tray.id].status == :served

    # Quotes never bind a deadline before the estimate; force one to show the
    # deadline boundary cancelling work in progress.
    [main] = tray.components
    early = tray.deadline - Clock.ratio()
    state = state |> put_in([:trays, tray.id, :deadline], early) |> put_in([:orders, main, :deadline], early)
    {late, events} = advance_hall({state, log}, tray.deadline)
    assert late.trays[tray.id].status == :cancelled
    assert late.visits[visit_id("visit-d1")].outcome.reason == :main_failed
    assert late.visits[visit_id("visit-d1")].outcome.score == 0
    assert late.restaurants["r1"].ledger.waste > 0
    Oracle.assert_settled!(late, events)
  end

  test "ready-food expiry wins an exact freshness tie with the handover" do
    # The main is ready at 4 min and handed over 4..8; a four-minute holding
    # life expires it exactly as the handover would complete.
    catalog =
      put_in(FeudHall.Domain.Content.SliceCatalog.catalog(), [:recipes, "bean_tacos", :holding_ms], 4 * Clock.minute())

    w = stocked_world(catalog: catalog) |> simulated_visit("d1", "bean_tacos")
    tray = tray_id("visit-d1")
    {state, _} = w
    [main] = state.trays[tray].components
    {state, events} = advance_hall(w, state.trays[tray].estimated_completion)
    assert state.orders[main].ready_expires_at == state.now
    assert state.trays[tray].status == :cancelled
    assert state.orders[main].cancel_reason == :ready_food_expired
    refute Enum.any?(events, &(&1.type == :tray_served))
    Oracle.assert_settled!(state, events)
  end
end
