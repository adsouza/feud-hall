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
  its own catch-up batch before the command is decided. The catch-up's command
  ID is `CommandWorkflow.catch_up_id/1` of its target (`"adv:<service_ms>"`),
  so a retry of the caller's command observed later catches up to its own
  target, and a lost catch-up reply is resolved inside the workflow: the
  caller only ever sees its own command ID as uncertain. `lateness_ms` in diagnostics is
  the elapsed time beyond the nominal one-second wake-up.

  ## Failures

  Calls into the store, the workflow, and recovery are shielded: a raised
  `DBConnection.ConnectionError` or `DBConnection.TransactionError`, or a
  `Postgrex.Error` whose code `PostgresEventStore.unavailable_code?/1` accepts,
  is `{:error, :unavailable}` (Ruling R31, narrowing R20). Any other raised
  `Postgrex.Error` is a defect, not an outage: it propagates and the process
  exits.
  Unavailable storage, an append conflict, or a lost reply emits
  `:storage_failure` and keeps the anchor; a lost reply is resolved by its
  command ID before the next tick or command. A fenced append emits `:fenced`
  and stops the process with `{:shutdown, :fenced}`: another owner holds the
  hall. Recovery after a gap re-acquires authority only from the epoch this
  authority still holds (`expected_epoch:`): if a successor took the hall
  while it was paused, recovery is fenced and the authority stops with
  `{:shutdown, :fenced}`, leaving the successor in charge. A recovery that
  fails for any reason other than storage availability or fencing (corrupt or
  missing history, invariant violations) stops the process with
  `{:shutdown, {:recovery_failed, reason}}`: restarting cannot repair history.
  At start-up, recovery acquires authority unconditionally.

  When a gap recovery fails after its acquisition committed, the authority
  adopts the store recovery hands back and retries from the epoch it now
  holds. If the acquisition's own reply was lost (the database committed it,
  but no store came back), the retry still succeeds: the store accepts this
  same owner at exactly one epoch past the expected one as its own lost
  acquisition. **The `owner` name therefore identifies one authority
  incarnation**: two processes must never share an owner name, or a paused
  one could mistake its successor's acquisition for its own.

  ## NPC owners

  After start-up recovery and after every step that committed a batch, the
  authority creates each catalog NPC profile's restaurant that does not exist
  yet (`create_restaurant` as `{:npc, profile_id}`, ID `"npc:<id>:create"`, the
  slot from `Planner.choose_slot/3`), then, for every NPC (sorted) whose
  `next_slot_at` has been reached, runs `Planner.plan/5` on the public view and
  executes one `npc_plan` command (ID `"npc:<op>:<slot>"`) at the latest
  crossed hour boundary. These commands go through the same workflow without
  a catch-up advance. A failure emits `:npc_planner_failed` (command ID and
  reason) and never stops the authority: storage unavailability or a lost
  reply is retried after the next commit; anything else is not retried for
  that slot (or, for a create, until restart). A fenced NPC append stops the
  authority after replying to the step that triggered it.

  ## Snapshots

  After a committed batch, when at least `snapshot_every_events` events or
  `snapshot_every_service_ms` of service time have been committed since the
  last verified snapshot (counted from start-up), the authority takes a
  snapshot of `%{hall:, control:}` at the committed position, saves it, reads it
  back, compares it with the live state, marks it verified, and prunes to the
  two newest verified ones, emitting `:snapshot_taken`. On PostgreSQL it then
  emits `:projection_backlog` (head minus the daily-activity checkpoint).

  A failed attempt verifies nothing, never stops the authority, and resets the
  baseline exactly like a success, so the next attempt waits a full threshold
  instead of retrying on every commit. Unreachable storage (including a raised
  driver error) emits `:storage_failure`; a body that does not load back, does
  not match the live head, or cannot be marked verified emits
  `:snapshot_failed`.
  """

  use GenServer, restart: :transient

  alias FeudHall.Application.{CommandWorkflow, Diagnostics, Recovery}
  alias FeudHall.Domain.{Clock, PublicView}
  alias FeudHall.Domain.Hall.Decider
  alias FeudHall.Domain.Npc.Planner
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
            held_epoch: nil,
            recovery: nil,
            anchor: 0,
            service_ms: 0,
            snapshot_events: 0,
            snapshot_service_ms: 0,
            npc_given_up: %{}

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

  @doc """
  Status and crash-report formatting (`:sys.get_status/1`, terminate reports):
  only scalar authority fields (scope, owner, epoch, mode, position, service
  time, anchor) appear, never the hall, control state, store, or runtime, which
  hold player-entered text and private business state. A request in the last
  message is reduced to its tag, the debug log is dropped, and stack frames keep
  their arity but not their arguments.
  """
  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &summary/1)
    |> Map.replace_lazy(:message, &redact_message/1)
    |> Map.replace_lazy(:log, fn _log -> [] end)
    |> Map.replace_lazy(:reason, &redact_reason/1)
  end

  defp summary(%__MODULE__{runtime: rt} = s) do
    %{
      scope: s.scope,
      owner: s.owner,
      epoch: s.held_epoch,
      mode: rt && rt.mode,
      position: rt && rt.position,
      service_ms: s.service_ms,
      anchor: s.anchor
    }
  end

  defp summary(_other), do: :redacted

  defp redact_message({:"$gen_call", from, request}), do: {:"$gen_call", from, request_tag(request)}
  defp redact_message(message) when is_atom(message), do: message
  defp redact_message(_message), do: :redacted

  defp request_tag(request) when is_atom(request), do: request
  defp request_tag(request) when is_tuple(request) and is_atom(elem(request, 0)), do: elem(request, 0)
  defp request_tag(_request), do: :redacted

  defp redact_reason({error, stack}) when is_list(stack), do: {error, Enum.map(stack, &redact_frame/1)}
  defp redact_reason(reason), do: reason

  defp redact_frame({mod, fun, args, location}) when is_list(args), do: {mod, fun, length(args), location}
  defp redact_frame(frame), do: frame

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

    with {:ok, s} <- recover(s, Keyword.fetch!(opts, :store), nil),
         {:ok, s} <- npc_work(s) do
      schedule(s)
      {:ok, s}
    else
      {:error, reason, _s} ->
        {:stop, {:recovery_failed, reason}}

      {:fenced, s} ->
        fenced(s)
        {:stop, {:shutdown, :fenced}}
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

      {:fenced_after, _value, s} ->
        {:stop, {:shutdown, :fenced}, fenced(s)}

      {_ok_or_error, _value, s} ->
        schedule(s)
        {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # Step results are `{:ok, value, s}`, `{:error, reason, s}`, `{:fenced, s}`, `{:stop, reason, s}`, or
  # `{:fenced_after, value, s}` (the step itself succeeded, then NPC work found the hall fenced).
  defp reply({:ok, value, s}, to_reply), do: {:reply, to_reply.(value), s}

  defp reply({:fenced_after, value, s}, to_reply),
    do: {:stop, {:shutdown, :fenced}, to_reply.(value), fenced(s)}

  defp reply({:error, reason, s}, _to_reply), do: {:reply, {:error, reason}, s}
  defp reply({:fenced, s}, _to_reply), do: {:stop, {:shutdown, :fenced}, {:error, :fenced}, fenced(s)}
  defp reply({:stop, {:shutdown, reason} = stop, s}, _to_reply), do: {:stop, stop, {:error, reason}, s}

  defp tick_reply({status, _receipt}) when status in [:accepted, :replayed], do: :ok
  defp tick_reply({:rejected, %{outcome: {:rejected, reason}}}), do: {:error, {:rejected, reason}}
  defp tick_reply({:uncertain, _id}), do: {:error, :unknown_outcome}
  defp tick_reply({:error, reason}), do: {:error, reason}
  defp tick_reply(:ok), do: :ok

  defp schedule(%{tick_ms: :manual}), do: :ok
  defp schedule(%{tick_ms: ms}) when is_integer(ms) and ms > 0, do: Process.send_after(self(), :tick, ms)

  # --- tick and execute --------------------------------------------------------

  defp run_tick(s), do: with_npc_work(s, &tick_step/1)

  defp run_execute(s, envelope), do: with_npc_work(s, &execute_step(&1, envelope))

  # NPC work follows every step that committed a batch (see "NPC owners").
  defp with_npc_work(s, step) do
    before = s.runtime.position

    case step.(s) do
      {status, value, %{runtime: %{position: position}} = s} when status in [:ok, :error] and position > before ->
        case npc_work(s) do
          {:ok, s} -> {status, value, s}
          {:fenced, s} -> {:fenced_after, value, s}
        end

      other ->
        other
    end
  end

  defp tick_step(s) do
    now = now(s)

    with {:ok, s} <- check_gap(s, now),
         {:ok, s} <- settle(s) do
      if s.runtime.state == nil, do: {:ok, :ok, %{s | anchor: now}}, else: advance(s, now - s.anchor)
    else
      {:recovered, s} -> {:ok, :ok, s}
      other -> other
    end
  end

  defp execute_step(s, envelope) do
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
      case recover(s, s.runtime.store, s.held_epoch) do
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

  # --- NPC owners --------------------------------------------------------------

  # After each committed batch (and once after start-up recovery): every NPC
  # profile without a venture is created, then every NPC whose planning slot
  # is due plans once, at the latest crossed hour boundary. NPC commands go
  # through the same workflow as any owner's, with deterministic IDs
  # (`npc:<op>:create`, `npc:<op>:<slot>`), so a retry after a restart replays
  # the original receipt. A failure emits `:npc_planner_failed` and never stops
  # the authority. A transient one (storage unavailable, a lost reply) is
  # retried after the next committed batch; any other is not retried for the
  # same slot (or, for a create, until restart), so nothing loops on it.
  defp npc_work(%{runtime: %{state: nil}} = s), do: {:ok, s}

  defp npc_work(s) do
    with {:ok, s} <- create_npcs(s), do: plan_npcs(s)
  end

  defp create_npcs(s) do
    s.runtime.state.catalog
    |> Map.get(:npc_profiles, [])
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, s}, fn profile, {:ok, s} ->
      cond do
        s.runtime.mode != :ready -> {:halt, {:ok, s}}
        Map.has_key?(s.runtime.state.owners, {:npc, profile.id}) -> {:cont, {:ok, s}}
        Map.has_key?(s.npc_given_up, {profile.id, :create}) -> {:cont, {:ok, s}}
        true -> create_npc(s, profile)
      end
    end)
  end

  defp create_npc(s, profile) do
    op = profile.id
    id = "npc:#{op}:create"
    hall = s.runtime.state

    with {:ok, slot} when slot != nil <-
           guarded(fn -> Planner.choose_slot(PublicView.build(hall), hall.layout, profile) end),
         {:ok, cuisine} <- starter_cuisine(hall.catalog) do
      payload = %{restaurant_id: "npc-#{op}", stall_id: slot, name: "NPC #{op}", cuisine: cuisine}
      npc_command(s, {op, :create}, %{command_id: id, actor: {:npc, op}, command: {:create_restaurant, payload}})
    else
      {:ok, nil} -> {:cont, {:ok, npc_failed(s, {op, :create}, id, :no_vacant_slot, :given_up)}}
      {:error, reason} -> {:cont, {:ok, npc_failed(s, {op, :create}, id, reason, :given_up)}}
    end
  end

  # Every restaurant is Mexican for now: NPCs take the cuisine of the first starter recipe.
  defp starter_cuisine(catalog) do
    case catalog.recipes |> Map.values() |> Enum.filter(& &1.starter) |> Enum.min_by(& &1.id, fn -> nil end) do
      nil -> {:error, :no_starter_recipe}
      recipe -> {:ok, recipe.cuisine}
    end
  end

  defp plan_npcs(s) do
    hall = s.runtime.state
    slot = div(hall.now, Clock.hour()) * Clock.hour()

    hall.npcs
    |> Enum.filter(fn {_op, npc} -> npc.next_slot_at <= hall.now end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, s}, fn op, {:ok, s} ->
      cond do
        s.runtime.mode != :ready -> {:halt, {:ok, s}}
        Map.get(s.npc_given_up, {op, :plan}) == slot -> {:cont, {:ok, s}}
        true -> plan_npc(s, op, slot)
      end
    end)
  end

  defp plan_npc(s, op, slot) do
    hall = s.runtime.state
    npc = hall.npcs[op]
    id = Decider.npc_plan_id(op, slot)

    with {:ok, profile} <- npc_profile(hall, npc),
         {:ok, own} <- fetch_restaurant(hall, npc.restaurant_id),
         {:ok, {actions, rng}} <-
           guarded(fn -> Planner.plan(PublicView.build(hall), own, profile, hall.catalog, npc.rng) end) do
      plan = %{operator: op, slot: slot, actions: actions, rng: rng}
      npc_command(s, {op, :plan}, %{command_id: id, actor: {:npc, op}, command: {:npc_plan, plan}}, slot)
    else
      {:error, reason} -> {:cont, {:ok, npc_failed(s, {op, :plan}, id, reason, slot)}}
    end
  end

  # Ruling R4: an NPC's profile is the one whose ID is its operator ID.
  defp npc_profile(hall, npc) do
    case Enum.find(Map.get(hall.catalog, :npc_profiles, []), &(&1.id == npc.profile_id)) do
      nil -> {:error, :unknown_npc_profile}
      profile -> {:ok, profile}
    end
  end

  defp fetch_restaurant(hall, id) do
    case hall.restaurants[id] do
      nil -> {:error, :unknown_restaurant}
      restaurant -> {:ok, restaurant}
    end
  end

  # Runs one NPC command; `{:cont | :halt, {:ok | :fenced, s}}` for `Enum.reduce_while/3`.
  defp npc_command(s, key, envelope, given_up \\ :given_up) do
    case workflow(s, envelope, nil) do
      {{:error, :fenced}, s} ->
        {:halt, {:fenced, s}}

      {{status, %{outcome: :accepted}}, s} when status in [:accepted, :replayed] ->
        {:cont, {:ok, s}}

      {{status, %{outcome: {:rejected, reason}}}, s} when status in [:rejected, :replayed] ->
        {:cont, {:ok, npc_failed(s, key, envelope.command_id, reason, given_up)}}

      {{:uncertain, _id}, s} ->
        {:halt, {:ok, npc_failed(s, key, envelope.command_id, :unknown_outcome, nil)}}

      {{:error, reason}, s} when reason in [:unavailable, :conflict, :recovery_required] ->
        {:halt, {:ok, npc_failed(s, key, envelope.command_id, reason, nil)}}

      {{:error, reason}, s} ->
        {:cont, {:ok, npc_failed(s, key, envelope.command_id, reason, given_up)}}
    end
  end

  # `given_up` (a slot, or `:given_up` for a create) marks the attempt as not to be retried; nil retries it.
  defp npc_failed(s, key, command_id, reason, given_up) do
    emit(s, :npc_planner_failed, %{
      command_id: command_id,
      reason: Diagnostics.reason(reason),
      position: s.runtime.position,
      hall_ms: s.runtime.state && s.runtime.state.now
    })

    if given_up == nil, do: s, else: %{s | npc_given_up: Map.put(s.npc_given_up, key, given_up)}
  end

  # The planner is pure, but a defect in it must not take the hall down: it is reported instead.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :planner_crashed}
  end

  # --- recovery ----------------------------------------------------------------

  # `expected_epoch` is nil at start-up and the held epoch when re-recovering after a gap. A failed
  # recovery hands back the store as it stood after its last successful step: once the acquisition
  # committed, that handle holds the newer epoch, so it is adopted (with its epoch) for the retry.
  # Only the store is adopted; the runtime keeps the last committed head until a recovery succeeds.
  defp recover(s, store, expected_epoch) do
    opts = [
      scope: s.scope,
      expected_epoch: expected_epoch,
      decode_snapshot: &Snapshot.load/1,
      diagnostics: s.diagnostics
    ]

    case shielded(fn -> Recovery.recover(s.store_mod, store, s.owner, opts) end, {:error, :unavailable, store}) do
      {:ok, runtime, report} ->
        s = %{
          s
          | runtime: runtime,
            held_epoch: runtime.epoch,
            recovery: report,
            anchor: now(s),
            service_ms: service_of(runtime)
        }

        s = snapshot_baseline(s)
        emit(s, :authority_acquired, %{position: runtime.position})
        {:ok, s}

      {:error, reason, _store} when s.runtime == nil ->
        {:error, reason, s}

      {:error, reason, store} ->
        {:error, reason, %{put_store(s, store) | held_epoch: s.store_mod.held_epoch(store)}}
    end
  end

  # Storage could not be reached (or the reply was lost): keep the anchor and try again on the next wake-up.
  defp recovery_error(s, :unavailable), do: {:error, :unavailable, storage_failure(s, :unavailable)}

  defp recovery_error(s, {:uncertain, _id}), do: {:error, :unknown_outcome, storage_failure(s, :unknown_outcome)}
  defp recovery_error(s, :fenced), do: {:fenced, s}
  defp recovery_error(s, reason), do: {:stop, {:shutdown, {:recovery_failed, reason}}, s}

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
            snapshot_failure(s, reason)
        end

      {:error, reason} ->
        snapshot_failure(s, reason)
    end
  end

  # A failed attempt counts as an attempt: the baseline moves so the next one waits a full threshold.
  defp snapshot_failure(s, :unavailable), do: s |> snapshot_baseline() |> storage_failure(:unavailable)

  defp snapshot_failure(s, reason) do
    s = snapshot_baseline(s)
    emit(s, :snapshot_failed, %{error_class: Diagnostics.reason(reason), position: s.runtime.position})
    s
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
    read = fn ->
      with head when is_integer(head) <- PostgresEventStore.head(store),
           do: {:ok, head - DailyActivityProjector.checkpoint(repo)}
    end

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

  # The epoch this authority holds: after a recovery failed past its acquisition, the newer one.
  defp emit(s, name, fields) do
    epoch = s.held_epoch
    Diagnostics.emit(s.diagnostics, name, Map.merge(%{epoch: epoch, scope: s.scope}, fields))
  end

  # Ruling R31 (narrowing R20): connection and transaction failures raised from the store, and
  # PostgreSQL errors with an unavailable code, are storage unavailability; anything else propagates.
  defp shielded(fun, unavailable) do
    fun.()
  rescue
    _error in [DBConnection.ConnectionError, DBConnection.TransactionError] ->
      unavailable

    error in Postgrex.Error ->
      if PostgresEventStore.unavailable_code?(postgres_code(error)),
        do: unavailable,
        else: reraise(error, __STACKTRACE__)
  end

  defp postgres_code(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp postgres_code(_error), do: nil
end
