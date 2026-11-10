defmodule FeudHall.Domain.SliceCatalogTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Content, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.EventCodec

  @menus [
    {"mughlai_punjabi", "chole_with_rice", "sweet_lassi", "gulab_jamun"},
    {"sichuan", "vegetarian_mapo_tofu_with_rice", "jasmine_tea", "brown_sugar_bingfen"},
    {"levantine", "falafel_wrap", "mint_lemonade", "knafeh"}
  ]

  test "the versioned catalog covers each cuisine and all mains participate in diner preferences" do
    catalog = SliceCatalog.catalog()
    recipes = Map.values(catalog.recipes)
    assert :ok = Content.validate(catalog)
    assert Enum.frequencies_by(recipes, & &1.cuisine) == Map.new(@menus, fn {id, _, _, _} -> {id, 5} end)

    mains = MapSet.new(for %{kind: :main, id: id} <- recipes, do: id)

    for segment <- catalog.rules.demand.segments do
      assert MapSet.new(Map.keys(segment.main_preference)) == mains
    end
  end

  for {cuisine, main, drink, dessert} <- @menus do
    @tag menu: {cuisine, main, drink, dessert}
    test "#{cuisine} starts, buys ingredients, and serves all three courses through shared rules", %{menu: menu} do
      {cuisine, main, drink, dessert} = menu
      catalog = quiet_catalog(SliceCatalog.catalog())

      world =
        {nil, []}
        |> run!({:initialize_hall, %{hall_id: "h1", catalog: catalog}}, {:system, :admin}, "init")
        |> run!(
          {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: "Alice", cuisine: cuisine}},
          owner(),
          "create"
        )

      {state, _} = world
      assert %{cuisine: ^cuisine, unlocked: [^main]} = state.restaurants["r1"]
      {_, foreign_main, _, _} = Enum.find(@menus, fn {other, _, _, _} -> other != cuisine end)
      assert :wrong_cuisine == reject!(world, unlock(foreign_main), owner(), "foreign-unlock")

      ingredients =
        for id <- [main, drink, dessert], line <- catalog.recipes[id].lines, reduce: %{} do
          quantities -> Map.update(quantities, line.product, line.qty, &(&1 + line.qty))
        end

      {state, events} =
        world
        |> run!(unlock(drink), owner(), "unlock-drink")
        |> run!(unlock(dessert), owner(), "unlock-dessert")
        |> price(catalog, drink)
        |> price(catalog, dessert)
        |> stock(ingredients)
        |> run!({:open_stall, %{stall_id: "s001"}}, owner(), "open")
        |> simulated_visit("diner", main, drink, "unrestricted", 10_000, true)
        |> serve_tray(tray_id("visit-diner"))
        |> then(fn {state, _} = world -> serve_dessert(world, state.visits[visit_id("visit-diner")].dessert_order) end)

      assert %{components: components} = visit_outcome({state, events}, visit_id("visit-diner"))
      assert [%{components: tray_orders}] = Enum.filter(events, &(&1.type == :tray_accepted))
      assert [%{order: dessert_order}] = Enum.filter(events, &(&1.type == :dessert_accepted))
      orders = tray_orders ++ [dessert_order]
      assert Enum.map(orders, & &1.recipe_id) == [main, drink, dessert]
      assert Enum.map(components, &{&1.order_id, &1.outcome}) == Enum.map(orders, &{&1.order_id, :served})

      decoded =
        Enum.map(events, fn event ->
          assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
          event
        end)

      assert Hall.replay(decoded) === state
    end
  end

  defp unlock(id), do: {:unlock_recipe, %{restaurant_id: "r1", recipe_id: id}}

  defp price(world, catalog, id) do
    command = {:set_menu_price, %{restaurant_id: "r1", recipe_id: id, price: catalog.recipes[id].suggested_price}}
    run!(world, command, owner(), "price-" <> id)
  end
end
