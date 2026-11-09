defmodule FeudHall.Infrastructure.InMemoryEventStoreTest do
  use ExUnit.Case, async: true

  alias FeudHall.Infrastructure.InMemoryEventStore

  use FeudHall.EventStoreContract, adapter: InMemoryEventStore, fresh: &InMemoryEventStore.new/0

  defp request(store, id) do
    %{
      command_id: id,
      expected_position: InMemoryEventStore.head(store),
      expected_versions: InMemoryEventStore.stream_versions(store, "hall:h1"),
      hall_stream: "hall:h1",
      events: [%{type: :clock_advanced, to: 24}],
      control_events: [],
      receipt: %{command_id: id, fingerprint: "f", outcome: :accepted},
      outbox: [],
      projection_rows: [],
      context: %{actor: {:system, :scheduler}, correlation_id: id, content_hash: nil, hall_ms: 24}
    }
  end

  describe "failure injection" do
    test "before-commit, unavailable, and fenced failures write nothing and are one-shot" do
      for {mode, reason} <- [before_commit: :unavailable, unavailable: :unavailable, fenced: :fenced] do
        store = InMemoryEventStore.fail_next(InMemoryEventStore.new(), mode)
        assert {:error, ^reason, store} = InMemoryEventStore.append(store, request(store, "a"))
        assert InMemoryEventStore.head(store) == 0
        assert InMemoryEventStore.receipt(store, "a") == :none
        assert InMemoryEventStore.stream_versions(store, "hall:h1") == %{hall: 0, control: 0}
        assert {:ok, _, 1} = InMemoryEventStore.append(store, request(store, "a"))
      end
    end

    test "an armed unavailable failure also refuses log and snapshot reads until an append clears it" do
      store = InMemoryEventStore.new()
      {:ok, store, _} = InMemoryEventStore.save_snapshot(store, 0, "body")
      down = InMemoryEventStore.fail_next(store, :unavailable)

      assert InMemoryEventStore.read_from(down, 0) == {:error, :unavailable}
      assert InMemoryEventStore.snapshots(down) == {:error, :unavailable}

      assert {:error, :unavailable, up} = InMemoryEventStore.append(down, request(down, "a"))
      assert InMemoryEventStore.read_from(up, 0) == {:ok, []}
      assert [%{body: "body"}] = InMemoryEventStore.snapshots(up)
    end

    test "a lost reply commits the batch but reports an unknown outcome" do
      store = InMemoryEventStore.fail_next(InMemoryEventStore.new(), :lost_reply)
      assert {:error, :unknown_outcome, store} = InMemoryEventStore.append(store, request(store, "a"))
      assert InMemoryEventStore.head(store) == 1
      assert {:ok, %{position: 1}} = InMemoryEventStore.receipt(store, "a")
    end
  end

  test "each authority acquisition returns a higher epoch" do
    store = InMemoryEventStore.new()
    assert {:ok, store, 1} = InMemoryEventStore.acquire_authority(store, "hall:h1", "node-a")
    assert {:ok, _store, 2} = InMemoryEventStore.acquire_authority(store, "hall:h1", "node-b")
  end

  test "snapshots belong to the store value that saved them" do
    empty = InMemoryEventStore.new()
    {:ok, saved, _id} = InMemoryEventStore.save_snapshot(empty, 0, "one")

    assert [%{position: 0}] = InMemoryEventStore.snapshots(saved)
    assert InMemoryEventStore.snapshots(empty) == []
  end
end
