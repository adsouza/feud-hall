defmodule FeudHall.Infrastructure.InMemoryEventStore do
  @moduledoc """
  Functional in-memory implementation of `FeudHall.Application.EventStore`
  for focused tests and the pure-core milestone.

  Failure injection mirrors the cases the PostgreSQL adapter must survive:
  `:before_commit` fails with nothing written; `:lost_reply` commits the
  batch and receipt but reports an unknown outcome.
  """

  @behaviour FeudHall.Application.EventStore

  defstruct batches: [], receipts: %{}, head: 0, fail_next: nil

  def new, do: %__MODULE__{}

  @doc "Arms a one-shot failure for the next append."
  def fail_next(store, mode) when mode in [:before_commit, :lost_reply], do: %{store | fail_next: mode}

  @impl true
  def head(store), do: store.head

  @impl true
  def read_from(store, after_position) do
    store.batches |> Enum.reverse() |> Enum.filter(&(&1.position > after_position))
  end

  @impl true
  def receipt(store, command_id) do
    case Map.fetch(store.receipts, command_id) do
      {:ok, receipt} -> {:ok, receipt}
      :error -> :none
    end
  end

  @impl true
  def append(%{fail_next: :before_commit} = store, _expected, _id, _events, _receipt),
    do: {:error, :unavailable, %{store | fail_next: nil}}

  def append(store, expected, command_id, events, receipt) do
    cond do
      expected != store.head ->
        {:error, :conflict, store}

      Map.has_key?(store.receipts, command_id) ->
        {:error, :conflict, store}

      true ->
        position = if events == [], do: store.head, else: store.head + 1
        receipt = Map.put(receipt, :position, position)

        batches =
          if events == [],
            do: store.batches,
            else: [%{position: position, command_id: command_id, events: events} | store.batches]

        committed = %{
          store
          | batches: batches,
            receipts: Map.put(store.receipts, command_id, receipt),
            head: position,
            fail_next: nil
        }

        if store.fail_next == :lost_reply,
          do: {:error, :unknown_outcome, committed},
          else: {:ok, committed, position}
    end
  end
end
