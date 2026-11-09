defmodule FeudHall.Domain.InvariantsTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Hall.Invariants}

  # A hall with an accepted, still-reserved tray (two components claiming stock).
  defp reserved_world do
    {state, _} = simulated_visit(stocked_world(), "d1", "bean_tacos", "horchata")
    state
  end

  defp reserved_order(state) do
    state.orders |> Map.values() |> Enum.find(&(&1.status == :queued_prep and &1.reservations != []))
  end

  test "an uninitialised hall and consistent halls pass" do
    assert Invariants.check(nil) == :ok
    assert Invariants.check(elem(stocked_world(), 0)) == :ok
    assert Invariants.check(reserved_world()) == :ok
  end

  test "a broken trial balance is reported per restaurant" do
    state = update_in(reserved_world(), [:restaurants, "r1", :ledger, :cash], &(&1 + 1))
    assert Invariants.check(state) == {:error, [{"r1", :trial_balance}]}
  end

  test "batch reservations must stay within quantity and match the reserved orders' claims" do
    state = reserved_world()
    %{reservations: [%{batch_id: batch_id} | _]} = reserved_order(state)

    stranded = update_in(state, [:restaurants, "r1", :batches, batch_id, :reserved], &(&1 + 1))
    assert {:error, [{"r1", {:stranded_reservation, ^batch_id}}]} = Invariants.check(stranded)

    qty = state.restaurants["r1"].batches[batch_id].qty
    over = put_in(stranded, [:restaurants, "r1", :batches, batch_id, :reserved], qty + 1)
    assert {:error, problems} = Invariants.check(over)
    assert {"r1", {:reservation_out_of_range, batch_id}} in problems
  end

  test "a claim on a batch the restaurant no longer holds is reported" do
    state = reserved_world()
    %{reservations: [%{batch_id: batch_id} | _]} = reserved_order(state)
    state = update_in(state, [:restaurants, "r1", :batches], &Map.delete(&1, batch_id))
    assert {:error, problems} = Invariants.check(state)
    assert {"r1", {:claim_on_missing_batch, batch_id}} in problems
  end

  test "every tray component must exist" do
    state = reserved_world()
    [tray_id] = Map.keys(state.trays)
    [order_id | _] = state.trays[tray_id].components
    {order, state} = pop_in(state, [:orders, order_id])
    assert order
    assert {:error, problems} = Invariants.check(state)
    assert {:missing_tray_component, tray_id, order_id} in problems
  end

  test "hall access must match the cleaning calendar" do
    state = elem(stocked_world(), 0)
    refute Clock.cleaning?(state.now)
    assert Invariants.check(%{state | access: :cleaning}) == {:error, [{:access_gate_mismatch, state.now}]}

    # Jump the clock (keeping the next market clearing ahead of it).
    three = Clock.cleaning_start_of(0)
    cleaning = %{state | now: three, market: %{state.market | next_clear_at: three + Clock.minute()}}
    assert Invariants.check(cleaning) == {:error, [{:access_gate_mismatch, cleaning.now}]}
    assert Invariants.check(%{cleaning | access: :cleaning}) == :ok
  end

  describe "market" do
    defp pending_world do
      request = %{restaurant_id: "r1", product: "rice_long", qty: 10, max_price_per_kunit: 1_000}
      {state, _} = run!(stocked_world(), {:submit_purchase_request, request}, owner(), "buy")
      state
    end

    test "a hall with a pending request passes" do
      assert map_size(pending_world().market.requests) == 1
      assert Invariants.check(pending_world()) == :ok
    end

    test "pending requests and their index must agree" do
      state = pending_world()

      unindexed = put_in(state, [:market, :by_key], %{})
      assert Invariants.check(unindexed) == {:error, [{:unindexed_purchase_request, "PR:buy"}]}

      dangling = put_in(state, [:market, :requests], %{})
      assert Invariants.check(dangling) == {:error, [{:dangling_request_index, "PR:buy"}]}

      wrong_key = put_in(state, [:market, :by_key], %{{"r1", "sugar"} => "PR:buy"})
      assert {:error, problems} = Invariants.check(wrong_key)
      assert {:dangling_request_index, "PR:buy"} in problems
      assert {:unindexed_purchase_request, "PR:buy"} in problems
    end

    test "a request must name an existing restaurant, stock stays non-negative, and clearing stays due" do
      state = pending_world()

      orphan = update_in(state, [:restaurants], &Map.delete(&1, "r1"))
      assert {:error, problems} = Invariants.check(orphan)
      assert {:request_for_unknown_restaurant, "PR:buy"} in problems

      negative = put_in(state, [:market, :stock, "sugar"], -1)
      assert Invariants.check(negative) == {:error, [{:negative_market_stock, "sugar"}]}

      overdue = put_in(state, [:market, :next_clear_at], state.now)
      assert Invariants.check(overdue) == {:error, [{:market_clearing_overdue, state.now}]}
    end
  end
end
