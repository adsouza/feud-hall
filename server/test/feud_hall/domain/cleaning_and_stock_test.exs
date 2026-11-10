defmodule FeudHall.Domain.CleaningAndStockTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Oracle

  @three Clock.cleaning_start_of(0)
  @five Clock.cleaning_end_of(0)

  describe "03:00 cleaning cutoff" do
    test "admission requires completion strictly before 03:00" do
      # An idle kitchen: no simulated diner queues ahead.
      w = stocked_world(arrivals: false)
      # Main work (4 min) plus handover (4 min) must finish before 03:00.
      w = advance_hall(w, @three - 8 * Clock.minute())
      {state, _} = w
      assert {:error, :cannot_finish_before_cleaning} = admit(state, "late")

      w = advance_hall(stocked_world(arrivals: false), @three - 8 * Clock.minute() - Clock.ratio())
      {state, _} = w
      assert {:ok, _} = admit(state, "just-in-time")
    end

    test "the cutoff cancels unserved work once, keeps consumed cost as waste, and exempts scoring" do
      w = stocked_world() |> advance_hall(@three - 14 * Clock.minute())
      w = simulated_visit(w, "prepared", "bean_tacos", "horchata")
      w = simulated_visit(w, "waiting", "chicken_tacos")
      # Both quotes finish before 03:00; a slower counter afterwards keeps the
      # first tray in handover and the second ready at the cutoff.
      {state, log} = w
      w = {put_in(state, [:catalog, :rules, :handover_ms], 30 * Clock.minute()), log}
      w = advance_hall(w, @three - Clock.ratio())
      {before, _} = w
      ledger = before.restaurants["r1"].ledger
      assert ledger.wip > 0
      assert before.trays[tray_id("visit-prepared")].status == :accepted

      # Nothing is served at exactly 03:00: the gate closes first.
      {state, events} = cut = advance_hall(w, @three)
      assert state.access == :cleaning

      for id <- ["visit-prepared", "visit-waiting"] do
        refute Map.has_key?(state.visits, visit_id(id))
        outcome = visit_outcome(cut, visit_id(id))
        assert outcome.reason == :cleaning
        assert outcome.score == nil
        refute outcome.competitive
      end

      after_ledger = state.restaurants["r1"].ledger
      assert after_ledger.wip == 0
      assert after_ledger.waste == ledger.waste + ledger.wip
      assert after_ledger.revenue == ledger.revenue
      assert state.stalls["s001"].counter == nil
      assert Enum.count(events, &(&1.type == :hall_cleaning_started)) == 1
      Oracle.assert_settled!(state, events)

      # No admissions during cleaning, including the last tick before 05:00.
      {state, _} = advance_hall({state, events}, @five - Clock.ratio())
      assert {:error, :hall_cleaning} = admit(state, "during")

      {state, events} = advance_hall({state, events}, @five)
      assert state.access == :open
      assert Enum.count(events, &(&1.type == :hall_cleaning_ended)) == 1
      assert {:ok, _} = admit(state, "after")
    end

    test "an open dessert offer is closed by the cutoff, keeping the served tray's score" do
      # Served at 02:48 (eight minutes of work): the dessert still fits before 03:00.
      w = stocked_world() |> advance_hall(@three - 20 * Clock.minute())
      w = grant(w, "gina", 2_500, "grant") |> guest_visit("gina", "d1", "bean_tacos")
      w = serve_tray(w, tray_id("d1"))
      {state, _} = w
      vid = visit_id("d1")
      assert state.visits[vid].dessert == :offered
      # The 30 s window (12 game minutes) is capped at 03:00.
      assert state.visits[vid].dessert_offer_deadline == @three

      {state, events} = cut = advance_hall(w, @three)
      assert visit_outcome(cut, vid).reason == :cleaning
      assert visit_outcome(cut, vid).score == 10_000
      # Guest visits are never competitive.
      refute visit_outcome(cut, vid).competitive
      Oracle.assert_settled!(state, events)
    end

    test "a simulated visit's accepted dessert still in the kitchen at 03:00 is cancelled; the served main keeps its score" do
      # An accepted dessert always quotes to finish before 03:00, so it is only
      # unfinished at the cutoff if the counter slows after acceptance (as in
      # automatic_kitchen_test's cleaning case).
      w = stocked_world() |> advance_hall(@three - 20 * Clock.minute())
      w = simulated_visit(w, "d1", "bean_tacos", nil, "unrestricted", 10_000, true)
      w = serve_tray(w, tray_id("visit-d1"))
      {state, log} = w
      vid = visit_id("visit-d1")
      assert state.visits[vid].dessert == :accepted
      dessert_id = state.visits[vid].dessert_order
      assert state.now < @three

      w = {put_in(state, [:catalog, :rules, :handover_ms], 30 * Clock.minute()), log}
      w = advance_hall(w, @three - Clock.ratio())
      {before, _} = w
      assert Map.has_key?(before.visits, vid)
      assert visit_outcome(w, vid) == nil
      assert before.orders[dessert_id].status != :served

      {state, events} = cut = advance_hall(w, @three)
      assert order_status(cut, dessert_id) == :cancelled
      assert order_cancel_reason(cut, dessert_id) == :cleaning
      assert Enum.any?(events, &(&1.type == :dessert_cancelled and &1.reason == :cleaning))
      assert visit_outcome(cut, vid).reason == :cleaning
      assert visit_outcome(cut, vid).score == 10_000
      assert visit_outcome(cut, vid).competitive
      Oracle.assert_settled!(state, events)
    end

    test "no dessert is offered when its work cannot finish before the cutoff" do
      # Served at 02:53: dessert work (seven minutes) would end exactly at 03:00.
      w = stocked_world() |> advance_hall(@three - 15 * Clock.minute())
      w = simulated_visit(w, "d1", "bean_tacos")
      # Dessert work no longer fits before the cutoff, so no offer is made.
      {state, events} = served = serve_tray(w, tray_id("visit-d1"))

      # Finalized at service.
      refute Map.has_key?(state.visits, visit_id("visit-d1"))
      assert visit_outcome(served, visit_id("visit-d1")).score == 10_000
      Oracle.assert_settled!(state, events)
    end
  end

  describe "warehouse stock" do
    test "raw stock expiring before preparation cancels the tray when no replacement exists" do
      # Six queued mains; two prep stations take two a minute, so the last two
      # still hold cilantro claims when it expires at 2 minutes.
      w = cilantro_queue(2 * Clock.minute())
      {queued, _} = w
      {state, _} = advance_hall(w, queued.now + Clock.minute())
      cilantro = state.restaurants["r1"].batches |> Map.values() |> Enum.find(&(&1.product == "cilantro"))
      assert cilantro.expires_at == queued.now + 2 * Clock.minute()

      {state, events} = expired = advance_hall(w, cilantro.expires_at)

      for i <- 1..6 do
        expected = if i <= 4, do: :accepted, else: :cancelled
        assert tray_status(expired, tray_id("visit-d#{i}")) == expected
      end

      assert visit_outcome(expired, visit_id("visit-d6")).reason == :main_failed
      [main] = queued.trays[tray_id("visit-d6")].components
      assert order_cancel_reason(expired, main) == :ingredient_expired
      refute Map.has_key?(state.restaurants["r1"].batches, cilantro.id)
      # Spoilage writes off the remaining batch once; the unprepared orders add no waste.
      spoiled = Enum.filter(events, &(&1.type == :stock_spoiled and &1.batch_id == cilantro.id))
      assert [%{cost: cost}] = spoiled
      assert cost == cilantro.cost
      assert state.restaurants["r1"].ledger.waste == cilantro.cost
      Oracle.assert_settled!(state, events)
    end

    test "with a fresh batch available the expiring claim moves instead of cancelling" do
      # The fresh batch arrives at the next market clearing, four minutes after
      # the stocked world's; the queue is built then, two minutes before the
      # first batch expires, so the same two mains still hold claims at expiry.
      w = cilantro_queue(6 * Clock.minute(), &buy(&1, "cilantro", 10, "fresh"))
      {state, _} = w
      old = state.restaurants["r1"].batches |> Map.values() |> Enum.min_by(& &1.expires_at)
      assert old.expires_at == state.now + 2 * Clock.minute()

      {state, events} = advance_hall(w, old.expires_at)
      [main] = state.trays[tray_id("visit-d6")].components
      assert state.trays[tray_id("visit-d6")].status == :accepted
      assert state.orders[main].status == :prep
      assert Enum.any?(events, &(&1.type == :reservation_replaced and &1.order_id == main))

      assert Enum.any?(
               events,
               &(&1.type == :stage_started and &1.order_id == main and hd(&1.consumed).batch_id != old.id)
             )

      Oracle.assert_settled!(state, events)
    end

    test "preparation consumes reserved units once with exact proportional cost" do
      w = stocked_world() |> simulated_visit("d1", "bean_tacos")
      {before, _} = w
      [main] = before.trays[tray_id("visit-d1")].components
      raw_before = before.restaurants["r1"].ledger.raw

      # Prep starts at the acceptance instant on the next advance.
      {state, events} = advance_hall(w, before.now)
      assert state.orders[main].status == :prep
      consumed = state.orders[main].consumed_cost
      assert consumed > 0
      assert state.restaurants["r1"].ledger.raw == raw_before - consumed
      assert state.restaurants["r1"].ledger.wip == consumed
      Oracle.assert_settled!(state, events)

      {state, events} = serve_tray({state, events}, tray_id("visit-d1"))
      assert Enum.count(events, &(&1.type == :stage_started and &1.stage == :prep and &1.order_id == main)) == 1
      assert state.restaurants["r1"].ledger.cost_of_sales == consumed
      Oracle.assert_settled!(state, events)
    end
  end

  describe "substitution" do
    test "prefer-primary falls back across the whole bill and pins the accepted variant" do
      w = stocked_world(stock: Map.put(default_stock(), "corn_tortilla", 1))
      {state, _} = w
      assert {:error, :unavailable} = admit(state, "short")

      w =
        run!(
          w,
          {:set_substitution_policy,
           %{restaurant_id: "r1", recipe_id: "bean_tacos", line_id: "tortilla", policy: :prefer_primary}},
          owner(),
          "pol"
        )
        |> buy("corn_tortilla_packaged", 4, "pack")

      w = simulated_visit(w, "d1", "bean_tacos")
      {state, _} = w
      [main] = state.trays[tray_id("visit-d1")].components
      assert Enum.find(state.orders[main].lines, &(&1.line_id == "tortilla")).product == "corn_tortilla_packaged"
      assert state.orders[main].quality == 97

      # Later policy edits never change an accepted bill.
      w =
        run!(
          w,
          {:set_substitution_policy,
           %{restaurant_id: "r1", recipe_id: "bean_tacos", line_id: "tortilla", policy: :primary_only}},
          owner(),
          "pol2"
        )

      {state, events} = w
      assert Enum.find(state.orders[main].lines, &(&1.line_id == "tortilla")).product == "corn_tortilla_packaged"
      Oracle.assert_settled!(state, events)
    end

    test "conversion rounds up and penalties cap at nine points" do
      w = stocked_world(stock: %{})

      w =
        Enum.reduce(~w(tortilla beans onion), w, fn line, w ->
          run!(
            w,
            {:set_substitution_policy,
             %{restaurant_id: "r1", recipe_id: "bean_tacos", line_id: line, policy: :prefer_substitute}},
            owner(),
            "pol-" <> line
          )
        end)
        |> stock(%{
          "corn_tortilla_packaged" => 2,
          "black_beans_canned" => 150,
          "onion_diced_frozen" => 20,
          "salsa_roja" => 40,
          "cilantro" => 5
        })

      w = simulated_visit(w, "d1", "bean_tacos")
      {state, _} = w
      [main] = state.trays[tray_id("visit-d1")].components
      order = state.orders[main]
      # 60 g dried beans -> 5/2 conversion -> 150 g canned.
      assert Enum.find(order.lines, &(&1.line_id == "beans")).qty == 150
      assert order.penalty == 9
      assert order.quality == 91
    end

    test "the nine-point cap binds when substitution penalties would exceed it" do
      # Slice content has at most three 3-point lines (exactly 9), so raise the
      # per-line penalty to make the cap observable.
      catalog =
        update_in(SliceCatalog.catalog(), [:recipes, "bean_tacos", :lines], fn lines ->
          Enum.map(lines, fn
            %{substitute: nil} = l -> l
            l -> put_in(l, [:substitute, :penalty], 4)
          end)
        end)

      w = stocked_world(catalog: catalog, stock: %{})

      w =
        Enum.reduce(~w(tortilla beans onion), w, fn line, w ->
          run!(
            w,
            {:set_substitution_policy,
             %{restaurant_id: "r1", recipe_id: "bean_tacos", line_id: line, policy: :prefer_substitute}},
            owner(),
            "pol-" <> line
          )
        end)
        |> stock(%{
          "corn_tortilla_packaged" => 2,
          "black_beans_canned" => 150,
          "onion_diced_frozen" => 20,
          "salsa_roja" => 40,
          "cilantro" => 5
        })
        |> simulated_visit("d1", "bean_tacos")

      {state, _} = w
      [main] = state.trays[tray_id("visit-d1")].components
      assert state.orders[main].penalty == 9
      assert state.orders[main].quality == 91
    end

    test "consolidated demand across tray components cannot over-reserve shared stock" do
      # Rice is used by the drink only; sugar by drink and dessert. Give exactly
      # one drink's worth of rice and verify a second drink cannot reserve it.
      w = stocked_world(stock: Map.merge(default_stock(), %{"rice_long" => 30}))
      w = simulated_visit(w, "d1", "bean_tacos", "horchata")
      {state, _} = w
      assert {:error, :unavailable} = admit(state, "second", "horchata")
    end
  end

  describe "purchasing and authority" do
    test "purchases respect cash, storage capacity, and price limits" do
      w = stocked_world()
      {state, _} = w

      # Quantities are validated at submission; limits, storage and cash at clearing.
      assert {:error, :invalid_quantity} = Hall.decide(state, purchase("rice_long", 0, 1_000_000), ctx(owner(), "p3"))

      assert [%{reason: :price_above_limit, qty: 10}] = unfilled_at_clearing(w, purchase("rice_long", 10, 1))

      assert %{reason: :insufficient_storage} =
               w |> unfilled_at_clearing(purchase("rice_long", 400_000, 1_000_000)) |> hd()

      poor = {put_in(state, [:restaurants, "r1", :ledger, :cash], 0), []}
      assert [%{reason: :insufficient_cash, qty: 10}] = unfilled_at_clearing(poor, purchase("rice_long", 10, 1_000_000))
    end

    test "a rival owner cannot spend, price, or reconfigure another restaurant" do
      w = stocked_world()

      w =
        run!(
          w,
          {:create_restaurant, %{restaurant_id: "r2", stall_id: "s002", name: "Bob's", cuisine: "mexican"}},
          {:principal, "bob"},
          "bob"
        )

      {state, _} = w
      bob = ctx({:principal, "bob"}, "evil")
      assert {:error, :forbidden} = Hall.decide(state, purchase("rice_long", 10, 1_000_000), bob)

      assert {:error, :forbidden} =
               Hall.decide(state, {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 1}}, bob)

      assert {:error, :forbidden} = Hall.decide(state, {:close_stall, %{stall_id: "s001"}}, bob)
      # One non-terminated venture per owner.
      assert {:error, :venture_already_active} =
               Hall.decide(
                 state,
                 {:create_restaurant, %{restaurant_id: "r3", stall_id: "s003", name: "Again", cuisine: "mexican"}},
                 bob
               )

      # Scheduler and visitor-fund capabilities are not owner powers.
      assert {:error, _} = Hall.decide(state, {:advance_clock, %{to_service_ms: 999}}, ctx(owner(), "clock"))

      assert {:error, _} =
               Hall.decide(state, {:grant_allowance, %{principal: "alice", amount: 100}}, ctx(owner(), "mint"))
    end
  end

  defp admit(state, id, drink \\ nil) do
    Hall.decide(
      state,
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: id,
         budget: 10_000,
         stall_id: "s001",
         main: "bean_tacos",
         drink: drink,
         profile_id: "unrestricted"
       }},
      ctx({:system, :demand}, id)
    )
  end

  # Six queued bean taco mains accepted at once, after `before_queue` has run on
  # a stocked world whose cilantro keeps for `shelf_ms`.
  defp cilantro_queue(shelf_ms, before_queue \\ & &1) do
    catalog = put_in(SliceCatalog.catalog(), [:products, "cilantro", :shelf_life_ms], shelf_ms)
    rules = %{catalog.rules | service_window_ms: 2 * Clock.hour()}
    w = before_queue.(stocked_world(catalog: %{catalog | rules: rules}))
    Enum.reduce(1..6, w, &simulated_visit(&2, "d#{&1}", "bean_tacos"))
  end

  # Submits `request` and returns its unfilled entries at the next clearing.
  defp unfilled_at_clearing(world, request) do
    {_, events} = world |> run!(request, owner(), "req") |> to_clearing()
    %{unfilled: unfilled} = events |> Enum.filter(&(&1.type == :market_cleared)) |> List.last()
    Enum.filter(unfilled, &(&1.request_id == "PR:req"))
  end

  defp purchase(product, qty, limit),
    do: {:submit_purchase_request, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: limit}}
end
