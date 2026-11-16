defmodule FeudHall.Application.Projections.MarketActivity do
  @moduledoc """
  Ephemeral read model of recent wholesale clearings: each owner's purchase
  outcomes (private) and every restaurant's market trips (public).

  Observe each committed event against the hall state immediately before that
  event, in the same pass that evolves the batch (`CommandWorkflow` folds it
  beside `CounterService`). A `market_cleared` event carries only request IDs,
  quantities and reasons for what did not fill; the restaurant, product and
  requested quantity come from `state.market.requests` as they stood just
  before the clearing. Restock automation can request and clear inside one
  clock-advance batch, so the state before the batch is not enough.

  Only clearings that settled at least one request are kept, the newest
  six first: the owner's outcomes come from all six, the public trips from
  the newest two only (a client stages only clearings newer than the last it
  saw). Recovery starts empty: the projection is not rebuilt from the
  log after a restart. That is acceptable because nothing here is
  authoritative: filled purchases are visible as stock and cash, and pending
  requests are read from committed state, not from this projection.

  A trip names only the clearing's batch number, the restaurant, the product
  IDs that filled and a size bucket; quantities, costs, limits, reasons and
  times stay in the owner's outcomes.
  """

  alias FeudHall.Domain.Market

  @keep 6
  @public 2

  @type outcome :: %{
          request_id: String.t(),
          batch: non_neg_integer(),
          at: integer(),
          product: String.t(),
          requested: pos_integer(),
          filled: non_neg_integer(),
          cost: non_neg_integer(),
          short: non_neg_integer(),
          automated: boolean(),
          reason: nil | :price_above_limit | :insufficient_cash | :insufficient_storage | :stock_exhausted
        }

  @type trip :: %{
          batch: non_neg_integer(),
          restaurant_id: String.t(),
          products: [String.t()],
          size: :small | :medium | :large
        }

  @doc "An empty projection, as after a restart."
  def new, do: %{clearings: []}

  @doc """
  Folds one committed event. `state` is the hall state immediately before
  `event`. Only a `market_cleared` that settled at least one request changes
  the projection.
  """
  def observe(activity, %{market: %{requests: requests}} = state, %{type: :market_cleared} = event)
      when map_size(requests) > 0 do
    at = state.market.next_clear_at
    outcomes = outcomes_of(requests, event, at)
    clearing = %{outcomes: outcomes, trips: trips_of(state.catalog, event)}
    %{activity | clearings: Enum.take([clearing | activity.clearings], @keep)}
  end

  def observe(activity, _state, _event), do: activity

  @doc "The restaurant's outcomes over the kept clearings, newest first (by product within a clearing)."
  @spec outcomes(map(), String.t()) :: [outcome()]
  def outcomes(activity, restaurant_id) do
    for clearing <- activity.clearings,
        {^restaurant_id, outcome} <- clearing.outcomes,
        do: outcome
  end

  @doc """
  Every restaurant's trips over the newest two kept clearings, newest first
  (by restaurant within a clearing). This is what the public view carries.
  """
  @spec trips(map()) :: [trip()]
  def trips(activity), do: activity.clearings |> Enum.take(@public) |> Enum.flat_map(& &1.trips)

  defp outcomes_of(requests, event, at) do
    fills = Map.new(event.fills, &{&1.request_id, &1})
    shortfalls = Enum.group_by(event.unfilled, & &1.request_id)

    requests
    |> Enum.sort_by(fn {id, r} -> {r.restaurant_id, r.product, id} end)
    |> Enum.map(fn {id, r} ->
      fill = Map.get(fills, id)
      filled = if fill, do: fill.qty, else: 0

      reason =
        case Map.get(shortfalls, id) do
          [first | _] -> first.reason
          nil -> nil
        end

      {r.restaurant_id,
       %{
         request_id: id,
         batch: event.batch,
         at: at,
         product: r.product,
         requested: r.qty,
         filled: filled,
         cost: if(fill, do: fill.cost, else: 0),
         short: r.qty - filled,
         automated: Map.get(r, :automated, false),
         reason: reason
       }}
    end)
  end

  defp trips_of(catalog, event) do
    crate_sizes = Market.crate_sizes(catalog)

    event.fills
    |> Enum.group_by(& &1.restaurant_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {restaurant_id, fills} ->
      units = Enum.reduce(fills, %{}, fn f, acc -> Map.update(acc, f.product, f.qty, &(&1 + f.qty)) end)

      %{
        batch: event.batch,
        restaurant_id: restaurant_id,
        products: units |> Map.keys() |> Enum.sort(),
        size: size(crates(crate_sizes, units))
      }
    end)
  end

  # Units filled over each product's crate size, summed exactly, then rounded up.
  defp crates(crate_sizes, units) do
    sized = Enum.map(units, fn {product, qty} -> {qty, Map.fetch!(crate_sizes, product)} end)
    den = Enum.reduce(sized, 1, fn {_, crate}, acc -> lcm(acc, crate) end)
    num = Enum.reduce(sized, 0, fn {qty, crate}, acc -> acc + qty * div(den, crate) end)
    div(num + den - 1, den)
  end

  defp lcm(a, b), do: div(a * b, Integer.gcd(a, b))

  defp size(crates) when crates <= 3, do: :small
  defp size(crates) when crates <= 9, do: :medium
  defp size(_crates), do: :large
end
