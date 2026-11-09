defmodule FeudHall.Domain.TrayLifecycleTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers}
  alias FeudHall.Oracle

  setup do
    %{world: stocked_world()}
  end

  test "main + drink tray settles jointly, offers dessert, and finalizes once with 4:1:2 weights", %{world: w} do
    w = simulated_visit(w, "d1", "bean_tacos", "horchata")
    {state, _events} = w
    tray = state.trays[tray_id("visit-d1")]
    assert length(tray.components) == 2

    # Two components, one queue place, one deadline.
    assert Enum.all?(tray.components, &(state.orders[&1].status == :reserved))
    refute Hall.decide(state, {:serve_tray, %{tray_id: tray.id}}, ctx({:system, :kitchen}, "early")) == :ok

    w = prepare_tray(w, tray.id)
    w = kitchen(w, :serve_tray, %{tray_id: tray.id}, "serve")
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
    w = prepare_order(w, dessert.id)
    w = kitchen(w, :serve_dessert, %{order_id: dessert.id}, "serve-dessert")
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

    w = prepare_tray(w, tray.id) |> kitchen(:serve_tray, %{tray_id: tray.id}, "serve")
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
    {:ok, quote} = Offers.quote_tray(state, "s1", "bean_tacos", "horchata", blank)
    terms = Offers.terms(quote)

    w = run!(w, {:set_menu_price, %{restaurant_id: "r1", recipe_id: "horchata", price: 400}}, owner(), "raise")
    {state, _} = w

    payload = %{source: :guest, stall_id: "s1", main: "bean_tacos", drink: "horchata", profile_id: "unrestricted"}

    assert {:error, :stale_terms} =
             Hall.decide(state, {:admit_visit, Map.put(payload, :confirmed, terms)}, ctx({:principal, "gina"}, "c1"))

    # A longer deadline than offered is also stale.
    {:ok, fresh} = Offers.quote_tray(state, "s1", "bean_tacos", "horchata", blank)
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

    # Preparation of either component closes voluntary cancellation.
    [main, _drink] = tray.components
    w = kitchen(w, :start_preparation, %{order_id: main}, "start-main")
    {state, _} = w

    assert {:error, :preparation_started} =
             Hall.decide(state, {:cancel_tray, %{tray_id: tray.id}}, ctx({:principal, "gina"}, "cancel2"))
  end

  test "dessert requires a served main, one slot, the same principal, and an open window", %{world: w} do
    w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "g1", "bean_tacos")
    {state, _} = w
    vid = visit_id("g1")

    assert {:error, :no_dessert_offer} =
             Hall.decide(state, {:accept_dessert, %{visit_id: vid}}, ctx({:principal, "gina"}, "d0"))

    w = prepare_tray(w, tray_id("g1")) |> kitchen(:serve_tray, %{tray_id: tray_id("g1")}, "serve")
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
    w = prepare_tray(w, tray_id("visit-d1")) |> kitchen(:serve_tray, %{tray_id: tray_id("visit-d1")}, "serve")
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

  test "service wins an exact deadline tie; one tick later the tray is cancelled as waste", %{world: w} do
    # A short service window so the deadline binds before ready-food expiry.
    rules = %{elem(w, 0).catalog.rules | service_window_ms: 10 * Clock.minute()}
    w = stocked_world(catalog: put_in(FeudHall.Domain.Content.SliceCatalog.catalog(), [:rules], rules))
    w = simulated_visit(w, "d1", "bean_tacos")
    {state, _} = w
    tray = state.trays[tray_id("visit-d1")]
    w = prepare_tray(w, tray.id)
    at_deadline = advance_hall(w, tray.deadline)
    {state, _} = at_deadline
    assert state.trays[tray.id].status == :accepted
    {served, _} = kitchen(at_deadline, :serve_tray, %{tray_id: tray.id}, "serve")
    assert served.trays[tray.id].status == :served

    {late, events} = advance_hall(w, tray.deadline + Clock.ratio())
    assert late.trays[tray.id].status == :cancelled
    assert late.visits[visit_id("visit-d1")].outcome.reason == :main_failed
    assert late.visits[visit_id("visit-d1")].outcome.score == 0
    assert late.restaurants["r1"].ledger.waste > 0
    Oracle.assert_settled!(late, events)
  end

  test "ready-food expiry wins an exact freshness tie", %{world: w} do
    # Stretch the deadline window so the holding lifetime binds first.
    rules = %{elem(w, 0).catalog.rules | service_window_ms: 6 * Clock.hour()}
    w = stocked_world(catalog: put_in(FeudHall.Domain.Content.SliceCatalog.catalog(), [:rules], rules))
    w = simulated_visit(w, "d1", "bean_tacos")
    tray = tray_id("visit-d1")
    w = prepare_tray(w, tray)
    {state, _} = w
    [main] = state.trays[tray].components
    expires = state.orders[main].ready_expires_at
    {state, events} = advance_hall(w, ceil_to_tick(expires))
    assert state.trays[tray].status == :cancelled
    assert state.orders[main].cancel_reason == :ready_food_expired
    assert {:error, :tray_settled} = Hall.decide(state, {:serve_tray, %{tray_id: tray}}, ctx({:system, :kitchen}, "s"))
    Oracle.assert_settled!(state, events)
  end

  test "the serve guard itself refuses food at its exact expiry instant" do
    # The scheduler normally expires food first; this checks the decider's own
    # guard against a state where the boundary has not been processed.
    w = stocked_world() |> simulated_visit("d1", "bean_tacos")
    tray = tray_id("visit-d1")
    {state, _} = prepare_tray(w, tray)
    [main] = state.trays[tray].components
    at_expiry = put_in(state, [:orders, main, :ready_expires_at], state.now)

    assert {:error, :tray_not_ready} =
             Hall.decide(at_expiry, {:serve_tray, %{tray_id: tray}}, ctx({:system, :kitchen}, "s"))

    just_fresh = put_in(state, [:orders, main, :ready_expires_at], state.now + 1)
    assert {:ok, _} = Hall.decide(just_fresh, {:serve_tray, %{tray_id: tray}}, ctx({:system, :kitchen}, "s"))
  end
end
