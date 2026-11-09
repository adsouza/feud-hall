defmodule FeudHall.Application.CommandWorkflowTest do
  # Not async: the "on PostgreSQL" cases share the test database.
  use ExUnit.Case, async: false

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.{Control, Money}
  alias FeudHall.Infrastructure.{EventCodec, InMemoryEventStore, PostgresEventStore, Snapshot}

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp runtime(store_mod \\ InMemoryEventStore, store \\ InMemoryEventStore.new()) do
    {:ok, rt} = Workflow.open(store_mod, store)

    {:accepted, _, rt} =
      Workflow.execute(
        rt,
        env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})
      )

    {:accepted, _, rt} =
      Workflow.execute(
        rt,
        env(
          "create",
          {:principal, "alice"},
          {:create_restaurant, %{restaurant_id: "r1", stall_id: "s1", name: "Casa", cuisine: "mexican"}}
        )
      )

    rt
  end

  defp purchase(qty),
    do: {:purchase_stock, %{restaurant_id: "r1", product: "rice_long", qty: qty, max_price_per_kunit: 1_000}}

  test "an identical retry returns the original receipt without a second purchase" do
    rt = runtime()
    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    cash = rt.state.restaurants["r1"].ledger.cash

    assert {:replayed, ^receipt, rt2} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert rt2.state.restaurants["r1"].ledger.cash == cash
    assert rt2.position == rt.position
  end

  test "changed content or actor under the same command ID is a conflict" do
    rt = runtime()
    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert {:error, :command_id_conflict} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(101)))
    assert {:error, :command_id_conflict} = Workflow.execute(rt, env("buy-1", {:principal, "bob"}, purchase(100)))
  end

  test "rejections keep their original result and append no domain events" do
    rt = runtime()
    head = rt.position
    {:rejected, receipt, rt} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(900_000)))
    assert receipt.outcome == {:rejected, :insufficient_storage}
    assert rt.position == head
    assert {:replayed, ^receipt, _} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(900_000)))
  end

  describe "control stream" do
    @authority {:system, :authority}

    defp started(rt) do
      {:accepted, _, rt} =
        Workflow.execute(rt, env("start:e1", @authority, {:start_availability, %{epoch_id: "e1"}}))

      rt
    end

    defp reconcile(id), do: env(id, @authority, {:reconcile_recovery, %{recovery_id: "recovery:e1"}})

    test "reconciliation appends control and hall events in one batch" do
      rt = started(runtime())
      before = rt.versions

      assert {:accepted, receipt, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert receipt.event_count == 2
      assert {:ok, batches} = InMemoryEventStore.read_from(rt.store, rt.position - 1)
      assert [%{events: [%{type: :hall_resumed}], control_events: [%{type: :availability_resumed}]}] = batches
      assert rt.versions == %{hall: before.hall + 1, control: before.control + 1}
      assert rt.state.last_recovery_id == "recovery:e1"
      assert Control.pending_recovery_id(rt.control) == "recovery:e1"
    end

    test "owners retrying the same recovery get the original receipt; a new command ID is already reconciled" do
      rt = started(runtime())
      {:accepted, receipt, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:replayed, ^receipt, _} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:rejected, %{outcome: {:rejected, :already_reconciled}}, _} = Workflow.execute(rt, reconcile("rec-2"))
    end

    test "start_availability works on an empty store and reconcile there is rejected" do
      {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())
      rt = started(rt)
      assert rt.versions == %{hall: 0, control: 1}
      assert Control.pending_recovery_id(rt.control) == "recovery:e1"

      assert {:rejected, %{outcome: {:rejected, :hall_not_initialized}}, _} = Workflow.execute(rt, reconcile("rec-1"))
    end

    test "a non-authority actor is refused and reopening replays the control stream" do
      rt = runtime()

      assert {:rejected, %{outcome: {:rejected, :forbidden}}, _} =
               Workflow.execute(rt, env("s", {:system, :admin}, {:start_availability, %{epoch_id: "e9"}}))

      rt = started(rt)
      {:accepted, _, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:ok, reopened} = Workflow.open(InMemoryEventStore, rt.store)
      assert reopened.control == rt.control
      assert reopened.versions == rt.versions
      assert reopened.state == rt.state
    end
  end

  test "malformed envelopes and unknown commands never reach the domain or storage" do
    rt = runtime()
    assert {:error, :unknown_command} = Workflow.execute(rt, env("x", {:principal, "alice"}, {:drop_tables, %{}}))
    assert {:error, :unauthenticated} = Workflow.execute(rt, env("x", {:principal, ""}, purchase(1)))
    assert {:error, :malformed_envelope} = Workflow.execute(rt, %{command_id: 7})
    assert {:error, :unauthenticated} = Workflow.execute(rt, env("x", {:system, :root}, purchase(1)))
  end

  test "a failure before commit leaves nothing; retrying the same ID then succeeds once" do
    rt = runtime()
    failing = %{rt | store: InMemoryEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable} = Workflow.execute(failing, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert InMemoryEventStore.receipt(failing.store, "buy-1") == :none

    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert map_size(rt.state.restaurants["r1"].batches) == 1
  end

  test "a lost reply is uncertain, blocks new commands, and resolves by the same ID" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :lost_reply)}
    {:uncertain, "buy-1", stuck} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
    # The in-memory head did not apply the batch, and new work is refused.
    assert stuck.state.restaurants["r1"].batches == %{}
    assert {:error, :recovery_required} = Workflow.execute(stuck, env("buy-2", {:principal, "alice"}, purchase(5)))

    assert {:committed, receipt, recovered} = Workflow.resolve(stuck, "buy-1")
    assert receipt.outcome == :accepted
    assert map_size(recovered.state.restaurants["r1"].batches) == 1
    # Retrying the original ID returns the original receipt, not a second fill.
    assert {:replayed, _, _} = Workflow.execute(recovered, env("buy-1", {:principal, "alice"}, purchase(100)))
  end

  test "a stale expected position conflicts instead of appending a competing batch" do
    rt = runtime()
    store = rt.store

    request = fn store, id, to ->
      %{
        command_id: id,
        expected_position: rt.position,
        expected_versions: rt.versions,
        hall_stream: "hall:h1",
        events: [%{type: :clock_advanced, to: to}],
        control_events: [],
        receipt: %{fingerprint: "x", outcome: :accepted},
        outbox: [],
        projection_rows: [],
        context: %{actor: {:system, :scheduler}, correlation_id: id, content_hash: nil, hall_ms: to}
      }
      |> then(&InMemoryEventStore.append(store, &1))
    end

    assert {:ok, store2, _} = request.(store, "a", 24)

    # A second writer that read the old head must not append.
    assert {:error, :conflict, _} = request.(store2, "b", 48)

    # A workflow holding the stale head reports the conflict without evolving.
    stale = %{rt | store: store2}
    assert {:error, :conflict} = Workflow.execute(stale, env("buy-9", {:principal, "alice"}, purchase(1)))
  end

  test "a fenced append stops the runtime" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}

    assert {:error, :fenced, fenced} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert fenced.mode == :fenced
    assert fenced.state == rt.state
    assert fenced.position == rt.position
    assert fenced.versions == rt.versions
    assert InMemoryEventStore.receipt(fenced.store, "buy-1") == :none

    # The injected failure was one-shot, so only the runtime's mode refuses further work,
    # and every later fenced result has the same shape and leaves the runtime unchanged.
    assert {:error, :fenced, ^fenced} = Workflow.execute(fenced, env("buy-1", {:principal, "alice"}, purchase(100)))

    assert {:error, :fenced, ^fenced} =
             Workflow.execute(fenced, env("buy-2", {:principal, "alice"}, purchase(5)), 60_000)

    assert {:error, :fenced, ^fenced} = Workflow.resolve(fenced, "buy-1")
  end

  test "a fenced clock advance stops the runtime before the command is decided" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}

    assert {:error, :fenced, fenced} =
             Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)), 60_000)

    assert fenced.mode == :fenced
    assert fenced.position == rt.position
    assert fenced.versions == rt.versions
    assert InMemoryEventStore.receipt(fenced.store, "adv:buy-1") == :none
  end

  test "an accepted command commits its projection rows and stream versions with the batch" do
    rt = runtime()
    assert rt.versions.hall == length(Enum.flat_map(elem(InMemoryEventStore.read_from(rt.store, 0), 1), & &1.events))

    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    ledger = rt.state.restaurants["r1"].ledger

    assert %{restaurant_id: "r1", account: :cash, amount: ledger.cash, position: receipt.position} in InMemoryEventStore.projection(
             rt.store,
             :balances
           )

    assert [%{restaurant_id: "r1", product: "rice_long", on_hand: 100, reserved: 0}] =
             InMemoryEventStore.projection(rt.store, :stock)

    assert InMemoryEventStore.stream_versions(rt.store, "hall:h1") == rt.versions
    assert {:ok, [_ | _] = batches} = InMemoryEventStore.read_from(rt.store, 0)
    assert List.last(batches).hall_ms == rt.state.now
  end

  test "a rejected initialization against an empty store records only its receipt" do
    {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())
    {:rejected, _receipt, rt} = Workflow.execute(rt, env("buy-0", {:principal, "alice"}, purchase(1)))
    assert rt.state == nil
    assert rt.position == 0
    assert rt.versions == %{hall: 0, control: 0}
  end

  test "due clock work commits as its own batch before the command is decided" do
    rt = runtime()
    head = rt.position
    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 60_000)
    assert {:ok, %{kind: :advance_clock}} = InMemoryEventStore.receipt(rt.store, "adv:buy-1")
    assert receipt.position == head + 2
    assert rt.state.now == 60_000 * 24
  end

  test "the store replays to the same head the workflow holds" do
    rt = runtime()
    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 1_000)
    assert {:ok, reopened} = Workflow.open(InMemoryEventStore, rt.store)
    assert reopened.state == rt.state
    assert reopened.versions == rt.versions
    assert reopened.position == rt.position
  end

  describe "on PostgreSQL" do
    setup do
      FeudHall.PostgresCase.reset!()
    end

    defp pg_runtime, do: runtime(PostgresEventStore, FeudHall.PostgresCase.fresh_store())

    test "an identical retry returns the stored receipt; changed content conflicts" do
      rt = pg_runtime()
      {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      cash = rt.state.restaurants["r1"].ledger.cash

      assert {:ok, ^receipt} = PostgresEventStore.receipt(rt.store, "buy-1")
      assert {:replayed, ^receipt, rt2} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert rt2.state.restaurants["r1"].ledger.cash == cash
      assert rt2.position == rt.position
      assert PostgresEventStore.head(rt.store) == rt.position

      assert {:error, :command_id_conflict} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(101)))
    end

    test "a rejection keeps its stored receipt and appends no batch" do
      rt = pg_runtime()
      head = rt.position
      {:rejected, receipt, rt} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(900_000)))
      assert receipt.outcome == {:rejected, :insufficient_storage}
      assert PostgresEventStore.head(rt.store) == head
      assert {:replayed, ^receipt, _} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(900_000)))
    end

    test "a failure before commit leaves nothing; retrying the same ID then succeeds once" do
      rt = pg_runtime()
      failing = %{rt | store: PostgresEventStore.fail_next(rt.store, :before_commit)}
      assert {:error, :unavailable} = Workflow.execute(failing, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert PostgresEventStore.receipt(rt.store, "buy-1") == :none
      assert PostgresEventStore.head(rt.store) == rt.position

      {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert map_size(rt.state.restaurants["r1"].batches) == 1
    end

    test "a lost reply is uncertain, blocks new commands, and resolves by the same ID" do
      rt = pg_runtime()
      armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :lost_reply)}
      {:uncertain, "buy-1", stuck} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert stuck.state.restaurants["r1"].batches == %{}
      assert {:error, :recovery_required} = Workflow.execute(stuck, env("buy-2", {:principal, "alice"}, purchase(5)))

      assert {:committed, receipt, recovered} = Workflow.resolve(stuck, "buy-1")
      assert receipt.outcome == :accepted
      assert map_size(recovered.state.restaurants["r1"].batches) == 1
      assert {:replayed, _, _} = Workflow.execute(recovered, env("buy-1", {:principal, "alice"}, purchase(100)))
    end

    test "the store replays to the head and projections the in-memory workflow reaches" do
      commands = [
        {env("buy-1", {:principal, "alice"}, purchase(10)), 1_000},
        {env("start:e1", {:system, :authority}, {:start_availability, %{epoch_id: "e1"}}), nil},
        {env("buy-2", {:principal, "alice"}, purchase(20)), 2_000}
      ]

      run = fn rt ->
        Enum.reduce(commands, rt, fn {envelope, observed}, rt ->
          {:accepted, _, rt} = Workflow.execute(rt, envelope, observed)
          rt
        end)
      end

      pg = run.(pg_runtime())
      memory = run.(runtime())

      assert {:ok, reopened} = Workflow.open(PostgresEventStore, pg.store)
      assert reopened.state == memory.state
      assert reopened.control == memory.control
      assert reopened.versions == memory.versions
      assert reopened.position == memory.position
      assert PostgresEventStore.read_from(pg.store, 0) == InMemoryEventStore.read_from(memory.store, 0)

      assert PostgresEventStore.projection(pg.store, :balances) ==
               InMemoryEventStore.projection(memory.store, :balances)

      assert PostgresEventStore.projection(pg.store, :stock) == InMemoryEventStore.projection(memory.store, :stock)
    end
  end

  describe "codec and snapshots" do
    test "events round-trip through JSON exactly" do
      rt = runtime()
      {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 1_000)

      {:ok, batches} = InMemoryEventStore.read_from(rt.store, 0)

      for batch <- batches, event <- batch.events do
        assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
      end
    end

    test "unknown atoms and schema versions block decoding instead of being skipped" do
      assert {:error, {:unknown_atom, "launch_missiles"}} =
               EventCodec.decode(~s({"v":1,"e":{"type":{"$a":"launch_missiles"}}}))

      assert {:error, {:unsupported_schema, 2}} = EventCodec.decode(~s({"v":2,"e":{}}))
      assert_raise ArgumentError, fn -> EventCodec.encode!(%{type: :not_allowlisted}) end
    end

    test "corrupt or incompatible snapshots are rejected for fallback" do
      rt = runtime()
      snap = Snapshot.take(%{hall: rt.state, control: nil}, rt.position)
      assert {:ok, %{position: _, state: state}} = Snapshot.load(snap)
      assert state == %{hall: rt.state, control: nil}
      <<first, rest::binary>> = snap
      assert {:error, :corrupt_snapshot} = Snapshot.load(<<Bitwise.bxor(first, 1), rest::binary>>)
      assert {:error, :corrupt_snapshot} = Snapshot.load("short")
    end

    test "money crosses the client boundary as canonical decimal strings beyond JS safe integers" do
      big = 9_007_199_254_740_993
      assert Money.to_canonical(big) == "9007199254740993"
      assert {:ok, ^big} = Money.parse("9007199254740993")

      for bad <- ["01", "+5", "1.0", "1e3", " 1", "-0", "", "99999999999999999999"],
          do: assert({:error, :invalid_money} = Money.parse(bad))
    end
  end
end
