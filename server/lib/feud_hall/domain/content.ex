defmodule FeudHall.Domain.Content do
  @moduledoc """
  Validation and identity of versioned gameplay content.

  Content is plain data. A hall pins the content hash at genesis so replay
  never reinterprets old facts against today's catalog. Validation enforces
  the design's content contracts before content can be enabled:

  * every cuisine has exactly three savory mains (one starter), one dessert,
    and one drink;
  * quantities, conversions, durations, and prices are positive and bounded;
  * substitutes are approved per line, distinct, non-recursive, and preserve
    the recipe's published dietary claims;
  * more than half of the distinct primary products have a substitute;
  * every enabled dietary profile has at least one viable main, and a profile
    declared stricter than another has a strictly lower carbohydrate ceiling.
  """

  alias FeudHall.Domain.Dietary

  @units [:g, :ml, :each]
  @origins [:plant, :mineral, :meat, :fish, :dairy, :egg, :honey, :gelatin, :animal_rennet, :animal_fat_stock]
  @kinds [:main, :drink, :dessert]
  @claims [:vegetarian, :vegan]

  @doc "Deterministic SHA-256 identity of a catalog."
  def hash(catalog) do
    :crypto.hash(:sha256, :erlang.term_to_binary(catalog, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns `:ok` or `{:error, [problem]}` listing every violation found."
  def validate(catalog) do
    structural =
      Enum.flat_map(Map.values(catalog.products), &product_problems/1) ++
        Enum.flat_map(Map.values(catalog.recipes), &recipe_problems(catalog, &1)) ++
        cuisine_problems(catalog) ++
        coverage_problems(catalog)

    # Profile viability evaluates recipes, so it only runs on structurally
    # valid content; structural problems are reported first.
    problems = if structural == [], do: profile_problems(catalog), else: structural

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp product_problems(p) do
    checks = [
      {is_integer(p.version) and p.version > 0, :bad_version},
      {p.unit in @units, :bad_unit},
      {is_nil(p.origins) or (is_list(p.origins) and p.origins != [] and Enum.all?(p.origins, &(&1 in @origins))),
       :bad_origins},
      {is_nil(p.carb_mg_per_kunit) or (is_integer(p.carb_mg_per_kunit) and p.carb_mg_per_kunit >= 0),
       :bad_carbohydrate},
      {is_integer(p.base_price_per_kunit) and p.base_price_per_kunit > 0, :bad_price},
      {is_integer(p.shelf_life_ms) and p.shelf_life_ms > 0, :bad_shelf_life},
      {is_integer(p.storage_per_kunit) and p.storage_per_kunit >= 0, :bad_storage}
    ]

    for {false, problem} <- checks, do: {:product, p.id, problem}
  end

  defp recipe_problems(catalog, r) do
    line_ids = Enum.map(r.lines, & &1.line_id)

    base =
      [
        {r.kind in @kinds, :bad_kind},
        {r.lines != [], :no_lines},
        {length(Enum.uniq(line_ids)) == length(line_ids), :duplicate_line},
        {Enum.all?(r.claims, &(&1 in @claims)), :bad_claim},
        {Enum.all?([r.prep_ms, r.finish_ms, r.holding_ms], &(is_integer(&1) and &1 > 0)), :bad_duration},
        {is_integer(r.unlock_cost) and r.unlock_cost >= 0, :bad_unlock_cost},
        {not r.starter or r.kind == :main, :non_main_starter}
      ]
      |> Enum.flat_map(fn {ok, problem} -> if ok, do: [], else: [{:recipe, r.id, problem}] end)

    base ++ Enum.flat_map(r.lines, &line_problems(catalog, r, &1))
  end

  defp line_problems(catalog, r, line) do
    primary = catalog.products[line.product]
    sub = line.substitute

    [
      {primary != nil, :unknown_product},
      {is_integer(line.qty) and line.qty > 0, :bad_quantity},
      {sub == nil or catalog.products[sub.product] != nil, :unknown_substitute},
      {sub == nil or sub.product != line.product, :self_substitute},
      {sub == nil or (is_integer(sub.num) and is_integer(sub.den) and sub.num > 0 and sub.den > 0), :bad_conversion},
      {sub == nil or (is_integer(sub.penalty) and sub.penalty >= 0 and sub.penalty <= 9), :bad_penalty},
      {primary == nil or claims_hold?(catalog, r.claims, line.product), :primary_breaks_claim},
      {sub == nil or catalog.products[sub.product] == nil or claims_hold?(catalog, r.claims, sub.product),
       :substitute_breaks_claim}
    ]
    |> Enum.flat_map(fn {ok, problem} ->
      if ok, do: [], else: [{:recipe_line, r.id, line.line_id, problem}]
    end)
  end

  defp claims_hold?(catalog, claims, product_id) do
    origins = catalog.products[product_id].origins

    Enum.all?(claims, fn claim ->
      excludes = claim_excludes(catalog, claim)
      is_list(origins) and not Enum.any?(origins, &(&1 in excludes))
    end)
  end

  defp claim_excludes(catalog, claim) do
    case catalog.profiles[Atom.to_string(claim)] do
      nil -> @origins -- [:plant, :mineral]
      profile -> profile.excludes
    end
  end

  defp cuisine_problems(catalog) do
    catalog.recipes
    |> Map.values()
    |> Enum.group_by(& &1.cuisine)
    |> Enum.flat_map(fn {cuisine, recipes} ->
      count = fn kind -> Enum.count(recipes, &(&1.kind == kind)) end
      starters = Enum.count(recipes, & &1.starter)

      [
        {count.(:main) == 3, :needs_three_mains},
        {count.(:dessert) == 1, :needs_one_dessert},
        {count.(:drink) == 1, :needs_one_drink},
        {starters == 1, :needs_one_starter}
      ]
      |> Enum.flat_map(fn {ok, problem} -> if ok, do: [], else: [{:cuisine, cuisine, problem}] end)
    end)
  end

  defp coverage_problems(catalog) do
    lines = catalog.recipes |> Map.values() |> Enum.flat_map(& &1.lines)
    primaries = lines |> Enum.map(& &1.product) |> Enum.uniq()
    covered = lines |> Enum.filter(& &1.substitute) |> Enum.map(& &1.product) |> Enum.uniq()

    if length(covered) * 2 > length(primaries),
      do: [],
      else: [{:catalog, :insufficient_substitute_coverage}]
  end

  defp profile_problems(catalog) do
    profiles = Map.values(catalog.profiles)

    viability =
      for p <- profiles, p.enabled, not viable_main?(catalog, p), do: {:profile, p.id, :no_viable_main}

    strictness =
      for p <- profiles,
          p.stricter_than != nil,
          other = catalog.profiles[p.stricter_than],
          other == nil or p.carb_ceiling_mg == nil or other.carb_ceiling_mg == nil or
            p.carb_ceiling_mg >= other.carb_ceiling_mg,
          do: {:profile, p.id, :not_stricter}

    weights = for p <- profiles, not (is_integer(p.weight) and p.weight > 0), do: {:profile, p.id, :bad_weight}

    viability ++ strictness ++ weights
  end

  # A main is viable for a profile if some policy variant (all-primary or any
  # approved substitution choice) is compatible from a fresh visit.
  defp viable_main?(catalog, profile) do
    requirement = %{profile_id: profile.id, excludes: profile.excludes, carb_ceiling_mg: profile.carb_ceiling_mg}

    catalog.recipes
    |> Map.values()
    |> Enum.filter(&(&1.kind == :main))
    |> Enum.any?(fn recipe ->
      recipe
      |> variants()
      |> Enum.any?(&match?({:ok, _}, Dietary.check(catalog, requirement, &1, 0)))
    end)
  end

  defp variants(recipe) do
    Enum.reduce(Enum.reverse(recipe.lines), [[]], fn line, tails ->
      primary = %{product: line.product, qty: line.qty}

      options =
        case line.substitute do
          nil -> [primary]
          s -> [primary, %{product: s.product, qty: div(line.qty * s.num + s.den - 1, s.den)}]
        end

      for o <- options, t <- tails, do: [o | t]
    end)
  end
end
