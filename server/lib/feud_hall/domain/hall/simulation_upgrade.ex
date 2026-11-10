defmodule FeudHall.Domain.Hall.SimulationUpgrade do
  @moduledoc "One-time live transition for halls initialized before the shared simulation."

  alias FeudHall.Domain.{Clock, Content, Demand, Market, Random}

  @simulation_rules [:seed, :exposure_permille, :kitchen, :market, :demand]

  def needed?(nil), do: false
  def needed?(%{catalog: %{rules: rules}}), do: not Map.has_key?(rules, :kitchen)

  # The current simulation supplies proposals for capabilities the old hall
  # lacked. The event pins the accepted data. Existing products, recipes,
  # profiles, rules and occupied slot IDs stay as they were.
  def decide(state, defaults) do
    catalog = state.catalog
    rules = Map.merge(Map.take(defaults.rules, @simulation_rules), catalog.rules)
    rules = %{rules | market: market_rules(rules.market, catalog.products), demand: demand_rules(rules.demand, catalog)}
    occupied = Map.keys(state.stalls) |> Enum.sort()
    layout = layout(defaults.layout, occupied)

    catalog =
      Map.merge(catalog, %{
        version: catalog.version + 1,
        rules: rules,
        layout: layout,
        npc_profiles: defaults.npc_profiles
      })

    with :ok <- Content.validate(catalog) do
      {:ok,
       [
         %{
           type: :hall_simulation_upgraded,
           catalog: catalog,
           content_hash: Content.hash(catalog),
           seed: rules.seed,
           market: %{stock: Market.opening_stock(catalog), next_clear_at: state.now + rules.market.clear_every_hall_ms},
           demand: %{
             rng: Random.new(Random.derive(rules.seed, "demand")),
             next_day_at: (Clock.day_of(state.now) + 1) * Clock.day(),
             acc_at: Clock.day_of(state.now) * Clock.day(),
             hour_quotas_millis: []
           }
         }
       ]}
    else
      {:error, problems} -> {:error, {:invalid_content, problems}}
    end
  end

  def evolve(state, event) do
    layout = Map.new(event.catalog.layout, &{&1.slot_id, &1.tier})
    stalls = Map.new(state.stalls, fn {id, stall} -> {id, %{stall | tier: Map.fetch!(layout, id)}} end)

    # Old combined preparations already consumed their ingredients. If the
    # old scheduler had left one ready to finish, complete it at the first
    # live opportunity, never at a timestamp before the upgrade.
    orders =
      Map.new(state.orders, fn
        {id, %{status: :finish} = order} ->
          {id, %{order | stage_done_at: max(order.stage_done_at, state.now)}}

        entry ->
          entry
      end)

    %{
      state
      | catalog: event.catalog,
        content_hash: event.content_hash,
        seed: event.seed,
        layout: layout,
        stalls: stalls,
        orders: orders,
        market: Map.merge(state.market, event.market),
        demand: Demand.new(event.catalog, event.demand)
    }
  end

  defp layout(defaults, occupied) do
    tiers = Map.new(defaults, &{&1.slot_id, &1.tier})
    ids = MapSet.new(occupied)
    remaining = Enum.reject(defaults, &MapSet.member?(ids, &1.slot_id))
    preserved = Enum.map(occupied, &%{slot_id: &1, tier: Map.get(tiers, &1, :standard)})
    preserved ++ Enum.take(remaining, max(0, length(defaults) - length(occupied)))
  end

  defp market_rules(default, products) do
    targets = Map.new(products, fn {id, _} -> {id, Map.get(default.target_stock_per_equivalent, id, 400)} end)
    caps = Map.new(targets, fn {id, target} -> {id, Map.get(default.replenish_cap, id, target * 4)} end)
    %{default | target_stock_per_equivalent: targets, replenish_cap: caps}
  end

  defp demand_rules(default, catalog) do
    mains = for {id, %{kind: :main}} <- catalog.recipes, do: id
    mix = Map.new(catalog.profiles, fn {id, _} -> {id, Map.get(default.profile_mix, id, 1)} end)

    segments =
      Enum.map(default.segments, fn segment ->
        %{segment | main_preference: Map.new(mains, &{&1, Map.get(segment.main_preference, &1, 1)})}
      end)

    %{default | segments: segments, profile_mix: mix}
  end
end
