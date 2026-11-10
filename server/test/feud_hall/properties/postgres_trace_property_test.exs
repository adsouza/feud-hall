defmodule FeudHall.Properties.PostgresTraceTest do
  @moduledoc """
  Model-based property: pure hall traces replayed through the command workflow
  on PostgreSQL, with authority restarts and injected commit failures.

  Each run generates trace actions (`FeudHall.HallTrace`), appends the
  closing service (`HallTrace.closing/0`: reopen the stall, a lunch peak, an
  NPC planning slot), runs the trace against the pure hall (whose setup
  creates the catalog's NPC restaurants, so NPC creation and plans are
  recorded commands too), checks that the run reached the structural floors
  of `HallTrace.floors/1` (a clearing with a fill, a stream arrival admitted
  and one that left, a served tray, an NPC plan), and then generates
  injection points for the recorded commands. It sends every recorded
  command, in order, through `CommandWorkflow` on an emptied database. An
  injection names a command by its index in the recorded list (generated
  within range, so no wrapping) and one of:

    * `:snapshot`: before the command, a verified snapshot of the head is
      stored, so later restarts recover from it plus the tail after it;
    * `:restart`: before the command, a new owner recovers the hall with
      `Recovery.recover/4` (from the newest verified snapshot, if any); the
      previous runtime must then be fenced;
    * `:before_commit`: the command's append aborts before commit
      (`:unavailable`, no receipt), then the same envelope is retried;
    * `:lost_reply`: the append commits but its reply is lost
      (`:uncertain`); the runtime refuses work until `resolve/2` finds the
      original receipt, and a retry replays it.

  Observed-clock arm: every other accepted scheduler advance that moves the
  hall forward and has a successor (alternating from a generated parity) is
  not sent as its own command. Its target is instead passed as the
  successor's `observed_service_ms`, so the workflow commits the same advance
  as a catch-up batch under `CommandWorkflow.catch_up_id/1` before deciding
  the successor. Faults planned for the merged advance move to the
  successor, and each merge also arms, in a cycle from a generated offset, a
  lost reply, a before-commit failure, or nothing on that delivery. While the
  catch-up is still due such a fault hits the catch-up append: a lost reply
  is resolved inside the workflow (the successor still commits, and a retry
  replays it), and a before-commit failure fails the successor, which is
  then retried with the same observed instant.

  Every receipt's outcome must equal the pure trace's outcome for that
  command. At the end the PostgreSQL hall state equals the pure trace's state
  (without `last_recovery_id`, which recovery legitimately sets), every
  delivered trace command ID has exactly one receipt, each merged advance has
  none and is matched by exactly one catch-up receipt (the only other receipts
  are recovery and availability-start ones), `Invariants.check/1` passes,
  rebuilding the projections leaves their values unchanged, and genesis
  replay of the stored log equals the live head.

  Every run's injections hold one of each kind on a gameplay command (an index
  past the fixture setup): a snapshot, a later restart (so that restart
  replays a tail after the snapshot), a before-commit failure, and then a lost
  reply. At most 12 random extras, which may also hit setup commands, follow.
  At one index the fixed injections come first, so each kind is exercised in
  every run; aggregate floors across runs restate that and also require
  served trays and snapshot recoveries with a non-empty trace tail, and catch-ups
  with lost replies and before-commit failures on their appends.

  Budgets: 15 runs, traces of at most 40 generated actions (plus the closing
  service), at most 4 + 12 injections per run; the test's ExUnit timeout is
  the default 60 seconds.
  """

  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, Recovery}
  alias FeudHall.Domain.{Clock, Control, Hall}
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.HallTrace
  alias FeudHall.Infrastructure.{PostgresEventStore, Snapshot}
  alias FeudHall.Oracle
  alias FeudHall.PostgresCase

  @runs 15
  @max_actions 40
  @max_injections 12
  @scope "hall:test"

  @kinds [:snapshot, :restart, :before_commit, :lost_reply]

  # The fixed part targets gameplay commands (indices `setup..count - 1`); the closing service
  # always records at least three, so a snapshot index below the last leaves room for a later restart.
  defp injections(setup, count) do
    gen all(
          snapshot <- integer(setup..(count - 2)),
          restart <- integer((snapshot + 1)..(count - 1)),
          before_commit <- integer(setup..(count - 1)),
          lost_reply <- integer(setup..(count - 1)),
          extras <- list_of(tuple({integer(0..(count - 1)), member_of(@kinds)}), max_length: @max_injections)
        ) do
      [{snapshot, :snapshot}, {restart, :restart}, {before_commit, :before_commit}, {lost_reply, :lost_reply} | extras]
    end
  end

  @catch_up_faults [:lost_reply, :before_commit, :none]

  property "PostgreSQL replays pure traces exactly through restarts and injected commit failures" do
    Process.put(:pg_progress, %{
      commands: 0,
      served_trays: 0,
      gameplay_injections: 0,
      snapshots: 0,
      restarts: 0,
      snapshot_tail_restarts: 0,
      reconciliations: 0,
      fenced_checks: 0,
      before_commit: 0,
      lost_replies: 0,
      catch_ups: 0,
      catch_up_before_commits: 0,
      catch_up_lost_replies: 0
    })

    check all(
            actions <- list_of(HallTrace.action(), max_length: @max_actions),
            trace = HallTrace.run(actions ++ HallTrace.closing()),
            count = length(trace.commands),
            injections <- injections(trace.setup_count, count),
            parity <- integer(0..1),
            fault_offset <- integer(0..(length(@catch_up_faults) - 1)),
            max_runs: @runs,
            initial_size: 30
          ) do
      # Structural floors: every run reaches the market, diners, kitchen, and NPCs.
      floors = HallTrace.floors(trace)
      assert Enum.all?(floors, fn {_key, n} -> n >= 1 end), "run below a structural floor: #{inspect(floors)}"

      # Many runs share this one test: each starts from an emptied database.
      PostgresCase.reset!()

      envelopes = HallTrace.envelopes(trace.commands)
      plan = Enum.group_by(injections, &elem(&1, 0), &elem(&1, 1))

      {:ok, rt} = CommandWorkflow.open(PostgresEventStore, PostgresCase.fresh_store())

      start = %{
        rt: rt,
        owners: 0,
        snapshot: nil,
        observed: nil,
        carried: [],
        merged: [],
        eligible: 0,
        parity: parity,
        fault_offset: fault_offset
      }

      %{rt: rt, merged: merged} =
        envelopes
        |> Enum.zip(trace.outcomes)
        |> Enum.with_index()
        |> Enum.reduce(start, fn {{envelope, expected}, index}, run ->
          injections = Map.get(plan, index, [])
          gameplay? = index >= trace.setup_count

          # Every other mergeable advance is merged, alternating from the generated parity.
          case mergeable(run, envelope, expected, index + 1 < count) do
            {:ok, target} ->
              run = %{run | eligible: run.eligible + 1}

              if rem(run.eligible, 2) == run.parity,
                do: merge(run, envelope, target, injections, gameplay?),
                else: deliver(run, envelope, expected, injections, gameplay?)

            :no ->
              deliver(run, envelope, expected, injections, gameplay?)
          end
        end)

      bump(:commands, count)
      bump(:served_trays, Enum.count(trace.events, &(&1.type == :tray_served)))

      # The hall the workflow committed is the pure trace's hall.
      assert strip(rt.state) == strip(trace.state)
      assert Invariants.check(rt.state) == :ok

      # The independent oracle agrees on the property's own final state and the stored log.
      assert {:ok, stored_batches} = PostgresEventStore.read_from(rt.store, 0)
      assert Oracle.violations(rt.state, Enum.flat_map(stored_batches, & &1.events)) == []

      # Exactly one receipt per delivered trace command, none for a merged advance, one catch-up
      # receipt per merged advance; any others come from recovery.
      ids = Enum.map(envelopes, & &1.command_id)
      assert length(Enum.uniq(ids)) == count
      delivered = ids -- merged
      %{rows: rows} = Repo.query!("select command_id from receipts")
      stored = Enum.map(rows, &hd/1)
      assert MapSet.subset?(MapSet.new(delivered), MapSet.new(stored))
      assert Enum.all?(merged, &(&1 not in stored))
      extras = stored -- delivered
      assert length(stored) == length(delivered) + length(extras)
      {catch_ups, others} = Enum.split_with(extras, &String.starts_with?(&1, "adv:"))
      assert length(catch_ups) == length(merged)
      assert Enum.all?(others, &(String.starts_with?(&1, "recovery:") or String.starts_with?(&1, "start:")))

      # Rebuilt projections carry the same values (only their positions move to the head).
      before = projections(rt.store)
      assert :ok = PostgresEventStore.rebuild_projections(rt.store)
      assert projections(rt.store) == before

      # Genesis replay of the stored log reproduces the live head.
      assert {:ok, batches} = PostgresEventStore.read_from(rt.store, 0)
      assert batches |> Enum.flat_map(& &1.events) |> Hall.replay() == rt.state
      assert batches |> Enum.flat_map(& &1.control_events) |> Control.replay() == rt.control
      assert PostgresEventStore.head(rt.store) == rt.position
    end

    progress = Process.get(:pg_progress)

    # Non-vacuity: the runs must exercise every injected path.
    for {key, min} <- [
          restarts: 10,
          before_commit: 10,
          lost_replies: 10,
          gameplay_injections: 10,
          snapshot_tail_restarts: 3,
          reconciliations: 3,
          served_trays: 10,
          catch_ups: 15,
          catch_up_lost_replies: 4,
          catch_up_before_commits: 4
        ] do
      assert progress[key] >= min, "too little #{key} across runs: #{inspect(progress)}"
    end
  end

  # An accepted scheduler advance that moves the hall forward, and has a successor to carry it.
  defp mergeable(
         %{rt: %{state: %{now: now}}, observed: nil},
         %{actor: {:system, :scheduler}, command: {:advance_clock, %{to_service_ms: target}}},
         :accepted,
         true
       ),
       do: if(Clock.hall_at_service(target) > now, do: {:ok, target}, else: :no)

  defp mergeable(_run, _envelope, _expected, _successor?), do: :no

  # The advance is not sent: snapshots and restarts planned for it happen now, its faults move to
  # the successor, which carries the target as its observed instant (with the next cycled fault).
  defp merge(run, envelope, target, injections, gameplay?) do
    run =
      Enum.reduce(injections, run, fn
        :snapshot, run ->
          if gameplay?, do: bump(:gameplay_injections)
          snapshot(run)

        :restart, run ->
          if gameplay?, do: bump(:gameplay_injections)
          restart(run, envelope)

        _fault, run ->
          run
      end)

    faults = Enum.filter(injections, &(&1 in [:before_commit, :lost_reply]))
    cycled = Enum.at(@catch_up_faults, rem(run.fault_offset + length(run.merged), length(@catch_up_faults)))
    carried = if cycled == :none, do: faults, else: [cycled | faults]

    bump(:catch_ups)
    %{run | observed: target, carried: carried, merged: [envelope.command_id | run.merged]}
  end

  # Snapshots and restarts at this index happen before the command; faults are successive
  # attempts at it, in generated order, until one commits. A fault after the command committed
  # would never reach an append (the retry is a receipt replay), so it is skipped rather than
  # left armed for the next command. Faults carried from a merged advance come first.
  defp deliver(run, envelope, expected, injections, gameplay?) do
    observed = run.observed

    {run, status} =
      Enum.reduce(run.carried ++ injections, {%{run | carried: []}, :pending}, fn
        fault, {run, :committed} when fault in [:before_commit, :lost_reply] ->
          {run, :committed}

        kind, {run, status} ->
          if gameplay?, do: bump(:gameplay_injections)

          case kind do
            :snapshot ->
              {snapshot(run), status}

            :restart ->
              {restart(run, if(status == :pending, do: envelope)), status}

            fault ->
              {rt, status} = attempt(run.rt, fault, envelope, expected, observed)
              {%{run | rt: rt}, status}
          end
      end)

    run = %{run | observed: nil}

    case status do
      :committed ->
        run

      :pending ->
        assert {outcome, receipt, rt} = CommandWorkflow.execute(run.rt, envelope, observed)
        assert outcome in [:accepted, :rejected], "#{envelope.command_id}: #{inspect(outcome)}"
        assert receipt.outcome == expected, "#{envelope.command_id}: #{inspect(receipt.outcome)}"
        if observed, do: assert({:ok, _} = PostgresEventStore.receipt(rt.store, CommandWorkflow.catch_up_id(observed)))
        %{run | rt: rt}
    end
  end

  # While the catch-up is still due, the armed fault hits its append, not the command's.
  defp attempt(rt, fault, envelope, expected, observed) do
    if observed && Clock.hall_at_service(observed) > rt.state.now,
      do: attempt_catch_up(rt, fault, envelope, expected, observed),
      else: attempt(rt, fault, envelope, expected)
  end

  defp attempt_catch_up(rt, :before_commit, envelope, _expected, observed) do
    armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable, rt} = CommandWorkflow.execute(armed, envelope, observed)
    assert rt.mode == :ready
    assert PostgresEventStore.receipt(rt.store, CommandWorkflow.catch_up_id(observed)) == :none
    assert PostgresEventStore.receipt(rt.store, envelope.command_id) == :none
    assert PostgresEventStore.head(rt.store) == rt.position
    bump(:before_commit)
    bump(:catch_up_before_commits)
    {rt, :pending}
  end

  # The catch-up's lost reply is resolved inside the workflow: the command itself still commits.
  defp attempt_catch_up(rt, :lost_reply, envelope, expected, observed) do
    id = envelope.command_id
    armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :lost_reply)}
    assert {outcome, receipt, rt} = CommandWorkflow.execute(armed, envelope, observed)
    assert outcome in [:accepted, :rejected], "#{id}: #{inspect(outcome)}"
    assert receipt.outcome == expected, "#{id}: #{inspect(receipt.outcome)}"
    assert rt.mode == :ready
    assert {:ok, %{outcome: :accepted}} = PostgresEventStore.receipt(rt.store, CommandWorkflow.catch_up_id(observed))
    assert {:replayed, ^receipt, rt} = CommandWorkflow.execute(rt, envelope, observed)
    bump(:lost_replies)
    bump(:catch_up_lost_replies)
    {rt, :committed}
  end

  defp attempt(rt, :before_commit, envelope, _expected) do
    armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable, rt} = CommandWorkflow.execute(armed, envelope)
    assert PostgresEventStore.receipt(rt.store, envelope.command_id) == :none
    assert PostgresEventStore.head(rt.store) == rt.position
    bump(:before_commit)
    {rt, :pending}
  end

  defp attempt(rt, :lost_reply, envelope, expected) do
    id = envelope.command_id
    armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :lost_reply)}
    assert {:uncertain, ^id, rt} = CommandWorkflow.execute(armed, envelope)
    assert {:error, :recovery_required, rt} = CommandWorkflow.execute(rt, envelope)
    assert {:committed, receipt, rt} = CommandWorkflow.resolve(rt, id)
    assert receipt.outcome == expected, "#{id}: #{inspect(receipt.outcome)}"
    assert {:replayed, ^receipt, rt} = CommandWorkflow.execute(rt, envelope)
    bump(:lost_replies)
    {rt, :committed}
  end

  defp snapshot(%{rt: %{state: nil}} = run), do: run

  defp snapshot(%{rt: rt} = run) do
    body = Snapshot.take(%{hall: rt.state, control: rt.control}, rt.position)
    assert {:ok, store, id} = PostgresEventStore.save_snapshot(rt.store, rt.position, body)
    assert {:ok, store} = PostgresEventStore.mark_snapshot_verified(store, id)
    bump(:snapshots)
    %{run | rt: %{rt | store: store}, snapshot: rt.position}
  end

  # A new authority incarnation (a unique owner name) recovers the hall from the newest verified
  # snapshot plus its tail. The runtime it replaced must be fenced on its next append, checked
  # with the still-pending command, which a fenced append leaves unrecorded.
  defp restart(%{rt: rt} = run, pending_envelope) do
    owners = run.owners + 1

    assert {:ok, recovered, report} =
             Recovery.recover(PostgresEventStore, rt.store, "p#{owners}",
               scope: @scope,
               decode_snapshot: &Snapshot.load/1
             )

    assert strip(recovered.state) == strip(rt.state)
    assert report.snapshot == (run.snapshot || :genesis)
    assert report.skipped == []

    if pending_envelope do
      assert {:error, :fenced, _old} = CommandWorkflow.execute(rt, pending_envelope)
      assert PostgresEventStore.receipt(recovered.store, pending_envelope.command_id) == :none
      bump(:fenced_checks)
    end

    bump(:restarts)
    if run.snapshot && trace_tail?(recovered.store, run.snapshot), do: bump(:snapshot_tail_restarts)
    if report.reconciliation == :accepted, do: bump(:reconciliations)
    %{run | rt: recovered, owners: owners}
  end

  # Whether a batch after the snapshot came from a trace command: recovery batches hold only
  # control events and `hall_resumed`.
  defp trace_tail?(store, position) do
    assert {:ok, tail} = PostgresEventStore.read_from(store, position)
    Enum.any?(tail, fn batch -> Enum.any?(batch.events, &(&1.type != :hall_resumed)) end)
  end

  defp strip(nil), do: nil
  defp strip(state), do: Map.delete(state, :last_recovery_id)

  defp projections(store) do
    for table <- [:balances, :stock], into: %{} do
      {table, store |> PostgresEventStore.projection(table) |> Enum.map(&Map.delete(&1, :position))}
    end
  end

  defp bump(key, by \\ 1), do: Process.put(:pg_progress, Map.update!(Process.get(:pg_progress), key, &(&1 + by)))
end
