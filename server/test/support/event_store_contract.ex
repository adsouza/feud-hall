defmodule FeudHall.EventStoreContract do
  @moduledoc """
  Sequential contract cases every `FeudHall.Application.EventStore` adapter must pass.

      use FeudHall.EventStoreContract, adapter: Mod, fresh: fn -> store end

  The cases use only the port callbacks, never adapter internals, so the
  in-memory and PostgreSQL adapters are held to the same behaviour. `fresh`
  returns a new, empty store whose authority (if any) is already held.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    fresh = Keyword.fetch!(opts, :fresh)

    quote do
      @contract_adapter unquote(adapter)
      @contract_hall "hall:contract"

      defp contract_fresh, do: unquote(fresh).()

      defp contract_request(store, id, overrides \\ []) do
        events = Keyword.get(overrides, :events, [%{type: :clock_advanced, to: 24}])
        hall_stream = Keyword.get(overrides, :hall_stream, @contract_hall)

        receipt = %{
          command_id: id,
          fingerprint: "fp-" <> id,
          kind: :advance_clock,
          actor: {:system, :scheduler},
          outcome: if(events == [], do: {:rejected, :contract}, else: :accepted),
          event_count: length(events)
        }

        Map.merge(
          %{
            command_id: id,
            expected_position: @contract_adapter.head(store),
            expected_versions: @contract_adapter.stream_versions(store, hall_stream),
            hall_stream: hall_stream,
            events: events,
            control_events: [],
            receipt: receipt,
            outbox: [],
            projection_rows: [],
            context: %{actor: {:system, :scheduler}, correlation_id: id, content_hash: nil, hall_ms: 24}
          },
          Map.new(Keyword.drop(overrides, [:events, :hall_stream]))
        )
      end

      defp contract_append!(store, id, overrides \\ []) do
        {:ok, store, _position} = @contract_adapter.append(store, contract_request(store, id, overrides))
        store
      end

      @contract_control [%{type: :clock_advanced, to: 24}]

      describe "event store contract" do
        test "contract: a fresh store is empty" do
          store = contract_fresh()
          assert @contract_adapter.head(store) == 0
          assert @contract_adapter.read_from(store, 0) == {:ok, []}
          assert @contract_adapter.receipt(store, "missing") == :none
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 0, control: 0}
          assert @contract_adapter.stream_versions(store, nil) == %{hall: 0, control: 0}
        end

        test "contract: appends advance the position by one batch each" do
          store = contract_fresh()
          request = contract_request(store, "a")
          assert {:ok, store, 1} = @contract_adapter.append(store, request)
          assert @contract_adapter.head(store) == 1
          assert {:ok, receipt} = @contract_adapter.receipt(store, "a")
          assert receipt == Map.put(request.receipt, :position, 1)

          events = [%{type: :clock_advanced, to: 48}, %{type: :clock_advanced, to: 72}]
          assert {:ok, store, 2} = @contract_adapter.append(store, contract_request(store, "b", events: events))
          assert @contract_adapter.head(store) == 2
        end

        test "contract: a rejection receipt appends no batch" do
          store = contract_append!(contract_fresh(), "a")
          request = contract_request(store, "rejected", events: [])

          assert {:ok, store, 1} = @contract_adapter.append(store, request)
          assert @contract_adapter.head(store) == 1
          assert {:ok, %{outcome: {:rejected, :contract}, position: 1}} = @contract_adapter.receipt(store, "rejected")
          assert {:ok, [%{command_id: "a"}]} = @contract_adapter.read_from(store, 0)
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 1, control: 0}
        end

        test "contract: a used command ID or stale expectation conflicts and writes nothing" do
          store = contract_fresh()
          stale = contract_request(store, "b")
          store = contract_append!(store, "a")

          # A retry of the same command ID never appends a second batch.
          assert {:error, :conflict, _} = @contract_adapter.append(store, contract_request(store, "a"))
          # A writer that read the old head must not append a competing batch.
          assert {:error, :conflict, _} = @contract_adapter.append(store, stale)

          # A writer holding a stale stream version conflicts even at the right position.
          stale_versions = %{contract_request(store, "c") | expected_versions: %{hall: 0, control: 0}}
          assert {:error, :conflict, _} = @contract_adapter.append(store, stale_versions)

          assert @contract_adapter.head(store) == 1
          assert @contract_adapter.receipt(store, "b") == :none
          assert @contract_adapter.receipt(store, "c") == :none
          assert {:ok, %{position: 1, fingerprint: "fp-a"}} = @contract_adapter.receipt(store, "a")
        end

        test "contract: a stale position alone conflicts even when every stream version is current" do
          store = contract_append!(contract_fresh(), "a")

          # Another hall stream, untouched by "a", with no control events: its versions are current.
          request = contract_request(store, "b", hall_stream: "hall:contract-other", expected_position: 0)
          assert request.expected_versions == %{hall: 0, control: 0}
          assert request.expected_versions == @contract_adapter.stream_versions(store, "hall:contract-other")

          assert {:error, :conflict, store} = @contract_adapter.append(store, request)
          assert @contract_adapter.head(store) == 1
          assert @contract_adapter.receipt(store, "b") == :none

          # Only the position was stale: the same request at the current head commits.
          assert {:ok, _, 2} = @contract_adapter.append(store, %{request | expected_position: 1})
        end

        test "contract: read_from returns complete batches in position order after the given position" do
          store =
            contract_fresh()
            |> contract_append!("a", events: [%{type: :clock_advanced, to: 24}])
            |> contract_append!("r", events: [])
            |> contract_append!("b",
              events: [%{type: :clock_advanced, to: 48}, %{type: :clock_advanced, to: 72}],
              context: %{actor: {:system, :scheduler}, correlation_id: "b", content_hash: nil, hall_ms: 72}
            )

          assert {:ok, [first, second]} = @contract_adapter.read_from(store, 0)

          assert first == %{
                   position: 1,
                   command_id: "a",
                   hall_ms: 24,
                   start_hall_ms: nil,
                   events: [%{type: :clock_advanced, to: 24}],
                   control_events: []
                 }

          assert second.position == 2
          assert second.command_id == "b"
          assert second.hall_ms == 72
          assert second.start_hall_ms == 24
          assert second.events == [%{type: :clock_advanced, to: 48}, %{type: :clock_advanced, to: 72}]

          assert {:ok, [%{position: 2}]} = @contract_adapter.read_from(store, 1)
          assert {:ok, []} = @contract_adapter.read_from(store, 2)
        end

        test "contract: projection rows are applied with the batch and stamped with its position" do
          rows = [{:balance, "r1", :cash, 500}, {:balance, "r1", :raw, 0}, {:stock, "r1", "rice_long", 100, 0}]
          store = contract_append!(contract_fresh(), "a", projection_rows: rows)

          assert @contract_adapter.projection(store, :balances) == [
                   %{restaurant_id: "r1", account: :cash, amount: 500, position: 1},
                   %{restaurant_id: "r1", account: :raw, amount: 0, position: 1}
                 ]

          assert @contract_adapter.projection(store, :stock) == [
                   %{restaurant_id: "r1", product: "rice_long", on_hand: 100, reserved: 0, position: 1}
                 ]

          rows = [{:balance, "r1", :cash, 400}, {:delete_stock, "r1", "rice_long"}]

          store =
            contract_append!(store, "b", events: [%{type: :clock_advanced, to: 48}], projection_rows: rows)

          assert @contract_adapter.projection(store, :balances) == [
                   %{restaurant_id: "r1", account: :cash, amount: 400, position: 2},
                   %{restaurant_id: "r1", account: :raw, amount: 0, position: 1}
                 ]

          assert @contract_adapter.projection(store, :stock) == []
        end

        test "contract: a stream version advances by its own event count only" do
          store = contract_fresh()

          two = [%{type: :clock_advanced, to: 24}, %{type: :clock_advanced, to: 48}]
          store = contract_append!(store, "a", events: two)
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 2, control: 0}

          # Another hall's stream is untouched.
          assert @contract_adapter.stream_versions(store, "hall:other") == %{hall: 0, control: 0}

          # A batch without events leaves every stream version unchanged.
          store = contract_append!(store, "rejected", events: [])
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 2, control: 0}

          store = contract_append!(store, "b", events: [%{type: :clock_advanced, to: 72}])
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 3, control: 0}
        end

        test "contract: a control-only batch creates a position and advances only the control version" do
          store = contract_append!(contract_fresh(), "a")
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 1, control: 0}

          control = @contract_control ++ [%{type: :clock_advanced, to: 48}]
          request = contract_request(store, "c", events: [], control_events: control)
          assert {:ok, store, 2} = @contract_adapter.append(store, request)

          assert @contract_adapter.head(store) == 2
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 1, control: 2}
          assert @contract_adapter.stream_versions(store, "hall:other") == %{hall: 0, control: 2}
          assert {:ok, %{position: 2}} = @contract_adapter.receipt(store, "c")

          assert {:ok, [%{position: 2, command_id: "c", events: [], control_events: ^control}]} =
                   @contract_adapter.read_from(store, 1)

          both = contract_request(store, "d", control_events: @contract_control)
          assert {:ok, store, 3} = @contract_adapter.append(store, both)
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 2, control: 3}

          assert {:ok, [%{events: [%{type: :clock_advanced, to: 24}], control_events: @contract_control}]} =
                   @contract_adapter.read_from(store, 2)
        end

        test "contract: a batch touching both streams advances both versions or neither" do
          store = contract_fresh()
          control = [%{type: :clock_advanced, to: 24}]

          failing = @contract_adapter.fail_next(store, :before_commit)
          request = contract_request(failing, "both", control_events: control)
          assert {:error, :unavailable, store} = @contract_adapter.append(failing, request)
          assert @contract_adapter.head(store) == 0
          assert @contract_adapter.receipt(store, "both") == :none
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 0, control: 0}

          assert {:ok, store, 1} = @contract_adapter.append(store, request)
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 1, control: 1}
        end

        test "contract: a stale control version conflicts and writes nothing" do
          store = contract_fresh()
          store = contract_append!(store, "c", events: [], control_events: @contract_control)
          # Control version 0 is stale only once the first batch has advanced it.
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 0, control: 1}

          stale = %{
            contract_request(store, "d", control_events: @contract_control)
            | expected_versions: %{hall: 0, control: 0}
          }

          assert {:error, :conflict, _} = @contract_adapter.append(store, stale)
          assert @contract_adapter.head(store) == 1
          assert @contract_adapter.receipt(store, "d") == :none
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 0, control: 1}
        end

        test "contract: an accepted append stores its outbox intents with the batch position" do
          store = contract_append!(contract_fresh(), "a")
          assert @contract_adapter.outbox(store) == []

          outbox = [
            %{dedupe_key: "n:1", kind: :test_notice, payload: %{to: "alice", n: 1}},
            %{dedupe_key: "n:2", kind: :test_notice, payload: %{to: "bob", n: 2}}
          ]

          store = contract_append!(store, "b", events: [%{type: :clock_advanced, to: 48}], outbox: outbox)

          assert @contract_adapter.outbox(store) == [
                   %{
                     dedupe_key: "n:1",
                     command_id: "b",
                     position: 2,
                     kind: :test_notice,
                     payload: %{to: "alice", n: 1}
                   },
                   %{dedupe_key: "n:2", command_id: "b", position: 2, kind: :test_notice, payload: %{to: "bob", n: 2}}
                 ]
        end

        test "contract: a failed commit stores no outbox intents" do
          store = contract_fresh()
          outbox = [%{dedupe_key: "n:1", kind: :test_notice, payload: %{}}]

          failing = @contract_adapter.fail_next(store, :before_commit)
          request = contract_request(failing, "a", outbox: outbox)
          assert {:error, :unavailable, store} = @contract_adapter.append(failing, request)
          assert @contract_adapter.outbox(store) == []

          assert {:ok, store, 1} = @contract_adapter.append(store, request)
          assert [%{dedupe_key: "n:1", position: 1}] = @contract_adapter.outbox(store)
        end

        test "contract: a reused dedupe key conflicts and writes nothing" do
          one = [%{dedupe_key: "n:1", kind: :test_notice, payload: %{v: 1}}]
          store = contract_append!(contract_fresh(), "a", outbox: one)

          reuse = [
            %{dedupe_key: "n:2", kind: :test_notice, payload: %{v: 2}},
            %{dedupe_key: "n:1", kind: :test_notice, payload: %{v: 3}}
          ]

          request = contract_request(store, "b", events: [%{type: :clock_advanced, to: 48}], outbox: reuse)
          assert {:error, :conflict, store} = @contract_adapter.append(store, request)

          assert @contract_adapter.head(store) == 1
          assert @contract_adapter.receipt(store, "b") == :none
          assert @contract_adapter.stream_versions(store, @contract_hall) == %{hall: 1, control: 0}
          assert [%{dedupe_key: "n:1", command_id: "a", payload: %{v: 1}}] = @contract_adapter.outbox(store)
        end

        test "contract: a dedupe key repeated within one request conflicts and writes nothing" do
          twice = List.duplicate(%{dedupe_key: "n:1", kind: :test_notice, payload: %{}}, 2)
          store = contract_fresh()

          assert {:error, :conflict, store} =
                   @contract_adapter.append(store, contract_request(store, "a", outbox: twice))

          assert @contract_adapter.head(store) == 0
          assert @contract_adapter.receipt(store, "a") == :none
          assert @contract_adapter.outbox(store) == []
        end

        test "contract: invalid requests are refused and write nothing" do
          store = contract_fresh()
          intent = %{dedupe_key: "n:1", kind: :test_notice, payload: %{}}

          # A rejection receipt (no events) cannot carry outbox intents.
          rejection = contract_request(store, "r", events: [], outbox: [intent])
          assert {:error, :invalid_request, store} = @contract_adapter.append(store, rejection)

          # An unknown outbox kind is refused, not converted to an atom.
          unknown = contract_request(store, "u", outbox: [%{intent | kind: :not_allowlisted}])
          assert {:error, :invalid_request, store} = @contract_adapter.append(store, unknown)

          # Hall events need a hall stream.
          no_stream = contract_request(store, "s", hall_stream: nil)
          assert {:error, :invalid_request, store} = @contract_adapter.append(store, no_stream)

          assert @contract_adapter.head(store) == 0
          assert @contract_adapter.outbox(store) == []

          for id <- ["r", "u", "s"], do: assert(@contract_adapter.receipt(store, id) == :none)

          # The same store still accepts a valid request afterwards.
          assert {:ok, _, 1} = @contract_adapter.append(store, contract_request(store, "ok", outbox: [intent]))
        end

        test "contract: snapshots are saved unverified and listed newest first" do
          store = contract_fresh()
          assert @contract_adapter.snapshots(store) == []

          assert {:ok, store, first} = @contract_adapter.save_snapshot(store, 3, "one")
          assert {:ok, store, second} = @contract_adapter.save_snapshot(store, 7, <<0, 255, 1>>)
          assert first != second

          assert [
                   %{id: ^second, position: 7, body: <<0, 255, 1>>, verified: false},
                   %{id: ^first, position: 3, body: "one", verified: false}
                 ] = @contract_adapter.snapshots(store)
        end

        test "contract: marking a snapshot verified changes only that snapshot" do
          store = contract_fresh()
          {:ok, store, first} = @contract_adapter.save_snapshot(store, 3, "one")
          {:ok, store, second} = @contract_adapter.save_snapshot(store, 7, "two")

          assert {:ok, store} = @contract_adapter.mark_snapshot_verified(store, first)

          assert [%{id: ^second, verified: false}, %{id: ^first, verified: true}] =
                   @contract_adapter.snapshots(store)

          # Verifying again is harmless.
          assert {:ok, store} = @contract_adapter.mark_snapshot_verified(store, first)
          assert [%{verified: false}, %{verified: true}] = @contract_adapter.snapshots(store)
        end

        test "contract: marking an unknown snapshot verified is refused" do
          store = contract_fresh()
          {:ok, store, id} = @contract_adapter.save_snapshot(store, 3, "one")
          unknown = if is_integer(id), do: id + 1_000, else: {:unknown, id}

          assert {:error, :unknown_snapshot} = @contract_adapter.mark_snapshot_verified(store, unknown)
          assert [%{id: ^id, verified: false}] = @contract_adapter.snapshots(store)
        end

        test "contract: snapshots are ordered by position, then id, whatever the save order" do
          store = contract_fresh()
          {:ok, store, a} = @contract_adapter.save_snapshot(store, 9, "a")
          {:ok, store, b} = @contract_adapter.save_snapshot(store, 4, "b")
          {:ok, store, c} = @contract_adapter.save_snapshot(store, 9, "c")

          assert [%{id: ^c}, %{id: ^a}, %{id: ^b}] = @contract_adapter.snapshots(store)
        end

        test "contract: pruning keeps the newest verified snapshots and every newer unverified one" do
          store = contract_fresh()

          {store, ids} =
            Enum.reduce([1, 2, 3, 4, 5], {store, %{}}, fn position, {store, ids} ->
              {:ok, store, id} = @contract_adapter.save_snapshot(store, position, "s#{position}")
              {store, Map.put(ids, position, id)}
            end)

          # Positions 1, 2 and 4 are verified; 3 (between the kept ones) and 5 (newer) are not.
          store =
            Enum.reduce([1, 2, 4], store, fn position, store ->
              {:ok, store} = @contract_adapter.mark_snapshot_verified(store, ids[position])
              store
            end)

          assert {:ok, store} = @contract_adapter.prune_snapshots(store, 2)
          kept = Enum.map(@contract_adapter.snapshots(store), & &1.position)
          assert kept == [5, 4, 3, 2]

          # Idempotent, and a default of two.
          assert {:ok, store} = @contract_adapter.prune_snapshots(store)
          assert Enum.map(@contract_adapter.snapshots(store), & &1.position) == [5, 4, 3, 2]

          assert {:ok, store} = @contract_adapter.prune_snapshots(store, 1)
          assert Enum.map(@contract_adapter.snapshots(store), & &1.position) == [5, 4]
        end

        test "contract: a conditional acquisition advances only from the expected epoch" do
          store = contract_fresh()
          {:ok, store, held} = @contract_adapter.acquire_authority(store, "hall:test", "node-a")

          assert {:ok, store, next} = @contract_adapter.acquire_authority(store, "hall:test", "node-b", held)
          assert next == held + 1

          # A holder whose epoch was superseded cannot take the scope back.
          assert {:error, :fenced} = @contract_adapter.acquire_authority(store, "hall:test", "node-c", held)
          assert {:ok, _store, after_next} = @contract_adapter.acquire_authority(store, "hall:test", "node-c", next)
          assert after_next == next + 1
        end

        test "contract: the same owner one epoch past the expected one is its own lost acquisition" do
          store = contract_fresh()
          {:ok, store, epoch} = @contract_adapter.acquire_authority(store, "hall:test", "node-a")

          # Another owner at expected + 1 superseded the holder of `epoch - 1`.
          assert {:error, :fenced} = @contract_adapter.acquire_authority(store, "hall:test", "node-b", epoch - 1)
          # The same owner, but two epochs on: something else held the scope in between.
          assert {:error, :fenced} = @contract_adapter.acquire_authority(store, "hall:test", "node-a", epoch - 2)

          # The same owner at exactly expected + 1: its own acquisition whose reply was lost.
          assert {:ok, store, next} = @contract_adapter.acquire_authority(store, "hall:test", "node-a", epoch - 1)
          assert next == epoch + 1
          assert @contract_adapter.held_epoch(store) == next
        end

        test "contract: a handle reports the epoch it holds" do
          store = contract_fresh()
          {:ok, store, epoch} = @contract_adapter.acquire_authority(store, "hall:test", "node-a")
          assert @contract_adapter.held_epoch(store) == epoch

          {:ok, store, next} = @contract_adapter.acquire_authority(store, "hall:test", "node-b", epoch)
          assert @contract_adapter.held_epoch(store) == next
        end

        test "contract: pruning with too few verified snapshots deletes nothing" do
          store = contract_fresh()
          {:ok, store, one} = @contract_adapter.save_snapshot(store, 1, "one")
          {:ok, store, _two} = @contract_adapter.save_snapshot(store, 2, "two")
          {:ok, store} = @contract_adapter.mark_snapshot_verified(store, one)

          assert {:ok, store} = @contract_adapter.prune_snapshots(store, 2)
          assert length(@contract_adapter.snapshots(store)) == 2
        end
      end
    end
  end
end
