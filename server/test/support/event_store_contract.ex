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
                   events: [%{type: :clock_advanced, to: 24}],
                   control_events: []
                 }

          assert second.position == 2
          assert second.command_id == "b"
          assert second.hall_ms == 72
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
      end
    end
  end
end
