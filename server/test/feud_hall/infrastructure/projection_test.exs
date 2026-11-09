defmodule FeudHall.Infrastructure.ProjectionTest do
  use FeudHall.PostgresCase

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall
  alias FeudHall.Infrastructure.PostgresEventStore, as: Store

  @recipes ~w(chicken_tacos vegetable_quesadilla arroz_con_leche horchata)

  defp run!(rt, id, actor, command, observed \\ nil) do
    assert {:accepted, _receipt, rt} =
             Workflow.execute(rt, %{command_id: id, actor: actor, command: command}, observed)

    rt
  end

  # Two restaurants, a stocked kitchen, and several simulated visits, all through the workflow.
  defp busy_world do
    catalog = SliceCatalog.catalog()
    alice = {:principal, "alice"}
    bob = {:principal, "bob"}
    {:ok, rt} = Workflow.open(Store, FeudHall.PostgresCase.fresh_store())

    rt = run!(rt, "init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: catalog}})
    rt = run!(rt, "start:e1", {:system, :authority}, {:start_availability, %{epoch_id: "e1"}}, 0)

    rt =
      run!(
        rt,
        "create-r1",
        alice,
        {:create_restaurant, %{restaurant_id: "r1", stall_id: "s1", name: "Casa Alice", cuisine: "mexican"}}
      )

    rt =
      run!(
        rt,
        "create-r2",
        bob,
        {:create_restaurant, %{restaurant_id: "r2", stall_id: "s2", name: "Casa Bob", cuisine: "mexican"}}
      )

    rt =
      Enum.reduce(@recipes, rt, fn recipe, rt ->
        rt
        |> run!("unlock-" <> recipe, alice, {:unlock_recipe, %{restaurant_id: "r1", recipe_id: recipe}})
        |> run!(
          "price-" <> recipe,
          alice,
          {:set_menu_price, %{restaurant_id: "r1", recipe_id: recipe, price: catalog.recipes[recipe].suggested_price}}
        )
      end)

    rt =
      FeudHall.Fixtures.default_stock()
      |> Enum.sort()
      |> Enum.reduce(rt, fn {product, qty}, rt ->
        run!(
          rt,
          "buy-" <> product,
          alice,
          {:purchase_stock, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}}
        )
      end)

    rt =
      run!(
        rt,
        "buy-r2-rice",
        bob,
        {:purchase_stock, %{restaurant_id: "r2", product: "rice_long", qty: 50, max_price_per_kunit: 1_000_000_000}}
      )

    rt = run!(rt, "open", alice, {:open_stall, %{stall_id: "s1"}})

    Enum.reduce(1..4, rt, fn n, rt ->
      run!(
        rt,
        "visit-#{n}",
        {:system, :demand},
        {:admit_visit,
         %{
           source: :simulated,
           diner_id: "d#{n}",
           budget: 10_000,
           stall_id: "s1",
           main: "chicken_tacos",
           drink: nil,
           profile_id: "unrestricted"
         }}
      )
    end)
  end

  defp tables, do: [:balances, :stock]

  defp fold_state(store) do
    {:ok, batches} = Store.read_from(store, 0)
    batches |> Enum.flat_map(& &1.events) |> Hall.replay()
  end

  defp expected_balances(state) do
    for {id, restaurant} <- state.restaurants, {account, amount} <- restaurant.ledger do
      {id, account, amount}
    end
    |> Enum.sort()
  end

  defp balance_values(store),
    do: for(%{restaurant_id: r, account: a, amount: m} <- Store.projection(store, :balances), do: {r, a, m})

  defp counts do
    for table <- ~w(events receipts outbox batches), into: %{} do
      %{rows: [[n]]} = Repo.query!("select count(*) from #{table}")
      {table, n}
    end
  end

  test "projections written with each batch equal the fold's ledger for every restaurant" do
    rt = busy_world()
    state = fold_state(rt.store)

    assert state == rt.state
    assert Enum.sort(balance_values(rt.store)) == expected_balances(state)

    stock =
      for %{restaurant_id: r, product: p, on_hand: o, reserved: res} <- Store.projection(rt.store, :stock),
          do: {r, p, o, res}

    assert [_ | _] = stock
    assert Enum.any?(stock, fn {_, _, _, reserved} -> reserved > 0 end)
  end

  test "rebuilding leaves the projection values identical" do
    rt = busy_world()
    head = Store.head(rt.store)
    before = Map.new(tables(), &{&1, Store.projection(rt.store, &1)})
    strip = fn rows -> Enum.map(rows, &Map.delete(&1, :position)) end

    assert :ok = Store.rebuild_projections(rt.store)

    for table <- tables() do
      after_rows = Store.projection(rt.store, table)
      assert strip.(after_rows) == strip.(before[table])
      assert Enum.all?(after_rows, &(&1.position == head))
    end

    rebuilt = Map.new(tables(), &{&1, Store.projection(rt.store, &1)})
    assert :ok = Store.rebuild_projections(rt.store)
    assert Map.new(tables(), &{&1, Store.projection(rt.store, &1)}) == rebuilt
  end

  test "deleting only projection rows and rebuilding restores them without touching the log" do
    rt = busy_world()
    head = Store.head(rt.store)
    before = Map.new(tables(), &{&1, Store.projection(rt.store, &1)})
    counts_before = counts()

    Repo.query!("delete from restaurant_balances")
    Repo.query!("delete from restaurant_stock")
    assert Store.projection(rt.store, :balances) == []
    assert Store.projection(rt.store, :stock) == []

    assert :ok = Store.rebuild_projections(rt.store)

    strip = fn rows -> Enum.map(rows, &Map.delete(&1, :position)) end

    for table <- tables() do
      rebuilt = Store.projection(rt.store, table)
      assert [_ | _] = rebuilt
      assert strip.(rebuilt) == strip.(before[table])
      # A rebuild cannot know which batch last changed a row, so every row carries the head.
      assert Enum.all?(rebuilt, &(&1.position == head))
    end

    assert counts() == counts_before
    assert Enum.sort(balance_values(rt.store)) == expected_balances(rt.state)
  end

  test "an empty log rebuilds to empty projections" do
    store = FeudHall.PostgresCase.fresh_store()
    assert :ok = Store.rebuild_projections(store)
    assert Store.projection(store, :balances) == []
  end

  test "a rebuilt store keeps accepting commands and projecting them" do
    rt = busy_world()
    assert :ok = Store.rebuild_projections(rt.store)

    rt =
      run!(
        rt,
        "buy-more",
        {:principal, "alice"},
        {:purchase_stock, %{restaurant_id: "r1", product: "rice_long", qty: 10, max_price_per_kunit: 1_000_000_000}}
      )

    assert Enum.sort(balance_values(rt.store)) == expected_balances(rt.state)
  end
end
