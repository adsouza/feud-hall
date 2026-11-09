defmodule FeudHall.Application.BalancesProjectionTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Application.Projections.Balances

  test "a purchase changes only the cash and raw balances and that product's stock" do
    {before, _} = world = stocked_world(stock: Map.delete(default_stock(), "rice_long"))
    {after_state, _} = buy(world, "rice_long", 100, "buy-rice")

    rows = Balances.changes(before, after_state, 7)
    ledger = after_state.restaurants["r1"].ledger

    assert {:balance, "r1", :cash, ledger.cash} in rows
    assert {:balance, "r1", :raw, ledger.raw} in rows
    assert {:stock, "r1", "rice_long", 100, 0} in rows

    assert for({:balance, _, account, _} <- rows, do: account) |> Enum.sort() == [:cash, :raw]
    assert for({:stock, _, product, _, _} <- rows, do: product) == ["rice_long"]
    assert length(rows) == 3
  end

  test "an unchanged state produces no rows" do
    {state, _} = stocked_world()
    assert Balances.changes(state, state, 7) == []
  end

  test "stock rows total every batch of a product, and a product with no batches left is deleted" do
    {before, _} = world = stocked_world()
    {after_buy, _} = buy(world, "rice_long", 100, "buy-rice-2")

    assert {:stock, "r1", "rice_long", 1_100, 0} in Balances.changes(before, after_buy, 8)

    emptied =
      update_in(after_buy, [:restaurants, "r1", :batches], &Map.reject(&1, fn {_, b} -> b.product == "rice_long" end))

    assert {:delete_stock, "r1", "rice_long"} in Balances.changes(after_buy, emptied, 9)
  end
end
