defmodule FeudHall.Infrastructure.InMemoryEventStore do
  @moduledoc """
  Functional in-memory implementation of `FeudHall.Application.EventStore`
  for focused tests and the pure-core milestone.

  The event log, receipts, stream versions, and projections live in the
  struct, so every append returns the next store value. There is one implicit
  authority: appends are never fenced unless a failure is injected, and
  `acquire_authority/3` only counts epochs. Snapshots are the exception to the
  functional style: the port's snapshot callbacks return no store, so they
  live in a public ETS table created by `new/0` and owned by its caller.

  Failure injection (`fail_next/2`, one-shot) mirrors the cases the PostgreSQL
  adapter must survive: `:before_commit` and `:unavailable` fail with nothing
  written (`{:error, :unavailable, store}`); `:fenced` fails with nothing
  written as a lost authority would; `:lost_reply` commits everything but
  reports an unknown outcome.
  """

  @behaviour FeudHall.Application.EventStore

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
            snapshot_table: nil,
            fail_next: nil

  def new, do: %__MODULE__{snapshot_table: :ets.new(__MODULE__, [:set, :public])}

  @doc "Arms a one-shot failure for the next append."
  def fail_next(store, mode) when mode in @failure_modes, do: %{store | fail_next: mode}

  @impl true
  def head(store), do: store.head

  @impl true
  def stream_versions(store, hall_stream) do
    %{hall: Map.get(store.streams, hall_stream, 0), control: store.control_version}
  end

  @impl true
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
  def acquire_authority(store, _scope, _owner) do
    epoch = store.epoch + 1
    {:ok, %{store | epoch: epoch}, epoch}
  end

  @impl true
  def save_snapshot(store, position, body) when is_binary(body) do
    id = :ets.update_counter(store.snapshot_table, :next_id, 1, {:next_id, 0})
    true = :ets.insert(store.snapshot_table, {{:snapshot, id}, position, body, false})
    {:ok, id}
  end

  @impl true
  def mark_snapshot_verified(store, id) do
    :ets.update_element(store.snapshot_table, {:snapshot, id}, {4, true})
    :ok
  end

  @impl true
  def snapshots(store) do
    store.snapshot_table
    |> :ets.match_object({{:snapshot, :_}, :_, :_, :_})
    |> Enum.map(fn {{:snapshot, id}, position, body, verified} ->
      %{id: id, position: position, body: body, verified: verified}
    end)
    |> Enum.sort_by(& &1.id, :desc)
  end
end
