defmodule FeudHall.Infrastructure.InMemoryEventStore do
  @moduledoc """
  Functional in-memory implementation of `FeudHall.Application.EventStore`
  for focused tests and the pure-core milestone.

  The event log, receipts, stream versions, projections, and snapshots live
  in the struct, so every write returns the next store value and no state is
  shared between copies. There is one implicit authority: appends are never
  fenced unless a failure is injected, and `acquire_authority/4` only counts
  epochs (refusing an `expected_epoch` the count has moved past).

  Failure injection (`fail_next/2`, one-shot) mirrors the cases the PostgreSQL
  adapter must survive: `:before_commit` and `:unavailable` fail with nothing
  written (`{:error, :unavailable, store}`); `:fenced` fails with nothing
  written as a lost authority would; `:lost_reply` commits everything but
  reports an unknown outcome. An armed `:unavailable` also makes
  `read_from/2` and `snapshots/1` return `{:error, :unavailable}`; reads return
  no store value, so it stays armed until an append consumes it.
  """

  @behaviour FeudHall.Application.EventStore

  alias FeudHall.Application.EventStore

  @failure_modes [:before_commit, :unavailable, :fenced, :lost_reply]

  defstruct batches: [],
            receipts: %{},
            head: 0,
            streams: %{},
            control_version: 0,
            balances: %{},
            stock: %{},
            outbox: [],
            epoch: 0,
            snapshots: [],
            next_snapshot_id: 1,
            fail_next: nil

  def new, do: %__MODULE__{}

  @doc "Arms a one-shot failure for the next append."
  def fail_next(store, mode) when mode in @failure_modes, do: %{store | fail_next: mode}

  @impl true
  def head(store), do: store.head

  @impl true
  def stream_versions(store, hall_stream) do
    %{hall: Map.get(store.streams, hall_stream, 0), control: store.control_version}
  end

  @impl true
  def read_from(%{fail_next: :unavailable}, _after_position), do: {:error, :unavailable}

  def read_from(store, after_position) do
    {:ok, store.batches |> Enum.reverse() |> Enum.filter(&(&1.position > after_position))}
  end

  @impl true
  def receipt(store, command_id) do
    case Map.fetch(store.receipts, command_id) do
      {:ok, receipt} -> {:ok, receipt}
      :error -> :none
    end
  end

  @impl true
  def append(%{fail_next: mode} = store, _request) when mode in [:before_commit, :unavailable],
    do: {:error, :unavailable, %{store | fail_next: nil}}

  def append(%{fail_next: :fenced} = store, _request), do: {:error, :fenced, %{store | fail_next: nil}}

  def append(store, request) do
    cond do
      EventStore.validate_request(request) == :invalid_request ->
        {:error, :invalid_request, store}

      duplicate_dedupe_key?(store, request) ->
        {:error, :conflict, store}

      request.expected_position != store.head ->
        {:error, :conflict, store}

      Map.has_key?(store.receipts, request.command_id) ->
        {:error, :conflict, store}

      request.expected_versions != stream_versions(store, request.hall_stream) ->
        {:error, :conflict, store}

      true ->
        committed = commit(store, request)

        if store.fail_next == :lost_reply,
          do: {:error, :unknown_outcome, committed},
          else: {:ok, committed, committed.head}
    end
  end

  defp duplicate_dedupe_key?(store, request) do
    keys = Enum.map(request.outbox, & &1.dedupe_key)
    used = MapSet.new(store.outbox, & &1.dedupe_key)
    length(Enum.uniq(keys)) != length(keys) or Enum.any?(keys, &MapSet.member?(used, &1))
  end

  defp commit(store, request) do
    %{events: events, control_events: control_events} = request
    batch? = events != [] or control_events != []
    position = if batch?, do: store.head + 1, else: store.head

    batches =
      if batch? do
        batch = %{
          position: position,
          command_id: request.command_id,
          hall_ms: request.context.hall_ms,
          events: events,
          control_events: control_events
        }

        [batch | store.batches]
      else
        store.batches
      end

    streams =
      if events == [],
        do: store.streams,
        else: Map.update(store.streams, request.hall_stream, length(events), &(&1 + length(events)))

    outbox = Enum.map(request.outbox, &Map.merge(&1, %{command_id: request.command_id, position: position}))

    store
    |> Map.merge(%{
      batches: batches,
      receipts: Map.put(store.receipts, request.command_id, Map.put(request.receipt, :position, position)),
      head: position,
      streams: streams,
      control_version: store.control_version + length(control_events),
      outbox: store.outbox ++ outbox,
      fail_next: nil
    })
    |> apply_rows(request.projection_rows, position)
  end

  defp apply_rows(store, rows, position) do
    Enum.reduce(rows, store, fn
      {:balance, r, account, amount}, acc ->
        row = %{restaurant_id: r, account: account, amount: amount, position: position}
        %{acc | balances: Map.put(acc.balances, {r, account}, row)}

      {:stock, r, product, on_hand, reserved}, acc ->
        row = %{restaurant_id: r, product: product, on_hand: on_hand, reserved: reserved, position: position}
        %{acc | stock: Map.put(acc.stock, {r, product}, row)}

      {:delete_stock, r, product}, acc ->
        %{acc | stock: Map.delete(acc.stock, {r, product})}
    end)
  end

  @impl true
  def projection(store, :balances), do: sorted_rows(store.balances)
  def projection(store, :stock), do: sorted_rows(store.stock)

  defp sorted_rows(rows), do: rows |> Enum.sort() |> Enum.map(&elem(&1, 1))

  @impl true
  def outbox(store), do: store.outbox

  @doc "Counts epochs; with an `expected_epoch` the count must still equal it, else `{:error, :fenced}`."
  @impl true
  def acquire_authority(store, scope, owner, expected_epoch \\ nil)

  def acquire_authority(store, _scope, _owner, expected) when is_nil(expected) or expected == store.epoch do
    epoch = store.epoch + 1
    {:ok, %{store | epoch: epoch}, epoch}
  end

  def acquire_authority(_store, _scope, _owner, expected) when is_integer(expected), do: {:error, :fenced}

  @impl true
  def save_snapshot(store, position, body) when is_binary(body) do
    id = store.next_snapshot_id
    snapshot = %{id: id, position: position, body: body, verified: false}
    {:ok, %{store | snapshots: sort_snapshots([snapshot | store.snapshots]), next_snapshot_id: id + 1}, id}
  end

  @impl true
  def mark_snapshot_verified(store, id) do
    if Enum.any?(store.snapshots, &(&1.id == id)) do
      snapshots = Enum.map(store.snapshots, &if(&1.id == id, do: %{&1 | verified: true}, else: &1))
      {:ok, %{store | snapshots: snapshots}}
    else
      {:error, :unknown_snapshot}
    end
  end

  @impl true
  def snapshots(%{fail_next: :unavailable}), do: {:error, :unavailable}
  def snapshots(store), do: store.snapshots

  @doc "Same semantics as `PostgresEventStore.prune_snapshots/2`."
  def prune_snapshots(store, keep_verified \\ 2) when is_integer(keep_verified) and keep_verified > 0 do
    case store.snapshots |> Enum.filter(& &1.verified) |> Enum.at(keep_verified - 1) do
      nil -> {:ok, store}
      cutoff -> {:ok, %{store | snapshots: Enum.filter(store.snapshots, &(snapshot_key(&1) >= snapshot_key(cutoff)))}}
    end
  end

  defp sort_snapshots(snapshots), do: Enum.sort_by(snapshots, &snapshot_key/1, :desc)
  defp snapshot_key(%{position: position, id: id}), do: {position, id}
end
