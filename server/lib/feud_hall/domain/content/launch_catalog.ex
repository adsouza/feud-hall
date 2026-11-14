defmodule FeudHall.Domain.Content.LaunchCatalog do
  @moduledoc "Versioned launch recipes, ingredient grades, and balanced market and demand inputs."

  alias FeudHall.Domain.Content.{RoomLayout, SliceCatalog}

  @menus Path.expand("../../../../priv/content/launch_menus.json", __DIR__)
  @products Path.expand("../../../../priv/content/launch_products.json", __DIR__)
  @external_resource @menus
  @external_resource @products
  @menu_rows JSON.decode!(File.read!(@menus))
  @product_rows JSON.decode!(File.read!(@products))

  @minute 60_000
  @day 24 * 60 * @minute

  @origins %{
    "plant" => :plant,
    "mineral" => :mineral,
    "meat" => :meat,
    "fish" => :fish,
    "dairy" => :dairy,
    "egg" => :egg,
    "honey" => :honey
  }
  @grades %{"value" => 30, "frozen" => 30, "chilled" => 12}
  @methods %{
    "steam" => {1, 3, 20},
    "simmer" => {1, 4, 20},
    "griddle" => {1, 2, 17},
    "roast" => {2, 4, 20},
    "wok" => {1, 2, 15},
    "fry" => {1, 3, 15},
    "cold" => {1, 2, 18},
    "brew" => {1, 1, 15}
  }

  @shared_substitutes %{
    "rice_long" => {"rice_broken", 1, 1},
    "onion" => {"onion_diced_frozen", 1, 1},
    "chicken_thigh" => {"chicken_breast_frozen", 1, 1},
    "milk_whole" => {"milk_powder", 3, 25},
    "yogurt_plain" => {"yogurt_shelf_stable", 1, 1},
    "sugar" => {"sugar_beet", 1, 1},
    "tofu_firm" => {"tofu_firm_frozen", 1, 1},
    "lentils_brown" => {"lentils_green", 1, 1},
    "tahini" => {"tahini_basic", 1, 1}
  }

  def catalog do
    slice = SliceCatalog.catalog(enable: ~w(unrestricted vegetarian vegan carb_conscious keto_style))
    {products, substitutes} = products()
    products = Map.merge(slice.products, products)
    recipes = Map.merge(slice_techniques(slice.recipes), recipes(products, substitutes))

    %{
      slice
      | id: "launch",
        version: 3,
        layout: RoomLayout.assign(slice.layout),
        npc_profiles: Enum.map(slice.npc_profiles, &launch_profile/1),
        products: products,
        recipes: recipes,
        rules:
          Map.merge(slice.rules, %{
            rooms: %{version: 1, count: 10, per_room: 15, scarcity_cap_permille: 1_500, class_gap: 100},
            market: market(slice.rules.market, products, recipes),
            demand: demand(slice.rules.demand, recipes),
            progression: %{
              stall_limit: 3,
              equipment_cost: 12_000,
              setup_ms: 24 * @minute,
              starter_techniques:
                Map.new(Enum.filter(Map.values(recipes), & &1.starter), fn recipe ->
                  {recipe.cuisine, Map.get(recipe, :technique)}
                end),
              distress_ms: @day * 24,
              dormancy_ms: @day * 24 * 7,
              award_days: 7,
              award_visits: 50,
              award_score: 8_500,
              award_bonus: 150,
              reliable_meals: 100,
              reliable_rate: 800,
              waste_min_sales: 5_000,
              waste_share: 50
            }
          })
    }
  end

  # Rooms make the prime spots scarce: the premium computer-run profile starts in standard spots.
  defp launch_profile(%{id: "premium"} = profile), do: %{profile | preferred_tier: :standard}
  defp launch_profile(profile), do: profile

  defp slice_techniques(recipes) do
    methods = %{
      "chole_with_rice" => "simmer",
      "butter_chicken_with_naan" => "simmer",
      "paneer_tikka_with_naan" => "roast",
      "gulab_jamun" => "fry",
      "sweet_lassi" => "cold",
      "vegetarian_mapo_tofu_with_rice" => "wok",
      "kung_pao_chicken_with_rice" => "wok",
      "dry_fried_green_beans_with_rice" => "wok",
      "brown_sugar_bingfen" => "cold",
      "jasmine_tea" => "brew",
      "falafel_wrap" => "fry",
      "chicken_shawarma_wrap" => "roast",
      "mujaddara" => "simmer",
      "knafeh" => "roast",
      "mint_lemonade" => "cold"
    }

    Map.new(recipes, fn {id, recipe} -> {id, Map.put(recipe, :technique, Map.fetch!(methods, id))} end)
  end

  defp products do
    Enum.reduce(@product_rows, {%{}, @shared_substitutes}, fn
      [id, _en, _ja, origins, carbs, price, days, grade], {products, substitutes} ->
        product = %{
          id: id,
          version: 1,
          unit: :g,
          origins: Enum.map(origins, &Map.fetch!(@origins, &1)),
          carb_mg_per_kunit: carbs * 1_000,
          base_price_per_kunit: price,
          shelf_life_ms: days * @day,
          storage_per_kunit: 1_000
        }

        if grade do
          alternative = id <> "_" <> grade

          replacement = %{
            product
            | id: alternative,
              base_price_per_kunit: div(price * 4, 5),
              shelf_life_ms: max(days, Map.fetch!(@grades, grade)) * @day
          }

          {products |> Map.put(id, product) |> Map.put(alternative, replacement),
           Map.put(substitutes, id, {alternative, 1, 1})}
        else
          {Map.put(products, id, product), substitutes}
        end
    end)
  end

  defp recipes(products, substitutes) do
    for [cuisine, _, _, rows] <- @menu_rows,
        {[id, _, _, method, price, ingredients], index} <- Enum.with_index(rows),
        into: %{} do
      kind = Enum.at([:main, :main, :main, :dessert, :drink], index)
      {prep, finish, holding} = Map.fetch!(@methods, method)

      lines =
        Enum.map(ingredients, fn [product, qty] ->
          alternative =
            case substitutes[product] do
              {id, numerator, denominator} -> %{product: id, num: numerator, den: denominator, penalty: 3}
              nil -> nil
            end

          %{line_id: product, product: product, qty: qty, substitute: alternative}
        end)

      origins = Enum.flat_map(ingredients, fn [product, _qty] -> products[product].origins end)

      claims =
        cond do
          Enum.any?(origins, &(&1 in [:fish, :meat, :gelatin, :animal_rennet, :animal_fat_stock])) -> []
          Enum.any?(origins, &(&1 in [:dairy, :egg, :honey])) -> [:vegetarian]
          true -> [:vegan, :vegetarian]
        end

      unlock = %{main: 26_000, dessert: 20_000, drink: 15_000}

      {id,
       %{
         id: id,
         version: 1,
         cuisine: cuisine,
         kind: kind,
         starter: index == 0,
         unlock_cost: if(index == 0, do: 0, else: Map.fetch!(unlock, kind)),
         claims: claims,
         suggested_price: price,
         prep_ms: prep * @minute,
         finish_ms: finish * @minute,
         holding_ms: holding * @minute,
         lines: lines,
         technique: method
       }}
    end
  end

  defp market(base, products, recipes) do
    starter_targets =
      recipes
      |> Map.values()
      |> Enum.filter(& &1.starter)
      |> Enum.flat_map(& &1.lines)
      |> Enum.reduce(%{}, fn line, totals -> Map.update(totals, line.product, line.qty * 6, &max(&1, line.qty * 6)) end)

    targets =
      Map.new(products, fn {id, _} ->
        {id, max(Map.get(base.target_stock_per_equivalent, id, 400), Map.get(starter_targets, id, 0))}
      end)

    %{base | target_stock_per_equivalent: targets, replenish_cap: Map.new(targets, fn {id, qty} -> {id, qty * 4} end)}
  end

  defp demand(base, recipes) do
    mains = Enum.filter(recipes, fn {_, recipe} -> recipe.kind == :main end)

    segments =
      Enum.map(base.segments, fn segment ->
        weights =
          Map.new(mains, fn {id, recipe} ->
            preference =
              case segment.id do
                "value" -> if(recipe.suggested_price <= 1_000, do: 4, else: 2)
                "time_sensitive" -> if(recipe.finish_ms <= 2 * @minute, do: 4, else: 2)
                "enthusiast" -> if(recipe.starter, do: 2, else: 4)
                "quality" -> if(recipe.suggested_price >= 1_200, do: 4, else: 2)
              end

            {id, Map.get(segment.main_preference, id, preference)}
          end)

        %{segment | main_preference: weights}
      end)

    %{base | segments: segments}
  end
end
