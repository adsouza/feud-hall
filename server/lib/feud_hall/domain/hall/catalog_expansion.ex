defmodule FeudHall.Domain.Hall.CatalogExpansion do
  @moduledoc "Adds versioned launch content to a managed hall without replacing pinned definitions."
  alias FeudHall.Domain.{Content, Market}

  def decide(%{catalog: %{id: id, version: old} = previous, management: _}, %{id: "launch", version: new} = launch)
      when id == "slice" or (id == "launch" and new > old) do
    products = Map.merge(launch.products, previous.products)
    recipes = Map.merge(launch.recipes, previous.recipes)

    market = %{
      previous.rules.market
      | target_stock_per_equivalent:
          Map.merge(launch.rules.market.target_stock_per_equivalent, previous.rules.market.target_stock_per_equivalent),
        replenish_cap: Map.merge(launch.rules.market.replenish_cap, previous.rules.market.replenish_cap)
    }

    defaults = Map.new(launch.rules.demand.segments, &{&1.id, &1.main_preference})

    segments =
      Enum.map(previous.rules.demand.segments, fn segment ->
        %{segment | main_preference: Map.merge(Map.get(defaults, segment.id, %{}), segment.main_preference)}
      end)

    demand = %{previous.rules.demand | segments: segments}
    profiles = Map.merge(launch.profiles, previous.profiles)
    profiles = if id == "slice", do: Map.update!(profiles, "keto_style", &%{&1 | enabled: true}), else: profiles

    progression =
      case previous.rules[:progression] do
        nil ->
          launch.rules.progression

        pinned ->
          Map.merge(launch.rules.progression, pinned)
          |> Map.put(
            :starter_techniques,
            Map.merge(launch.rules.progression.starter_techniques, pinned.starter_techniques)
          )
      end

    catalog = %{
      previous
      | id: launch.id,
        version: launch.version,
        products: products,
        recipes: recipes,
        profiles: profiles,
        rules: Map.merge(previous.rules, %{market: market, demand: demand, progression: progression})
    }

    with :ok <- Content.validate(catalog) do
      stock = Map.drop(Market.opening_stock(catalog), Map.keys(previous.products))
      {:ok, [%{type: :hall_catalog_expanded, catalog: catalog, content_hash: Content.hash(catalog), stock: stock}]}
    else
      {:error, problems} -> {:error, {:invalid_content, problems}}
    end
  end

  def decide(_state, _catalog), do: {:error, :catalog_expansion_unavailable}

  def evolve(state, event) do
    %{state | catalog: event.catalog, content_hash: event.content_hash}
    |> update_in([:market, :stock], &Map.merge(event.stock, &1))
    |> FeudHall.Domain.Hall.Progression.start()
  end
end
