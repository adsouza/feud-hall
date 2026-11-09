defmodule FeudHall.Infrastructure.Diagnostics.Exporter do
  @moduledoc """
  A bounded, non-blocking diagnostic exporter.

  `emit/2` is a cast: it never waits for the exporter, let alone for an
  export. The backlog (records waiting plus those in the current export) is
  capped by `:max_queue`; a record arriving at a full backlog is dropped and
  counted. Records leave in batches of at most `:batch` through the `:export`
  function (`list -> :ok`), run in a separate monitored process that is killed
  after `:timeout_ms`. An export that raises, exits, times out, or returns
  anything but `:ok` counts its records as `failed`; the exporter itself never
  fails because of it. `stats/1` reports record counts.

  `:on_event` (a pid, optional) receives `{:exporter, :exported | :failed |
  :timeout, record_count}` as each export ends, so tests need not poll.
  """
  @behaviour FeudHall.Application.Diagnostics

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl FeudHall.Application.Diagnostics
  def emit(exporter, record) do
    GenServer.cast(exporter, {:emit, record})
  end

  @spec stats(GenServer.server()) :: %{
          queued: non_neg_integer(),
          exported: non_neg_integer(),
          dropped: non_neg_integer(),
          failed: non_neg_integer()
        }
  def stats(exporter), do: GenServer.call(exporter, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       export: Keyword.fetch!(opts, :export),
       max_queue: Keyword.fetch!(opts, :max_queue),
       batch: Keyword.fetch!(opts, :batch),
       timeout_ms: Keyword.fetch!(opts, :timeout_ms),
       on_event: Keyword.get(opts, :on_event),
       queue: :queue.new(),
       queue_len: 0,
       inflight: nil,
       exported: 0,
       dropped: 0,
       failed: 0
     }}
  end

  @impl true
  def handle_cast({:emit, record}, state) do
    if backlog(state) >= state.max_queue do
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      {:noreply, maybe_export(%{state | queue: :queue.in(record, state.queue), queue_len: state.queue_len + 1})}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{queued: backlog(state), exported: state.exported, dropped: state.dropped, failed: state.failed}, state}
  end

  @impl true
  def handle_info({:export_result, pid, result}, %{inflight: %{pid: pid}} = state) do
    outcome = if result == :ok, do: :exported, else: :failed
    {:noreply, finish(state, outcome)}
  end

  def handle_info({:export_timeout, pid}, %{inflight: %{pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, finish(state, :timeout)}
  end

  # The export process died without reporting a result.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: %{ref: ref}} = state) do
    {:noreply, finish(state, :failed)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp backlog(state), do: state.queue_len + if(state.inflight, do: state.inflight.count, else: 0)

  defp maybe_export(%{inflight: nil, queue_len: len} = state) when len > 0 do
    count = min(len, state.batch)
    {batch, rest} = :queue.split(count, state.queue)
    parent = self()
    export = state.export

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            export.(:queue.to_list(batch))
          rescue
            _ -> :error
          catch
            _, _ -> :error
          end

        send(parent, {:export_result, self(), result})
      end)

    timer = Process.send_after(self(), {:export_timeout, pid}, state.timeout_ms)

    %{state | queue: rest, queue_len: len - count, inflight: %{pid: pid, ref: ref, timer: timer, count: count}}
  end

  defp maybe_export(state), do: state

  defp finish(%{inflight: %{ref: ref, timer: timer, count: count}} = state, outcome) do
    Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    if state.on_event, do: send(state.on_event, {:exporter, outcome, count})

    state =
      case outcome do
        :exported -> %{state | exported: state.exported + count}
        _ -> %{state | failed: state.failed + count}
      end

    maybe_export(%{state | inflight: nil})
  end
end
