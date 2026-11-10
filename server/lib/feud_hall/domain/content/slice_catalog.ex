defmodule FeudHall.Domain.Content.SliceCatalog do
  @moduledoc """
  Internal three-cuisine catalog for the shared simulation, authored as
  versioned data. Each cuisine has three savory recipes, one dessert and one drink.

  The full launch catalog is specified in the game design. Every number here
  is a proposed tuning value. Quantities use base units
  (`:g`, `:ml`, `:each`); `*_per_kunit` values are per 1000 base units so
  fractional unit prices and nutrient densities stay integral. Hall-time
  durations are in hall milliseconds.
  """

  @minute 60_000
  @hour 60 * @minute

  @plant_based [:vegan, :vegetarian]

  @vegetarian_excludes [:meat, :fish, :gelatin, :animal_rennet, :animal_fat_stock]
  @vegan_excludes @vegetarian_excludes ++ [:dairy, :egg, :honey]

  @doc "The slice catalog. Pass `enable: [...]` profile ids to override enablement."
  def catalog(opts \\ []) do
    enabled = Keyword.get(opts, :enable, ~w(unrestricted vegetarian vegan carb_conscious))

    %{
      id: "slice",
      version: 2,
      rules: rules(),
      layout: layout(),
      npc_profiles: npc_profiles(),
      products: Map.new(products(), &{&1.id, &1}),
      recipes: Map.new(recipes(), &{&1.id, &1}),
      profiles: Map.new(profiles(), fn p -> {p.id, Map.put(p, :enabled, p.id in enabled)} end)
    }
  end

  def rules do
    %{
      quality_base: 100,
      substitution_penalty_cap: 9,
      # Proposed main:drink:dessert recognition weights (4:1:2).
      course_weights: %{main: 4, drink: 1, dessert: 2},
      # Proposed 30 available-service seconds to choose dessert.
      dessert_window_service_ms: 30_000,
      # Counter selection plus handover: two game minutes each.
      handover_ms: 4 * @minute,
      # Maximum service deadline offered after acceptance.
      service_window_ms: 45 * @minute,
      starter_grant: 500_000,
      storage_capacity: 300_000,
      visitor_fund: 200_000,
      max_allowance_grant: 2_500,
      # Default hall seed, passed to `Random.new/1` (non-negative, below 2^64).
      seed: 20_261_109,
      exposure_permille: %{quiet: 800, standard: 1_000, busy: 1_250, prime: 1_500},
      kitchen: %{prep_stations: 2, finish_stations: 1, queue_limit: 6},
      market: market(),
      demand: demand()
    }
  end

  defp market do
    # Proposed target stock per demand equivalent. Keep common staples available
    # across cuisines while perishables and specialty ingredients stay scarce.
    staple_targets = %{
      "chicken_thigh" => 800,
      "chickpeas_dried" => 800,
      "cilantro" => 100,
      "filtered_water" => 5_000,
      "milk_whole" => 3_000,
      "onion" => 800,
      "rice_long" => 1_200,
      "tofu_firm" => 800,
      "yogurt_plain" => 1_000
    }

    targets = Map.new(products(), fn %{id: id} -> {id, Map.get(staple_targets, id, 400)} end)

    %{
      clear_every_hall_ms: 4 * @minute,
      price_floor_permille: 500,
      price_ceiling_permille: 3_000,
      target_stock_per_equivalent: targets,
      replenish_cap: Map.new(targets, fn {id, qty} -> {id, qty * 4} end)
    }
  end

  defp demand do
    %{
      arrivals_per_equivalent: 90,
      equivalent_floor_millis: 3_000,
      operating_hours_ms: 22 * @hour,
      # Index is the hall hour; 03:00 to 05:00 is scheduled cleaning.
      hourly_weights: [
        2,
        1,
        1,
        0,
        0,
        1,
        2,
        4,
        6,
        6,
        8,
        12,
        14,
        12,
        8,
        6,
        6,
        8,
        12,
        14,
        10,
        8,
        5,
        3
      ],
      segments: [
        segment("value", 40, [400, 1_200], [10 * @minute, 25 * @minute], 200, 300, 600, 100, 100, 400, %{
          "chole_with_rice" => 4,
          "butter_chicken_with_naan" => 1,
          "paneer_tikka_with_naan" => 2,
          "vegetarian_mapo_tofu_with_rice" => 3,
          "kung_pao_chicken_with_rice" => 2,
          "dry_fried_green_beans_with_rice" => 3,
          "falafel_wrap" => 4,
          "chicken_shawarma_wrap" => 2,
          "mujaddara" => 4
        }),
        segment("time_sensitive", 25, [800, 2_000], [5 * @minute, 12 * @minute], 300, 150, 200, 100, 200, 600, %{
          "chole_with_rice" => 3,
          "butter_chicken_with_naan" => 2,
          "paneer_tikka_with_naan" => 2,
          "vegetarian_mapo_tofu_with_rice" => 3,
          "kung_pao_chicken_with_rice" => 3,
          "dry_fried_green_beans_with_rice" => 3,
          "falafel_wrap" => 4,
          "chicken_shawarma_wrap" => 3,
          "mujaddara" => 2
        }),
        segment("enthusiast", 20, [800, 2_500], [15 * @minute, 40 * @minute], 400, 400, 200, 300, 100, 200, %{
          "chole_with_rice" => 2,
          "butter_chicken_with_naan" => 3,
          "paneer_tikka_with_naan" => 4,
          "vegetarian_mapo_tofu_with_rice" => 4,
          "kung_pao_chicken_with_rice" => 4,
          "dry_fried_green_beans_with_rice" => 3,
          "falafel_wrap" => 3,
          "chicken_shawarma_wrap" => 4,
          "mujaddara" => 2
        }),
        segment("quality", 15, [1_500, 4_000], [12 * @minute, 30 * @minute], 500, 500, 100, 600, 100, 300, %{
          "chole_with_rice" => 2,
          "butter_chicken_with_naan" => 4,
          "paneer_tikka_with_naan" => 4,
          "vegetarian_mapo_tofu_with_rice" => 3,
          "kung_pao_chicken_with_rice" => 4,
          "dry_fried_green_beans_with_rice" => 2,
          "falafel_wrap" => 2,
          "chicken_shawarma_wrap" => 4,
          "mujaddara" => 3
        })
      ],
      # The keto weight applies only when that profile is enabled; disabled
      # profiles are dropped and the mix renormalised at draw time.
      profile_mix: %{
        "unrestricted" => 60,
        "vegetarian" => 20,
        "vegan" => 10,
        "carb_conscious" => 7,
        "keto_style" => 3
      },
      variety_weight: 50,
      variety_cap: 3
    }
  end

  defp segment(id, weight, budget, patience, drink, dessert, price_w, quality_w, wait_w, leave_w, mains) do
    %{
      id: id,
      weight: weight,
      budget: budget,
      patience_hall_ms: patience,
      drink_attach_permille: drink,
      dessert_appetite_permille: dessert,
      price_weight: price_w,
      quality_weight: quality_w,
      wait_weight: wait_w,
      leave_weight: leave_w,
      main_preference: mains
    }
  end

  # 150 physical slots; tier by position: 40 quiet, 60 standard, 35 busy, 15 prime.
  defp layout do
    for n <- 1..150 do
      tier =
        cond do
          n <= 40 -> :quiet
          n <= 100 -> :standard
          n <= 135 -> :busy
          true -> :prime
        end

      %{slot_id: "s" <> String.pad_leading(Integer.to_string(n), 3, "0"), tier: tier}
    end
  end

  defp npc_profiles do
    [
      %{id: "budget", price_permille: 850, policy: :prefer_substitute, restock_days: 3, preferred_tier: :quiet},
      %{id: "mainstream", price_permille: 1_000, policy: :prefer_primary, restock_days: 2, preferred_tier: :standard},
      %{id: "premium", price_permille: 1_250, policy: :primary_only, restock_days: 1, preferred_tier: :prime}
    ]
  end

  # carb_mg_per_kunit: milligrams of carbohydrate per 1000 base units.
  # origins: nil marks missing metadata (never compatible with a requirement).
  defp products do
    [
      product("chickpeas_dried", :g, [:plant], 600_000, 350, 90, 1_000),
      product("chickpeas_canned", :g, [:plant], 150_000, 130, 60, 1_000),
      product("rice_long", :g, [:plant], 800_000, 280, 60, 1_000),
      product("rice_broken", :g, [:plant], 790_000, 180, 60, 1_000),
      product("onion", :g, [:plant], 90_000, 250, 6, 1_000),
      product("onion_diced_frozen", :g, [:plant], 95_000, 200, 20, 1_000),
      product("cilantro", :g, [:plant], 37_000, 1_800, 2, 1_000),
      product("chicken_thigh", :g, [:meat], 0, 900, 2, 1_000),
      product("chicken_breast_frozen", :g, [:meat], 0, 750, 14, 1_000),
      product("milk_whole", :ml, [:dairy], 48_000, 110, 3, 1_000),
      product("milk_powder", :g, [:dairy], 520_000, 900, 60, 1_000),
      product("sugar", :g, [:plant], 1_000_000, 120, 120, 1_000),
      product("sugar_beet", :g, [:plant], 1_000_000, 100, 120, 1_000),
      product("filtered_water", :ml, [:mineral], 0, 5, 30, 1_000),
      product("chole_masala", :g, [:plant], 220_000, 1_600, 14, 1_000),
      product("chole_masala_basic", :g, [:plant], 220_000, 1_200, 30, 1_000),
      product("butter_masala_sauce", :g, [:plant, :dairy], 70_000, 600, 4, 1_000),
      product("butter_masala_sauce_shelf_stable", :g, [:plant, :dairy], 80_000, 500, 30, 1_000),
      product("naan", :each, [:plant], 23_000_000, 32_000, 3, 10_000),
      product("naan_packaged", :each, [:plant], 24_000_000, 25_000, 8, 10_000),
      product("paneer", :g, [:dairy], 40_000, 1_450, 5, 1_000),
      product("paneer_frozen", :g, [:dairy], 45_000, 1_200, 30, 1_000),
      product("tikka_masala", :g, [:plant], 180_000, 1_700, 14, 1_000),
      product("yogurt_plain", :g, [:dairy], 47_000, 250, 5, 1_000),
      product("yogurt_shelf_stable", :g, [:dairy], 49_000, 210, 20, 1_000),
      product("jamun_mix", :g, [:plant, :dairy], 610_000, 650, 30, 1_000),
      product("jamun_mix_basic", :g, [:plant, :dairy], 630_000, 500, 60, 1_000),
      product("cardamom", :g, [:plant], 680_000, 5_500, 120, 1_000),
      product("tofu_firm", :g, [:plant], 25_000, 680, 4, 1_000),
      product("tofu_firm_frozen", :g, [:plant], 27_000, 530, 30, 1_000),
      product("mapo_sauce_vegetarian", :g, [:plant], 120_000, 870, 4, 1_000),
      product("mapo_sauce_vegetarian_shelf_stable", :g, [:plant], 125_000, 650, 30, 1_000),
      product("kung_pao_sauce", :g, [:plant], 150_000, 800, 6, 1_000),
      product("peanuts_roasted", :g, [:plant], 160_000, 920, 30, 1_000),
      product("green_beans", :g, [:plant], 70_000, 480, 4, 1_000),
      product("green_beans_frozen", :g, [:plant], 72_000, 350, 30, 1_000),
      product("dry_fry_seasoning_vegetarian", :g, [:plant], 220_000, 950, 14, 1_000),
      product("bingfen_base", :g, [:plant], 150_000, 820, 60, 1_000),
      product("brown_sugar", :g, [:plant], 980_000, 160, 120, 1_000),
      product("jasmine_tea_leaf", :g, [:plant], 0, 2_800, 120, 1_000),
      product("pita", :each, [:plant], 21_000_000, 27_000, 3, 10_000),
      product("pita_packaged", :each, [:plant], 22_000_000, 22_000, 8, 10_000),
      product("tahini", :g, [:plant], 210_000, 1_100, 20, 1_000),
      product("tahini_basic", :g, [:plant], 220_000, 900, 30, 1_000),
      product("falafel_seasoning", :g, [:plant], 200_000, 1_100, 14, 1_000),
      product("shawarma_marinade", :g, [:plant], 100_000, 770, 6, 1_000),
      product("lentils_brown", :g, [:plant], 630_000, 380, 90, 1_000),
      product("lentils_green", :g, [:plant], 640_000, 360, 90, 1_000),
      product("akkawi_vegetarian", :g, [:dairy], 25_000, 1_500, 6, 1_000),
      product("akkawi_vegetarian_frozen", :g, [:dairy], 25_000, 1_250, 30, 1_000),
      product("kataifi_pastry", :g, [:plant], 680_000, 780, 6, 1_000),
      product("kataifi_pastry_frozen", :g, [:plant], 690_000, 650, 30, 1_000),
      product("lemon_juice", :ml, [:plant], 70_000, 550, 4, 1_000),
      product("lemon_juice_bottled", :ml, [:plant], 72_000, 430, 18, 1_000),
      product("mint", :g, [:plant], 80_000, 1_600, 2, 1_000)
    ]
  end

  defp product(id, unit, origins, carbs, price, shelf_days, storage) do
    %{
      id: id,
      version: 1,
      unit: unit,
      origins: origins,
      carb_mg_per_kunit: carbs,
      base_price_per_kunit: price,
      shelf_life_ms: shelf_days * 24 * 60 * @minute,
      storage_per_kunit: storage
    }
  end

  defp recipes do
    mughlai_punjabi = "mughlai_punjabi"
    sichuan = "sichuan"
    levantine = "levantine"

    [
      recipe(mughlai_punjabi, "chole_with_rice", :main, true, 0, @plant_based, 900, [
        line("chickpeas", "chickpeas_dried", 30, sub("chickpeas_canned", 5, 2)),
        line("rice", "rice_long", 28, sub("rice_broken", 1, 1)),
        line("masala", "chole_masala", 10, sub("chole_masala_basic", 1, 1)),
        line("onion", "onion", 15, sub("onion_diced_frozen", 1, 1)),
        line("herb", "cilantro", 3, nil)
      ]),
      recipe(mughlai_punjabi, "butter_chicken_with_naan", :main, false, 30_000, [], 1_200, [
        line("chicken", "chicken_thigh", 120, sub("chicken_breast_frozen", 1, 1)),
        line("naan", "naan", 1, sub("naan_packaged", 1, 1)),
        line("sauce", "butter_masala_sauce", 90, sub("butter_masala_sauce_shelf_stable", 1, 1))
      ]),
      recipe(mughlai_punjabi, "paneer_tikka_with_naan", :main, false, 25_000, [:vegetarian], 1_100, [
        line("paneer", "paneer", 90, sub("paneer_frozen", 1, 1)),
        line("naan", "naan", 1, sub("naan_packaged", 1, 1)),
        line("yogurt", "yogurt_plain", 30, sub("yogurt_shelf_stable", 1, 1)),
        line("masala", "tikka_masala", 10, nil)
      ]),
      recipe(mughlai_punjabi, "gulab_jamun", :dessert, false, 20_000, [:vegetarian], 500, [
        line("dough", "jamun_mix", 35, sub("jamun_mix_basic", 1, 1)),
        line("milk", "milk_whole", 30, sub("milk_powder", 3, 25)),
        line("sugar", "sugar", 20, sub("sugar_beet", 1, 1)),
        line("water", "filtered_water", 60, nil),
        line("spice", "cardamom", 1, nil)
      ]),
      recipe(mughlai_punjabi, "sweet_lassi", :drink, false, 15_000, [:vegetarian], 350, [
        line("yogurt", "yogurt_plain", 150, sub("yogurt_shelf_stable", 1, 1)),
        line("sugar", "sugar", 12, sub("sugar_beet", 1, 1)),
        line("water", "filtered_water", 70, nil),
        line("spice", "cardamom", 1, nil)
      ]),
      recipe(sichuan, "vegetarian_mapo_tofu_with_rice", :main, true, 0, @plant_based, 950, [
        line("tofu", "tofu_firm", 100, sub("tofu_firm_frozen", 1, 1)),
        line("rice", "rice_long", 37, sub("rice_broken", 1, 1)),
        line("sauce", "mapo_sauce_vegetarian", 40, sub("mapo_sauce_vegetarian_shelf_stable", 1, 1))
      ]),
      recipe(sichuan, "kung_pao_chicken_with_rice", :main, false, 30_000, [], 1_250, [
        line("chicken", "chicken_thigh", 110, sub("chicken_breast_frozen", 1, 1)),
        line("rice", "rice_long", 40, sub("rice_broken", 1, 1)),
        line("peanuts", "peanuts_roasted", 15, nil),
        line("sauce", "kung_pao_sauce", 40, nil)
      ]),
      recipe(sichuan, "dry_fried_green_beans_with_rice", :main, false, 23_000, @plant_based, 900, [
        line("beans", "green_beans", 125, sub("green_beans_frozen", 1, 1)),
        line("rice", "rice_long", 35, sub("rice_broken", 1, 1)),
        line("seasoning", "dry_fry_seasoning_vegetarian", 18, nil)
      ]),
      recipe(sichuan, "brown_sugar_bingfen", :dessert, false, 20_000, @plant_based, 500, [
        line("jelly", "bingfen_base", 12, nil),
        line("sugar", "brown_sugar", 18, nil),
        line("water", "filtered_water", 140, nil)
      ]),
      recipe(sichuan, "jasmine_tea", :drink, false, 15_000, @plant_based, 300, [
        line("tea", "jasmine_tea_leaf", 3, nil),
        line("water", "filtered_water", 220, nil)
      ]),
      recipe(levantine, "falafel_wrap", :main, true, 0, @plant_based, 900, [
        line("chickpeas", "chickpeas_dried", 25, nil),
        line("pita", "pita", 1, sub("pita_packaged", 1, 1)),
        line("tahini", "tahini", 15, sub("tahini_basic", 1, 1)),
        line("seasoning", "falafel_seasoning", 6, nil)
      ]),
      recipe(levantine, "chicken_shawarma_wrap", :main, false, 30_000, [], 1_200, [
        line("chicken", "chicken_thigh", 120, sub("chicken_breast_frozen", 1, 1)),
        line("pita", "pita", 1, sub("pita_packaged", 1, 1)),
        line("tahini", "tahini", 15, sub("tahini_basic", 1, 1)),
        line("marinade", "shawarma_marinade", 30, nil)
      ]),
      recipe(levantine, "mujaddara", :main, false, 23_000, @plant_based, 850, [
        line("lentils", "lentils_brown", 30, sub("lentils_green", 1, 1)),
        line("rice", "rice_long", 25, sub("rice_broken", 1, 1)),
        line("onion", "onion", 28, sub("onion_diced_frozen", 1, 1))
      ]),
      recipe(levantine, "knafeh", :dessert, false, 20_000, [:vegetarian], 550, [
        line("cheese", "akkawi_vegetarian", 60, sub("akkawi_vegetarian_frozen", 1, 1)),
        line("pastry", "kataifi_pastry", 30, sub("kataifi_pastry_frozen", 1, 1)),
        line("sugar", "sugar", 16, sub("sugar_beet", 1, 1)),
        line("water", "filtered_water", 40, nil)
      ]),
      recipe(levantine, "mint_lemonade", :drink, false, 15_000, @plant_based, 350, [
        line("lemon", "lemon_juice", 40, sub("lemon_juice_bottled", 1, 1)),
        line("mint", "mint", 4, nil),
        line("sugar", "sugar", 14, sub("sugar_beet", 1, 1)),
        line("water", "filtered_water", 170, nil)
      ])
    ]
  end

  defp recipe(cuisine, id, kind, starter, unlock_cost, claims, suggested_price, lines) do
    {prep, finish, holding} =
      case kind do
        :main -> {1 * @minute, 3 * @minute, 20 * @minute}
        :drink -> {1 * @minute, 1 * @minute, 15 * @minute}
        :dessert -> {1 * @minute, 2 * @minute, 20 * @minute}
      end

    %{
      id: id,
      version: 1,
      cuisine: cuisine,
      kind: kind,
      starter: starter,
      unlock_cost: unlock_cost,
      claims: claims,
      suggested_price: suggested_price,
      prep_ms: prep,
      finish_ms: finish,
      holding_ms: holding,
      lines: lines
    }
  end

  defp line(id, product, qty, substitute),
    do: %{line_id: id, product: product, qty: qty, substitute: substitute}

  # Proposed three-point quality penalty per substituted line.
  defp sub(product, num, den), do: %{product: product, num: num, den: den, penalty: 3}

  defp profiles do
    [
      %{id: "unrestricted", excludes: [], carb_ceiling_mg: nil, weight: 60, stricter_than: nil},
      %{
        id: "vegetarian",
        excludes: @vegetarian_excludes,
        carb_ceiling_mg: nil,
        weight: 20,
        stricter_than: nil
      },
      %{id: "vegan", excludes: @vegan_excludes, carb_ceiling_mg: nil, weight: 10, stricter_than: nil},
      %{
        id: "carb_conscious",
        excludes: [],
        carb_ceiling_mg: 45_000,
        weight: 7,
        stricter_than: nil
      },
      # Disabled in this slice: no authored main fits its ceiling yet, and the
      # design forbids enabling a profile without a viable main.
      %{
        id: "keto_style",
        excludes: [],
        carb_ceiling_mg: 20_000,
        weight: 3,
        stricter_than: "carb_conscious"
      }
    ]
  end
end
