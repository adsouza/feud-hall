defmodule FeudHall.Domain.PublicView do
  @moduledoc """
  The public projection of committed hall state: what any owner, human or NPC,
  may see about the hall and its rivals.

  Shape:

      %{
        now: hall_ms,
        market: %{product => %{price: per_kunit, stock: units}},
        stalls: [%{stall_id, restaurant_id, tier, open?, menu: %{recipe_id => price}}],
        today: %{arrivals, admitted, left},
        demand: [%{day, arrivals, admitted, left, trays_served, menu_prices_median}]
      }

  Stalls are sorted by stall ID and include closed ones (they still occupy a
  slot). A menu is the public price list. `today` is today's arrival totals:
  `left` is one integer, the sum of the per-reason counts. Rival cash,
  warehouse batches, orders, costs, unlocks, policies and random state are
  never copied in, and neither are the reasons diners left or the per-stall
  lost-diner counts: the projection names its fields rather than filtering a
  state map.
  """

  alias FeudHall.Domain.Market
  alias FeudHall.Domain.Hall.Progression

  @summary_keys [:day, :arrivals, :admitted, :left, :trays_served, :menu_prices_median]

  @spec build(map()) :: map()
  def build(state) do
    %{
      now: state.now,
      market: market(state),
      stalls: stalls(state),
      today: today(state),
      demand: Enum.map(state.demand.summaries, &Map.take(&1, @summary_keys))
    }
  end

  defp today(%{demand: %{today: day}}) do
    %{arrivals: day.arrivals, admitted: day.admitted, left: day.left |> Map.values() |> Enum.sum()}
  end

  defp market(%{catalog: catalog, market: market}) do
    Map.new(Map.keys(catalog.products), fn product ->
      {product, %{price: Market.price(catalog, market, product), stock: Map.get(market.stock, product, 0)}}
    end)
  end

  def stalls(state) do
    state.stalls
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {stall_id, stall} ->
      %{
        stall_id: stall_id,
        restaurant_id: stall.restaurant,
        tier: stall.tier,
        open?: stall.mode == :open,
        menu: Progression.stall_menu(state, stall, state.restaurants[stall.restaurant])
      }
    end)
  end
end
