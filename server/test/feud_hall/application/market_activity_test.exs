defmodule FeudHall.Application.MarketActivityTest do
  use ExUnit.Case, async: true

  alias FeudHall.Application.Projections.MarketActivity
  alias FeudHall.Domain.Market
  alias FeudHall.MexicanFixture

  # Crate sizes in the Mexican fixture: horchata uses 30 of rice_long (-> 500),
  # the tacos 20 of onion (-> 200).
  @rice_crate 500
  @onion_crate 200
  @limit 1_000_000
  @rich 100_000_000

  defp restaurant(id, cash \\ @rich), do: {id, %{id: id, ledger: %{cash: cash}, batches: %{}}}

  defp request(rid, restaurant, product, qty, limit \\ @limit),
    do: {rid, %{restaurant_id: restaurant, product: product, qty: qty, max_price_per_kunit: limit, submitted_at: 0}}

  # A hall-shaped state as it stands just before a clearing, in the shape
  # `Market.clear/1` reads.
  defp state(stock, restaurants, requests, opts \\ []) do
    market =
      Enum.reduce(
        requests,
        %{
          stock: stock,
          requests: %{},
          by_key: %{},
          batch: Keyword.get(opts, :batch, 0),
          next_clear_at: Keyword.get(opts, :at, 240_000)
        },
        fn {rid, req}, m -> Market.put_request(m, rid, req) end
      )

    %{
      catalog: put_in(MexicanFixture.catalog(), [:rules, :storage_capacity], 300_000),
      market: market,
      restaurants: Map.new(restaurants),
      now: Keyword.get(opts, :at, 240_000)
    }
  end

  # Observes the clearing `Market.clear/1` produces from `state`, as the
  # workflow does: against the state immediately before the event.
  defp observe_clearing(activity, state) do
    event = Market.clear(state)
    {MarketActivity.observe(activity, state, event), event}
  end

  test "the crate sizes this file relies on" do
    assert Market.crate_size(MexicanFixture.catalog(), "rice_long") == @rice_crate
    assert Market.crate_size(MexicanFixture.catalog(), "onion") == @onion_crate
  end

  test "a clearing yields one outcome per settled request with what filled and what fell short" do
    cilantro_price = Market.price(MexicanFixture.catalog(), %{stock: %{"cilantro" => 100}}, "cilantro")
    # Cash for about 600 cilantro: funding falls short first, then stock (100) does.
    d_cash = div(600 * cilantro_price, 1000)

    st =
      state(
        %{"rice_long" => 10_000, "onion" => 500, "sugar" => 5_000, "cilantro" => 100},
        [restaurant("a"), restaurant("b"), restaurant("c"), restaurant("d", d_cash)],
        [
          request("PR:a", "a", "rice_long", 3_000),
          request("PR:b", "b", "onion", 2_000),
          request("PR:c", "c", "sugar", 700, 1),
          request("PR:d", "d", "cilantro", 1_000)
        ],
        batch: 4,
        at: 960_000
      )

    {activity, event} = observe_clearing(MarketActivity.new(), st)
    fill = fn id -> Enum.find(event.fills, &(&1.request_id == id)) end

    # Premises about the event the projection reads.
    assert fill.("PR:a").qty == 3_000
    assert fill.("PR:b").qty == 500
    assert fill.("PR:c") == nil

    assert [%{reason: :insufficient_cash}, %{reason: :stock_exhausted}] =
             Enum.filter(event.unfilled, &(&1.request_id == "PR:d"))

    assert MarketActivity.outcomes(activity, "a") == [
             %{
               request_id: "PR:a",
               batch: 4,
               at: 960_000,
               product: "rice_long",
               requested: 3_000,
               filled: 3_000,
               cost: fill.("PR:a").cost,
               short: 0,
               automated: false,
               reason: nil
             }
           ]

    assert [%{product: "onion", requested: 2_000, filled: 500, short: 1_500, reason: :stock_exhausted} = b] =
             MarketActivity.outcomes(activity, "b")

    assert b.cost == fill.("PR:b").cost

    assert [%{product: "sugar", requested: 700, filled: 0, cost: 0, short: 700, reason: :price_above_limit}] =
             MarketActivity.outcomes(activity, "c")

    # Two shortfalls: short is everything that did not fill; the reason is the first in the event.
    d_filled = fill.("PR:d").qty
    assert d_filled == 100

    assert [%{requested: 1_000, filled: ^d_filled, short: short, reason: :insufficient_cash}] =
             MarketActivity.outcomes(activity, "d")

    assert short == 1_000 - d_filled
    assert MarketActivity.outcomes(activity, "nobody") == []
  end

  test "trips say which products filled and a size bucket, and nothing else" do
    st =
      state(
        %{"rice_long" => 50_000, "onion" => 50_000, "sugar" => 5_000},
        Enum.map(~w(a b c d e f g), &restaurant/1),
        [
          # 3 crates.
          request("PR:a1", "a", "rice_long", 3 * @rice_crate),
          # 2 + 2 crates across two products.
          request("PR:b1", "b", "onion", 2 * @onion_crate),
          request("PR:b2", "b", "rice_long", 2 * @rice_crate),
          # 9 crates.
          request("PR:c1", "c", "onion", 9 * @onion_crate),
          # 10 crates.
          request("PR:d1", "d", "rice_long", 10 * @rice_crate),
          # No fill: its limit is below the price.
          request("PR:e1", "e", "sugar", 100, 1),
          # 0.5 + 0.2 crates: rounded up to one.
          request("PR:f1", "f", "onion", div(@onion_crate, 2)),
          request("PR:f2", "f", "rice_long", 100),
          # 1.5 + 1.5 crates: summed before rounding, so 3 (small), not 2 + 2.
          request("PR:g1", "g", "onion", 300),
          request("PR:g2", "g", "rice_long", 750)
        ],
        batch: 2,
        at: 480_000
      )

    {activity, event} = observe_clearing(MarketActivity.new(), st)
    assert event.unfilled |> Enum.map(& &1.request_id) == ["PR:e1"]

    trips = MarketActivity.trips(activity)

    for trip <- trips do
      assert trip |> Map.keys() |> Enum.sort() == [:batch, :products, :restaurant_id, :size]
      assert %{batch: 2} = trip
    end

    by_restaurant = Map.new(trips, &{&1.restaurant_id, {&1.products, &1.size}})

    assert by_restaurant == %{
             "a" => {["rice_long"], :small},
             "b" => {["onion", "rice_long"], :medium},
             "c" => {["onion"], :medium},
             "d" => {["rice_long"], :large},
             "f" => {["onion", "rice_long"], :small},
             "g" => {["onion", "rice_long"], :small}
           }

    assert length(trips) == 6
  end

  test "only the last six clearings with outcomes are kept, newest first; trips come from the newest two" do
    activity =
      Enum.reduce(0..8, MarketActivity.new(), fn batch, activity ->
        # Batch 5 settles nothing: it does not count toward the six.
        requests = if batch == 5, do: [], else: [request("PR:#{batch}", "a", "onion", 10 + batch)]
        st = state(%{"onion" => 10_000}, [restaurant("a")], requests, batch: batch, at: (batch + 1) * 240_000)
        elem(observe_clearing(activity, st), 0)
      end)

    assert Enum.map(MarketActivity.outcomes(activity, "a"), & &1.batch) == [8, 7, 6, 4, 3, 2]
    assert Enum.map(MarketActivity.outcomes(activity, "a"), & &1.request_id) == ~w(PR:8 PR:7 PR:6 PR:4 PR:3 PR:2)
    assert Enum.map(MarketActivity.trips(activity), & &1.batch) == [8, 7]
  end

  test "a clearing that settles requests but fills nothing keeps outcomes and adds no trip" do
    st = state(%{"onion" => 0}, [restaurant("a")], [request("PR:a", "a", "onion", 50)])
    {activity, _} = observe_clearing(MarketActivity.new(), st)

    assert [%{filled: 0, short: 50, reason: :stock_exhausted}] = MarketActivity.outcomes(activity, "a")
    assert MarketActivity.trips(activity) == []
  end

  test "a clearing with no requests changes nothing" do
    empty = state(%{"onion" => 1_000}, [restaurant("a")], [])
    assert elem(observe_clearing(MarketActivity.new(), empty), 0) == MarketActivity.new()

    busy = state(%{"onion" => 1_000}, [restaurant("a")], [request("PR:a", "a", "onion", 50)])
    {activity, _} = observe_clearing(MarketActivity.new(), busy)
    assert elem(observe_clearing(activity, %{empty | market: %{empty.market | batch: 1}}), 0) == activity

    # Other events change nothing either.
    assert MarketActivity.observe(activity, busy, %{type: :purchase_requested, request_id: "PR:x"}) == activity
    assert MarketActivity.observe(activity, nil, %{type: :hall_initialized}) == activity
  end
end
