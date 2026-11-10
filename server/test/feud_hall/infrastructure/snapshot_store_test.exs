defmodule FeudHall.Infrastructure.SnapshotStoreTest do
  # PostgreSQL-only snapshot behaviour: saving never waits on the append-head lock, the evolution
  # version is read from the binary, and a stored row damaged byte-for-byte fails to load.
  use FeudHall.PostgresCase

  alias FeudHall.Infrastructure.{PostgresEventStore, Snapshot}

  import FeudHall.PostgresCase, only: [fresh_store: 0]

  @moduletag :capture_log
  @guard_ms 15_000

  defp snapshot(position), do: Snapshot.take(%{hall: nil, control: nil}, position)

  defp request do
    %{
      command_id: "a",
      expected_position: 0,
      expected_versions: %{hall: 0, control: 0},
      hall_stream: "hall:h1",
      events: [%{type: :clock_advanced, to: 24}],
      control_events: [],
      receipt: %{command_id: "a", fingerprint: "fp-a", kind: :advance_clock, outcome: :accepted},
      outbox: [],
      projection_rows: [],
      context: %{actor: {:system, :scheduler}, correlation_id: "corr-a", content_hash: nil, hall_ms: 24}
    }
  end

  test "a saved snapshot is unverified until marked, then listed among the verified" do
    store = fresh_store()
    {:ok, store, first} = PostgresEventStore.save_snapshot(store, 3, snapshot(3))
    {:ok, store, second} = PostgresEventStore.save_snapshot(store, 7, snapshot(7))

    assert [%{id: ^second, verified: false}, %{id: ^first, verified: false}] = PostgresEventStore.snapshots(store)
    assert {:ok, store} = PostgresEventStore.mark_snapshot_verified(store, first)

    assert [%{id: ^first}] = Enum.filter(PostgresEventStore.snapshots(store), & &1.verified)
  end

  test "the stored evolution comes from the binary" do
    store = fresh_store()
    {:ok, store, _} = PostgresEventStore.save_snapshot(store, 1, snapshot(1))
    {:ok, _store, _} = PostgresEventStore.save_snapshot(store, 2, "not a snapshot")

    assert [[0], [4]] = Repo.query!("select evolution from snapshots order by id").rows |> Enum.sort()
    assert Snapshot.evolution_version() == 4
  end

  test "pruning in PostgreSQL keeps the two newest verified and every newer unverified snapshot" do
    store = fresh_store()

    ids =
      for position <- 1..5 do
        {:ok, ^store, id} = PostgresEventStore.save_snapshot(store, position, snapshot(position))
        id
      end

    for id <- Enum.take(ids, 2) ++ [Enum.at(ids, 3)],
        do: {:ok, _} = PostgresEventStore.mark_snapshot_verified(store, id)

    assert {:ok, ^store} = PostgresEventStore.prune_snapshots(store)
    assert Enum.map(PostgresEventStore.snapshots(store), & &1.position) == [5, 4, 3, 2]
  end

  test "a snapshot with one flipped stored byte fails to load as corrupt" do
    store = fresh_store()
    {:ok, store, id} = PostgresEventStore.save_snapshot(store, 3, snapshot(3))

    Repo.query!(
      "update snapshots set body = set_byte(body, 40, get_byte(body, 40) # 1) where id = $1",
      [id]
    )

    assert [%{body: body}] = PostgresEventStore.snapshots(store)
    assert {:error, :corrupt_snapshot} = Snapshot.load(body)
  end

  test "an evolution 1 snapshot is incompatible" do
    body = :erlang.term_to_binary(%{position: 3, evolution: 1, state: nil}, [:deterministic])
    old = <<:crypto.hash(:sha256, body)::binary, body::binary>>

    assert {:error, :incompatible_snapshot} = Snapshot.load(old)

    store = fresh_store()
    {:ok, store, _} = PostgresEventStore.save_snapshot(store, 3, old)
    assert [%{body: ^old}] = PostgresEventStore.snapshots(store)
    assert Repo.query!("select evolution from snapshots").rows == [[1]]
  end

  test "restore replays hall and control events after the snapshot position" do
    snap = Snapshot.take(%{hall: nil, control: nil}, 0)
    batch = %{position: 1, events: [], control_events: [%{type: :availability_started, epoch_id: "e1"}]}

    assert {:ok, %{hall: nil, control: control}} = Snapshot.restore(snap, [batch])
    assert control != nil
  end

  test "saving a snapshot does not wait on a writer holding the append-head lock" do
    test = self()

    hook = fn ->
      send(test, {:locked, self()})

      receive do
        :release -> :ok
      end
    end

    writer_store = %{fresh_store() | hooks: %{before_commit: hook, lost_reply: false, refuse: nil}}
    {:ok, writer} = Task.start_link(fn -> PostgresEventStore.append(writer_store, request()) end)

    on_exit(fn -> Process.exit(writer, :kill) end)

    receive do
      {:locked, ^writer} -> :ok
    after
      @guard_ms -> flunk("the writer never reached its commit point")
    end

    store = sibling(writer_store)
    saver = Task.async(fn -> PostgresEventStore.save_snapshot(store, 0, snapshot(0)) end)
    assert {:ok, _, id} = Task.await(saver, @guard_ms)
    assert is_integer(id)

    send(writer, :release)
    assert PostgresEventStore.head(store) in [0, 1]
  end

  defp sibling(store), do: PostgresEventStore.new(Repo, store.scope, owner: store.owner, epoch: store.epoch)
end
