defmodule FeudHall.Domain.LaunchCatalogTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Content, Hall}
  alias FeudHall.Domain.Content.LaunchCatalog
  alias FeudHall.Domain.Hall.Invariants

  test "all launch cuisines serve their starter, drink and later dessert with funded wholesale stock" do
    catalog = quiet_catalog(LaunchCatalog.catalog())
    assert :ok = Content.validate(catalog)

    cuisines = catalog.recipes |> Map.values() |> Enum.group_by(& &1.cuisine)
    assert map_size(cuisines) == 25
    assert map_size(catalog.recipes) == 125

    for {cuisine, recipes} <- cuisines do
      assert %{main: 3, dessert: 1, drink: 1} == Enum.frequencies_by(recipes, & &1.kind)
      [starter] = Enum.filter(recipes, & &1.starter)
      drink = Enum.find(recipes, &(&1.kind == :drink))
      dessert = Enum.find(recipes, &(&1.kind == :dessert))

      operator = {:npc, "budget"}

      world =
        run!(
          {nil, []},
          {:initialize_hall, %{hall_id: "launch", catalog: catalog, managed: true}},
          {:system, :admin},
          "init"
        )
        |> run!(
          {:create_restaurant, %{stall_id: "s001", restaurant_id: "r1", name: "Launch counter", cuisine: cuisine}},
          operator,
          "create"
        )
        |> run!({:open_stall, %{stall_id: "s001"}}, operator, "open")

      world =
        Enum.reduce([drink, dessert], world, fn recipe, world ->
          world
          |> run!({:unlock_recipe, %{restaurant_id: "r1", recipe_id: recipe.id}}, operator, "unlock-" <> recipe.id)
          |> run!(
            {:set_menu_price, %{restaurant_id: "r1", recipe_id: recipe.id, price: recipe.suggested_price}},
            operator,
            "price-" <> recipe.id
          )
        end)

      lines = Enum.flat_map([starter, drink, dessert], & &1.lines)
      quantities = Enum.reduce(lines, %{}, fn line, qs -> Map.update(qs, line.product, line.qty, &(&1 + line.qty)) end)

      world =
        Enum.reduce(quantities, world, fn {product, qty}, world ->
          run!(
            world,
            {:submit_purchase_request,
             %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000}},
            operator,
            "buy-" <> product
          )
        end)
        |> advance_hall(4 * Clock.minute())
        |> simulated_visit("diner", starter.id, drink.id, "unrestricted", 10_000, true)
        |> advance_hall(40 * Clock.minute())

      {state, events} = world
      assert %{served_mains: 1, served_drinks: 1, served_desserts: 1, finalized_visits: 1} = state.stats

      assert state.restaurants["r1"].ledger.revenue ==
               starter.suggested_price + drink.suggested_price + dessert.suggested_price

      assert :ok = Invariants.check(state)
      assert Hall.replay(events) == state
    end
  end

  test "Maori's unlockable mains buy their own ingredients and serve through their station" do
    catalog = quiet_catalog(LaunchCatalog.catalog())
    npc = {:npc, "budget"}

    for id <- ~w(hangi_style_chicken green_lipped_mussel_fritters) do
      recipe = catalog.recipes[id]

      world =
        run!(
          {nil, []},
          {:initialize_hall, %{hall_id: "maori", catalog: catalog, managed: true}},
          {:system, :admin},
          "init"
        )
        |> run!(
          {:create_restaurant, %{stall_id: "s001", restaurant_id: "r1", name: "Maori", cuisine: "maori"}},
          npc,
          "create"
        )
        |> run!({:unlock_recipe, %{restaurant_id: "r1", recipe_id: id}}, npc, "unlock")
        |> run!({:set_menu_price, %{restaurant_id: "r1", recipe_id: id, price: recipe.suggested_price}}, npc, "price")
        |> run!({:open_stall, %{stall_id: "s001"}}, npc, "open")

      world =
        Enum.reduce(recipe.lines, world, fn line, world ->
          run!(
            world,
            {:submit_purchase_request,
             %{restaurant_id: "r1", product: line.product, qty: line.qty, max_price_per_kunit: 1_000_000}},
            npc,
            "buy-" <> line.product
          )
        end)

      {state, events} =
        world
        |> advance_hall(4 * Clock.minute())
        |> simulated_visit("diner", id, nil, "unrestricted", 10_000, false)
        |> advance_hall(40 * Clock.minute())

      assert state.stats.served_mains == 1
      assert state.restaurants["r1"].ledger.revenue == recipe.suggested_price
      assert :ok = Invariants.check(state)
      assert Hall.replay(events) == state
    end
  end

  describe "rooms" do
    alias FeudHall.Domain.Content.SliceCatalog

    @rooms %{version: 1, count: 10, per_room: 15, scarcity_cap_permille: 1_500, class_gap: 100}

    test "the launch catalog is version 3 with room data and a validating layout" do
      catalog = LaunchCatalog.catalog()
      assert catalog.version == 3
      assert :ok = Content.validate(catalog)
      assert catalog.rules.rooms == @rooms
      assert Enum.all?(catalog.layout, &(&1.room in 1..10 and &1.position in 0..14))
      assert Enum.find(catalog.npc_profiles, &(&1.id == "premium")).preferred_tier == :standard
      assert Enum.find(catalog.npc_profiles, &(&1.id == "budget")).preferred_tier == :quiet
      assert Enum.find(catalog.npc_profiles, &(&1.id == "mainstream")).preferred_tier == :standard
    end

    test "the slice catalog has no room data and keeps its profiles" do
      slice = SliceCatalog.catalog()
      refute Map.has_key?(slice.rules, :rooms)
      refute Enum.any?(slice.layout, &Map.has_key?(&1, :room))
      assert :ok = Content.validate(slice)
      assert Enum.find(slice.npc_profiles, &(&1.id == "premium")).preferred_tier == :prime
    end

    defp problems(catalog) do
      {:error, problems} = Content.validate(catalog)
      problems
    end

    defp tweak_spot(catalog, slot_id, fun),
      do: %{catalog | layout: Enum.map(catalog.layout, &if(&1.slot_id == slot_id, do: fun.(&1), else: &1))}

    test "room data problems are reported when the rooms rule is present" do
      catalog = LaunchCatalog.catalog()

      assert {:layout, :slot_without_room, "s001"} in problems(tweak_spot(catalog, "s001", &Map.delete(&1, :room)))
      assert {:layout, :room_out_of_range, "s001"} in problems(tweak_spot(catalog, "s001", &%{&1 | room: 11}))
      assert {:layout, :position_out_of_range, "s001"} in problems(tweak_spot(catalog, "s001", &%{&1 | position: 15}))

      duplicate = tweak_spot(catalog, "s002", &%{&1 | room: 1, position: 0})
      assert {:layout, :duplicate_position, {1, 0}} in problems(duplicate)
    end

    test "rooms rule values must be present and positive" do
      catalog = LaunchCatalog.catalog()

      missing = put_in(catalog.rules.rooms, Map.delete(@rooms, :scarcity_cap_permille))
      assert {:rules, :rooms, :scarcity_cap_permille} in problems(missing)

      zero = put_in(catalog.rules.rooms, %{@rooms | class_gap: 0})
      assert {:rules, :rooms, :class_gap} in problems(zero)
    end
  end
end
