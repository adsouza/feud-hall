defmodule FeudHall.Domain.Content.Tuning do
  @moduledoc """
  The tunable values of a catalog, read and written as one set.

  A tuning gathers the demand, wholesale-market and computer-run-owner values
  that balance changes adjust:

      %{
        version: pos_integer,
        demand: %{arrivals_per_equivalent: non_neg_integer, hourly_weights: [non_neg_integer]},
        market: %{target_stock_per_equivalent: %{product_id => non_neg_integer},
                  replenish_cap: %{product_id => non_neg_integer}},
        npc: %{fallback_trays_per_day: pos_integer,
               expected_use: String.t(),
               starter_shifts: %{profile_id => [start_hour, end_hour]}}
      }

  Demand and market values live where the simulation already reads them
  (`rules.demand`, `rules.market`). The computer-run owner values live in
  `rules.npc`; a catalog without it uses `npc_defaults/0`, so catalogs that
  predate it keep their content hash. A shift is a two-element list, never a
  tuple: catalogs ride inside events and the event codec stores no tuples.

  This module owns the list of expected-use heuristic names so that content
  validation does not depend on the NPC planner; the planner exposes the same
  list through `FeudHall.Domain.Npc.Planner.expected_use_heuristics/0`.
  """

  @demand_keys [:arrivals_per_equivalent, :hourly_weights]
  @market_keys [:target_stock_per_equivalent, :replenish_cap]
  @npc_keys [:fallback_trays_per_day, :expected_use, :starter_shifts]
  @top_keys [:version, :demand, :market, :npc]
  @heuristics ["even_share"]

  @doc "The expected-use heuristic names a tuning may select."
  @spec expected_use_heuristics() :: [String.t()]
  def expected_use_heuristics, do: @heuristics

  @doc "The computer-run owner values a catalog without `rules.npc` uses."
  @spec npc_defaults() :: map()
  def npc_defaults do
    %{
      fallback_trays_per_day: 10,
      expected_use: "even_share",
      starter_shifts: %{"budget" => [5, 17], "mainstream" => [12, 0], "premium" => [19, 7]}
    }
  end

  @doc "`catalog.rules.npc` when present, otherwise `npc_defaults/0`."
  @spec npc(map()) :: map()
  def npc(catalog), do: Map.get(catalog.rules, :npc) || npc_defaults()

  @doc "The tuning a catalog currently has."
  @spec of(map()) :: map()
  def of(catalog) do
    rules = catalog.rules

    %{
      version: get_in(rules, [:tuning, :version]) || 1,
      demand: Map.take(rules.demand, @demand_keys),
      market: Map.take(rules.market, @market_keys),
      npc: npc(catalog)
    }
  end

  @doc """
  The catalog with the tuning's values written into its rules and
  `rules.tuning` set to the tuning's version. Every other rule is kept.
  """
  @spec put(map(), map()) :: map()
  def put(catalog, tuning) do
    rules =
      catalog.rules
      |> Map.update!(:demand, &Map.merge(&1, tuning.demand))
      |> Map.update!(:market, &Map.merge(&1, tuning.market))
      |> Map.put(:npc, tuning.npc)
      |> Map.put(:tuning, %{version: tuning.version})

    %{catalog | rules: rules}
  end

  @doc "Returns `:ok` or `{:error, [problem]}` listing every violation found."
  @spec validate(map(), term()) :: :ok | {:error, [term()]}
  def validate(catalog, tuning) do
    problems = tuning_problems(catalog, tuning)
    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc "The problems with a `rules.npc` value, checked against the catalog's NPC profiles."
  @spec npc_problems(map(), term()) :: [term()]
  def npc_problems(catalog, npc) do
    if exact_keys?(npc, @npc_keys) do
      trays = if pos_int?(npc.fallback_trays_per_day), do: [], else: [{:npc, :bad_fallback_trays}]
      use = if npc.expected_use in @heuristics, do: [], else: [{:npc, :bad_expected_use}]
      trays ++ use ++ shift_problems(catalog, npc.starter_shifts)
    else
      [{:npc, :malformed}]
    end
  end

  defp tuning_problems(catalog, tuning) do
    if exact_keys?(tuning, @top_keys) do
      version = if pos_int?(tuning.version), do: [], else: [{:tuning, :bad_version}]

      version ++
        demand_problems(tuning.demand) ++ market_problems(catalog, tuning.market) ++ npc_problems(catalog, tuning.npc)
    else
      [{:tuning, :malformed}]
    end
  end

  defp demand_problems(demand) do
    if exact_keys?(demand, @demand_keys) do
      arrivals = if nonneg_int?(demand.arrivals_per_equivalent), do: [], else: [{:demand, :bad_arrivals}]
      arrivals ++ hourly_problems(demand.hourly_weights)
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

  defp market_problems(catalog, market) do
    if exact_keys?(market, @market_keys) do
      products = catalog |> Map.get(:products, %{}) |> Map.keys() |> Enum.sort()

      for key <- @market_keys,
          values = Map.fetch!(market, key),
          not (is_map(values) and Enum.sort(Map.keys(values)) == products and
                 Enum.all?(Map.values(values), &nonneg_int?/1)),
          do: {:market, key, :bad_products}
    else
      [{:market, :malformed}]
    end
  end

  defp shift_problems(catalog, shifts) do
    # Profile shape is Content's concern (it reports `:bad_profile`); here ids are read
    # tolerantly, and a profile without one means the shifts cannot be matched.
    list = if is_list(Map.get(catalog, :npc_profiles)), do: catalog.npc_profiles, else: []
    ids = for %{id: id} <- list, do: id
    profiles = Enum.sort(ids)
    unmatched = if length(ids) == length(list), do: [], else: [{:npc, :bad_profile}]

    ok =
      is_map(shifts) and Enum.sort(Map.keys(shifts)) == profiles and
        Enum.all?(Map.values(shifts), &shift?/1)

    unmatched ++ if(ok, do: [], else: [{:npc, :bad_starter_shifts}])
  end

  defp shift?([start, finish]), do: start in 0..23 and finish in 0..23
  defp shift?(_), do: false

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp pos_int?(v), do: is_integer(v) and v > 0
  defp nonneg_int?(v), do: is_integer(v) and v >= 0
end
