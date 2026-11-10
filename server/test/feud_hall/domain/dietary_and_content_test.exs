defmodule FeudHall.Domain.DietaryAndContentTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Content, Dietary, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.MexicanFixture
  alias FeudHall.Oracle

  describe "hard dietary compatibility" do
    test "incompatible mains are rejected regardless of price; compatible ones are accepted" do
      w = stocked_world()
      # Even at a price of one cent, a vegan cannot buy cheese.
      w =
        run!(
          w,
          {:set_menu_price, %{restaurant_id: "r1", recipe_id: "vegetable_quesadilla", price: 1}},
          owner(),
          "cheap"
        )

      {state, _} = w

      assert {:error, {:excluded_ingredient, "queso_oaxaca", :dairy}} =
               admit(state, "v1", "vegetable_quesadilla", nil, "vegan")

      assert {:error, {:excluded_ingredient, "chicken_thigh", :meat}} =
               admit(state, "v2", "chicken_tacos", nil, "vegetarian")

      assert {:ok, _} = admit(state, "v3", "bean_tacos", "horchata", "vegan")
      # Unrestricted diners may buy restricted-diet food.
      assert {:ok, _} = admit(state, "v4", "bean_tacos", nil, "unrestricted")
    end

    test "missing metadata is never compatible with a requirement" do
      # Vegan is disabled here: with cilantro's metadata missing, validation
      # (correctly) finds no viable vegan main.
      catalog = MexicanFixture.catalog(enable: ~w(unrestricted vegetarian carb_conscious))
      catalog = put_in(catalog, [:products, "cilantro", :origins], nil)
      catalog = put_in(catalog, [:recipes, "bean_tacos", :claims], [])
      w = stocked_world(catalog: catalog)
      {state, _} = w
      assert {:error, {:missing_metadata, "cilantro"}} = admit(state, "v1", "bean_tacos", nil, "vegetarian")
      assert {:ok, _} = admit(state, "v2", "bean_tacos", nil, "unrestricted")
    end

    test "a tray must fit the carbohydrate ceiling as a whole; carbs round up once per portion" do
      w = stocked_world()
      {state, _} = w
      # Chicken tacos: 2 x 12 g + 40 g x 60 mg/g + 20 g x 90 mg/g = 28,200 mg.
      assert {:ok, events} = admit(state, "c1", "chicken_tacos", nil, "carb_conscious")
      [%{components: [main]}] = Enum.filter(events, &(&1.type == :tray_accepted))
      assert main.carbs_mg == 28_200

      # Horchata adds 44,800 mg: 73,000 > 45,000, so the whole tray is refused.
      assert {:error, :carbohydrate_limit} = admit(state, "c2", "chicken_tacos", "horchata", "carb_conscious")
    end

    test "dessert is not offered when it would exceed the remaining carbohydrate allowance" do
      w = stocked_world() |> simulated_visit("c1", "chicken_tacos", nil, "carb_conscious")
      w = serve_tray(w, tray_id("visit-c1"))
      {state, events} = w
      # The visit finalized at service; its served carbohydrate is its served tray's.
      [served] = Enum.filter(events, &(&1.type == :tray_served and &1.tray_id == tray_id("visit-c1")))
      assert served.components |> Enum.map(& &1.carbs_mg) |> Enum.sum() == 28_200
      outcome = visit_outcome(w, visit_id("visit-c1"))
      assert outcome.components |> Enum.map(& &1.kind) == [:main]
      Oracle.assert_settled!(state, events)
    end

    test "the dessert shares the visit's ceiling with the already served tray" do
      # 90 g ceiling: dessert alone (67,400 mg) fits, main + dessert does not.
      catalog = put_in(MexicanFixture.catalog(), [:profiles, "carb_conscious", :carb_ceiling_mg], 90_000)
      w = stocked_world(catalog: catalog) |> simulated_visit("c1", "chicken_tacos", nil, "carb_conscious", 10_000, true)
      w = serve_tray(w, tray_id("visit-c1"))
      assert %{components: [%{kind: :main}]} = visit_outcome(w, visit_id("visit-c1"))

      # The same diner profile with an unrestricted first course gets the dessert.
      w = stocked_world(catalog: catalog) |> simulated_visit("u1", "chicken_tacos", nil, "unrestricted", 10_000, true)
      w = serve_tray(w, tray_id("visit-u1"))
      {state, _} = w
      assert state.visits[visit_id("visit-u1")].dessert == :accepted
    end

    test "portion carbohydrate rounds up exactly once after the whole bill" do
      catalog = MexicanFixture.catalog()
      lines = [%{product: "cinnamon", qty: 1}, %{product: "cinnamon", qty: 1}]
      # 2 g x 800,000 mg/kunit = 1,600 mg exactly (no per-line rounding).
      assert {:ok, 1_600} = Dietary.portion_carbs(catalog, lines)
      odd = put_in(catalog, [:products, "cinnamon", :carb_mg_per_kunit], 1)
      assert {:ok, 1} = Dietary.portion_carbs(odd, lines)
    end
  end

  describe "content validation" do
    test "the slice catalog is valid and hashes deterministically" do
      assert :ok = Content.validate(SliceCatalog.catalog())
      assert Content.hash(SliceCatalog.catalog()) == Content.hash(SliceCatalog.catalog())
    end

    test "a profile without any viable main cannot be enabled" do
      catalog = MexicanFixture.catalog(enable: ~w(unrestricted vegetarian vegan carb_conscious keto_style))
      assert {:error, problems} = Content.validate(catalog)
      assert {:profile, "keto_style", :no_viable_main} in problems
    end

    test "invalid conversions, recursive or claim-breaking substitutes, and incomplete cuisines are rejected" do
      base = MexicanFixture.catalog()

      bad_conv = put_in(base, [:recipes, "bean_tacos", :lines], bean_lines(base, &%{&1 | den: 0}))
      assert {:error, problems} = Content.validate(bad_conv)
      assert {:recipe_line, "bean_tacos", "tortilla", :bad_conversion} in problems

      meaty_sub =
        put_in(base, [:recipes, "bean_tacos", :lines], bean_lines(base, &%{&1 | product: "chicken_thigh"}))

      assert {:error, problems} = Content.validate(meaty_sub)
      assert {:recipe_line, "bean_tacos", "tortilla", :substitute_breaks_claim} in problems

      missing = update_in(base, [:recipes], &Map.delete(&1, "horchata"))
      assert {:error, problems} = Content.validate(missing)
      assert {:cuisine, "mexican", :needs_one_drink} in problems

      stricter = put_in(base, [:profiles, "keto_style", :carb_ceiling_mg], 50_000)
      assert {:error, problems} = Content.validate(stricter)
      assert {:profile, "keto_style", :not_stricter} in problems
    end

    test "removing metadata from the only vegan main makes enabling vegan invalid" do
      catalog = put_in(MexicanFixture.catalog(), [:products, "cilantro", :origins], nil)
      catalog = put_in(catalog, [:recipes, "bean_tacos", :claims], [])
      assert {:error, [{:profile, "vegan", :no_viable_main}]} = Content.validate(catalog)
    end

    test "a hall refuses invalid content at genesis" do
      bad = put_in(MexicanFixture.catalog(), [:products, "sugar", :base_price_per_kunit], 0)

      assert {:error, {:invalid_content, [{:product, "sugar", :bad_price}]}} =
               Hall.decide(nil, {:initialize_hall, %{hall_id: "h", catalog: bad}}, ctx({:system, :admin}, "i"))
    end
  end

  describe "simulation content" do
    defp broken(path, value), do: put_in(MexicanFixture.catalog(), path, value)

    defp problems!(catalog) do
      assert {:error, problems} = Content.validate(catalog)
      problems
    end

    test "the shipped simulation content is complete" do
      catalog = SliceCatalog.catalog()
      assert length(catalog.layout) == 150
      assert Enum.map(catalog.npc_profiles, & &1.id) == ~w(budget mainstream premium)
      assert Enum.map(catalog.rules.demand.segments, & &1.id) == ~w(value time_sensitive enthusiast quality)

      assert catalog.rules.seed in 0..18_446_744_073_709_551_615
      assert Content.hash(catalog) == Content.hash(SliceCatalog.catalog())
    end

    test "kitchen capacity must be positive" do
      assert {:kitchen, :bad_capacity} in problems!(broken([:rules, :kitchen, :prep_stations], 0))
    end

    test "every product needs a market target and a cap of at least three targets" do
      catalog =
        update_in(MexicanFixture.catalog(), [:rules, :market, :target_stock_per_equivalent], &Map.delete(&1, "sugar"))

      assert {:market, "sugar", :missing_target} in problems!(catalog)

      target = MexicanFixture.catalog().rules.market.target_stock_per_equivalent["onion"]

      assert {:market, "onion", :bad_cap} in problems!(
               broken([:rules, :market, :replenish_cap, "onion"], target * 3 - 1)
             )

      assert :ok = Content.validate(broken([:rules, :market, :replenish_cap, "onion"], target * 3))
    end

    test "market price bounds must be ordered" do
      assert {:market, :bad_price_bounds} in problems!(broken([:rules, :market, :price_floor_permille], 4_000))
    end

    test "hourly weights need 24 non-negative entries, zero during cleaning" do
      good = MexicanFixture.catalog().rules.demand.hourly_weights
      bad = [good |> tl(), List.replace_at(good, 0, -1), List.replace_at(good, 3, 1), List.replace_at(good, 4, 1)]

      for weights <- bad do
        assert {:demand, :bad_hourly_weights} in problems!(broken([:rules, :demand, :hourly_weights], weights))
      end
    end

    test "segment ranges must be ordered and positive" do
      assert {:demand, "value", :bad_range} in problems!(
               broken([:rules, :demand, :segments], bad_segment(:budget, [9, 3]))
             )

      assert {:demand, "value", :bad_range} in problems!(
               broken([:rules, :demand, :segments], bad_segment(:patience_hall_ms, [0, 3]))
             )
    end

    test "layout is capped at 150 slots with unique ids" do
      layout = MexicanFixture.catalog().layout
      extra = layout ++ [%{slot_id: "s151", tier: :quiet}]
      assert {:layout, :too_many_slots} in problems!(broken([:layout], extra))

      dup = List.replace_at(layout, 1, %{slot_id: "s001", tier: :quiet})
      assert {:layout, "s001", :duplicate} in problems!(broken([:layout], dup))
    end

    test "NPC profiles are validated" do
      [first | rest] = MexicanFixture.catalog().npc_profiles

      for bad <- [
            %{first | price_permille: 0},
            %{first | policy: :bogus},
            %{first | restock_days: 0},
            %{first | preferred_tier: :nowhere}
          ] do
        assert {:npc, "budget", :bad_profile} in problems!(broken([:npc_profiles], [bad | rest]))
      end
    end

    defp bad_segment(key, value) do
      [first | rest] = MexicanFixture.catalog().rules.demand.segments
      [Map.put(first, key, value) | rest]
    end
  end

  describe "simulation content hardening" do
    defp bad(path, value), do: put_in(MexicanFixture.catalog(), path, value)

    defp has?(catalog, problem) do
      assert {:error, problems} = Content.validate(catalog)
      assert problem in problems
    end

    defp drop(path) do
      {parent, [key]} = Enum.split(path, -1)

      if parent == [],
        do: Map.delete(MexicanFixture.catalog(), key),
        else: update_in(MexicanFixture.catalog(), parent, &Map.delete(&1, key))
    end

    defp seg(key, value) do
      [first | rest] = MexicanFixture.catalog().rules.demand.segments
      [:rules, :demand, :segments] |> then(&bad(&1, [Map.put(first, key, value) | rest]))
    end

    defp seg_without(key) do
      [first | rest] = MexicanFixture.catalog().rules.demand.segments
      bad([:rules, :demand, :segments], [Map.delete(first, key) | rest])
    end

    test "the shipped fixed values are as designed" do
      c = SliceCatalog.catalog()
      assert c.rules.kitchen == %{prep_stations: 2, finish_stations: 1, queue_limit: 6}
      m = c.rules.market
      assert {m.clear_every_hall_ms, m.price_floor_permille, m.price_ceiling_permille} == {240_000, 500, 3_000}
      assert c.rules.exposure_permille == %{quiet: 800, standard: 1_000, busy: 1_250, prime: 1_500}
      d = c.rules.demand
      assert [d.profile_mix["unrestricted"], d.profile_mix["vegetarian"], d.profile_mix["vegan"]] == [60, 20, 10]
      assert [d.profile_mix["carb_conscious"], d.profile_mix["keto_style"]] == [7, 3]
      assert length(d.hourly_weights) == 24
      assert Enum.at(d.hourly_weights, 3) == 0 and Enum.at(d.hourly_weights, 4) == 0
      assert Enum.sum(d.hourly_weights) > 0
      assert d.arrivals_per_equivalent == 90 and d.equivalent_floor_millis == 3_000
      assert d.operating_hours_ms == 79_200_000

      for {id, target} <- m.target_stock_per_equivalent, do: assert(m.replenish_cap[id] >= target * 3)

      assert Enum.map(c.layout, & &1.slot_id) == for(n <- 1..150, do: "s" <> String.pad_leading("#{n}", 3, "0"))
    end

    test "kitchen cases" do
      has?(bad([:rules, :kitchen, :finish_stations], 0), {:kitchen, :bad_capacity})
      has?(bad([:rules, :kitchen, :queue_limit], 0), {:kitchen, :bad_capacity})
      has?(drop([:rules, :kitchen, :queue_limit]), {:kitchen, :bad_capacity})
      has?(bad([:rules, :kitchen], :nope), {:kitchen, :bad_capacity})
    end

    test "slot tiers" do
      layout = List.replace_at(MexicanFixture.catalog().layout, 4, %{slot_id: "s005", tier: :nowhere})
      has?(bad([:layout], layout), {:layout, "s005", :bad_tier})
    end

    test "exposure" do
      has?(drop([:rules, :exposure_permille, :prime]), {:exposure, :bad_exposure})
      has?(bad([:rules, :exposure_permille, :quiet], 0), {:exposure, :bad_exposure})
      has?(bad([:rules, :exposure_permille, :extra], 5), {:exposure, :bad_exposure})
      has?(drop([:rules, :exposure_permille]), {:exposure, :bad_exposure})
    end

    test "segment weights" do
      for key <- ~w(weight)a, v <- [0, -1, "1"], do: has?(seg(key, v), {:demand, "value", :bad_weights})

      for key <- ~w(price_weight quality_weight wait_weight leave_weight)a,
          v <- [-1, 1.5],
          do: has?(seg(key, v), {:demand, "value", :bad_weights})

      for key <- ~w(drink_attach_permille dessert_appetite_permille)a,
          v <- [-1, 1001],
          do: has?(seg(key, v), {:demand, "value", :bad_weights})

      has?(seg_without(:wait_weight), {:demand, "value", :bad_weights})
    end

    test "segment main preference" do
      for v <- [%{}, %{"ghost" => 1}, %{"bean_tacos" => -1}, %{"bean_tacos" => 0}, :x] do
        has?(seg(:main_preference, v), {:demand, "value", :bad_main_preference})
      end

      has?(seg_without(:main_preference), {:demand, "value", :bad_main_preference})
    end

    test "profile mix" do
      for v <- [%{"ghost" => 1}, %{"vegan" => -1}, %{"vegan" => 0}, %{}, :x] do
        has?(bad([:rules, :demand, :profile_mix], v), {:demand, :bad_profile_mix})
      end

      # Arrivals draw only enabled profiles: a mix weighting only disabled ones cannot be drawn.
      has?(bad([:rules, :demand, :profile_mix], %{"keto_style" => 3, "vegan" => 0}), {:demand, :bad_profile_mix})
    end

    test "arrivals per equivalent may be zero (a hall without simulated diners) but not negative" do
      assert :ok = Content.validate(bad([:rules, :demand, :arrivals_per_equivalent], 0))
      has?(bad([:rules, :demand, :arrivals_per_equivalent], -1), {:demand, :malformed})
    end

    test "hourly weights with zero total, and variety" do
      has?(bad([:rules, :demand, :hourly_weights], List.duplicate(0, 24)), {:demand, :bad_hourly_weights})
      has?(bad([:rules, :demand, :variety_weight], -1), {:demand, :bad_variety})
      has?(bad([:rules, :demand, :variety_cap], 1.5), {:demand, :bad_variety})
    end

    test "malformed sections report instead of raising" do
      has?(drop([:rules, :market, :target_stock_per_equivalent]), {:market, :malformed})
      has?(bad([:rules, :market], nil), {:market, :malformed})
      has?(drop([:rules, :demand, :segments]), {:demand, :malformed})
      has?(bad([:rules, :demand], nil), {:demand, :malformed})
      has?(bad([:rules, :demand, :segments], [:junk]), {:demand, :malformed})
      has?(seg_without(:budget), {:demand, "value", :bad_range})
      has?(bad([:layout], :nope), {:layout, :malformed})
      has?(bad([:layout], [%{tier: :quiet}]), {:layout, :malformed})
      has?(drop([:layout]), {:layout, :malformed})
      has?(bad([:npc_profiles], [%{id: "budget"}]), {:npc, "budget", :bad_profile})
      has?(bad([:npc_profiles], [:junk]), {:npc, nil, :bad_profile})
      has?(drop([:rules, :seed]), {:seed, :bad_seed})
      has?(bad([:rules, :seed], "7"), {:seed, :bad_seed})
      has?(bad([:rules, :seed], -1), {:seed, :bad_seed})
      has?(bad([:rules, :seed], 18_446_744_073_709_551_616), {:seed, :bad_seed})
      assert :ok = Content.validate(bad([:rules, :seed], 18_446_744_073_709_551_615))
    end
  end

  defp bean_lines(catalog, sub_fun) do
    Enum.map(catalog.recipes["bean_tacos"].lines, fn
      %{line_id: "tortilla", substitute: s} = l -> %{l | substitute: sub_fun.(s)}
      l -> l
    end)
  end

  defp admit(state, id, main, drink, profile) do
    Hall.decide(
      state,
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: id,
         budget: 10_000,
         stall_id: "s001",
         main: main,
         drink: drink,
         profile_id: profile
       }},
      ctx({:system, :demand}, id)
    )
  end

  test "content rejects invalid starter prices, unaddressable NPCs and unsampleable weights" do
    catalog = MexicanFixture.catalog()
    assert {:error, errors} = Content.validate(put_in(catalog.recipes["bean_tacos"].suggested_price, -900))
    assert {:recipe, "bean_tacos", :bad_suggested_price} in errors

    [npc | _] = catalog.npc_profiles
    broken = %{catalog | npc_profiles: [Map.delete(npc, :id), npc, npc, %{npc | id: "contains:separator"}]}
    assert {:error, errors} = Content.validate(broken)
    assert {:npc, nil, :bad_profile} in errors
    assert {:npc, npc.id, :duplicate} in errors
    assert {:npc, "contains:separator", :bad_profile} in errors

    max = FeudHall.Domain.Random.max_bound()
    broken = put_in(catalog.rules.demand.profile_mix["unrestricted"], max)
    assert {:error, errors} = Content.validate(broken)
    assert {:demand, :bad_profile_mix} in errors

    broken =
      update_in(catalog.rules.demand.segments, fn [segment | rest] -> [%{segment | leave_weight: max} | rest] end)

    assert {:error, errors} = Content.validate(broken)
    assert {:demand, "value", :choice_weights_too_large} in errors
  end
end
