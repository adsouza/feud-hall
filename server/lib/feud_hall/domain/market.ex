defmodule FeudHall.Domain.Market do
  @moduledoc """
  Pure rules for the wholesale market: the published scarcity price, batch
  clearing, and replenishment.

  Market state is `%{stock, requests, by_key, batch, next_clear_at}`. `requests`
  maps a request ID to `%{restaurant_id, product, qty, max_price_per_kunit,
  submitted_at}`; `by_key` maps `{restaurant_id, product}` to the one pending
  request for that key, so a restaurant cannot split a purchase across several
  requests (submitting again replaces the pending one). The tuple keys exist in
  state only; the clearing result is a plain event-shaped map.

  Clearing never mutates anything: `clear/1` returns the `:market_cleared`
  facts, including the instant of the next clearing (`next_clear_at`), and
  the caller (the decider) is responsible for appending them.

  Allocation order is total and deterministic. Restaurants are processed by ID
  and each restaurant's requests by product ID, so cash and storage budgets are
  reserved in a fixed priority. Contended products are split proportionally with
  integer largest remainders; ties go to restaurants in an order rotated by the
  batch number, so no restaurant is permanently favoured.
  """

  alias FeudHall.Domain.{Inventory, Money}

  @doc """
  Whether the hall clears the market at all: its catalog's `clear_every_hall_ms` is a positive
  integer. The clock advance and the recovery checks both use this one predicate.
  """
  def clearing?(catalog) do
    case get_in(catalog, [:rules, :market, :clear_every_hall_ms]) do
      n when is_integer(n) and n > 0 -> true
      _ -> false
    end
  end

  @doc """
  Adds `request` under `request_id`, replacing any pending request from the same
  restaurant for the same product.
  """
  def put_request(market, request_id, %{restaurant_id: r, product: p} = request) do
    key = {r, p}

    requests =
      case market.by_key do
        %{^key => old} -> Map.delete(market.requests, old)
        _ -> market.requests
      end

    %{market | requests: Map.put(requests, request_id, request), by_key: Map.put(market.by_key, key, request_id)}
  end

  @doc """
  The published price per thousand units: the base price scaled by how far
  stock sits from the target at the demand-equivalent floor, clamped to the
  content's price band (never below one).
  """
  def price(catalog, market, product) do
    rules = catalog.rules.market
    base = catalog.products[product].base_price_per_kunit
    stock = Map.get(market.stock, product, 0)

    target_at_floor =
      div(Map.fetch!(rules.target_stock_per_equivalent, product) * catalog.rules.demand.equivalent_floor_millis, 1000)

    floor = max(1, div(base * rules.price_floor_permille, 1000))
    ceiling = max(floor, div(base * rules.price_ceiling_permille, 1000))

    (base * target_at_floor)
    |> div(max(stock, 1))
    |> max(floor)
    |> min(ceiling)
  end

  @doc """
  Clears the pending requests against current stock. Takes `now`, the catalog,
  the restaurants' cash and warehouses, and the market from the hall state.
  """
  def clear(state) do
    %{catalog: catalog, market: market, now: now} = state
    prices = Map.new(Map.keys(catalog.products), &{&1, price(catalog, market, &1)})

    funded = fund_requests(state, prices)
    {fills, stock_exhausted} = allocate(funded, market)

    fills =
      fills
      |> Enum.map(&to_fill(&1, catalog, prices, market.batch, now))
      |> Enum.sort_by(&{&1.restaurant_id, &1.product})

    unfilled =
      funded
      |> Enum.flat_map(&shortfall/1)
      |> Kernel.++(stock_exhausted)
      |> Enum.sort_by(&{&1.restaurant_id, &1.product, &1.reason})
      |> Enum.map(&Map.take(&1, [:request_id, :qty, :reason]))

    %{
      type: :market_cleared,
      batch: market.batch,
      prices: prices,
      fills: fills,
      unfilled: unfilled,
      next_clear_at: market.next_clear_at + catalog.rules.market.clear_every_hall_ms
    }
  end

  @doc "Market stock after applying a `clear/1` result."
  def stock_after(market, cleared) do
    Enum.reduce(cleared.fills, market.stock, fn f, stock -> Map.update!(stock, f.product, &(&1 - f.qty)) end)
  end

  @doc """
  Units to add per product: toward the target scaled by `scale_millis`
  business equivalents. The content cap is the baseline at the demand floor
  and scales proportionally above it with the number of open restaurants.
  """
  def replenish(catalog, market, scale_millis, open_restaurants) do
    rules = catalog.rules.market
    floor_millis = catalog.rules.demand.equivalent_floor_millis
    cap_scale_millis = max(floor_millis, open_restaurants * 1000)

    Map.new(Map.keys(catalog.products), fn product ->
      target = div(Map.fetch!(rules.target_stock_per_equivalent, product) * scale_millis, 1000)
      cap = div(Map.fetch!(rules.replenish_cap, product) * cap_scale_millis, floor_millis)
      {product, max(0, min(target, cap) - Map.get(market.stock, product, 0))}
    end)
  end

  # -- funding ----------------------------------------------------------------

  # Per restaurant (by ID), per request (by product), the quantity its limit,
  # cash and storage allow. Budgets are reserved cumulatively in that order.
  defp fund_requests(state, prices) do
    state.market.requests
    |> Enum.map(fn {id, r} -> Map.put(r, :request_id, id) end)
    |> Enum.group_by(& &1.restaurant_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {restaurant_id, requests} ->
      restaurant = Map.fetch!(state.restaurants, restaurant_id)
      room = state.catalog.rules.storage_capacity - Inventory.storage_used(restaurant.batches, state.catalog)

      requests
      |> Enum.sort_by(& &1.product)
      |> Enum.map_reduce({restaurant.ledger.cash, room}, &fund(&1, &2, prices, state.catalog))
      |> elem(0)
    end)
  end

  defp fund(request, {cash, room}, prices, catalog) do
    price = Map.fetch!(prices, request.product)

    if price > request.max_price_per_kunit do
      {shape(request, 0, :price_above_limit), {cash, room}}
    else
      per_kunit = catalog.products[request.product].storage_per_kunit
      by_cash = div(cash * 1000, price)
      by_room = if per_kunit == 0, do: request.qty, else: div(max(room, 0) * 1000, per_kunit)
      funded = min(request.qty, min(by_cash, by_room))

      reason =
        cond do
          funded == request.qty -> nil
          by_cash <= by_room -> :insufficient_cash
          true -> :insufficient_storage
        end

      budget =
        {cash - Money.ceil_div(funded * price, 1000), room - Inventory.storage_for(catalog, request.product, funded)}

      {shape(request, funded, reason), budget}
    end
  end

  defp shape(request, funded, reason), do: Map.merge(request, %{funded: funded, reason: reason})

  defp shortfall(%{reason: nil}), do: []

  defp shortfall(r),
    do: [
      %{
        request_id: r.request_id,
        qty: r.qty - r.funded,
        reason: r.reason,
        restaurant_id: r.restaurant_id,
        product: r.product
      }
    ]

  # -- allocation -------------------------------------------------------------

  defp allocate(funded, market) do
    funded
    |> Enum.filter(&(&1.funded > 0))
    |> Enum.group_by(& &1.product)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], []}, fn {product, requests}, {fills, exhausted} ->
      stock = Map.get(market.stock, product, 0)
      requests = Enum.sort_by(requests, & &1.restaurant_id)
      shares = shares(requests, stock, market.batch)

      new_fills = for {r, qty} <- shares, qty > 0, do: Map.put(r, :fill, qty)

      new_exhausted =
        for {r, qty} <- shares, r.funded - qty > 0 do
          %{
            request_id: r.request_id,
            qty: r.funded - qty,
            reason: :stock_exhausted,
            restaurant_id: r.restaurant_id,
            product: product
          }
        end

      {fills ++ new_fills, exhausted ++ new_exhausted}
    end)
  end

  # `requests` is sorted by restaurant ID. Uncontended requests fill fully.
  defp shares(requests, stock, batch) do
    total = requests |> Enum.map(& &1.funded) |> Enum.sum()

    if total <= stock do
      Enum.map(requests, &{&1, &1.funded})
    else
      n = length(requests)
      start = rem(batch, n)

      scored =
        requests
        |> Enum.with_index()
        |> Enum.map(fn {r, i} ->
          {r, div(stock * r.funded, total), rem(stock * r.funded, total), rem(i - start + n, n)}
        end)

      leftover = stock - Enum.sum(Enum.map(scored, &elem(&1, 1)))

      winners =
        scored
        |> Enum.sort_by(fn {_r, _base, remainder, pos} -> {-remainder, pos} end)
        |> Enum.take(leftover)
        |> MapSet.new(fn {r, _, _, _} -> r.request_id end)

      Enum.map(scored, fn {r, base, _, _} -> {r, base + if(r.request_id in winners, do: 1, else: 0)} end)
    end
  end

  defp to_fill(r, catalog, prices, batch, now) do
    product = catalog.products[r.product]

    %{
      request_id: r.request_id,
      restaurant_id: r.restaurant_id,
      product: r.product,
      product_version: product.version,
      qty: r.fill,
      cost: Money.ceil_div(r.fill * Map.fetch!(prices, r.product), 1000),
      batch_id: "MB:#{batch}:#{r.request_id}",
      expires_at: now + product.shelf_life_ms
    }
  end
end
