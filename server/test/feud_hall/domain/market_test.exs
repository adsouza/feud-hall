defmodule FeudHall.Domain.MarketTest do
  use ExUnit.Case, async: true

  alias FeudHall.MexicanFixture
  alias FeudHall.Domain.Market

  # onion: base 250, 1000 storage per kunit, shelf life 6 days.
  # sugar: base 120, 1000 storage per kunit.
  # Target 400 per equivalent and an equivalent floor of 3000 millis give a
  # target-at-floor of 1200, so the price equals base at stock 1200.
  @limit 1_000_000

  defp catalog, do: MexicanFixture.catalog()

  defp restaurant(id, cash, stored \\ 0) do
    batches =
      if stored > 0,
        do: %{"B:#{id}" => %{id: "B:#{id}", product: "onion", qty: stored, reserved: 0, cost: 0, expires_at: 10}},
        else: %{}

    {id, %{id: id, ledger: %{cash: cash}, batches: batches}}
  end

  defp request(rid, restaurant, product, qty, limit \\ @limit, at \\ 0),
    do: {rid, %{restaurant_id: restaurant, product: product, qty: qty, max_price_per_kunit: limit, submitted_at: at}}

  defp state(stock, restaurants, requests, opts \\ []) do
    market =
      Enum.reduce(
        requests,
        %{stock: stock, requests: %{}, by_key: %{}, batch: Keyword.get(opts, :batch, 0), next_clear_at: 0},
        fn {rid, req}, m -> Market.put_request(m, rid, req) end
      )

    %{
      catalog: put_in(catalog(), [:rules, :storage_capacity], Keyword.get(opts, :capacity, 300_000)),
      market: market,
      restaurants: Map.new(restaurants),
      now: 5_000
    }
  end

  defp fills_by(cleared, product),
    do: cleared.fills |> Enum.filter(&(&1.product == product)) |> Map.new(&{&1.restaurant_id, &1.qty})

  describe "price/3" do
    test "equals the base price when stock is at the target-at-floor" do
      m = %{stock: %{"onion" => 1_200}}
      assert Market.price(catalog(), m, "onion") == 250
    end

    test "scales inversely with stock inside the band" do
      assert Market.price(catalog(), %{stock: %{"onion" => 600}}, "onion") == 500
      assert Market.price(catalog(), %{stock: %{"onion" => 2_400}}, "onion") == 125
    end

    test "clamps at the ceiling and the floor" do
      assert Market.price(catalog(), %{stock: %{"onion" => 1}}, "onion") == 750
      assert Market.price(catalog(), %{stock: %{}}, "onion") == 750
      assert Market.price(catalog(), %{stock: %{"onion" => 1_000_000}}, "onion") == 125
    end
  end

  describe "clear/1 uncontended" do
    test "fills fully at the published price with ceiling cost and bound fields" do
      st = state(%{"onion" => 1_200}, [restaurant("a", 10_000)], [request("q1", "a", "onion", 7)])
      cleared = Market.clear(st)

      assert cleared.type == :market_cleared
      assert cleared.batch == 0
      assert cleared.prices["onion"] == 250
      assert cleared.unfilled == []

      assert [fill] = cleared.fills
      assert fill.request_id == "q1"
      assert fill.restaurant_id == "a"
      assert fill.product == "onion"
      assert fill.product_version == 1
      assert fill.qty == 7
      # 7 * 250 / 1000 = 1.75, rounded up.
      assert fill.cost == 2
      assert fill.batch_id == "MB:0:q1"
      assert fill.expires_at == 5_000 + 6 * 24 * 60 * 60_000
    end

    test "prices come from stock before allocation and cover every product" do
      st = state(%{"onion" => 1_200, "sugar" => 600}, [restaurant("a", 10_000)], [request("q1", "a", "onion", 7)])
      cleared = Market.clear(st)
      assert cleared.prices["onion"] == 250
      assert cleared.prices["sugar"] == 240
      assert map_size(cleared.prices) == map_size(catalog().products)
    end

    test "returned event holds no tuples" do
      st = state(%{"onion" => 10}, [restaurant("a", 10_000)], [request("q1", "a", "onion", 7)])
      refute contains_tuple?(Market.clear(st))
    end

    test "rejects a price above the request limit without filling" do
      st = state(%{"onion" => 1_200}, [restaurant("a", 10_000)], [request("q1", "a", "onion", 7, 249)])
      cleared = Market.clear(st)
      assert cleared.fills == []
      assert cleared.unfilled == [%{request_id: "q1", qty: 7, reason: :price_above_limit}]
    end

    test "a limit equal to the price fills" do
      st = state(%{"onion" => 1_200}, [restaurant("a", 10_000)], [request("q1", "a", "onion", 7, 250)])
      assert [%{qty: 7}] = Market.clear(st).fills
    end
  end

  describe "clear/1 contention" do
    defp three(batch) do
      st =
        state(
          %{"onion" => 10},
          [restaurant("a", 10_000), restaurant("b", 10_000), restaurant("c", 10_000)],
          [request("qa", "a", "onion", 7), request("qb", "b", "onion", 7), request("qc", "c", "onion", 7)],
          batch: batch
        )

      Market.clear(st)
    end

    test "stock 10 over 7/7/7 fills 4/3/3 and the rotation decides who gets the 4" do
      assert fills_by(three(0), "onion") == %{"a" => 4, "b" => 3, "c" => 3}
      assert fills_by(three(1), "onion") == %{"a" => 3, "b" => 4, "c" => 3}
      assert fills_by(three(2), "onion") == %{"a" => 3, "b" => 3, "c" => 4}
      assert fills_by(three(3), "onion") == %{"a" => 4, "b" => 3, "c" => 3}
    end

    test "unfilled remainder is reported as stock exhausted and fills conserve stock" do
      cleared = three(0)
      assert Enum.sum(for f <- cleared.fills, do: f.qty) == 10

      assert Enum.sort(cleared.unfilled) == [
               %{request_id: "qa", qty: 3, reason: :stock_exhausted},
               %{request_id: "qb", qty: 4, reason: :stock_exhausted},
               %{request_id: "qc", qty: 4, reason: :stock_exhausted}
             ]

      assert Enum.map(cleared.fills, & &1.batch_id) |> Enum.sort() == ["MB:0:qa", "MB:0:qb", "MB:0:qc"]
    end

    test "largest remainders beat the rotation, which only breaks ties" do
      # stock 10, requests 9 and 3: shares 7.5 and 2.5 with equal remainders
      # (rem 6 of 12 each); batch 1 rotates the extra unit to b.
      st = fn batch ->
        state(
          %{"onion" => 10},
          [restaurant("a", 10_000), restaurant("b", 10_000)],
          [request("qa", "a", "onion", 9), request("qb", "b", "onion", 3)],
          batch: batch
        )
      end

      assert fills_by(Market.clear(st.(0)), "onion") == %{"a" => 8, "b" => 2}
      assert fills_by(Market.clear(st.(1)), "onion") == %{"a" => 7, "b" => 3}

      # stock 10, requests 8 and 3 and 1: remainders differ, so the rotation is irrelevant.
      st2 =
        state(
          %{"onion" => 10},
          [restaurant("a", 10_000), restaurant("b", 10_000), restaurant("c", 10_000)],
          [request("qa", "a", "onion", 8), request("qb", "b", "onion", 3), request("qc", "c", "onion", 1)],
          batch: 2
        )

      # 80/12 = 6 r8, 30/12 = 2 r6, 10/12 = 0 r10 -> leftover 2 to c (10) then a (8).
      assert fills_by(Market.clear(st2), "onion") == %{"a" => 7, "b" => 2, "c" => 1}
    end

    test "no fill exceeds its funded request even with several leftover units" do
      st =
        state(
          %{"onion" => 5},
          [restaurant("a", 10_000), restaurant("b", 10_000), restaurant("c", 10_000)],
          [request("qa", "a", "onion", 1), request("qb", "b", "onion", 100), request("qc", "c", "onion", 100)]
        )

      fills = fills_by(Market.clear(st), "onion")
      assert Enum.sum(Map.values(fills)) == 5
      assert Map.get(fills, "a", 0) <= 1
    end

    test "contention for one product does not affect another" do
      st =
        state(
          %{"onion" => 10, "sugar" => 1_200},
          [restaurant("a", 100_000), restaurant("b", 100_000)],
          [request("qa", "a", "onion", 7), request("qb", "b", "onion", 7), request("qs", "a", "sugar", 50)]
        )

      cleared = Market.clear(st)
      assert fills_by(cleared, "sugar") == %{"a" => 50}
      assert Enum.sum(Map.values(fills_by(cleared, "onion"))) == 10
    end
  end

  describe "one request per key" do
    test "put_request replaces the pending request for the same restaurant and product" do
      m = %{stock: %{}, requests: %{}, by_key: %{}, batch: 0, next_clear_at: 0}
      {_, r1} = request("q1", "a", "onion", 7)
      {_, r2} = request("q2", "a", "onion", 7)

      m = m |> Market.put_request("q1", r1) |> Market.put_request("q2", r2)

      assert Map.keys(m.requests) == ["q2"]
      assert m.by_key == %{{"a", "onion"} => "q2"}
    end

    test "resubmitting the same total gains nothing against a competitor" do
      contested = fn requests ->
        state(
          %{"onion" => 10},
          [restaurant("a", 10_000), restaurant("b", 10_000)],
          requests ++ [request("qb", "b", "onion", 7)]
        )
      end

      once = Market.clear(contested.([request("qa1", "a", "onion", 7)]))
      twice = Market.clear(contested.([request("qa1", "a", "onion", 7), request("qa2", "a", "onion", 7)]))

      assert fills_by(once, "onion") == fills_by(twice, "onion")
      assert length(twice.fills) == 2
      assert Enum.count(twice.fills, &(&1.restaurant_id == "a")) == 1
    end

    test "different products from one restaurant are separate keys" do
      m = %{stock: %{}, requests: %{}, by_key: %{}, batch: 0, next_clear_at: 0}
      {_, r1} = request("q1", "a", "onion", 7)
      {_, r2} = request("q2", "a", "sugar", 7)
      m = m |> Market.put_request("q1", r1) |> Market.put_request("q2", r2)
      assert map_size(m.requests) == 2
    end
  end

  describe "cash and storage reservation" do
    test "zero-cash and full-storage buyers get nothing while a funded buyer fills" do
      st =
        state(
          %{"onion" => 1_200},
          [restaurant("a", 10_000), restaurant("b", 0), restaurant("c", 10_000, 300_000)],
          [request("qa", "a", "onion", 100), request("qb", "b", "onion", 100), request("qc", "c", "onion", 100)]
        )

      cleared = Market.clear(st)
      assert fills_by(cleared, "onion") == %{"a" => 100}

      assert Enum.sort(cleared.unfilled) == [
               %{request_id: "qb", qty: 100, reason: :insufficient_cash},
               %{request_id: "qc", qty: 100, reason: :insufficient_storage}
             ]
    end

    test "a shortfall funds a partial fill bounded by cash" do
      # cash 5 buys floor(5 * 1000 / 250) = 20 units at price 250 (cost exactly 5).
      st = state(%{"onion" => 1_200}, [restaurant("a", 5)], [request("q1", "a", "onion", 100)])
      cleared = Market.clear(st)
      assert [%{qty: 20, cost: 5}] = cleared.fills
      assert cleared.unfilled == [%{request_id: "q1", qty: 80, reason: :insufficient_cash}]
    end

    test "a shortfall funds a partial fill bounded by storage room" do
      st = state(%{"onion" => 1_200}, [restaurant("a", 10_000, 299_990)], [request("q1", "a", "onion", 100)])
      cleared = Market.clear(st)
      assert [%{qty: 10}] = cleared.fills
      assert cleared.unfilled == [%{request_id: "q1", qty: 90, reason: :insufficient_storage}]
    end

    test "cash is cumulative across a restaurant's products in product order" do
      # onion (first) costs 250/kunit, sugar 120/kunit at stock 1200 (price) -> sugar price 120.
      # Cash 30 buys 120 onion (cost 30), leaving nothing for sugar.
      st =
        state(
          %{"onion" => 1_200, "sugar" => 1_200},
          [restaurant("a", 30)],
          [request("qo", "a", "onion", 120), request("qs", "a", "sugar", 100)]
        )

      cleared = Market.clear(st)
      assert [%{product: "onion", qty: 120, cost: 30}] = cleared.fills
      assert cleared.unfilled == [%{request_id: "qs", qty: 100, reason: :insufficient_cash}]
    end

    test "storage is cumulative across a restaurant's products in product order" do
      st =
        state(
          %{"onion" => 1_200, "sugar" => 1_200},
          [restaurant("a", 1_000_000)],
          [request("qo", "a", "onion", 80), request("qs", "a", "sugar", 80)],
          capacity: 100
        )

      cleared = Market.clear(st)
      assert fills_by(cleared, "onion") == %{"a" => 80}
      assert fills_by(cleared, "sugar") == %{"a" => 20}
      assert cleared.unfilled == [%{request_id: "qs", qty: 60, reason: :insufficient_storage}]
    end

    test "budget is reserved against funded quantity, so contention frees no budget for later products" do
      st =
        state(
          %{"onion" => 10, "sugar" => 1_200},
          [restaurant("a", 40), restaurant("b", 10_000)],
          [request("qo", "a", "onion", 7), request("qb", "b", "onion", 7), request("qs", "a", "sugar", 1_000)]
        )

      cleared = Market.clear(st)
      # onion price is the 750 ceiling: 7 units cost ceil(5.25) = 6; 34 cash left buys 283 sugar at 120.
      assert fills_by(cleared, "sugar") == %{"a" => 283}
    end

    test "no fill ever costs more than the restaurant's cash or exceeds its storage room" do
      restaurants = [restaurant("a", 123), restaurant("b", 77, 299_000), restaurant("c", 9_999)]

      requests =
        for r <- ["a", "b", "c"], p <- ["onion", "sugar", "cilantro"], do: request("q#{r}#{p}", r, p, 5_000)

      st = state(%{"onion" => 900, "sugar" => 700, "cilantro" => 50}, restaurants, requests)
      cleared = Market.clear(st)

      for {id, cash, room} <- [{"a", 123, 300_000}, {"b", 77, 1_000}, {"c", 9_999, 300_000}] do
        mine = Enum.filter(cleared.fills, &(&1.restaurant_id == id))
        assert Enum.sum(Enum.map(mine, & &1.cost)) <= cash
        assert Enum.sum(Enum.map(mine, & &1.qty)) <= room
      end
    end
  end

  describe "conservation" do
    test "stock before equals fills plus stock after for every product" do
      stock = %{"onion" => 10, "sugar" => 1_200, "cilantro" => 3}

      st =
        state(
          stock,
          [restaurant("a", 10_000), restaurant("b", 10_000), restaurant("c", 10_000)],
          [
            request("q1", "a", "onion", 7),
            request("q2", "b", "onion", 7),
            request("q3", "c", "onion", 7),
            request("q4", "a", "sugar", 40),
            request("q5", "b", "cilantro", 9)
          ]
        )

      cleared = Market.clear(st)

      for {product, before} <- stock do
        filled = cleared.fills |> Enum.filter(&(&1.product == product)) |> Enum.map(& &1.qty) |> Enum.sum()
        after_stock = Market.stock_after(st.market, cleared)[product]
        assert before == filled + after_stock
        assert after_stock >= 0
      end

      # Contended products are drained exactly; an uncontended one keeps its surplus.
      assert Market.stock_after(st.market, cleared) == %{"onion" => 0, "sugar" => 1_160, "cilantro" => 0}
    end

    test "every request is accounted for as fill plus unfilled" do
      st =
        state(
          %{"onion" => 10},
          [restaurant("a", 10_000), restaurant("b", 3)],
          [request("q1", "a", "onion", 7), request("q2", "b", "onion", 50)]
        )

      cleared = Market.clear(st)

      for {rid, req} <- st.market.requests do
        filled = cleared.fills |> Enum.filter(&(&1.request_id == rid)) |> Enum.map(& &1.qty) |> Enum.sum()
        open = cleared.unfilled |> Enum.filter(&(&1.request_id == rid)) |> Enum.map(& &1.qty) |> Enum.sum()
        assert filled + open == req.qty
      end
    end

    test "an empty request book clears to nothing and still publishes prices" do
      cleared = Market.clear(state(%{"onion" => 1_200}, [], []))
      assert cleared.fills == []
      assert cleared.unfilled == []
      assert cleared.prices["onion"] == 250
    end

    test "clearing is deterministic regardless of request insertion order" do
      rs = [restaurant("a", 10_000), restaurant("b", 10_000), restaurant("c", 10_000)]
      reqs = [request("qa", "a", "onion", 7), request("qb", "b", "onion", 7), request("qc", "c", "onion", 7)]

      assert Market.clear(state(%{"onion" => 10}, rs, reqs)) ==
               Market.clear(state(%{"onion" => 10}, Enum.reverse(rs), Enum.reverse(reqs)))
    end
  end

  describe "replenish/4" do
    test "tops up toward the scaled target" do
      # onion target 400 per equivalent; scale 2.5 equivalents -> 1000.
      r = Market.replenish(catalog(), %{stock: %{"onion" => 300}}, 2_500, 2)
      assert r["onion"] == 700
    end

    test "caps deliveries at the baseline through the floor and scales the cap above it" do
      market = %{stock: %{"onion" => 100}}

      assert Market.replenish(catalog(), market, 10_000, 0)["onion"] == 1_500
      assert Market.replenish(catalog(), market, 10_000, 3)["onion"] == 1_500
      assert Market.replenish(catalog(), market, 10_000, 4)["onion"] == 2_033
      assert Market.replenish(catalog(), market, 10_000, 6)["onion"] == 3_100
      assert Market.replenish(catalog(), market, 10_000, 150)["onion"] == 3_900
    end

    test "stock above a reduced cap receives no delivery" do
      market = %{stock: %{"onion" => 3_000}}
      assert Market.replenish(catalog(), market, 10_000, 3)["onion"] == 0
    end

    test "covers every product and treats missing stock as zero" do
      r = Market.replenish(catalog(), %{stock: %{}}, 1_000, 1)
      assert map_size(r) == map_size(catalog().products)
      assert r["onion"] == 400
      assert r["cilantro"] == 100
    end
  end

  defp contains_tuple?(term) when is_tuple(term), do: true

  defp contains_tuple?(term) when is_map(term),
    do: Enum.any?(term, fn {k, v} -> contains_tuple?(k) or contains_tuple?(v) end)

  defp contains_tuple?(term) when is_list(term), do: Enum.any?(term, &contains_tuple?/1)
  defp contains_tuple?(_), do: false
end
