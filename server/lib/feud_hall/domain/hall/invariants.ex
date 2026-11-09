defmodule FeudHall.Domain.Hall.Invariants do
  @moduledoc """
  Pure consistency checks a recovered hall state must pass before the
  authority adopts it and accepts new work.

  These are a small production subset of the test oracle: they read only the
  state (not the event history), so they also catch a damaged snapshot whose
  checksum is intact. Checked:

    * each restaurant's trial balance
      (`cash + raw + wip + cost_of_sales + waste + capex == capital + revenue`);
    * each warehouse batch's reservation stays within `0..qty` and equals the
      claims of the restaurant's still-reserved orders, and no claim names a
      batch the restaurant no longer holds;
    * every tray component names an existing order;
    * the access gate matches the cleaning calendar (`Clock.cleaning?/1`);
    * the market's pending purchase requests and their `{restaurant, product}`
      index agree, each names an existing restaurant, market stock is never
      negative, and the next clearing lies after the clock.

  Problems are terms naming the broken invariant: `{restaurant_id, problem}`
  for restaurant checks, `{:missing_tray_component, tray_id, order_id}`,
  `{:access_gate_mismatch, hall_ms}`, `{:unindexed_purchase_request, id}`,
  `{:dangling_request_index, id}`, `{:request_for_unknown_restaurant, id}`,
  `{:negative_market_stock, product}`, and `{:market_clearing_overdue, at}`.
  """

  alias FeudHall.Domain.Clock

  @spec check(map() | nil) :: :ok | {:error, [term()]}
  def check(nil), do: :ok

  def check(state) do
    case restaurants(state) ++ trays(state) ++ access(state) ++ market(state) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp restaurants(state) do
    claims = claims_by_restaurant(state)

    state.restaurants
    |> Enum.sort()
    |> Enum.flat_map(fn {rid, r} ->
      l = r.ledger
      reserved = Map.get(claims, rid, %{})

      balance = [
        {l.cash + l.raw + l.wip + l.cost_of_sales + l.waste + l.capex == l.capital + l.revenue, :trial_balance}
      ]

      batches =
        r.batches
        |> Enum.sort()
        |> Enum.flat_map(fn {bid, b} ->
          [
            {b.reserved >= 0 and b.reserved <= b.qty, {:reservation_out_of_range, bid}},
            {b.reserved == Map.get(reserved, bid, 0), {:stranded_reservation, bid}}
          ]
        end)

      orphans =
        for {bid, _} <- Enum.sort(reserved),
            not Map.has_key?(r.batches, bid),
            do: {false, {:claim_on_missing_batch, bid}}

      for {false, problem} <- balance ++ batches ++ orphans, do: {rid, problem}
    end)
  end

  # Units claimed per restaurant and batch by orders that still hold reservations.
  defp claims_by_restaurant(state) do
    state.orders
    |> Map.values()
    |> Enum.filter(&(&1.status == :queued_prep))
    |> Enum.reduce(%{}, fn order, acc ->
      rid = state.visits |> Map.get(order.visit, %{}) |> Map.get(:restaurant)

      Enum.reduce(order.reservations, acc, fn %{batch_id: bid, qty: qty}, acc ->
        Map.update(acc, rid, %{bid => qty}, &Map.update(&1, bid, qty, fn held -> held + qty end))
      end)
    end)
  end

  defp trays(state) do
    for {tid, tray} <- Enum.sort(state.trays),
        oid <- tray.components,
        not Map.has_key?(state.orders, oid),
        do: {:missing_tray_component, tid, oid}
  end

  # Pending requests and their one-per-key index agree, each names an existing
  # restaurant (clearing funds it from that restaurant), stock is never
  # negative, and the next clearing is still ahead of the clock.
  defp market(%{market: market} = state) do
    indexed =
      for {id, r} <- Enum.sort(market.requests),
          Map.get(market.by_key, {r.restaurant_id, r.product}) != id,
          do: {:unindexed_purchase_request, id}

    dangling =
      for {{r, p}, id} <- Enum.sort(market.by_key),
          not match?(%{restaurant_id: ^r, product: ^p}, Map.get(market.requests, id)),
          do: {:dangling_request_index, id}

    orphaned =
      for {id, r} <- Enum.sort(market.requests),
          not Map.has_key?(state.restaurants, r.restaurant_id),
          do: {:request_for_unknown_restaurant, id}

    negative = for {product, qty} <- Enum.sort(market.stock), qty < 0, do: {:negative_market_stock, product}

    overdue =
      if clears?(state) and market.next_clear_at <= state.now,
        do: [{:market_clearing_overdue, market.next_clear_at}],
        else: []

    indexed ++ dangling ++ orphaned ++ negative ++ overdue
  end

  defp clears?(state), do: (get_in(state.catalog, [:rules, :market, :clear_every_hall_ms]) || 0) > 0

  defp access(state) do
    if state.access == :cleaning == Clock.cleaning?(state.now),
      do: [],
      else: [{:access_gate_mismatch, state.now}]
  end
end
