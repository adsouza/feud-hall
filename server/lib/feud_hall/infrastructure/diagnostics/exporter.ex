defmodule FeudHall.Infrastructure.Diagnostics.Exporter do
  @moduledoc """
  A bounded, non-blocking diagnostic exporter.

  `emit/2` is a cast: it never waits for the exporter, let alone for an
  export. The backlog (mailbox, internal queue and in-flight records) is
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

  @registry Module.concat(__MODULE__, Registry)
  @free 1
  @dropped 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl FeudHall.Application.Diagnostics
  def emit(exporter, record) do
    exporter = GenServer.whereis(exporter)

    case Registry.lookup(@registry, exporter) do
      [{^exporter, credits}] ->
        if :atomics.sub_get(credits, @free, 1) >= 0 do
          GenServer.cast(exporter, {:emit, record})
        else
          :atomics.add(credits, @free, 1)
          :atomics.add(credits, @dropped, 1)
        end

      [] ->
        :ok
    end
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
    max_queue = Keyword.fetch!(opts, :max_queue)
    batch = Keyword.fetch!(opts, :batch)
    timeout = Keyword.fetch!(opts, :timeout_ms)

    with true <- Enum.all?([max_queue, batch, timeout], &(is_integer(&1) and &1 > 0)) do
      Process.flag(:trap_exit, true)
      credits = :atomics.new(2, signed: true)
      :ok = :atomics.put(credits, @free, max_queue)
      {:ok, _} = Registry.register(@registry, self(), credits)

      {:ok,
       %{
         export: Keyword.fetch!(opts, :export),
         credits: credits,
         max_queue: max_queue,
         batch: batch,
         timeout_ms: timeout,
         on_event: Keyword.get(opts, :on_event),
         queue: :queue.new(),
         queue_len: 0,
         inflight: nil,
         exported: 0,
         failed: 0
       }}
    else
      false -> {:stop, :invalid_exporter_limits}
    end
  end

  @impl true
  def handle_cast({:emit, record}, state),
    do: {:noreply, maybe_export(%{state | queue: :queue.in(record, state.queue), queue_len: state.queue_len + 1})}

  @impl true
  def handle_call(:stats, _from, state) do
    queued = state.max_queue - max(0, :atomics.get(state.credits, @free))
    dropped = :atomics.get(state.credits, @dropped)
    {:reply, %{queued: queued, exported: state.exported, dropped: dropped, failed: state.failed}, state}
  end

  @impl true
  def handle_info({:export_result, pid, result}, %{inflight: %{pid: pid, timed_out?: false}} = state) do
    outcome = if result == :ok, do: :exported, else: :failed
    {:noreply, finish(state, outcome)}
  end

  def handle_info({:export_timeout, pid}, %{inflight: %{pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, put_in(state.inflight.timed_out?, true)}
  end

  # The export process died without reporting a result.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{inflight: %{ref: ref, timed_out?: timed_out?}} = state) do
    {:noreply, finish(state, if(timed_out?, do: :timeout, else: :failed))}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{inflight: %{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_reason, _state), do: :ok

  defp maybe_export(%{inflight: nil, queue_len: len} = state) when len > 0 do
    count = min(len, state.batch)
    {batch, rest} = :queue.split(count, state.queue)
    parent = self()
    export = state.export

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              export.(:queue.to_list(batch))
            rescue
              _ -> :error
            catch
              _, _ -> :error
            end

          send(parent, {:export_result, self(), result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:export_timeout, pid}, state.timeout_ms)

    %{
      state
      | queue: rest,
        queue_len: len - count,
        inflight: %{pid: pid, ref: ref, timer: timer, count: count, timed_out?: false}
    }
  end

  defp maybe_export(state), do: state

  defp finish(%{inflight: %{ref: ref, timer: timer, count: count}} = state, outcome) do
    Process.cancel_timer(timer)
    Process.demonitor(ref, [:flush])
    :atomics.add(state.credits, @free, count)
    if state.on_event, do: send(state.on_event, {:exporter, outcome, count})

    state =
      case outcome do
        :exported -> %{state | exported: state.exported + count}
        _ -> %{state | failed: state.failed + count}
      end

    maybe_export(%{state | inflight: nil})
  end
end
