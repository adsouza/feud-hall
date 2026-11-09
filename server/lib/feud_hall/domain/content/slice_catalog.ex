defmodule FeudHall.Domain.Content.SliceCatalog do
  @moduledoc """
  Internal vertical-slice content: one complete cuisine (three savory recipes,
  one dessert, one drink) authored as versioned data.

  The game design permits an internal slice with one cuisine and a few stalls;
  it does not change the launch requirement of twenty cuisines and 100 recipes.
  Every number here is a proposed tuning value. Quantities use base units
  (`:g`, `:ml`, `:each`); `*_per_kunit` values are per 1000 base units so
  fractional unit prices and nutrient densities stay integral. Hall-time
  durations are in hall milliseconds.
  """

  @minute 60_000
  @hour 60 * @minute

  @vegetarian_excludes [:meat, :fish, :gelatin, :animal_rennet, :animal_fat_stock]
  @vegan_excludes @vegetarian_excludes ++ [:dairy, :egg, :honey]

  @doc "The slice catalog. Pass `enable: [...]` profile ids to override enablement."
  def catalog(opts \\ []) do
    enabled = Keyword.get(opts, :enable, ~w(unrestricted vegetarian vegan carb_conscious))

    %{
      id: "slice",
      version: 1,
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
    ids = Enum.map(products(), & &1.id)

    # Proposed target stock per demand equivalent; perishables stay small.
    targets =
      Map.new(ids, fn id ->
        {id, Map.get(%{"cilantro" => 100, "filtered_water" => 5_000, "milk_whole" => 3_000}, id, 400)}
      end)

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
          "bean_tacos" => 3,
          "chicken_tacos" => 2,
          "vegetable_quesadilla" => 2
        }),
        segment("time_sensitive", 25, [800, 2_000], [5 * @minute, 12 * @minute], 300, 150, 200, 100, 200, 600, %{
          "bean_tacos" => 2,
          "chicken_tacos" => 3,
          "vegetable_quesadilla" => 2
        }),
        segment("enthusiast", 20, [800, 2_500], [15 * @minute, 40 * @minute], 400, 400, 200, 300, 100, 200, %{
          "bean_tacos" => 2,
          "chicken_tacos" => 2,
          "vegetable_quesadilla" => 3
        }),
        segment("quality", 15, [1_500, 4_000], [12 * @minute, 30 * @minute], 500, 500, 100, 600, 100, 300, %{
          "bean_tacos" => 1,
          "chicken_tacos" => 3,
          "vegetable_quesadilla" => 3
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
      patience_service_ms: patience,
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
      product("corn_tortilla", :each, [:plant], 12_000_000, 15_000, 3, 10_000),
      product("corn_tortilla_packaged", :each, [:plant], 12_500_000, 10_000, 8, 10_000),
      product("flour_tortilla", :each, [:plant], 25_000_000, 22_000, 3, 10_000),
      product("flour_tortilla_packaged", :each, [:plant], 26_000_000, 16_000, 8, 10_000),
      product("black_beans_dried", :g, [:plant], 600_000, 300, 30, 1_000),
      product("black_beans_canned", :g, [:plant], 230_000, 250, 20, 1_000),
      product("salsa_roja", :g, [:plant], 40_000, 900, 2, 1_000),
      product("salsa_verde", :g, [:plant], 60_000, 950, 2, 1_000),
      product("onion", :g, [:plant], 90_000, 250, 6, 1_000),
      product("onion_diced_frozen", :g, [:plant], 95_000, 200, 20, 1_000),
      product("cilantro", :g, [:plant], 37_000, 1_800, 2, 1_000),
      product("chicken_thigh", :g, [:meat], 0, 900, 2, 1_000),
      product("chicken_breast_frozen", :g, [:meat], 0, 750, 14, 1_000),
      product("queso_oaxaca", :g, [:dairy], 20_000, 1_400, 5, 1_000),
      product("monterey_jack", :g, [:dairy], 5_000, 1_100, 10, 1_000),
      product("peppers", :g, [:plant], 60_000, 500, 4, 1_000),
      product("peppers_frozen", :g, [:plant], 62_000, 380, 20, 1_000),
      product("rice_long", :g, [:plant], 800_000, 280, 60, 1_000),
      product("rice_broken", :g, [:plant], 790_000, 180, 60, 1_000),
      product("milk_whole", :ml, [:dairy], 48_000, 110, 3, 1_000),
      product("milk_powder", :g, [:dairy], 520_000, 900, 60, 1_000),
      product("sugar", :g, [:plant], 1_000_000, 120, 120, 1_000),
      product("sugar_beet", :g, [:plant], 1_000_000, 100, 120, 1_000),
      product("cinnamon", :g, [:plant], 800_000, 4_000, 120, 1_000),
      product("filtered_water", :ml, [:mineral], 0, 5, 30, 1_000)
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
    [
      recipe("bean_tacos", :main, true, 0, [:vegan, :vegetarian], 900, [
        line("tortilla", "corn_tortilla", 2, sub("corn_tortilla_packaged", 1, 1)),
        line("beans", "black_beans_dried", 60, sub("black_beans_canned", 5, 2)),
        line("salsa", "salsa_roja", 40, nil),
        line("onion", "onion", 20, sub("onion_diced_frozen", 1, 1)),
        line("herb", "cilantro", 5, nil)
      ]),
      recipe("chicken_tacos", :main, false, 30_000, [], 1_200, [
        line("tortilla", "corn_tortilla", 2, sub("corn_tortilla_packaged", 1, 1)),
        line("chicken", "chicken_thigh", 120, sub("chicken_breast_frozen", 1, 1)),
        line("salsa", "salsa_verde", 40, nil),
        line("onion", "onion", 20, sub("onion_diced_frozen", 1, 1))
      ]),
      recipe("vegetable_quesadilla", :main, false, 25_000, [:vegetarian], 1_000, [
        line("tortilla", "flour_tortilla", 1, sub("flour_tortilla_packaged", 1, 1)),
        line("cheese", "queso_oaxaca", 80, sub("monterey_jack", 1, 1)),
        line("peppers", "peppers", 60, sub("peppers_frozen", 1, 1)),
        line("salsa", "salsa_roja", 30, nil)
      ]),
      recipe("arroz_con_leche", :dessert, false, 20_000, [:vegetarian], 500, [
        line("rice", "rice_long", 40, sub("rice_broken", 1, 1)),
        line("milk", "milk_whole", 200, sub("milk_powder", 3, 25)),
        line("sugar", "sugar", 25, sub("sugar_beet", 1, 1)),
        line("spice", "cinnamon", 1, nil)
      ]),
      recipe("horchata", :drink, false, 15_000, [:vegan, :vegetarian], 350, [
        line("rice", "rice_long", 30, sub("rice_broken", 1, 1)),
        line("sugar", "sugar", 20, sub("sugar_beet", 1, 1)),
        line("spice", "cinnamon", 1, nil),
        line("water", "filtered_water", 250, nil)
      ])
    ]
  end

  defp recipe(id, kind, starter, unlock_cost, claims, suggested_price, lines) do
    {prep, finish, holding} =
      case kind do
        :main -> {1 * @minute, 3 * @minute, 20 * @minute}
        :drink -> {1 * @minute, 1 * @minute, 15 * @minute}
        :dessert -> {1 * @minute, 2 * @minute, 20 * @minute}
      end

    %{
      id: id,
      version: 1,
      cuisine: "mexican",
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
