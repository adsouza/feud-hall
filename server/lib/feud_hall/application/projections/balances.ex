defmodule FeudHall.Application.Projections.Balances do
  @moduledoc """
  Synchronous restaurant balance and stock projection rows.

  `changes/3` compares the hall state before and after one batch and returns
  only the rows that differ: one `:balance` row per changed ledger account and
  one `:stock` row per product whose on-hand or reserved total changed, or a
  `:delete_stock` row when a product has no batches left. Rows are derived
  from evolved state only; the adapter writes them in the same transaction as
  the batch and stamps them with the committed position. A `nil` before-state
  means nothing was projected yet, so every account and product is a change.
  """

  alias FeudHall.Domain.Hall

  @type row ::
          {:balance, restaurant_id :: String.t(), account :: atom(), amount :: integer()}
          | {:stock, restaurant_id :: String.t(), product :: String.t(), on_hand :: integer(), reserved :: integer()}
          | {:delete_stock, restaurant_id :: String.t(), product :: String.t()}

  @doc "Rows that bring the projection from `before` to `after`."
  @spec changes(Hall.state(), Hall.state(), non_neg_integer()) :: [row()]
  def changes(before, after_state, _position) do
    before_restaurants = restaurants(before)

    after_state
    |> restaurants()
    |> Enum.sort()
    |> Enum.flat_map(fn {id, restaurant} ->
      case Map.get(before_restaurants, id) do
        nil -> restaurant_rows(id, nil, restaurant)
        ^restaurant -> []
        previous -> restaurant_rows(id, previous, restaurant)
      end
    end)
  end

  defp restaurants(nil), do: %{}
  defp restaurants(state), do: state.restaurants

  defp restaurant_rows(id, previous, restaurant) do
    balance_rows(id, previous && previous.ledger, restaurant.ledger) ++
      stock_rows(id, previous && previous.batches, restaurant.batches)
  end

  defp balance_rows(_id, same, same), do: []

  defp balance_rows(id, before_ledger, ledger) do
    for {account, amount} <- Enum.sort(ledger),
        Map.get(before_ledger || %{}, account) != amount,
        do: {:balance, id, account, amount}
  end

  defp stock_rows(_id, same, same), do: []

  defp stock_rows(id, before_batches, batches) do
    old = totals(before_batches || %{})
    new = totals(batches)

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn product ->
      case {Map.get(old, product), Map.get(new, product)} do
        {same, same} -> []
        {_, nil} -> [{:delete_stock, id, product}]
        {_, {on_hand, reserved}} -> [{:stock, id, product, on_hand, reserved}]
      end
    end)
  end

  defp totals(batches) do
    Enum.reduce(Map.values(batches), %{}, fn b, acc ->
      Map.update(acc, b.product, {b.qty, b.reserved}, fn {q, r} -> {q + b.qty, r + b.reserved} end)
    end)
  end
end
