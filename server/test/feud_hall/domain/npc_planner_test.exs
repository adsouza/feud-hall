defmodule FeudHall.Domain.NpcPlannerTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Hall, Market, PublicView, Random}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Npc.Planner

  @catalog SliceCatalog.catalog()
  @budget Enum.find(@catalog.npc_profiles, &(&1.id == "budget"))
  @premium Enum.find(@catalog.npc_profiles, &(&1.id == "premium"))
  @sentinel 777_123_457

  # A quiet hall at time 0 with only alice's starter recipe unlocked.
  defp bare_state do
    {state, _} = stocked_world(arrivals: false, unlock: false, stock: %{})
    state
  end

  defp own(state, id \\ "r1"), do: state.restaurants[id]

  defp plan(state, profile, rng \\ Random.new(7)) do
    Planner.plan(PublicView.build(state), own(state), profile, state.catalog, rng)
  end

  defp actions(state, profile), do: state |> plan(profile) |> elem(0)

  defp with_cash(state, cash), do: put_in(state, [:restaurants, "r1", :ledger, :cash], cash)
  defp closed(state), do: put_in(state, [:stalls, "s001", :mode], :closed)

  defp with_summary(state, summary),
    do:
      put_in(state, [:demand, :summaries], [
        Map.merge(%{day: 0, arrivals: 0, admitted: 0, left: %{}, trays_served: 0}, summary)
      ])

  describe "PublicView.build/1" do
    test "exposes only time, published prices and stock, stalls with public menus, and day summaries" do
      state = bare_state()
      view = PublicView.build(state)

      assert Map.keys(view) |> Enum.sort() == [:demand, :market, :now, :stalls]
      assert view.now == state.now
      assert Map.keys(view.market) |> Enum.sort() == Map.keys(state.catalog.products) |> Enum.sort()

      for {product, entry} <- view.market do
        assert entry == %{
                 price: Market.price(state.catalog, state.market, product),
                 stock: state.market.stock[product] || 0
               }
      end

      assert [%{stall_id: "s001", restaurant_id: "r1", tier: :quiet, open?: true, menu: menu}] = view.stalls
      assert menu == state.restaurants["r1"].menu
      assert view.demand == state.demand.summaries
    end

    test "never carries rival cash, batches, orders, costs or random state" do
      state = bare_state()

      rival = %{
        id: "r2",
        cuisine: "mexican",
        unlocked: ["bean_tacos"],
        menu: %{"bean_tacos" => 900},
        policies: %{},
        batches: %{"sentinel-batch" => %{product: "onion", qty: @sentinel}},
        ledger: %{cash: @sentinel}
      }

      state =
        state
        |> put_in([:restaurants, "r2"], rival)
        |> put_in([:stalls, "s002"], %{id: "s002", restaurant: "r2", tier: :quiet, mode: :open, counter: nil})
        |> put_in([:orders, "sentinel-order"], %{cost: @sentinel})
        |> put_in([:demand, :rng], @sentinel)

      view = PublicView.build(state)
      refute inspect(view, limit: :infinity) =~ Integer.to_string(@sentinel)
      refute inspect(view, limit: :infinity) =~ "sentinel"
      assert Enum.map(view.stalls, & &1.stall_id) == ["s001", "s002"]
      assert Enum.all?(view.stalls, &(Map.keys(&1) |> Enum.sort() == [:menu, :open?, :restaurant_id, :stall_id, :tier]))
    end

    test "day summaries expose only public counters" do
      state =
        bare_state()
        |> put_in([:demand, :summaries], [
          %{
            day: 0,
            arrivals: 5,
            admitted: 3,
            left: %{impatient: 2},
            trays_served: 3,
            menu_prices_median: 900,
            secret: @sentinel
          }
        ])

      assert [summary] = PublicView.build(state).demand
      assert Map.keys(summary) |> Enum.sort() == [:admitted, :arrivals, :day, :left, :menu_prices_median, :trays_served]
    end
  end

  describe "purity" do
    test "plan/5 takes no hall state and is deterministic" do
      assert {:plan, 5} in Planner.__info__(:functions)
      refute Enum.any?(Planner.__info__(:functions), fn {name, arity} -> name == :plan and arity != 5 end)

      state = bare_state() |> with_cash(10_000_000) |> closed()
      rng = Random.new(42)
      view = PublicView.build(state)

      first = Planner.plan(view, own(state), @budget, state.catalog, rng)
      assert first == Planner.plan(view, own(state), @budget, state.catalog, rng)
      assert {[_ | _], ^rng} = first
    end
  end

  describe "heuristics" do
    test "opens a closed stall outside cleaning, never during cleaning" do
      state = bare_state() |> closed()
      assert {:open_stall, %{stall_id: "s001"}} in actions(state, @budget)

      cleaning = %{state | now: 3 * 3_600_000 + 1_000}
      refute Enum.any?(actions(cleaning, @budget), &match?({:open_stall, _}, &1))

      open = bare_state()
      refute Enum.any?(actions(open, @budget), &match?({:open_stall, _}, &1))
    end

    test "unlocks the cheapest locked recipe only with cash of at least four times its cost" do
      state = bare_state()

      cheapest =
        state.catalog.recipes
        |> Map.values()
        |> Enum.filter(&(&1.cuisine == "mexican" and not &1.starter))
        |> Enum.min_by(&{&1.unlock_cost, &1.id})

      short = with_cash(state, cheapest.unlock_cost * 4 - 1)
      refute Enum.any?(actions(short, @budget), &match?({:unlock_recipe, _}, &1))

      enough = with_cash(state, cheapest.unlock_cost * 4)

      assert {:unlock_recipe, %{restaurant_id: "r1", recipe_id: cheapest.id}} in actions(enough, @budget)
      assert Enum.count(actions(enough, @budget), &match?({:unlock_recipe, _}, &1)) == 1
    end

    test "prices every unlocked recipe at the suggested price scaled by the profile" do
      {state, _} = stocked_world(arrivals: false, stock: %{})

      for profile <- [@budget, @premium] do
        prices =
          for {:set_menu_price, %{restaurant_id: "r1", recipe_id: id, price: price}} <- actions(state, profile),
              into: %{},
              do: {id, price}

        expected =
          Map.new(own(state).unlocked, fn id ->
            {id, div(state.catalog.recipes[id].suggested_price * profile.price_permille, 1000)}
          end)

        # Skips menu lines that already carry the target price.
        assert prices == Map.reject(expected, fn {id, price} -> own(state).menu[id] == price end)
        assert map_size(prices) > 0
      end
    end

    test "does not reprice a line already at its target price" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      menu = Map.new(own(state).unlocked, &{&1, div(state.catalog.recipes[&1].suggested_price * 1000, 1000)})
      state = put_in(state, [:restaurants, "r1", :menu], menu)
      refute Enum.any?(actions(state, %{@budget | price_permille: 1000}), &match?({:set_menu_price, _}, &1))
    end

    test "sets the profile's substitution policy on each line with a substitute that differs" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      acts = actions(state, @budget)

      policies = for {:set_substitution_policy, p} <- acts, do: p
      assert Enum.all?(policies, &(&1.policy == :prefer_substitute and &1.restaurant_id == "r1"))

      expected =
        for id <- Enum.sort(own(state).unlocked),
            line <- state.catalog.recipes[id].lines,
            line.substitute != nil,
            do: {id, line.line_id}

      assert Enum.map(policies, &{&1.recipe_id, &1.line_id}) == expected
      assert expected != []

      # Lines already carrying the policy are left alone; primary_only is the default.
      assert Enum.filter(actions(state, @premium), &match?({:set_substitution_policy, _}, &1)) == []
    end

    test "restocks the menu's products from expected use over restock_days, capped by storage and bounds" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      state = with_summary(state, %{admitted: 30, trays_served: 30})

      requests = for {:submit_purchase_request, p} <- actions(state, @budget), do: p
      assert requests != []

      assert Enum.all?(
               requests,
               &(&1.restaurant_id == "r1" and &1.qty in 1..1_000_000 and &1.max_price_per_kunit in 1..1_000_000_000)
             )

      assert Enum.map(requests, & &1.product) == Enum.sort(Enum.map(requests, & &1.product))

      view = PublicView.build(state)

      for r <- requests do
        assert r.max_price_per_kunit == div(view.market[r.product].price * 1500, 1000)
      end

      # Larger observed demand never requests less.
      busier = with_summary(state, %{admitted: 300, trays_served: 300})
      bigger = for {:submit_purchase_request, p} <- actions(busier, @budget), into: %{}, do: {p.product, p.qty}
      smaller = Map.new(requests, &{&1.product, &1.qty})
      assert Enum.all?(smaller, fn {product, qty} -> Map.get(bigger, product, 0) >= qty end)
      assert Enum.any?(smaller, fn {product, qty} -> Map.get(bigger, product, 0) > qty end)
    end

    test "never requests more than storage room allows" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      state = with_summary(state, %{admitted: 10_000_000, trays_served: 10_000_000})
      requests = for {:submit_purchase_request, p} <- actions(state, @budget), do: p

      used =
        Enum.sum(for r <- requests, do: FeudHall.Domain.Inventory.storage_for(state.catalog, r.product, r.qty))

      assert used <= state.catalog.rules.storage_capacity
      assert Enum.all?(requests, &(&1.qty <= 1_000_000))
    end

    test "with no day summary yet it still restocks a deterministic minimum" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      assert state.demand.summaries == []
      assert Enum.any?(actions(state, @budget), &match?({:submit_purchase_request, _}, &1))
    end

    test "stock on hand reduces the request" do
      {state, _} = stocked_world(arrivals: false, stock: %{})
      acts = for {:submit_purchase_request, p} <- actions(state, @budget), do: p
      %{product: product, qty: qty} = hd(acts)

      stocked =
        put_in(state, [:restaurants, "r1", :batches], %{
          "b1" => %{id: "b1", product: product, qty: qty * 10, expires_at: 10 ** 12, unit_cost: 1, received_at: 0}
        })

      refute Enum.any?(actions(stocked, @budget), &match?({:submit_purchase_request, %{product: ^product}}, &1))
    end

    test "actions are exactly decider commands that the hall accepts" do
      {state, _} = stocked_world(arrivals: false, unlock: false, stock: %{})
      state = state |> with_cash(10_000_000) |> closed()

      for action <- actions(state, @budget) do
        assert {:ok, _} = Hall.decide(state, action, ctx(owner(), "check"))
      end
    end
  end

  describe "choose_slot/3" do
    @layout %{"a1" => :quiet, "a2" => :quiet, "b1" => :standard, "c1" => :prime}

    defp view_with(slots), do: %{stalls: Enum.map(slots, &%{stall_id: &1})}

    test "takes the first vacant slot of the preferred tier by slot ID" do
      assert Planner.choose_slot(view_with([]), @layout, %{preferred_tier: :quiet}) == "a1"
      assert Planner.choose_slot(view_with(["a1"]), @layout, %{preferred_tier: :quiet}) == "a2"
      assert Planner.choose_slot(view_with([]), @layout, %{preferred_tier: :prime}) == "c1"
    end

    test "falls back to the first vacant slot of any tier by slot ID" do
      assert Planner.choose_slot(view_with(["a1", "a2"]), @layout, %{preferred_tier: :quiet}) == "b1"
      assert Planner.choose_slot(view_with(["c1"]), @layout, %{preferred_tier: :prime}) == "a1"
    end

    test "is nil when the hall is full" do
      assert Planner.choose_slot(view_with(Map.keys(@layout)), @layout, %{preferred_tier: :quiet}) == nil
    end

    test "works against the real layout and a view built from state" do
      state = bare_state()
      view = PublicView.build(state)
      assert Planner.choose_slot(view, state.layout, @budget) == "s002"
      assert Planner.choose_slot(view, state.layout, @premium) == "s136"
    end
  end
end
