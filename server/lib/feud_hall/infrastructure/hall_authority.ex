defmodule FeudHall.Infrastructure.HallAuthority do
  @moduledoc """
  The single, fenced authority process for one hall: it owns the hall's
  command runtime, turns monotonic elapsed time into committed clock advances,
  and serialises every command through `CommandWorkflow`.

  ## Start

  `start_link/1` runs `Recovery.recover/4` (snapshot-tail replay, reconciliation,
  a new availability epoch) for `opts[:owner]` and `opts[:scope]`, then sets the
  monotonic anchor to the clock's current reading. Options:

    * `:store_mod`, `:store`, `:owner`, `:scope` (required);
    * `:clock` — `{module, ref}` implementing `FeudHall.Application.MonotonicClock`
      (default the system monotonic clock);
    * `:diagnostics` — a `FeudHall.Application.Diagnostics` configuration;
    * `:tick_ms` — `1000` (default) schedules a wake-up every second, `:manual`
      only ticks on `tick/1`;
    * `:max_gap_ms` (5,000), `:snapshot_every_events` (10,000),
      `:snapshot_every_service_ms` (300,000).

  ## Clocks

  The authority keeps the committed available-service instant `service_ms`
  (the hall's `now` divided by `Clock.ratio/0`) and the monotonic `anchor` that
  corresponds to it, so the observed service instant is always
  `service_ms + (now - anchor)`. A committed advance moves the anchor forward by
  exactly the service time it charged; anything that fails leaves both where
  they were, so the clocks stay frozen at the last committed boundary.

  A tick with `elapsed = now - anchor`:

    * before `initialize_hall` there is no hall clock: the tick only moves the
      anchor to `now`, so time before initialisation is never charged;
    * `elapsed > max_gap_ms` is a discontinuity, not scheduler lag: nothing is
      advanced; recovery runs again on the held store for the same owner
      (acquiring a new epoch), the anchor is reset to `now`, and
      `:scheduler_gap` is emitted. Hall time is unchanged by the gap;
    * otherwise `{:advance_clock, %{to_service_ms: service_ms + elapsed}}` is
      executed as `{:system, :scheduler}` with command ID
      `"tick:<epoch>:<target_service_ms>"`; `:tick_late` is emitted first when
      `elapsed > 1500`.

  `execute/2` applies the same gap rule, then stamps `observed_service_ms` from
  the authority's own clock (never from the caller: only `command_id`, `actor`,
  and `command` are taken from the envelope), so due clock work is committed in
  its own batch before the command is decided. `lateness_ms` in diagnostics is
  the elapsed time beyond the nominal one-second wake-up.

  ## Failures

  Calls into the store, the workflow, and recovery are shielded: a raised
  `DBConnection.ConnectionError`, `Postgrex.Error`, or
  `DBConnection.TransactionError` is `{:error, :unavailable}` (Ruling R20).
  Unavailable storage, an append conflict, or a lost reply emits
  `:storage_failure` and keeps the anchor; a lost reply is resolved by its
  command ID before the next tick or command. A fenced append emits `:fenced`
  and stops the process with `{:shutdown, :fenced}`: another owner holds the
  hall. A recovery that fails for any reason other than storage availability
  (corrupt or missing history, invariant violations) stops the process.
  Rerunning recovery after a gap acquires a new epoch unconditionally, so an
  authority that wakes after a long pause takes the hall back from any
  successor, which is then fenced on its next append.

  ## Snapshots

  After a committed batch, when at least `snapshot_every_events` events or
  `snapshot_every_service_ms` of service time have been committed since the
  last verified snapshot (counted from start-up), the authority takes a
  snapshot of `%{hall:, control:}` at the committed position, saves it, reads it
  back, compares it with the live state, marks it verified, and prunes to the
  two newest verified ones, emitting `:snapshot_taken`. On PostgreSQL it then
  emits `:projection_backlog` (head minus the daily-activity checkpoint). A
  failed save or check emits `:storage_failure`, verifies nothing, and never
  stops the authority.
  """

  use GenServer, restart: :transient

  alias FeudHall.Application.{CommandWorkflow, Diagnostics, Recovery}
  alias FeudHall.Domain.Clock
  alias FeudHall.Infrastructure.{PostgresEventStore, Snapshot, SystemClock}
  alias FeudHall.Infrastructure.Postgres.DailyActivityProjector

  @scheduler {:system, :scheduler}
  @nominal_ms 1_000
  @late_ms 1_500
  @keep_verified 2
  @call_timeout 60_000

  defstruct store_mod: nil,
            owner: nil,
            scope: nil,
            clock: nil,
            diagnostics: nil,
            tick_ms: @nominal_ms,
            max_gap_ms: 5_000,
            snapshot_every_events: 10_000,
            snapshot_every_service_ms: 300_000,
            runtime: nil,
            recovery: nil,
            anchor: 0,
            service_ms: 0,
            snapshot_events: 0,
            snapshot_service_ms: 0

  # --- client ------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Runs one scheduling step now; `:ok` or `{:error, reason}`."
  @spec tick(GenServer.server()) :: :ok | {:error, term()}
  def tick(pid), do: GenServer.call(pid, :tick, @call_timeout)

  @doc """
  Executes a command envelope at the authority's own service clock. Returns the
  workflow result without the runtime: `{:accepted | :rejected | :replayed, receipt}`,
  `{:uncertain, command_id}`, or `{:error, reason}`.
  """
  @spec execute(GenServer.server(), map()) :: tuple()
  def execute(pid, envelope), do: GenServer.call(pid, {:execute, envelope}, @call_timeout)

  @doc "The committed head the authority holds."
  @spec state(GenServer.server()) :: %{
          hall: map() | nil,
          control: map() | nil,
          position: non_neg_integer(),
          service_ms: non_neg_integer(),
          mode: atom(),
          epoch: pos_integer(),
          recovery: Recovery.report()
        }
  def state(pid), do: GenServer.call(pid, :state, @call_timeout)

  @doc "`{store_mod, store}` as held now; lets tests hand a value-typed store to another authority."
  def store(pid), do: GenServer.call(pid, :store, @call_timeout)

  @doc "Arms `store_mod.fail_next(store, fault)` on the held store (Ruling R7)."
  def inject_fault(pid, fault), do: GenServer.call(pid, {:inject_fault, fault}, @call_timeout)

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    s = %__MODULE__{
      store_mod: Keyword.fetch!(opts, :store_mod),
      owner: Keyword.fetch!(opts, :owner),
      scope: Keyword.fetch!(opts, :scope),
      clock: Keyword.get(opts, :clock, {SystemClock, nil}),
      diagnostics: Keyword.get(opts, :diagnostics),
      tick_ms: Keyword.get(opts, :tick_ms, @nominal_ms),
      max_gap_ms: Keyword.get(opts, :max_gap_ms, 5_000),
      snapshot_every_events: Keyword.get(opts, :snapshot_every_events, 10_000),
      snapshot_every_service_ms: Keyword.get(opts, :snapshot_every_service_ms, 300_000)
    }

    case recover(s, Keyword.fetch!(opts, :store)) do
      {:ok, s} ->
        schedule(s)
        {:ok, s}

      {:error, reason, _s} ->
        {:stop, {:recovery_failed, reason}}
    end
  end

  @impl true
  def handle_call(:tick, _from, s), do: s |> run_tick() |> reply(&tick_reply/1)

  def handle_call({:execute, envelope}, _from, s), do: s |> run_execute(envelope) |> reply(& &1)

  def handle_call(:state, _from, %{runtime: rt} = s) do
    {:reply,
     %{
       hall: rt.state,
       control: rt.control,
       position: rt.position,
       service_ms: s.service_ms,
       mode: rt.mode,
       epoch: rt.epoch,
       recovery: s.recovery
     }, s}
  end

  def handle_call(:store, _from, %{runtime: rt} = s), do: {:reply, {rt.store_mod, rt.store}, s}

  def handle_call({:inject_fault, fault}, _from, %{runtime: rt} = s),
    do: {:reply, :ok, put_store(s, rt.store_mod.fail_next(rt.store, fault))}

  @impl true
  def handle_info(:tick, s) do
    case run_tick(s) do
      {:fenced, s} ->
        {:stop, {:shutdown, :fenced}, fenced(s)}

      {:stop, reason, s} ->
        {:stop, reason, s}

      {_ok_or_error, _value, s} ->
        schedule(s)
        {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # Step results are `{:ok, value, s}`, `{:error, reason, s}`, `{:fenced, s}`, or `{:stop, reason, s}`.
  defp reply({:ok, value, s}, to_reply), do: {:reply, to_reply.(value), s}
  defp reply({:error, reason, s}, _to_reply), do: {:reply, {:error, reason}, s}
  defp reply({:fenced, s}, _to_reply), do: {:stop, {:shutdown, :fenced}, {:error, :fenced}, fenced(s)}
  defp reply({:stop, reason, s}, _to_reply), do: {:stop, reason, {:error, reason}, s}

  defp tick_reply({status, _receipt}) when status in [:accepted, :replayed], do: :ok
  defp tick_reply({:rejected, %{outcome: {:rejected, reason}}}), do: {:error, {:rejected, reason}}
  defp tick_reply({:uncertain, _id}), do: {:error, :unknown_outcome}
  defp tick_reply({:error, reason}), do: {:error, reason}
  defp tick_reply(:ok), do: :ok

  defp schedule(%{tick_ms: :manual}), do: :ok
  defp schedule(%{tick_ms: ms}) when is_integer(ms) and ms > 0, do: Process.send_after(self(), :tick, ms)

  # --- tick and execute --------------------------------------------------------

  defp run_tick(s) do
    now = now(s)

    with {:ok, s} <- check_gap(s, now),
         {:ok, s} <- settle(s) do
      if s.runtime.state == nil, do: {:ok, :ok, %{s | anchor: now}}, else: advance(s, now - s.anchor)
    else
      {:recovered, s} -> {:ok, :ok, s}
      other -> other
    end
  end

  defp run_execute(s, envelope) do
    now = now(s)
    envelope = if is_map(envelope), do: Map.take(envelope, [:command_id, :actor, :command]), else: envelope

    with {gap, s} when gap in [:ok, :recovered] <- check_gap(s, now),
         {:ok, s} <- settle(s) do
      s = if s.runtime.state == nil, do: %{s | anchor: now}, else: s
      observed = s.service_ms + (now - s.anchor)

      case workflow(s, envelope, observed) do
        {{:error, :fenced}, s} -> {:fenced, s}
        {result, s} -> {:ok, result, s}
      end
    end
  end

  # More than `max_gap_ms` unobserved: recover instead of charging the interval.
  defp check_gap(%{runtime: %{state: hall}} = s, now) when hall != nil do
    elapsed = now - s.anchor

    if elapsed > s.max_gap_ms do
      case recover(s, s.runtime.store) do
        {:ok, s} ->
          emit(s, :scheduler_gap, %{lateness_ms: elapsed - @nominal_ms, position: s.runtime.position})
          {:recovered, s}

        {:error, reason, s} ->
          recovery_error(s, reason)
      end
    else
      {:ok, s}
    end
  end

  defp check_gap(s, _now), do: {:ok, s}

  defp advance(s, elapsed) when elapsed <= 0, do: {:ok, :ok, s}

  defp advance(s, elapsed) do
    if elapsed > @late_ms, do: emit(s, :tick_late, %{lateness_ms: elapsed - @nominal_ms})
    target = s.service_ms + elapsed

    envelope = %{
      command_id: "tick:#{s.runtime.epoch}:#{target}",
      actor: @scheduler,
      command: {:advance_clock, %{to_service_ms: target}}
    }

    case workflow(s, envelope, nil) do
      {{:error, :fenced}, s} -> {:fenced, s}
      {result, s} -> {:ok, result, s}
    end
  end

  # Resolves a lost append reply by its command ID before any new work.
  defp settle(%{runtime: %{mode: :recovery_required, pending: id} = rt} = s) do
    position = rt.position

    case shielded(fn -> CommandWorkflow.resolve(rt, id) end, {:error, :unavailable, rt}) do
      {:committed, _receipt, rt} -> {:ok, s |> adopt(rt) |> after_commit(position)}
      {:not_committed, rt} -> {:ok, adopt(s, rt)}
      {:error, :fenced, rt} -> {:fenced, adopt(s, rt)}
      {:error, reason, rt} -> {:error, reason, s |> adopt(rt) |> storage_failure(reason)}
    end
  end

  defp settle(s), do: {:ok, s}

  # Runs one envelope through the workflow; returns `{result_without_runtime, s}`.
  defp workflow(%{runtime: rt} = s, envelope, observed) do
    position = rt.position

    result =
      shielded(fn -> CommandWorkflow.execute(rt, envelope, observed) end, {:error, :unavailable, rt})

    s = s |> adopt(elem(result, tuple_size(result) - 1)) |> after_commit(position)

    case result do
      {:uncertain, id, _rt} ->
        {{:uncertain, id}, storage_failure(s, :unknown_outcome)}

      {:error, :fenced, _rt} ->
        {{:error, :fenced}, s}

      {:error, reason, _rt} when reason in [:unavailable, :conflict] ->
        {{:error, reason}, storage_failure(s, reason)}

      {:error, reason, _rt} ->
        {{:error, reason}, s}

      {status, receipt, _rt} ->
        {{status, receipt}, s}
    end
  end

  # Adopts a runtime the workflow returned. The anchor moves by exactly the
  # service time that was committed, so nothing is charged twice or skipped.
  defp adopt(s, runtime) do
    service = service_of(runtime)
    %{s | runtime: runtime, service_ms: service, anchor: s.anchor + (service - s.service_ms)}
  end

  defp after_commit(%{runtime: rt} = s, before) when rt.position > before and rt.state != nil, do: maybe_snapshot(s)
  defp after_commit(s, _before), do: s

  # --- recovery ----------------------------------------------------------------

  defp recover(s, store) do
    opts = [scope: s.scope, decode_snapshot: &Snapshot.load/1, diagnostics: s.diagnostics]

    case shielded(fn -> Recovery.recover(s.store_mod, store, s.owner, opts) end, {:error, :unavailable}) do
      {:ok, runtime, report} ->
        s = %{s | runtime: runtime, recovery: report, anchor: now(s), service_ms: service_of(runtime)}
        s = snapshot_baseline(s)
        emit(s, :authority_acquired, %{position: runtime.position})
        {:ok, s}

      {:error, reason} ->
        {:error, reason, s}
    end
  end

  # Storage could not be reached (or the reply was lost): keep the anchor and try again on the next wake-up.
  defp recovery_error(s, :unavailable), do: {:error, :unavailable, storage_failure(s, :unavailable)}

  defp recovery_error(s, {:uncertain, _id}), do: {:error, :unknown_outcome, storage_failure(s, :unknown_outcome)}
  defp recovery_error(s, :fenced), do: {:fenced, s}
  defp recovery_error(s, reason), do: {:stop, {:recovery_failed, reason}, s}

  # --- snapshots ---------------------------------------------------------------

  defp snapshot_baseline(%{runtime: rt} = s),
    do: %{s | snapshot_events: rt.versions.hall + rt.versions.control, snapshot_service_ms: s.service_ms}

  defp maybe_snapshot(%{runtime: rt} = s) do
    events = rt.versions.hall + rt.versions.control

    if events - s.snapshot_events >= s.snapshot_every_events or
         s.service_ms - s.snapshot_service_ms >= s.snapshot_every_service_ms,
       do: snapshot(s),
       else: s
  end

  defp snapshot(%{runtime: rt} = s) do
    started = System.monotonic_time(:microsecond)
    mod = rt.store_mod
    body = Snapshot.take(%{hall: rt.state, control: rt.control}, rt.position)

    case shielded(fn -> mod.save_snapshot(rt.store, rt.position, body) end, {:error, :unavailable}) do
      {:ok, store, id} ->
        s = put_store(s, store)

        case shielded(fn -> verify(mod, store, id, rt) end, {:error, :unavailable}) do
          {:ok, store} ->
            s = s |> put_store(store) |> snapshot_baseline()

            emit(s, :snapshot_taken, %{
              snapshot_position: rt.position,
              duration_us: System.monotonic_time(:microsecond) - started
            })

            emit_backlog(s)
            s

          {:error, reason} ->
            storage_failure(s, reason)
        end

      {:error, reason} ->
        storage_failure(s, reason)
    end
  end

  # Reads the saved body back, checks it decodes to the live head, then marks it verified and prunes.
  defp verify(mod, store, id, rt) do
    with {:ok, body} <- stored_body(mod, store, id),
         {:ok, %{position: position, state: state}} <- Snapshot.load(body),
         true <- (position == rt.position and state == %{hall: rt.state, control: rt.control}) || {:error, :mismatch},
         {:ok, store} <- mod.mark_snapshot_verified(store, id) do
      mod.prune_snapshots(store, @keep_verified)
    end
  end

  defp stored_body(mod, store, id) do
    case mod.snapshots(store) do
      snapshots when is_list(snapshots) ->
        case Enum.find(snapshots, &(&1.id == id)) do
          %{body: body} -> {:ok, body}
          nil -> {:error, :unknown_snapshot}
        end

      {:error, _} = error ->
        error
    end
  end

  # The asynchronous daily-activity projection only exists on PostgreSQL.
  defp emit_backlog(%{runtime: %{store: %PostgresEventStore{repo: repo} = store}} = s) do
    read = fn -> {:ok, PostgresEventStore.head(store) - DailyActivityProjector.checkpoint(repo)} end

    case shielded(read, {:error, :unavailable}) do
      {:ok, backlog} -> emit(s, :projection_backlog, %{backlog: backlog, position: s.runtime.position})
      {:error, reason} -> storage_failure(s, reason)
    end
  end

  defp emit_backlog(_s), do: :ok

  # --- helpers -----------------------------------------------------------------

  defp put_store(%{runtime: rt} = s, store), do: %{s | runtime: %{rt | store: store}}

  defp service_of(%{state: nil}), do: 0
  defp service_of(%{state: hall}), do: Clock.service_ms(hall.now)

  defp now(%{clock: {mod, ref}}), do: mod.now_ms(ref)

  # Another owner holds the hall: report it with the epoch this authority held, then stop.
  defp fenced(s) do
    emit(s, :fenced, %{position: s.runtime.position})
    s
  end

  defp storage_failure(s, reason) do
    emit(s, :storage_failure, %{error_class: Diagnostics.reason(reason), position: s.runtime && s.runtime.position})
    s
  end

  defp emit(s, name, fields) do
    epoch = s.runtime && s.runtime.epoch
    Diagnostics.emit(s.diagnostics, name, Map.merge(%{epoch: epoch, scope: s.scope}, fields))
  end

  # Ruling R20: driver-level failures raised from the store are storage unavailability; nothing else is rescued.
  defp shielded(fun, unavailable) do
    fun.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, DBConnection.TransactionError] -> unavailable
  end
end
