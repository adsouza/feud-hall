defmodule FeudHall.Infrastructure.PostgresEventStoreTest do
  use FeudHall.PostgresCase

  alias FeudHall.Application.CommandWorkflow
  alias FeudHall.Application.Replay
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall
  alias FeudHall.Infrastructure.PostgresEventStore

  use FeudHall.EventStoreContract, adapter: PostgresEventStore, fresh: &FeudHall.PostgresCase.fresh_store/0

  import FeudHall.PostgresCase, only: [fresh_store: 0]

  # A request against an empty store; callers override the expectations once the store has history.
  defp request(overrides \\ []) do
    id = Keyword.get(overrides, :command_id, "a")
    events = Keyword.get(overrides, :events, [%{type: :clock_advanced, to: 24}])

    Map.merge(
      %{
        command_id: id,
        expected_position: 0,
        expected_versions: %{hall: 0, control: 0},
        hall_stream: "hall:h1",
        events: events,
        control_events: [],
        receipt: %{command_id: id, fingerprint: "fp-" <> id, kind: :advance_clock, outcome: :accepted},
        outbox: [],
        projection_rows: [],
        context: %{actor: {:system, :scheduler}, correlation_id: "corr-" <> id, content_hash: nil, hall_ms: 24}
      },
      Map.new(Keyword.drop(overrides, [:command_id, :events]))
    )
  end

  defp next_request(store, overrides) do
    hall_stream = Keyword.get(overrides, :hall_stream, "hall:h1")

    request(
      [
        expected_position: PostgresEventStore.head(store),
        expected_versions: PostgresEventStore.stream_versions(store, hall_stream)
      ] ++ overrides
    )
  end

  defp count(table), do: Repo.query!("select count(*) from #{table}").rows |> hd() |> hd()

  defp assert_nothing_written(store) do
    assert PostgresEventStore.head(store) == 0
    assert PostgresEventStore.receipt(store, "a") == :none
    assert PostgresEventStore.stream_versions(store, "hall:h1") == %{hall: 0, control: 0}
    assert count("batches") == 0
    assert count("events") == 0
    assert count("receipts") == 0
  end

  defp initialized_event(hall_id) do
    {:ok, [event]} =
      Hall.decide(nil, {:initialize_hall, %{hall_id: hall_id, catalog: SliceCatalog.catalog()}}, %{
        command_id: "init-" <> hall_id,
        actor: {:system, :admin}
      })

    event
  end

  test "paged replay folds a full cut and refuses corruption across a page boundary" do
    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: [initialized_event("h1")]))

    store =
      Enum.reduce(2..133, store, fn position, store ->
        attrs = [command_id: "page-#{position}", events: [%{type: :clock_advanced, to: position * 24}]]
        assert {:ok, store, ^position} = PostgresEventStore.append(store, next_request(store, attrs))
        store
      end)

    assert {:ok, [%{position: 128}, %{position: 129}]} = PostgresEventStore.read_page(store, 127, 129, 5)
    assert {:ok, %{position: 133, tail_batches: 133, hall: %{now: 3192}}} = Replay.load(PostgresEventStore, store)
    Repo.query!("update events set payload = '{}' where position = 129")
    assert {:error, {:undecodable, 129, _}} = Replay.load(PostgresEventStore, store)
  end

  describe "failure injection" do
    test "before-commit, unavailable, and fenced failures write nothing and are one-shot" do
      for {mode, reason} <- [before_commit: :unavailable, unavailable: :unavailable, fenced: :fenced] do
        store = PostgresEventStore.fail_next(fresh_store(), mode)
        assert {:error, ^reason, store} = PostgresEventStore.append(store, request())
        assert_nothing_written(store)

        assert {:ok, _, 1} = PostgresEventStore.append(store, request())
        FeudHall.PostgresCase.reset!()
      end
    end

    test "a lost reply commits the batch but reports an unknown outcome" do
      store = PostgresEventStore.fail_next(fresh_store(), :lost_reply)
      assert {:error, :unknown_outcome, store} = PostgresEventStore.append(store, request())
      assert PostgresEventStore.head(store) == 1
      assert {:ok, %{position: 1}} = PostgresEventStore.receipt(store, "a")

      # The injection was one-shot.
      assert {:ok, _, 2} = PostgresEventStore.append(store, next_request(store, command_id: "b"))
    end
  end

  describe "authority" do
    test "each acquisition returns a higher epoch and fences the previous holder" do
      old = fresh_store()
      assert old.epoch == 1
      assert {:ok, new, 2} = PostgresEventStore.acquire_authority(old, "hall:test", "node-b")
      assert %{scope: "hall:test", owner: "node-b", epoch: 2} = new

      assert {:error, :fenced, _} = PostgresEventStore.append(old, request())
      assert_nothing_written(old)
      assert {:ok, _, 1} = PostgresEventStore.append(new, request())
    end

    test "a superseded holder whose head is also stale is told it is fenced, not conflicting" do
      old = fresh_store()
      assert {:ok, new, 2} = PostgresEventStore.acquire_authority(old, "hall:test", "node-b")
      assert {:ok, _, 1} = PostgresEventStore.append(new, request())

      # `old` still expects position 0: both checks fail, and fencing is reported.
      assert {:error, :fenced, _} = PostgresEventStore.append(old, request(command_id: "b"))
      assert PostgresEventStore.head(old) == 1
    end

    test "a store that never acquired authority is fenced" do
      store = PostgresEventStore.new(Repo, "hall:test")
      assert {:error, :fenced, _} = PostgresEventStore.append(store, request())
      assert_nothing_written(store)
    end

    test "authority is per scope" do
      store = fresh_store()
      assert {:ok, other, 1} = PostgresEventStore.acquire_authority(store, "hall:other", "node-b")
      assert {:ok, store, 1} = PostgresEventStore.append(store, request())
      assert {:ok, _, 2} = PostgresEventStore.append(other, next_request(store, command_id: "b"))
    end
  end

  test "event envelopes record their stream, version, actor, causation, and correlation" do
    store = fresh_store()

    assert {:ok, _, 1} =
             PostgresEventStore.append(
               store,
               request(
                 events: [%{type: :clock_advanced, to: 24}, %{type: :clock_advanced, to: 48}],
                 control_events: [%{type: :availability_started, epoch_id: "e1"}],
                 context: %{actor: {:principal, "alice"}, correlation_id: "corr-a", content_hash: "abc", hall_ms: 48}
               )
             )

    assert %{rows: rows} =
             Repo.query!("""
             select event_id, position, batch_order, stream, stream_version, type, schema, actor,
                    causation_id, correlation_id, content_hash, hall_ms
             from events order by batch_order
             """)

    assert rows == [
             ["1:0", 1, 0, "hall:h1", 1, "clock_advanced", 1, "principal:alice", "a", "corr-a", "abc", 48],
             ["1:1", 1, 1, "hall:h1", 2, "clock_advanced", 1, "principal:alice", "a", "corr-a", "abc", 48],
             ["1:2", 1, 2, "control", 1, "availability_started", 1, "principal:alice", "a", "corr-a", "abc", 48]
           ]

    assert %{rows: [[1, "a", 48]]} = Repo.query!("select position, command_id, hall_ms from batches")
  end

  test "outbox intents commit with their batch position and command" do
    store = fresh_store()
    outbox = [%{dedupe_key: "mail:1", kind: :test_notice, payload: %{to: "alice"}}]
    assert {:ok, _, 1} = PostgresEventStore.append(store, request(outbox: outbox))

    assert %{rows: [["mail:1", "a", 1, "test_notice"]]} =
             Repo.query!("select dedupe_key, command_id, position, kind from outbox")
  end

  test "content is stored once by hash and rehydrated on read" do
    first = initialized_event("h1")
    second = initialized_event("h2")
    assert first.catalog == second.catalog

    store = fresh_store()
    {:ok, other, _} = PostgresEventStore.acquire_authority(store, "hall:other", "node-b")

    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: [first]))

    assert {:ok, _, 2} =
             PostgresEventStore.append(
               other,
               next_request(store, command_id: "b", hall_stream: "hall:h2", events: [second])
             )

    assert count("content") == 1
    assert %{rows: [[content_hash]]} = Repo.query!("select content_hash from content")
    assert content_hash == first.content_hash

    # The stored payload references the catalog instead of repeating it.
    %{rows: payloads} = Repo.query!("select payload from events")
    for [payload] <- payloads, do: refute(payload =~ "substitution_penalty_cap")

    assert {:ok, [%{events: [^first]}, %{events: [^second]}]} = PostgresEventStore.read_from(store, 0)
  end

  test "missing content blocks reading with its position" do
    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: [initialized_event("h1")]))
    Repo.query!("delete from content")

    assert {:error, {:undecodable, 1, {:missing_content, _hash}}} = PostgresEventStore.read_from(store, 0)
  end

  test "an unknown stored event type blocks reading with its position" do
    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request())
    Repo.query!("update events set payload = $1", [~s({"v":1,"e":{"type":{"$a":"launch_missiles"}}})])

    assert {:error, {:undecodable, 1, {:unknown_atom, "launch_missiles"}}} = PostgresEventStore.read_from(store, 0)
  end

  # An external term naming an atom no module defines: built from bytes (SMALL_ATOM_UTF8_EXT), so
  # the atom itself is never created and `binary_to_term/2` with `[:safe]` refuses it.
  defp unknown_atom_term do
    name = "feud_hall_never_defined_" <> Integer.to_string(System.unique_integer([:positive]))
    <<131, 119, byte_size(name), name::binary>>
  end

  test "a receipt naming an atom this build does not define is an error, not a raise" do
    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request())
    Repo.query!("update receipts set body = $1 where command_id = 'a'", [Base.encode64(unknown_atom_term())])

    assert PostgresEventStore.receipt(store, "a") == {:error, {:undecodable_receipt, "a"}}

    # The workflow reports it for a retry of that ID instead of crashing its caller.
    # The receipt lookup comes before any decision, so the head's state does not matter here.
    head = %{hall: nil, control: nil, position: 1, versions: PostgresEventStore.stream_versions(store, nil)}
    {:ok, rt} = CommandWorkflow.from_state(PostgresEventStore, store, head)
    envelope = %{command_id: "a", actor: {:system, :scheduler}, command: {:advance_clock, %{to_service_ms: 1}}}
    assert {:error, {:undecodable_receipt, "a"}, _rt} = CommandWorkflow.execute(rt, envelope)
  end

  test "an outbox payload naming an atom this build does not define is an error, not a raise" do
    store = fresh_store()
    outbox = [%{dedupe_key: "mail:1", kind: :test_notice, payload: %{to: "alice"}}]
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(outbox: outbox))
    Repo.query!("update outbox set payload = $1", [Base.encode64(unknown_atom_term())])

    assert PostgresEventStore.outbox(store) == {:error, {:undecodable_outbox, "mail:1"}}
  end

  test "content naming an atom this build does not define blocks reading with its position" do
    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: [initialized_event("h1")]))
    %{rows: [[old_ref]]} = Repo.query!("select content_hash from content")

    # A body whose hash still matches its reference, so only decoding can refuse it.
    body = unknown_atom_term()
    new_ref = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    Repo.query!("update content set content_hash = $1, body = $2", [new_ref, body])
    Repo.query!("update events set payload = replace(payload, $1, $2)", [old_ref, new_ref])

    assert {:error, {:undecodable, 1, {:undecodable_content, ^new_ref}}} = PostgresEventStore.read_from(store, 0)
  end

  test "a 10,000-event batch commits in one transaction" do
    store = fresh_store()
    events = for i <- 1..10_000, do: %{type: :clock_advanced, to: i * 24}
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: events))
    assert {:ok, [%{events: read}]} = PostgresEventStore.read_from(store, 0)
    assert length(read) == 10_000
    assert read == events
    assert PostgresEventStore.stream_versions(store, "hall:h1") == %{hall: 10_000, control: 0}
  end

  test "player text with NUL, emoji, and quotes round-trips exactly through the store" do
    name = "Casa \u0000 \"Ñ\" 🌮 'x' \\ $1"
    event = %{type: :restaurant_created, restaurant_id: "r1", owner: "alice", name: name}

    store = fresh_store()
    assert {:ok, store, 1} = PostgresEventStore.append(store, request(events: [event]))
    assert {:ok, [%{events: [^event]}]} = PostgresEventStore.read_from(store, 0)
  end

  test "a restaurant name with emoji and quotes round-trips through the workflow" do
    name = "Casa \"Ñ\" 🌮 'x'"
    {:ok, rt} = CommandWorkflow.open(PostgresEventStore, fresh_store())

    {:accepted, _, rt} =
      CommandWorkflow.execute(rt, %{
        command_id: "init",
        actor: {:system, :admin},
        command: {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}}
      })

    {:accepted, _, rt} =
      CommandWorkflow.execute(rt, %{
        command_id: "create",
        actor: {:principal, "alice"},
        command: {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: name, cuisine: "sichuan"}}
      })

    assert {:ok, reopened} = CommandWorkflow.open(PostgresEventStore, rt.store)
    assert reopened.state.restaurants["r1"].name == name
    assert reopened.state == rt.state
    assert reopened.versions == rt.versions
    assert reopened.position == rt.position
  end

  test "a connection lost while committing is an unknown outcome that resolves by the same ID" do
    store = %{fresh_store() | repo: FeudHall.CommitDropRepo}

    assert {:error, :unknown_outcome, store} = PostgresEventStore.append(store, request())

    # The batch did commit: the head advanced and the receipt resolves by the original ID.
    assert PostgresEventStore.head(store) == 1
    assert {:ok, %{command_id: "a", position: 1}} = PostgresEventStore.receipt(store, "a")
    assert {:ok, [%{position: 1, command_id: "a"}]} = PostgresEventStore.read_from(store, 0)
  end

  test "a connection lost before the transaction body finishes is a proven rollback" do
    store = fresh_store()

    lost =
      PostgresEventStore.new(Repo, store.scope,
        epoch: store.epoch,
        hooks: %{before_commit: fn -> raise DBConnection.ConnectionError, "lost" end}
      )

    assert {:error, :unavailable, _} = PostgresEventStore.append(lost, request())
    assert_nothing_written(store)
  end

  test "each batch records its event count, and a batch missing event rows stops reading there" do
    store = fresh_store()
    events = [%{type: :clock_advanced, to: 24}, %{type: :clock_advanced, to: 48}]

    {:ok, store, 1} =
      PostgresEventStore.append(store, request(events: events, control_events: [%{type: :clock_advanced, to: 1}]))

    {:ok, store, 2} = PostgresEventStore.append(store, next_request(store, command_id: "b"))
    assert [[1, 3], [2, 1]] = Repo.query!("select position, event_count from batches order by position").rows

    Repo.query!("delete from events where position = 1 and batch_order = 1")
    assert PostgresEventStore.read_from(store, 0) == {:error, {:undecodable, 1, {:event_count_mismatch, 3, 2}}}
    assert {:ok, [%{position: 2}]} = PostgresEventStore.read_from(store, 1)

    Repo.query!("delete from events where position = 2")
    assert PostgresEventStore.read_from(store, 1) == {:error, {:undecodable, 2, {:event_count_mismatch, 1, 0}}}

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("insert into batches (position, command_id, event_count) values (9, 'empty', 0)")
  end

  @tag :capture_log
  test "a refused connection is reported as unavailable" do
    start_supervised!(FeudHall.UnreachableRepo)
    unreachable = PostgresEventStore.new(FeudHall.UnreachableRepo, "hall:test", epoch: 1)

    assert {:error, :unavailable, ^unreachable} = PostgresEventStore.append(unreachable, request())
    assert {:error, :unavailable} = PostgresEventStore.acquire_authority(unreachable, "hall:test", "node-a")
    assert {:error, :unavailable} = PostgresEventStore.read_from(unreachable, 0)
    assert {:error, :unavailable} = PostgresEventStore.snapshots(unreachable)
    assert {:error, :unavailable} = PostgresEventStore.head(unreachable)
    assert {:error, :unavailable} = PostgresEventStore.stream_versions(unreachable, "hall:h1")
    assert {:error, :unavailable} = PostgresEventStore.receipt(unreachable, "a")
    assert {:error, :unavailable} = PostgresEventStore.acquire_authority(unreachable, "hall:test", "node-a", 1)
  end
end
