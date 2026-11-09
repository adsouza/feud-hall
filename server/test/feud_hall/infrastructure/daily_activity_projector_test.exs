defmodule FeudHall.Infrastructure.DailyActivityProjectorTest do
  use FeudHall.PostgresCase

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.Postgres.DailyActivityProjector, as: Projector
  alias FeudHall.Infrastructure.PostgresEventStore, as: Store

  defp run!(rt, id, actor, command, observed \\ nil) do
    assert {:accepted, _receipt, rt} =
             Workflow.execute(rt, %{command_id: id, actor: actor, command: command}, observed)

    rt
  end

  defp world(visits) do
    catalog = SliceCatalog.catalog()
    alice = {:principal, "alice"}
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
      rt
      |> run!("unlock", alice, {:unlock_recipe, %{restaurant_id: "r1", recipe_id: "chicken_tacos"}})
      |> run!(
        "price",
        alice,
        {:set_menu_price,
         %{restaurant_id: "r1", recipe_id: "chicken_tacos", price: catalog.recipes["chicken_tacos"].suggested_price}}
      )

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

    rt = run!(rt, "open", alice, {:open_stall, %{stall_id: "s1"}})

    Enum.reduce(1..visits, rt, fn n, rt ->
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

  defp activity,
    do: Repo.query!("select day, restaurant_id, visits_admitted, trays_accepted from daily_activity order by 1, 2").rows

  defp checkpoint,
    do: Repo.query!("select position from projector_checkpoints where name = 'daily_activity'").rows

  # Independent oracle: count the events straight off the decoded log.
  defp counted(store) do
    {:ok, batches} = Store.read_from(store, 0)

    for %{hall_ms: ms, events: events} <- batches,
        ms != nil,
        %{type: type, restaurant_id: r} <- events,
        type in [:visit_admitted, :tray_accepted],
        reduce: %{} do
      acc -> Map.update(acc, {FeudHall.Domain.Clock.day_of(ms), r, type}, 1, &(&1 + 1))
    end
  end

  test "an empty log catches up to position 0 and creates the checkpoint" do
    assert checkpoint() == []
    assert {:ok, 0} = Projector.catch_up(Repo)
    assert checkpoint() == [[0]]
    assert activity() == []
  end

  test "totals equal a direct count over the events, across several read pages" do
    rt = world(4)
    head = Store.head(rt.store)

    assert {:ok, ^head} = Projector.catch_up(Repo, batch_size: 3)
    assert checkpoint() == [[head]]

    oracle = counted(rt.store)
    assert map_size(oracle) > 0

    projected =
      for [day, r, visits, trays] <- activity(), reduce: %{} do
        acc -> acc |> Map.put({day, r, :visit_admitted}, visits) |> Map.put({day, r, :tray_accepted}, trays)
      end

    assert Map.reject(projected, fn {_, n} -> n == 0 end) == oracle
    assert Enum.sum(for [_, _, v, _] <- activity(), do: v) == 4
  end

  test "running catch_up twice changes nothing" do
    world(2)
    assert {:ok, head} = Projector.catch_up(Repo)
    rows = activity()
    assert [_ | _] = rows

    assert {:ok, ^head} = Projector.catch_up(Repo)
    assert activity() == rows
    assert checkpoint() == [[head]]
  end

  test "catch_up resumes from the checkpoint after more commands commit" do
    rt = world(2)
    assert {:ok, first} = Projector.catch_up(Repo)

    run!(
      rt,
      "visit-more",
      {:system, :demand},
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: "dx",
         budget: 10_000,
         stall_id: "s1",
         main: "chicken_tacos",
         drink: nil,
         profile_id: "unrestricted"
       }}
    )

    assert {:ok, second} = Projector.catch_up(Repo)
    assert second > first
    assert Enum.sum(for [_, _, v, _] <- activity(), do: v) == 3
  end

  test "delivering the same batch twice adds it once" do
    rt = world(1)
    {:ok, batches} = Store.read_from(rt.store, 0)
    batch = Enum.find(batches, fn b -> Enum.any?(b.events, &(&1.type == :visit_admitted)) end)

    Repo.query!("insert into projector_checkpoints (name, position) values ('daily_activity', $1)", [
      batch.position - 1
    ])

    assert :applied = Projector.apply_batch(Repo, batch)
    once = activity()
    assert [[_, "r1", 1, 1]] = once

    assert :skipped = Projector.apply_batch(Repo, batch)
    assert activity() == once
    assert checkpoint() == [[batch.position]]
  end

  defp project(projected) do
    for [day, r, visits, trays] <- projected, reduce: %{} do
      acc -> acc |> Map.put({day, r, :visit_admitted}, visits) |> Map.put({day, r, :tray_accepted}, trays)
    end
    |> Map.reject(fn {_, n} -> n == 0 end)
  end

  test "batch positions in a world are contiguous from 1 to the head" do
    rt = world(3)
    {:ok, batches} = Store.read_from(rt.store, 0)
    assert Enum.map(batches, & &1.position) == Enum.to_list(1..Store.head(rt.store))
  end

  test "a batch delivered ahead of the checkpoint is skipped, and catch_up then applies the gap in order" do
    rt = world(3)
    {:ok, batches} = Store.read_from(rt.store, 0)
    {early, [gap, ahead]} = Enum.split(batches, -2)
    assert Enum.any?(ahead.events, &(&1.type == :visit_admitted))

    Repo.query!("insert into projector_checkpoints (name, position) values ('daily_activity', 0)")
    for batch <- early, do: assert(:applied = Projector.apply_batch(Repo, batch))
    assert checkpoint() == [[gap.position - 1]]
    rows = activity()

    assert :skipped = Projector.apply_batch(Repo, ahead)
    assert checkpoint() == [[gap.position - 1]]
    assert activity() == rows

    head = Store.head(rt.store)
    assert {:ok, ^head} = Projector.catch_up(Repo)
    assert project(activity()) == counted(rt.store)
  end

  test "killing the projector inside the transaction leaves deltas and checkpoint unapplied" do
    rt = world(2)
    head = Store.head(rt.store)
    assert {:ok, _} = Projector.catch_up(Repo, batch_size: 1_000_000)
    rows = activity()
    before = checkpoint()
    assert before == [[head]]

    # Rewind to an empty projection, then replay from 0 in a process that is killed mid-transaction.
    Repo.query!("truncate daily_activity")
    Repo.query!("update projector_checkpoints set position = 0")

    test = self()

    pid =
      spawn(fn ->
        Projector.catch_up(Repo,
          before_checkpoint: fn ->
            send(test, {:in_transaction, self()})
            receive do: (:never -> :ok)
          end
        )
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    ref = Process.monitor(pid)

    assert_receive {:in_transaction, ^pid}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    assert activity() == []
    assert checkpoint() == [[0]]

    # The killed transaction's locks are gone: a fresh catch_up applies everything exactly once.
    assert {:ok, ^head} = Projector.catch_up(Repo)
    assert activity() == rows
    assert checkpoint() == [[head]]
  end

  test "rebuild reproduces the same rows from an empty projection" do
    world(3)
    assert {:ok, head} = Projector.catch_up(Repo)
    rows = activity()
    assert [_ | _] = rows

    assert {:ok, ^head} = Projector.rebuild(Repo)
    assert activity() == rows
    assert checkpoint() == [[head]]
  end

  test "the projector does not block appends" do
    rt = world(1)
    parent = self()

    pid =
      spawn(fn ->
        Projector.catch_up(Repo,
          before_checkpoint: fn ->
            send(parent, :held)
            receive do: (:release -> :ok)
          end
        )
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :held, 5_000

    run!(
      rt,
      "visit-while-projecting",
      {:system, :demand},
      {:admit_visit,
       %{
         source: :simulated,
         diner_id: "dy",
         budget: 10_000,
         stall_id: "s1",
         main: "chicken_tacos",
         drink: nil,
         profile_id: "unrestricted"
       }}
    )

    send(pid, :release)
  end
end
