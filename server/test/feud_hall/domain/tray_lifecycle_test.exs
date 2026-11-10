defmodule FeudHall.Domain.TrayLifecycleTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Dietary, Hall, Offers}
  alias FeudHall.Oracle

  # Lifecycle counts are exact here: no simulated diner arrives unless admitted.
  setup do
    %{world: stocked_world(arrivals: false)}
  end

  test "main + drink tray settles jointly, accepts dessert, and finalizes once with 4:1:2 weights", %{world: w} do
    w = simulated_visit(w, "d1", "bean_tacos", "horchata", "unrestricted", 10_000, true)
    {state, _events} = w
    tray = state.trays[tray_id("visit-d1")]
    assert length(tray.components) == 2

    # Two components, one queue place, one deadline.
    assert Enum.all?(tray.components, &(state.orders[&1].status == :queued_prep))

    w = serve_tray(w, tray.id)
    {state, events} = w
    Oracle.assert_settled!(state, events)

    visit = state.visits[visit_id("visit-d1")]
    assert visit.dessert == :accepted
    assert state.stats.served_mains == 1
    assert state.stats.served_drinks == 1
    assert state.restaurants["r1"].ledger.revenue == 900 + 350

    dessert = state.orders[state.visits[visit.id].dessert_order]
    w = serve_dessert(w, dessert.id)
    {state, events} = w
    Oracle.assert_settled!(state, events)

    refute Map.has_key?(state.visits, visit.id)
    final = visit_outcome(w, visit.id)
    assert final.reason == :completed
    assert Enum.map(final.components, & &1.weight) == [4, 1, 2]
    # All primary ingredients: every course scores 100.
    assert final.score == 10_000
    assert final.competitive
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
    {state, events} = w
    vid = visit_id("visit-d2")
    assert Enum.any?(events, &match?(%{type: :dessert_declined, visit_id: ^vid}, &1))
    outcome = visit_outcome(w, vid)
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

    {after_cancel, events} = cancelled = run!(w, {:cancel_tray, %{tray_id: tray.id}}, {:principal, "gina"}, "cancel")
    Oracle.assert_settled!(after_cancel, events)
    assert after_cancel.wallets["gina"].slices |> Map.values() |> Enum.map(&{&1.amount, &1.reserved}) == [{2_000, 0}]
    assert visit_outcome(cancelled, visit_id("g1")).reason == :guest_cancelled
    assert visit_outcome(cancelled, visit_id("g1")).score == nil
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
    {state, events} = cancelled = run!(w, {:cancel_dessert, %{visit_id: vid}}, {:principal, "gina"}, "d4")
    Oracle.assert_settled!(state, events)
    refute Map.has_key?(state.visits, vid)
    assert visit_outcome(cancelled, vid).score == 10_000
    assert state.restaurants["r1"].ledger.revenue == 900

    # The finalized visit has left live state, so it is no longer known to commands.
    assert {:error, :unknown_visit} =
             Hall.decide(
               state,
               {:accept_dessert, %{visit_id: vid, confirmed: confirmed}},
               ctx({:principal, "gina"}, "d5")
             )
  end

  test "a guest declining a real dessert offer finalizes the visit without penalty", %{world: w} do
    w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "g1", "bean_tacos")
    w = serve_tray(w, tray_id("g1"))
    vid = visit_id("g1")
    {state, _} = w
    assert state.visits[vid].dessert == :offered

    w = run!(w, {:decline_dessert, %{visit_id: vid}}, {:principal, "gina"}, "decline")
    {state, events} = w
    refute Map.has_key?(state.visits, vid)
    assert [%{type: :dessert_declined, visit_id: ^vid}, %{type: :visit_finalized}] = Enum.take(events, -2)
    outcome = visit_outcome(w, vid)
    assert outcome.reason == :completed
    assert outcome.score == 10_000
    assert Enum.map(outcome.components, & &1.kind) == [:main]
    Oracle.assert_settled!(state, events)
  end

  test "an unaccepted dessert offer times out after 30 available-service seconds", %{world: w} do
    w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "d1", "bean_tacos")
    w = serve_tray(w, tray_id("d1"))
    {state, _} = w
    vid = visit_id("d1")
    deadline = state.visits[vid].dessert_offer_deadline
    assert deadline == state.now + Clock.service_duration(30_000)

    w = advance_hall(w, deadline - Clock.ratio())
    {state, _} = w
    assert state.visits[vid].dessert == :offered

    {state, events} = expired = advance_hall(w, deadline)
    assert visit_outcome(expired, vid).reason == :dessert_offer_expired
    assert visit_outcome(expired, vid).score == 10_000
    Oracle.assert_settled!(state, events)
  end

  test "service wins an exact deadline tie; a deadline missed mid-handover cancels the tray as waste", %{world: w} do
    # A service window exactly as long as the work, so the deadline is the handover's end.
    rules = %{elem(w, 0).catalog.rules | service_window_ms: 8 * Clock.minute()}
    w = stocked_world(catalog: put_in(FeudHall.MexicanFixture.catalog(), [:rules], rules))
    w = simulated_visit(w, "d1", "bean_tacos")
    {state, log} = w
    tray = state.trays[tray_id("visit-d1")]
    assert tray.deadline == tray.estimated_completion

    {before, _} = advance_hall(w, tray.deadline - Clock.ratio())
    assert before.trays[tray.id].status == :accepted
    assert tray_status(advance_hall(w, tray.deadline), tray.id) == :served

    # Quotes never bind a deadline before the estimate; force one to show the
    # deadline boundary cancelling work in progress.
    [main] = tray.components
    early = tray.deadline - Clock.ratio()
    state = state |> put_in([:trays, tray.id, :deadline], early) |> put_in([:orders, main, :deadline], early)
    {late, events} = missed = advance_hall({state, log}, tray.deadline)
    assert tray_status(missed, tray.id) == :cancelled
    assert visit_outcome(missed, visit_id("visit-d1")).reason == :main_failed
    assert visit_outcome(missed, visit_id("visit-d1")).score == 0
    assert late.restaurants["r1"].ledger.waste > 0
    Oracle.assert_settled!(late, events)
  end

  test "ready-food expiry wins an exact freshness tie with the handover" do
    # The main is ready at 4 min and handed over 4..8; a four-minute holding
    # life expires it exactly as the handover would complete.
    catalog =
      put_in(FeudHall.MexicanFixture.catalog(), [:recipes, "bean_tacos", :holding_ms], 4 * Clock.minute())

    w = stocked_world(catalog: catalog) |> simulated_visit("d1", "bean_tacos")
    tray = tray_id("visit-d1")
    {state, _} = w
    [main] = state.trays[tray].components
    {_ready, _} = ready = advance_hall(w, state.trays[tray].estimated_completion - Clock.ratio())
    {state, events} = expired = advance_hall(w, state.trays[tray].estimated_completion)
    assert elem(ready, 0).orders[main].ready_expires_at == state.now
    assert tray_status(expired, tray) == :cancelled
    assert order_cancel_reason(expired, main) == :ready_food_expired
    refute Enum.any?(events, &(&1.type == :tray_served))
    Oracle.assert_settled!(state, events)
  end

  describe "simulated dessert" do
    defp service_batch(events, tray),
      do: events |> Enum.drop_while(&(&1[:tray_id] != tray or &1.type != :tray_served))

    test "appetite and an eligible, affordable dessert accept it in the service batch; the kitchen serves it", %{
      world: w
    } do
      w = simulated_visit(w, "d1", "bean_tacos", nil, "unrestricted", 10_000, true)
      vid = visit_id("visit-d1")
      w = serve_tray(w, tray_id("visit-d1"))
      {state, events} = w

      assert [%{type: :tray_served}, %{type: :dessert_accepted, visit_id: ^vid} | _] =
               service_batch(events, tray_id("visit-d1"))

      refute Enum.any?(events, &(&1.type == :dessert_offered))

      visit = state.visits[vid]
      assert visit_outcome(w, vid) == nil
      assert visit.dessert == :accepted
      assert visit.dessert_offer_deadline == nil
      order = state.orders[visit.dessert_order]
      assert order.kind == :dessert
      assert String.contains?(order.id, "DS:" <> vid)
      Oracle.assert_settled!(state, events)

      w = serve_dessert(w, order.id)
      {state, events} = w
      refute Map.has_key?(state.visits, vid)
      final = visit_outcome(w, vid)
      assert final.reason == :completed
      assert Enum.map(final.components, & &1.kind) == [:main, :dessert]
      assert final.score == 10_000
      assert final.competitive
      assert state.stats.served_desserts == 1
      assert state.stats.arrivals == 1
      assert state.demand.today.left == %{}
      Oracle.assert_settled!(state, events)
    end

    test "no appetite declines and finalizes in the service batch", %{world: w} do
      w = simulated_visit(w, "d1", "bean_tacos")
      vid = visit_id("visit-d1")
      w = serve_tray(w, tray_id("visit-d1"))
      {state, events} = w

      assert [%{type: :tray_served}, %{type: :dessert_declined, visit_id: ^vid}, %{type: :visit_finalized} = fin | _] =
               service_batch(events, tray_id("visit-d1"))

      assert fin.reason == :completed
      assert fin.score == 10_000
      assert visit_outcome(w, vid) == fin
      refute Map.has_key?(state.visits, vid)
      refute Enum.any?(events, &(&1.type in [:dessert_offered, :dessert_accepted]))
      # A served main followed by a declined dessert is not a visit that left.
      assert state.demand.today.left == %{}
      Oracle.assert_settled!(state, events)
    end

    test "a dessert over the carbohydrate ceiling finalizes without penalty despite appetite", %{world: w} do
      w = simulated_visit(w, "c1", "chicken_tacos", nil, "carb_conscious", 10_000, true)
      w = serve_tray(w, tray_id("visit-c1"))
      {state, events} = w
      outcome = visit_outcome(w, visit_id("visit-c1"))

      refute Map.has_key?(state.visits, visit_id("visit-c1"))
      assert Enum.map(outcome.components, & &1.kind) == [:main]
      assert outcome.score == 10_000
      assert outcome.reason == :completed
      refute Enum.any?(events, &(&1.type in [:dessert_offered, :dessert_accepted]))
      Oracle.assert_settled!(state, events)
    end

    test "a dessert that does not fit the remaining budget is declined", %{world: w} do
      w = simulated_visit(w, "d1", "bean_tacos", nil, "unrestricted", 900, true)
      w = serve_tray(w, tray_id("visit-d1"))
      {state, events} = w

      assert %{reason: :completed} = visit_outcome(w, visit_id("visit-d1"))
      refute Map.has_key?(state.visits, visit_id("visit-d1"))
      refute Enum.any?(events, &(&1.type == :dessert_accepted))
      Oracle.assert_settled!(state, events)
    end

    # A simulated diner's dessert order is `"O:DS:" <> visit_id <> ":dessert"`; a guest's is
    # `"O:" <> command_id <> ":dessert"`. The workflow refuses `DS:` command IDs to every actor;
    # the domain itself must also never let one live order replace another. Both trays are
    # accepted together: gina's is handed over 4..8 and d1's 8..12, so gina's dessert offer
    # (and, once accepted, her dessert) is still live when d1's dessert is decided at 12.
    defp gina_then_d1(w) do
      w
      |> grant("gina", 2_500, "grant")
      |> guest_visit("gina", "g1", "bean_tacos")
      |> simulated_visit("d1", "bean_tacos", nil, "unrestricted", 10_000, true)
    end

    test "a dessert acceptance whose order ID a live order holds is refused", %{world: w} do
      w = gina_then_d1(w)
      w = serve_tray(w, tray_id("visit-d1"))
      taken = "O:DS:" <> visit_id("visit-d1") <> ":dessert"
      assert elem(w, 0).orders[taken].status in FeudHall.Domain.Kitchen.stages()

      {state, _} = w
      vid = visit_id("g1")
      assert state.visits[vid].dessert == :offered
      {:ok, quote} = Offers.quote_dessert(state, state.visits[vid])
      accept = {:accept_dessert, %{visit_id: vid, confirmed: Offers.terms(quote)}}

      assert {:error, :order_id_taken} =
               Hall.decide(state, accept, ctx({:principal, "gina"}, "DS:" <> visit_id("visit-d1")))

      assert {:ok, _} = Hall.decide(state, accept, ctx({:principal, "gina"}, "g1-dessert"))
    end

    test "a simulated diner whose dessert order ID a live order holds declines and finalizes", %{world: w} do
      w = gina_then_d1(w)
      w = serve_tray(w, tray_id("g1"))
      {state, _} = w
      gid = visit_id("g1")
      {:ok, quote} = Offers.quote_dessert(state, state.visits[gid])
      claimed = "DS:" <> visit_id("visit-d1")

      w =
        run!(w, {:accept_dessert, %{visit_id: gid, confirmed: Offers.terms(quote)}}, {:principal, "gina"}, claimed)

      order_id = "O:" <> claimed <> ":dessert"
      assert elem(w, 0).orders[order_id].visit == gid

      w = serve_tray(w, tray_id("visit-d1"))
      {state, events} = w
      sid = visit_id("visit-d1")

      assert [%{type: :tray_served}, %{type: :dessert_declined, visit_id: ^sid}, %{type: :visit_finalized} | _] =
               service_batch(events, tray_id("visit-d1"))

      assert %{reason: :completed, components: [%{kind: :main}]} = visit_outcome(w, sid)
      refute Map.has_key?(state.visits, sid)
      assert state.orders[order_id].visit == gid
      assert state.visits[gid].dessert_order == order_id
      assert :ok = FeudHall.Domain.Hall.Invariants.check(state)
      Oracle.assert_settled!(state, events)
    end

    test "guests keep the timed dessert offer", %{world: w} do
      w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "g1", "bean_tacos")
      w = serve_tray(w, tray_id("g1"))
      {state, events} = w
      visit = state.visits[visit_id("g1")]

      assert visit.dessert == :offered
      assert visit.dessert_offer_deadline == state.now + Clock.service_duration(30_000)
      assert [%{type: :tray_served}, %{type: :dessert_offered} | _] = service_batch(events, tray_id("g1"))
    end
  end
end
