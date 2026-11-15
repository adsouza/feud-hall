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

  alias FeudHall.Domain.{Dietary, Money, Random}
  alias FeudHall.Domain.Content.Tuning

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
    problems =
      if(structural == [], do: profile_problems(catalog), else: structural) ++ simulation_problems(catalog)

    if problems == [], do: :ok, else: {:error, problems}
  end

  @tiers [:quiet, :standard, :busy, :prime]
  @policies [:prefer_substitute, :prefer_primary, :primary_only]
  @max_slots 150
  @max_seed 18_446_744_073_709_551_615
  @demand_keys ~w(arrivals_per_equivalent equivalent_floor_millis operating_hours_ms hourly_weights
                  segments profile_mix variety_weight variety_cap)a

  # Simulation sections are checked defensively: a missing key or wrong type is
  # reported as a problem, never raised.
  defp simulation_problems(catalog) do
    rules = get(catalog, :rules)

    problems =
      seed_problems(get(rules, :seed)) ++
        kitchen_problems(get(rules, :kitchen)) ++
        exposure_problems(get(rules, :exposure_permille)) ++
        market_problems(catalog, get(rules, :market)) ++
        demand_problems(catalog, get(rules, :demand)) ++
        layout_problems(get(catalog, :layout), get(rules, :rooms)) ++
        rooms_rule_problems(get(rules, :rooms)) ++
        npc_problems(get(catalog, :npc_profiles)) ++
        npc_rules_problems(catalog, get(rules, :npc)) ++
        progression_problems(catalog, get(rules, :progression))

    if problems == [], do: choice_weight_problems(rules), else: problems
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(_, _), do: nil

  defp pos_int?(v), do: is_integer(v) and v > 0
  defp nonneg_int?(v), do: is_integer(v) and v >= 0

  @techniques ~w(steam simmer griddle roast wok fry cold brew)

  defp progression_problems(_catalog, nil), do: []

  defp progression_problems(catalog, rules) do
    positive =
      ~w(setup_ms distress_ms dormancy_ms equipment_cost award_days award_visits reliable_meals waste_min_sales)a

    techniques = get(rules, :starter_techniques)
    starters = for {_, %{starter: true} = recipe} <- catalog.recipes, do: recipe.cuisine

    valid = [
      {Enum.all?(positive, &pos_int?(get(rules, &1))), :invalid_duration_or_limit},
      {get(rules, :stall_limit) in 1..3, :invalid_stall_limit},
      {get(rules, :award_score) in 1..10_000 and get(rules, :award_bonus) in 0..150, :invalid_award_tuning},
      {get(rules, :reliable_rate) in 1..1_000 and get(rules, :waste_share) in 0..1_000, :invalid_milestone_tuning},
      {is_map(techniques) and Enum.all?(starters, &(Map.get(techniques, &1) in @techniques)),
       :invalid_starter_equipment}
    ]

    for {false, problem} <- valid, do: {:progression, problem}
  end

  defp seed_problems(seed),
    do: if(is_integer(seed) and seed in 0..@max_seed//1, do: [], else: [{:seed, :bad_seed}])

  defp kitchen_problems(k) do
    if Enum.all?([:prep_stations, :finish_stations, :queue_limit], &pos_int?(get(k, &1))),
      do: [],
      else: [{:kitchen, :bad_capacity}]
  end

  defp exposure_problems(e) do
    ok =
      is_map(e) and Enum.sort(Map.keys(e)) == Enum.sort(@tiers) and Enum.all?(Map.values(e), &pos_int?/1)

    if ok, do: [], else: [{:exposure, :bad_exposure}]
  end

  defp market_problems(catalog, m) do
    targets = get(m, :target_stock_per_equivalent)
    caps = get(m, :replenish_cap)

    if is_map(targets) and is_map(caps) do
      floor = get(m, :price_floor_permille)
      ceiling = get(m, :price_ceiling_permille)

      bounds_ok =
        pos_int?(get(m, :clear_every_hall_ms)) and pos_int?(floor) and is_integer(ceiling) and floor <= ceiling

      per_product =
        for id <- catalog.products |> Map.keys() |> Enum.sort(),
            problem <- market_product_problems(targets, caps, id),
            do: {:market, id, problem}

      if(bounds_ok, do: [], else: [{:market, :bad_price_bounds}]) ++ per_product
    else
      [{:market, :malformed}]
    end
  end

  defp market_product_problems(targets, caps, id) do
    target = Map.get(targets, id)
    cap = Map.get(caps, id)

    cond do
      not pos_int?(target) -> [:missing_target]
      not is_integer(cap) or cap < target * 3 -> [:bad_cap]
      true -> []
    end
  end

  defp demand_problems(catalog, d) do
    segments = get(d, :segments)

    well_formed =
      is_map(d) and Enum.all?(@demand_keys, &Map.has_key?(d, &1)) and
        nonneg_int?(d[:arrivals_per_equivalent]) and
        Enum.all?([:equivalent_floor_millis, :operating_hours_ms], &pos_int?(d[&1])) and
        is_list(segments) and segments != [] and Enum.all?(segments, &(is_map(&1) and Map.has_key?(&1, :id)))

    if well_formed do
      hourly_problems(d.hourly_weights) ++
        variety_problems(d) ++
        profile_mix_problems(catalog, d.profile_mix) ++
        segment_total_problems(segments) ++
        Enum.flat_map(segments, &segment_problems(catalog, &1))
    else
      [{:demand, :malformed}]
    end
  end

  defp hourly_problems(w) do
    ok =
      is_list(w) and length(w) == 24 and Enum.all?(w, &nonneg_int?/1) and
        Enum.at(w, 3) == 0 and Enum.at(w, 4) == 0 and Enum.sum(w) > 0

    if ok, do: [], else: [{:demand, :bad_hourly_weights}]
  end

  defp variety_problems(d),
    do: if(nonneg_int?(d.variety_weight) and nonneg_int?(d.variety_cap), do: [], else: [{:demand, :bad_variety}])

  defp profile_mix_problems(catalog, mix) do
    # Arrivals draw only enabled profiles, so their weights must be positive in total.
    ok =
      is_map(mix) and mix != %{} and Enum.all?(Map.keys(mix), &Map.has_key?(catalog.profiles, &1)) and
        weights_ok?(Map.values(mix)) and
        weights_ok?(for({id, w} <- mix, catalog.profiles[id][:enabled] == true, do: w))

    if ok, do: [], else: [{:demand, :bad_profile_mix}]
  end

  defp weights_ok?(values),
    do: Enum.all?(values, &nonneg_int?/1) and Enum.sum(values) in 1..Random.max_bound()

  defp segment_total_problems(segments) do
    if weights_ok?(Enum.map(segments, &get(&1, :weight))), do: [], else: [{:demand, :bad_segment_total}]
  end

  defp segment_problems(catalog, s) do
    id = s.id

    patience = Map.get(s, :patience_hall_ms, get(s, :patience_service_ms))
    ranges_ok = range?(get(s, :budget)) and range?(patience)

    weights_ok =
      pos_int?(get(s, :weight)) and
        Enum.all?([:price_weight, :quality_weight, :wait_weight, :leave_weight], &nonneg_int?(get(s, &1))) and
        Enum.all?([:drink_attach_permille, :dessert_appetite_permille], fn k ->
          v = get(s, k)
          is_integer(v) and v in 0..1000
        end)

    pref = get(s, :main_preference)

    pref_ok =
      is_map(pref) and pref != %{} and Enum.all?(Map.keys(pref), &Map.has_key?(catalog.recipes, &1)) and
        weights_ok?(Map.values(pref))

    for {false, problem} <- [{ranges_ok, :bad_range}, {weights_ok, :bad_weights}, {pref_ok, :bad_main_preference}],
        do: {:demand, id, problem}
  end

  # Choice can put one weighted entry per slot, plus the option to leave.
  # Bound that generated total as well as the authored segment/profile draws.
  defp choice_weight_problems(rules) do
    quality = get(rules, :quality_base)

    if nonneg_int?(quality) do
      max_exposure = rules.exposure_permille |> Map.values() |> Enum.max()
      variety = rules.demand.variety_weight * min(rules.demand.variety_cap, 2)

      for segment <- rules.demand.segments,
          preference = segment.main_preference |> Map.values() |> Enum.max(),
          score = (segment.price_weight + segment.wait_weight) * 1000 + segment.quality_weight * quality + preference,
          total = @max_slots * div((score + variety) * max_exposure, 1000) + segment.leave_weight,
          total > Random.max_bound(),
          do: {:demand, segment.id, :choice_weights_too_large}
    else
      [{:rules, :bad_quality_base}]
    end
  end

  defp range?([lo, hi]),
    do: is_integer(lo) and is_integer(hi) and lo > 0 and lo <= hi and hi - lo + 1 <= Random.max_bound()

  defp range?(_), do: false

  @rooms_keys ~w(version count per_room scarcity_cap_permille class_gap)a

  defp rooms_rule_problems(nil), do: []

  defp rooms_rule_problems(rooms),
    do: for(key <- @rooms_keys, not rooms_value?(key, get(rooms, key)), do: {:rules, :rooms, key})

  # The cap never lowers a rent below its base; a zero gap lets neighbouring classes meet.
  defp rooms_value?(:scarcity_cap_permille, v), do: is_integer(v) and v >= 1000
  defp rooms_value?(:class_gap, v), do: nonneg_int?(v)
  defp rooms_value?(_key, v), do: pos_int?(v)

  defp layout_problems(layout, rooms) do
    if is_list(layout) and Enum.all?(layout, &(is_map(&1) and is_binary(get(&1, :slot_id)) and Map.has_key?(&1, :tier))) do
      too_many = if length(layout) > @max_slots, do: [{:layout, :too_many_slots}], else: []

      duplicates =
        layout
        |> Enum.map(& &1.slot_id)
        |> Enum.frequencies()
        |> Enum.filter(fn {_, n} -> n > 1 end)
        |> Enum.map(fn {id, _} -> {:layout, id, :duplicate} end)
        |> Enum.sort()

      too_many ++
        duplicates ++
        for(slot <- layout, slot.tier not in @tiers, do: {:layout, slot.slot_id, :bad_tier}) ++
        room_problems(layout, rooms)
    else
      [{:layout, :malformed}]
    end
  end

  # Room data is checked only when the catalog carries the rooms rule (the slice catalog does not).
  defp room_problems(_layout, nil), do: []

  defp room_problems(layout, rooms) do
    count = get(rooms, :count)
    per_room = get(rooms, :per_room)

    if pos_int?(count) and pos_int?(per_room) do
      spots =
        for slot <- layout do
          room = Map.get(slot, :room)
          position = Map.get(slot, :position)

          problem =
            cond do
              not (Map.has_key?(slot, :room) and Map.has_key?(slot, :position)) ->
                {:layout, :slot_without_room, slot.slot_id}

              not (is_integer(room) and room in 1..count//1) ->
                {:layout, :room_out_of_range, slot.slot_id}

              not (is_integer(position) and position in 0..(per_room - 1)//1) ->
                {:layout, :position_out_of_range, slot.slot_id}

              true ->
                nil
            end

          {slot, problem}
        end

      duplicates =
        for({%{room: room, position: position}, nil} <- spots, do: {room, position})
        |> Enum.frequencies()
        |> Enum.filter(fn {_, n} -> n > 1 end)
        |> Enum.map(fn {pair, _} -> {:layout, :duplicate_position, pair} end)
        |> Enum.sort()

      for({_, problem} <- spots, problem, do: problem) ++ duplicates
    else
      []
    end
  end

  defp npc_problems(profiles) when is_list(profiles) do
    invalid = Enum.flat_map(profiles, &npc_profile_problems/1)

    duplicates =
      profiles
      |> Enum.frequencies_by(&get(&1, :id))
      |> Enum.sort()
      |> Enum.flat_map(fn {id, n} -> if n > 1, do: [{:npc, id, :duplicate}], else: [] end)

    invalid ++ duplicates
  end

  defp npc_problems(_), do: [{:npc, nil, :bad_profile}]

  # `rules.npc` is optional: absent means the planner's defaults.
  defp npc_rules_problems(_catalog, nil), do: []

  defp npc_rules_problems(catalog, npc), do: Tuning.npc_problems(catalog, npc)

  defp npc_profile_problems(p) do
    ok =
      npc_id?(get(p, :id)) and pos_int?(get(p, :price_permille)) and get(p, :policy) in @policies and
        pos_int?(get(p, :restock_days)) and
        get(p, :preferred_tier) in @tiers

    if ok, do: [], else: [{:npc, get(p, :id), :bad_profile}]
  end

  # An operator ID is embedded in reserved command IDs and restaurant IDs.
  defp npc_id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-zA-Z0-9_-]{1,32}\z/, id)
  defp npc_id?(_), do: false

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
        {Money.menu_price?(get(r, :suggested_price)), :bad_suggested_price},
        {is_integer(r.unlock_cost) and r.unlock_cost >= 0, :bad_unlock_cost},
        {not r.starter or r.kind == :main, :non_main_starter},
        {is_nil(get(r, :technique)) or get(r, :technique) in @techniques, :invalid_technique}
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
