defmodule FeudHall.Application.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias FeudHall.Application.{CommandWorkflow, Diagnostics, Recovery}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.Diagnostics.{Exporter, MemorySink}
  alias FeudHall.Infrastructure.InMemoryEventStore

  @allowed ~w(command_id kind actor_kind outcome reason attempt position epoch hall_ms duration_us scope
              recovery_id snapshot_position skipped error_class batch_events backlog lateness_ms)a

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp open(opts \\ []) do
    {:ok, rt} = CommandWorkflow.open(InMemoryEventStore, InMemoryEventStore.new(), opts)

    {:accepted, _, rt} =
      CommandWorkflow.execute(
        rt,
        env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})
      )

    rt
  end

  defp create(rt, name, id \\ "create"),
    do:
      CommandWorkflow.execute(
        rt,
        env(
          id,
          {:principal, "alice-secret-id"},
          {:create_restaurant, %{restaurant_id: "r1", stall_id: "s1", name: name, cuisine: "mexican"}}
        )
      )

  defp outcomes(sink), do: for(%{name: :command_outcome} = r <- MemorySink.records(sink), do: r.fields)

  setup do
    {:ok, sink} = MemorySink.start_link()
    %{sink: sink}
  end

  test "records carry schema 1 and only allowlisted fields; long strings are cut", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, _} = create(rt, "Casa")
    records = MemorySink.records(sink)
    assert records != []

    for r <- records do
      assert r.schema == 1
      assert is_integer(r.at_mono)
      assert Map.keys(r.fields) -- @allowed == []
    end

    record = Diagnostics.record(:x, %{command_id: String.duplicate("a", 500), secret: "no", actor_kind: "alice-id"})
    assert byte_size(record.fields.command_id) == 128
    refute Map.has_key?(record.fields, :secret)
    refute Map.has_key?(record.fields, :actor_kind)
    assert Diagnostics.record(:x, %{actor_kind: :principal}).fields.actor_kind == :principal
  end

  test "player text and principal IDs never reach a record", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, _} = create(rt, "sentinel-secret-🌮")
    big = {:purchase_stock, %{restaurant_id: "r1", product: "rice_long", qty: 900_000, max_price_per_kunit: 1_000}}
    {:rejected, _, _} = CommandWorkflow.execute(rt, env("big", {:principal, "alice-secret-id"}, big))
    dump = inspect(MemorySink.records(sink), limit: :infinity)
    refute dump =~ "sentinel"
    refute dump =~ "alice-secret-id"
    assert Enum.any?(outcomes(sink), &(&1.actor_kind == :principal))
  end

  test "accepted is emitted only after the append; failures map to unavailable and commit_unknown", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    before = length(outcomes(sink))

    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable, _} = create(armed, "Casa")
    [last] = Enum.drop(outcomes(sink), before)
    assert last.outcome == :unavailable
    assert last.command_id == "create"
    refute Enum.any?(Enum.drop(outcomes(sink), before), &(&1.outcome == :accepted))

    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :lost_reply)}
    assert {:uncertain, "create", _} = create(armed, "Casa")
    assert List.last(outcomes(sink)).outcome == :commit_unknown
    refute Enum.any?(Enum.drop(outcomes(sink), before), &(&1.outcome == :accepted))
  end

  test "rejection, replay, conflict, and fenced outcomes", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, rt} = create(rt, "Casa")
    {:replayed, _, rt} = create(rt, "Casa")
    assert List.last(outcomes(sink)).outcome == :replayed
    {:rejected, _, rt} = CommandWorkflow.execute(rt, env("dup", {:principal, "a"}, create_cmd("Casa")))
    last = List.last(outcomes(sink))
    assert last.outcome == :rejected and is_atom(last.reason) and last.batch_events == 0
    {:error, :command_id_conflict, _} = create(rt, "Other")
    last = List.last(outcomes(sink))
    assert last.outcome == :rejected and last.reason == :command_id_conflict

    fenced = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}
    {:error, :fenced, _} = create(fenced, "Zed", "create-3")
    assert List.last(outcomes(sink)).outcome == :fenced
  end

  defp create_cmd(name),
    do: {:create_restaurant, %{restaurant_id: "r1", stall_id: "s1", name: name, cuisine: "mexican"}}

  test "recovery emits started, snapshot_skipped, completed", %{sink: sink} do
    rt = open()
    {:accepted, _, rt} = create(rt, "Casa")
    {:ok, store, id} = InMemoryEventStore.save_snapshot(rt.store, rt.position, "junk")
    {:ok, store} = InMemoryEventStore.mark_snapshot_verified(store, id)
    decode = fn _ -> {:error, :corrupt_snapshot} end

    assert {:ok, _, _} =
             Recovery.recover(InMemoryEventStore, store, "boot",
               scope: "hall:t",
               decode_snapshot: decode,
               diagnostics: {MemorySink, sink}
             )

    names = Enum.map(MemorySink.records(sink), & &1.name)
    assert hd(names) == :recovery_started
    assert :recovery_completed in names
    skipped = Enum.find(MemorySink.records(sink), &(&1.name == :snapshot_skipped))
    assert skipped.fields.reason == :corrupt_snapshot
    assert skipped.fields.snapshot_position == rt.position
    assert :recovery_failed not in names
  end

  test "recovery failure emits recovery_failed without payloads", %{sink: sink} do
    assert {:error, :invalid_owner} =
             Recovery.recover(InMemoryEventStore, InMemoryEventStore.new(), "",
               scope: "hall:t",
               diagnostics: {MemorySink, sink}
             )

    failed = Enum.find(MemorySink.records(sink), &(&1.name == :recovery_failed))
    assert failed.severity == :error
    assert failed.fields.error_class == :invalid_owner
  end

  test "a raising sink never reaches the workflow" do
    defmodule Boom do
      @behaviour FeudHall.Application.Diagnostics
      def emit(_sink, _record), do: raise("sink down")
    end

    rt = open(diagnostics: {Boom, :x})
    assert {:accepted, _, _} = create(rt, "Casa")
  end

  defp workload(diag) do
    rt = open(diagnostics: diag)
    {:accepted, _, rt} = create(rt, "Casa")

    ids = ["init", "create"]

    {rt, ids} =
      Enum.reduce(1..28, {rt, ids}, fn i, {rt, ids} ->
        id = "buy-#{rem(i, 25)}"
        qty = if rem(i, 7) == 0, do: 900_000, else: 10 + i

        cmd =
          {:purchase_stock, %{restaurant_id: "r1", product: "rice_long", qty: qty, max_price_per_kunit: 1_000}}

        {_status, _receipt, rt} = CommandWorkflow.execute(rt, env(id, {:principal, "alice-secret-id"}, cmd))
        {rt, [id | ids]}
      end)

    receipts = ids |> Enum.uniq() |> Map.new(&{&1, InMemoryEventStore.receipt(rt.store, &1)})

    %{
      state: rt.state,
      receipts: receipts,
      balances: InMemoryEventStore.projection(rt.store, :balances),
      stock: InMemoryEventStore.projection(rt.store, :stock),
      position: rt.position
    }
  end

  test "diagnostics never change hall state, receipts, or projections", %{sink: sink} do
    {:ok, exporter} =
      Exporter.start_link(export: fn _ -> raise "exporter down" end, max_queue: 5, batch: 2, timeout_ms: 1_000)

    base = workload(nil)
    assert workload({MemorySink, sink}) == base
    assert workload({Exporter, exporter}) == base
    assert length(MemorySink.records(sink)) > 30
    assert base.position > 20
  end
end
