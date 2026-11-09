defmodule FeudHall.Domain.MarketFlowTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.{Clock, Hall, Market}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Infrastructure.{EventCodec, InMemoryEventStore}
  alias FeudHall.Oracle

  @interval SliceCatalog.rules().market.clear_every_hall_ms

  # alice's restaurant, created but holding no stock.
  defp bare_world, do: stocked_world(stock: %{}, unlock: false)

  defp request(product, qty, limit \\ 1_000_000),
    do: {:submit_purchase_request, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: limit}}

  defp submit(world, product, qty, id, limit \\ 1_000_000), do: run!(world, request(product, qty, limit), owner(), id)

  defp to_next_clearing(world), do: advance_hall(world, elem(world, 0).market.next_clear_at)

  defp cleared(events), do: Enum.filter(events, &(&1.type == :market_cleared))

  describe "submitting and cancelling" do
    test "a request is pending, holds no cash, and records its ID from the command ID" do
      {before, _} = world = bare_world()
      {state, events} = submit(world, "rice_long", 100, "buy-rice")

      assert [
               %{
                 type: :purchase_requested,
                 request_id: "PR:buy-rice",
                 restaurant_id: "r1",
                 product: "rice_long",
                 qty: 100,
                 max_price_per_kunit: 1_000_000,
                 replaces: nil
               }
             ] = Enum.take(events, -1)

      assert state.restaurants["r1"].ledger == before.restaurants["r1"].ledger
      assert state.restaurants["r1"].batches == %{}
      assert Map.keys(state.market.requests) == ["PR:buy-rice"]
      assert state.market.by_key == %{{"r1", "rice_long"} => "PR:buy-rice"}
      assert Invariants.check(state) == :ok
    end

    test "submissions are validated" do
      world = bare_world()

      assert reject!(world, request("caviar", 10), owner(), "x") == :unknown_product
      assert reject!(world, request("rice_long", 0), owner(), "x") == :invalid_quantity
      assert reject!(world, request("rice_long", 1_000_001), owner(), "x") == :invalid_quantity
      assert reject!(world, request("rice_long", 10, 0), owner(), "x") == :invalid_price_limit
      assert reject!(world, request("rice_long", 10, "5"), owner(), "x") == :invalid_price_limit
      assert reject!(world, request("rice_long", 10), owner("mallory"), "x") == :forbidden

      assert reject!(
               world,
               {:submit_purchase_request, %{restaurant_id: "r9", product: "rice_long", qty: 1, max_price_per_kunit: 1}},
               owner(),
               "x"
             ) == :unknown_restaurant

      assert {_, [_ | _]} = submit(world, "rice_long", 1_000_000, "max")
    end

    test "a replacing request supersedes the pending one" do
      world = bare_world() |> submit("rice_long", 100, "first") |> submit("rice_long", 30, "second")
      {state, events} = world

      assert %{type: :purchase_requested, request_id: "PR:second", replaces: "PR:first"} = List.last(events)
      assert Map.keys(state.market.requests) == ["PR:second"]
      assert state.market.by_key == %{{"r1", "rice_long"} => "PR:second"}

      {state, events} = to_next_clearing(world)
      assert [%{fills: [fill], unfilled: []}] = cleared(events)
      assert %{request_id: "PR:second", qty: 30} = fill
      assert [%{qty: 30}] = Map.values(state.restaurants["r1"].batches)
      Oracle.assert_settled!(state, events)
    end

    test "cancellation before clearing leaves no fill" do
      world = bare_world() |> submit("rice_long", 100, "buy") |> submit("sugar", 50, "buy-sugar")

      {state, events} =
        world = run!(world, {:cancel_purchase_request, %{restaurant_id: "r1", product: "rice_long"}}, owner(), "cancel")

      assert %{type: :purchase_request_cancelled, request_id: "PR:buy"} = List.last(events)
      assert Map.keys(state.market.requests) == ["PR:buy-sugar"]
      assert state.market.by_key == %{{"r1", "sugar"} => "PR:buy-sugar"}

      {state, events} = to_next_clearing(world)
      assert [%{fills: [%{request_id: "PR:buy-sugar"}], unfilled: []}] = cleared(events)
      assert [%{product: "sugar"}] = Map.values(state.restaurants["r1"].batches)
      Oracle.assert_settled!(state, events)
    end

    test "cancelling needs a pending request owned by the actor" do
      world = submit(bare_world(), "rice_long", 100, "buy")
      cancel = fn product -> {:cancel_purchase_request, %{restaurant_id: "r1", product: product}} end

      assert reject!(world, cancel.("sugar"), owner(), "c") == :no_pending_request
      assert reject!(world, cancel.("rice_long"), owner("mallory"), "c") == :forbidden

      cleared_world = to_next_clearing(world)
      assert reject!(cleared_world, cancel.("rice_long"), owner(), "c") == :no_pending_request
    end
  end

  describe "clearing inside the clock advance" do
    test "a request filled at the next clearing produces a batch and the right ledger posts" do
      {before, _} = world = submit(bare_world(), "rice_long", 100, "buy-rice")
      opening = before.market.stock["rice_long"]
      price = Market.price(before.catalog, before.market, "rice_long")
      assert before.market.next_clear_at == @interval

      # Nothing happens before the clearing instant.
      {early, early_events} = advance_hall(world, @interval - Clock.ratio())
      assert cleared(early_events) == []
      assert Map.has_key?(early.market.requests, "PR:buy-rice")

      {state, events} = to_next_clearing(world)
      cost = div(100 * price + 999, 1000)

      assert [
               %{
                 batch: 0,
                 fills: [
                   %{
                     request_id: "PR:buy-rice",
                     restaurant_id: "r1",
                     product: "rice_long",
                     qty: 100,
                     cost: ^cost,
                     batch_id: batch_id
                   }
                 ],
                 unfilled: []
               }
             ] = cleared(events)

      batch = state.restaurants["r1"].batches[batch_id]
      assert %{product: "rice_long", qty: 100, reserved: 0, cost: ^cost} = batch

      ledger = state.restaurants["r1"].ledger
      old = before.restaurants["r1"].ledger
      assert ledger.cash == old.cash - cost
      assert ledger.raw == old.raw + cost
      assert Map.drop(ledger, [:cash, :raw]) == Map.drop(old, [:cash, :raw])

      assert state.market.stock["rice_long"] == opening - 100
      assert state.market.requests == %{}
      assert state.market.by_key == %{}
      assert state.market.batch == 1
      assert state.market.next_clear_at == 2 * @interval
      assert Invariants.check(state) == :ok
      Oracle.assert_settled!(state, events)
    end

    test "every interval clears, with or without requests, and settles every pending request" do
      {state, events} = advance_hall(bare_world(), 3 * @interval)
      assert Enum.map(cleared(events), & &1.batch) == [0, 1, 2]
      assert Enum.all?(cleared(events), &(&1.fills == [] and &1.unfilled == []))
      assert state.market.next_clear_at == 4 * @interval

      # A request that cannot be filled at all expires at the clearing.
      {state, events} = bare_world() |> submit("rice_long", 100, "cheap", 1) |> to_next_clearing()

      assert [%{fills: [], unfilled: [%{request_id: "PR:cheap", qty: 100, reason: :price_above_limit}]}] =
               cleared(events)

      assert state.market.requests == %{}
      assert state.restaurants["r1"].batches == %{}
      Oracle.assert_settled!(state, events)
    end

    test "a request submitted at 03:30 fills at the 03:32 clearing during cleaning" do
      w = advance_hall(bare_world(), Clock.cleaning_start_of(0) + 30 * Clock.minute())
      assert elem(w, 0).access == :cleaning
      w = submit(w, "rice_long", 100, "night-buy")
      assert elem(w, 0).market.next_clear_at == Clock.cleaning_start_of(0) + 32 * Clock.minute()

      {state, events} = to_next_clearing(w)
      assert state.access == :cleaning
      assert %{fills: [%{request_id: "PR:night-buy", qty: 100}]} = List.last(cleared(events))
      # Every clearing through the night ran, one per interval since the start.
      assert length(cleared(events)) == div(state.now, @interval)
      assert [%{qty: 100}] = Map.values(state.restaurants["r1"].batches)
      Oracle.assert_settled!(state, events)
    end

    test "a fill's expiry starts at the fill time, not at submission" do
      shelf = SliceCatalog.catalog().products["cilantro"].shelf_life_ms
      w = advance_hall(bare_world(), Clock.minute())
      w = submit(w, "cilantro", 10, "herbs")
      {state, events} = to_next_clearing(w)

      assert state.now == @interval
      assert [%{fills: [%{expires_at: expires_at, batch_id: bid}]}] = cleared(events)
      assert expires_at == @interval + shelf
      assert state.restaurants["r1"].batches[bid].expires_at == @interval + shelf
    end

    test "fills go through the same code as clear/1 and the event round-trips through the codec" do
      {before, _} = world = bare_world() |> submit("rice_long", 100, "a") |> submit("chicken_thigh", 5_000, "b")
      before = %{before | now: before.market.next_clear_at}
      {_state, events} = to_next_clearing(world)

      assert [event] = cleared(events)
      assert event == Market.clear(before)
      # More chicken than the market holds: the rest is reported unfilled.
      assert %{reason: :stock_exhausted} = Enum.find(event.unfilled, &(&1.request_id == "PR:b"))

      for e <- events, e.type in [:market_cleared, :purchase_requested, :purchase_request_cancelled] do
        assert {:ok, ^e} = e |> EventCodec.encode!() |> EventCodec.decode()
      end

      {_, cancel} =
        run!(
          submit(bare_world(), "sugar", 1, "s"),
          {:cancel_purchase_request, %{restaurant_id: "r1", product: "sugar"}},
          owner(),
          "c"
        )

      for e <- Enum.take(cancel, -2), do: assert({:ok, ^e} = e |> EventCodec.encode!() |> EventCodec.decode())
    end
  end

  describe "oracle market conservation" do
    test "holds across clearings and catches stock that was not filled" do
      world = bare_world() |> submit("rice_long", 100, "a") |> submit("sugar", 40, "b")
      {state, events} = world |> to_next_clearing() |> submit("rice_long", 10, "c") |> to_next_clearing()
      assert Oracle.violations(state, events) == []

      leaked = update_in(state, [:market, :stock, "rice_long"], &(&1 + 1))
      assert {:market_stock_not_conserved, "rice_long"} in Oracle.violations(leaked, events)

      stray = put_in(state, [:market, :requests, "PR:ghost"], %{restaurant_id: "r1", product: "sugar", qty: 1})
      assert :pending_requests_mismatch in Oracle.violations(stray, events)
    end
  end

  test "a historical stock_purchased event still replays" do
    {state, _} = bare_world()

    event = %{
      type: :stock_purchased,
      restaurant_id: "r1",
      batch_id: "B:old",
      product: "rice_long",
      product_version: 1,
      qty: 10,
      cost: 3,
      expires_at: 1_000
    }

    state = Hall.evolve(state, event)
    assert state.restaurants["r1"].batches["B:old"].qty == 10
    assert state.restaurants["r1"].ledger.raw == 3
  end

  test "purchase_stock through the workflow is an unknown command" do
    {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())

    {:accepted, _, rt} =
      Workflow.execute(rt, %{
        command_id: "init",
        actor: {:system, :admin},
        command: {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}}
      })

    command = {:purchase_stock, %{restaurant_id: "r1", product: "rice_long", qty: 1, max_price_per_kunit: 1_000}}

    assert {:error, :unknown_command, _} =
             Workflow.execute(rt, %{command_id: "buy", actor: {:principal, "alice"}, command: command})

    {state, _} = bare_world()
    assert {:error, :unauthorized_or_malformed} = Hall.decide(state, command, ctx(owner(), "buy"))
  end
end
