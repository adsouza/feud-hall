defmodule FeudHall.Domain.Inventory do
  @moduledoc """
  Pure helpers over a restaurant's shared warehouse batches.

  A batch is `%{id, product, product_version, qty, reserved, cost, expires_at}`
  where `qty` is on-hand units, `reserved` the part claimed by accepted orders,
  and `cost` the remaining acquisition cost of the on-hand units. Consuming
  part of a batch takes a proportional share of its remaining cost and the
  final unit takes the remainder, so the batch's original cost is conserved
  exactly. A batch is usable while `now < expires_at` (expiry wins a tie).
  """

  @doc "Unreserved, unexpired units of `product` across the warehouse."
  def available(batches, product, now) do
    batches
    |> Map.values()
    |> Enum.filter(&usable?(&1, product, now))
    |> Enum.reduce(0, fn b, acc -> acc + b.qty - b.reserved end)
  end

  @doc "Available units per product for every product present."
  def availability(batches, now) do
    batches
    |> Map.values()
    |> Enum.filter(&(now < &1.expires_at))
    |> Enum.reduce(%{}, fn b, acc -> Map.update(acc, b.product, b.qty - b.reserved, &(&1 + b.qty - b.reserved)) end)
  end

  @doc """
  Plans a reservation of `qty` units of `product`, earliest-expiring eligible
  batch first (ties by batch id). Returns claims without mutating batches.
  `excluded` batch ids are skipped (used when replacing expiring claims).
  """
  def plan_reservation(batches, product, qty, now, excluded \\ []) do
    eligible =
      batches
      |> Map.values()
      |> Enum.filter(&(usable?(&1, product, now) and &1.id not in excluded))
      |> Enum.sort_by(&{&1.expires_at, &1.id})

    Enum.reduce_while(eligible, {qty, []}, fn b, {left, claims} ->
      take = min(left, b.qty - b.reserved)

      cond do
        take <= 0 -> {:cont, {left, claims}}
        take == left -> {:halt, {0, [%{batch_id: b.id, qty: take} | claims]}}
        true -> {:cont, {left - take, [%{batch_id: b.id, qty: take} | claims]}}
      end
    end)
    |> case do
      {0, claims} -> {:ok, Enum.reverse(claims)}
      _ -> {:error, :insufficient_stock}
    end
  end

  @doc "Applies reservation claims (positive) or releases (negative sign)."
  def adjust_reserved(batches, claims, sign) do
    Enum.reduce(claims, batches, fn %{batch_id: id, qty: q}, acc ->
      Map.update!(acc, id, &%{&1 | reserved: &1.reserved + sign * q})
    end)
  end

  @doc """
  Computes the cost taken by consuming `qty` reserved units from a batch.
  Pure calculation used by the decider; evolution applies the recorded cost.
  """
  def consumption_cost(%{qty: on_hand, cost: cost}, qty) when qty == on_hand, do: cost
  def consumption_cost(%{qty: on_hand, cost: cost}, qty), do: div(cost * qty, on_hand)

  @doc "Storage units occupied by on-hand stock."
  def storage_used(batches, catalog) do
    batches
    |> Map.values()
    |> Enum.reduce(0, fn b, acc -> acc + storage_for(catalog, b.product, b.qty) end)
  end

  def storage_for(catalog, product, qty) do
    per_kunit = catalog.products[product].storage_per_kunit
    div(qty * per_kunit + 999, 1000)
  end

  defp usable?(b, product, now), do: b.product == product and now < b.expires_at
end
