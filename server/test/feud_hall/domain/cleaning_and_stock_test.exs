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
      w = stocked_world()
      # Main work (4 min) plus handover (4 min) must finish before 03:00.
      w = advance_hall(w, @three - 8 * Clock.minute())
      {state, _} = w
      assert {:error, :cannot_finish_before_cleaning} = admit(state, "late")

      w = advance_hall(stocked_world(), @three - 8 * Clock.minute() - Clock.ratio())
      {state, _} = w
      assert {:ok, _} = admit(state, "just-in-time")
    end

    test "the cutoff cancels unserved work once, keeps consumed cost as waste, and exempts scoring" do
      # Late enough that the drink's 15-minute holding lifetime outlasts 03:00.
      w = stocked_world() |> advance_hall(@three - 10 * Clock.minute())
      w = simulated_visit(w, "prepared", "bean_tacos", "horchata")
      w = simulated_visit(w, "waiting", "chicken_tacos")
      w = prepare_tray(w, tray_id("visit-prepared"))
      {before, _} = w
      ledger = before.restaurants["r1"].ledger
      assert ledger.wip > 0

      # A ready tray cannot be served at exactly 03:00: the gate closes first.
      {state, events} = advance_hall(w, @three)
      assert state.access == :cleaning

      assert {:error, _} =
               Hall.decide(state, {:serve_tray, %{tray_id: tray_id("visit-prepared")}}, ctx({:system, :kitchen}, "s"))

      for id <- ["visit-prepared", "visit-waiting"] do
        visit = state.visits[visit_id(id)]
        assert visit.status == :finalized
        assert visit.outcome.reason == :cleaning
        assert visit.outcome.score == nil
        refute visit.outcome.competitive
      end

      after_ledger = state.restaurants["r1"].ledger
      assert after_ledger.wip == 0
      assert after_ledger.waste == ledger.waste + ledger.wip
      assert after_ledger.revenue == ledger.revenue
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
      w = stocked_world() |> advance_hall(@three - 12 * Clock.minute())
      w = simulated_visit(w, "d1", "bean_tacos")
      w = prepare_tray(w, tray_id("visit-d1")) |> kitchen(:serve_tray, %{tray_id: tray_id("visit-d1")}, "serve")
      {state, _} = w
      vid = visit_id("visit-d1")
      assert state.visits[vid].dessert == :offered
      # The 30 s window (12 game minutes) is capped at 03:00.
      assert state.visits[vid].dessert_offer_deadline == @three

      {state, events} = advance_hall(w, @three)
      assert state.visits[vid].outcome.reason == :cleaning
      assert state.visits[vid].outcome.score == 10_000
      assert state.visits[vid].outcome.competitive
      Oracle.assert_settled!(state, events)
    end

    test "no dessert is offered when its work cannot finish before the cutoff" do
      w = stocked_world() |> advance_hall(@three - 15 * Clock.minute())
      w = simulated_visit(w, "d1", "bean_tacos")
      w = prepare_tray(w, tray_id("visit-d1"))
      # Serve close enough to 03:00 that the 30 s offer window is capped by it.
      w = advance_hall(w, @three - Clock.service_duration(10_000))
      {state, _} = w
      # Dessert work no longer fits before the cutoff, so no offer is made.
      {state, events} =
        run!({state, elem(w, 1)}, {:serve_tray, %{tray_id: tray_id("visit-d1")}}, {:system, :kitchen}, "s")

      assert state.visits[visit_id("visit-d1")].status == :finalized
      assert state.visits[visit_id("visit-d1")].outcome.score == 10_000
      Oracle.assert_settled!(state, events)
    end
  end

  describe "warehouse stock" do
    test "raw stock expiring before preparation cancels the tray when no replacement exists" do
      catalog =
        update_in(SliceCatalog.catalog(), [:products, "cilantro", :shelf_life_ms], fn _ -> 30 * Clock.minute() end)

      rules = %{catalog.rules | service_window_ms: 2 * Clock.hour()}
      w = stocked_world(catalog: %{catalog | rules: rules})
      w = simulated_visit(w, "d1", "bean_tacos")
      {state, _} = w
      cilantro = state.restaurants["r1"].batches |> Map.values() |> Enum.find(&(&1.product == "cilantro"))

      {state, events} = advance_hall(w, ceil_to_tick(cilantro.expires_at))
      assert state.trays[tray_id("visit-d1")].status == :cancelled
      assert state.visits[visit_id("visit-d1")].outcome.reason == :main_failed
      refute Map.has_key?(state.restaurants["r1"].batches, cilantro.id)
      # Spoilage writes off the batch once; the unprepared order adds no waste.
      spoiled = Enum.filter(events, &(&1.type == :stock_spoiled and &1.batch_id == cilantro.id))
      assert [%{cost: cost}] = spoiled
      assert cost == cilantro.cost
      Oracle.assert_settled!(state, events)
    end

    test "with a fresh batch available the expiring claim moves instead of cancelling" do
      catalog =
        update_in(SliceCatalog.catalog(), [:products, "cilantro", :shelf_life_ms], fn _ -> 30 * Clock.minute() end)

      rules = %{catalog.rules | service_window_ms: 2 * Clock.hour()}
      w = stocked_world(catalog: %{catalog | rules: rules})
      w = simulated_visit(w, "d1", "bean_tacos")
      w = advance_hall(w, 10 * Clock.minute()) |> buy("cilantro", 10, "fresh")
      {state, _} = w
      old = state.restaurants["r1"].batches |> Map.values() |> Enum.min_by(& &1.expires_at)

      {state, events} = advance_hall(w, ceil_to_tick(old.expires_at))
      [main] = state.trays[tray_id("visit-d1")].components
      assert state.trays[tray_id("visit-d1")].status == :accepted
      assert Enum.any?(state.orders[main].reservations, &(&1.batch_id == "B:fresh"))
      assert Enum.any?(events, &(&1.type == :reservation_replaced))
      Oracle.assert_settled!(state, events)
    end

    test "preparation consumes reserved units once with exact proportional cost" do
      w = stocked_world() |> simulated_visit("d1", "bean_tacos")
      {before, _} = w
      [main] = before.trays[tray_id("visit-d1")].components
      raw_before = before.restaurants["r1"].ledger.raw

      {state, events} = kitchen(w, :start_preparation, %{order_id: main}, "start")
      consumed = state.orders[main].consumed_cost
      assert consumed > 0
      assert state.restaurants["r1"].ledger.raw == raw_before - consumed
      assert state.restaurants["r1"].ledger.wip == consumed

      assert {:error, :invalid_order_state} =
               Hall.decide(state, {:start_preparation, %{order_id: main}}, ctx({:system, :kitchen}, "again"))

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

      assert {:error, :price_above_limit} =
               Hall.decide(state, purchase("rice_long", 10, 1), ctx(owner(), "p1"))

      assert {:error, :insufficient_storage} =
               Hall.decide(state, purchase("rice_long", 400_000, 1_000_000), ctx(owner(), "p2"))

      assert {:error, :invalid_quantity} = Hall.decide(state, purchase("rice_long", 0, 1_000_000), ctx(owner(), "p3"))

      poor = put_in(state, [:restaurants, "r1", :ledger, :cash], 1)
      assert {:error, :insufficient_cash} = Hall.decide(poor, purchase("rice_long", 10, 1_000_000), ctx(owner(), "p4"))
    end

    test "a rival owner cannot spend, price, or reconfigure another restaurant" do
      w = stocked_world()

      w =
        run!(
          w,
          {:create_restaurant, %{restaurant_id: "r2", stall_id: "s2", name: "Bob's", cuisine: "mexican"}},
          {:principal, "bob"},
          "bob"
        )

      {state, _} = w
      bob = ctx({:principal, "bob"}, "evil")
      assert {:error, :forbidden} = Hall.decide(state, purchase("rice_long", 10, 1_000_000), bob)

      assert {:error, :forbidden} =
               Hall.decide(state, {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 1}}, bob)

      assert {:error, :forbidden} = Hall.decide(state, {:close_stall, %{stall_id: "s1"}}, bob)
      # One non-terminated venture per owner.
      assert {:error, :venture_already_active} =
               Hall.decide(
                 state,
                 {:create_restaurant, %{restaurant_id: "r3", stall_id: "s3", name: "Again", cuisine: "mexican"}},
                 bob
               )

      # Kitchen and demand capabilities are not owner powers.
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
         stall_id: "s1",
         main: "bean_tacos",
         drink: drink,
         profile_id: "unrestricted"
       }},
      ctx({:system, :demand}, id)
    )
  end

  defp purchase(product, qty, limit),
    do: {:purchase_stock, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: limit}}
end
