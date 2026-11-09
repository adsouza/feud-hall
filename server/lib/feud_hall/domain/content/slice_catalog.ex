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

  @vegetarian_excludes [:meat, :fish, :gelatin, :animal_rennet, :animal_fat_stock]
  @vegan_excludes @vegetarian_excludes ++ [:dairy, :egg, :honey]

  @doc "The slice catalog. Pass `enable: [...]` profile ids to override enablement."
  def catalog(opts \\ []) do
    enabled = Keyword.get(opts, :enable, ~w(unrestricted vegetarian vegan carb_conscious))

    %{
      id: "slice",
      version: 1,
      rules: rules(),
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
      max_allowance_grant: 2_500
    }
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
