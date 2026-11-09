defmodule FeudHall.Application.CommandWorkflowTest do
  use ExUnit.Case, async: true

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Money
  alias FeudHall.Infrastructure.{EventCodec, InMemoryEventStore, Snapshot}

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp runtime do
    rt = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())

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
    receipt = %{fingerprint: "x", outcome: :accepted}

    assert {:ok, store2, _} =
             InMemoryEventStore.append(store, rt.position, "a", [%{type: :clock_advanced, to: 24}], receipt)

    # A second writer that read the old head must not append.
    assert {:error, :conflict, _} =
             InMemoryEventStore.append(store2, rt.position, "b", [%{type: :clock_advanced, to: 48}], receipt)

    # A workflow holding the stale head reports the conflict without evolving.
    stale = %{rt | store: store2}
    assert {:error, :conflict} = Workflow.execute(stale, env("buy-9", {:principal, "alice"}, purchase(1)))
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
    assert Workflow.open(InMemoryEventStore, rt.store).state == rt.state
  end

  describe "codec and snapshots" do
    test "events round-trip through JSON exactly" do
      rt = runtime()
      {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 1_000)

      for batch <- InMemoryEventStore.read_from(rt.store, 0), event <- batch.events do
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
      snap = Snapshot.take(rt.state, rt.position)
      assert {:ok, %{position: _, state: state}} = Snapshot.load(snap)
      assert state == rt.state
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
