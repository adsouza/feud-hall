defmodule FeudHall.Properties.PostgresTraceTest do
  @moduledoc """
  Model-based property: pure hall traces replayed through the command workflow
  on PostgreSQL, with authority restarts and injected commit failures.

  Each run generates a trace (`FeudHall.HallTrace`) and a list of injection
  points, runs the trace against the pure hall, then sends every recorded
  command, in order, through `CommandWorkflow` on an emptied database. An
  injection names a command by index (taken modulo the command count, so
  shrinking moves it towards the first command) and one of:

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

  Every receipt's outcome must equal the pure trace's outcome for that
  command. At the end the PostgreSQL hall state equals the pure trace's state
  (without `last_recovery_id`, which recovery legitimately sets), every trace
  command ID has exactly one receipt (the only others are recovery and
  availability-start receipts), `Invariants.check/1` passes, rebuilding the
  projections leaves their values unchanged, and genesis replay of the stored
  log equals the live head. Aggregate counters guard against vacuous passes.

  Budgets: 15 runs, traces of at most 40 actions, at most 12 injections per run.
  """

  use FeudHall.PostgresCase
  use ExUnitProperties

  alias FeudHall.Application.{CommandWorkflow, Recovery}
  alias FeudHall.Domain.{Control, Hall}
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.HallTrace
  alias FeudHall.Infrastructure.{PostgresEventStore, Snapshot}
  alias FeudHall.PostgresCase

  @runs 15
  @max_actions 40
  @max_injections 12
  @scope "hall:test"

  defp injection, do: tuple({integer(0..999), member_of([:snapshot, :restart, :before_commit, :lost_reply])})

  property "PostgreSQL replays pure traces exactly through restarts and injected commit failures" do
    Process.put(:pg_progress, %{
      commands: 0,
      served_trays: 0,
      snapshots: 0,
      restarts: 0,
      snapshot_tail_restarts: 0,
      reconciliations: 0,
      fenced_checks: 0,
      before_commit: 0,
      lost_replies: 0
    })

    check all(
            actions <- list_of(HallTrace.action(), max_length: @max_actions),
            injections <- list_of(injection(), max_length: @max_injections),
            max_runs: @runs,
            initial_size: 30
          ) do
      # Many runs share this one test: each starts from an emptied database.
      PostgresCase.reset!()

      trace = HallTrace.run(actions)
      envelopes = HallTrace.envelopes(trace.commands)
      count = length(envelopes)
      plan = Enum.group_by(injections, fn {index, _kind} -> rem(index, count) end, &elem(&1, 1))

      {:ok, rt} = CommandWorkflow.open(PostgresEventStore, PostgresCase.fresh_store())

      %{rt: rt} =
        envelopes
        |> Enum.zip(trace.outcomes)
        |> Enum.with_index()
        |> Enum.reduce(%{rt: rt, owners: 0, snapshot: nil}, fn {{envelope, expected}, index}, run ->
          deliver(run, envelope, expected, Map.get(plan, index, []))
        end)

      bump(:commands, count)
      bump(:served_trays, Enum.count(trace.events, &(&1.type == :tray_served)))

      # The hall the workflow committed is the pure trace's hall.
      assert strip(rt.state) == strip(trace.state)
      assert Invariants.check(rt.state) == :ok

      # Exactly one receipt per trace command; any others come from recovery.
      ids = Enum.map(envelopes, & &1.command_id)
      assert length(Enum.uniq(ids)) == count
      %{rows: rows} = Repo.query!("select command_id from receipts")
      stored = Enum.map(rows, &hd/1)
      assert MapSet.subset?(MapSet.new(ids), MapSet.new(stored))
      extras = stored -- ids
      assert length(stored) == count + length(extras)
      assert Enum.all?(extras, &(String.starts_with?(&1, "recovery:") or String.starts_with?(&1, "start:")))

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
          snapshot_tail_restarts: 3,
          reconciliations: 3,
          # Traces at this budget are short (the pure property covers lifecycle breadth); at
          # least one tray must still be served through the workflow.
          served_trays: 1
        ] do
      assert progress[key] >= min, "too little #{key} across runs: #{inspect(progress)}"
    end
  end

  # Snapshots and restarts at this index happen before the command; faults are successive
  # attempts at it, in generated order, until one commits. A fault after the command committed
  # would never reach an append (the retry is a receipt replay), so it is skipped rather than
  # left armed for the next command.
  defp deliver(run, envelope, expected, injections) do
    {run, status} =
      Enum.reduce(injections, {run, :pending}, fn
        :snapshot, {run, status} ->
          {snapshot(run), status}

        :restart, {run, status} ->
          {restart(run, if(status == :pending, do: envelope)), status}

        _fault, {run, :committed} ->
          {run, :committed}

        fault, {run, :pending} ->
          {rt, status} = attempt(run.rt, fault, envelope, expected)
          {%{run | rt: rt}, status}
      end)

    case status do
      :committed ->
        run

      :pending ->
        assert {outcome, receipt, rt} = CommandWorkflow.execute(run.rt, envelope)
        assert outcome in [:accepted, :rejected], "#{envelope.command_id}: #{inspect(outcome)}"
        assert receipt.outcome == expected, "#{envelope.command_id}: #{inspect(receipt.outcome)}"
        %{run | rt: rt}
    end
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
    if run.snapshot && report.tail_batches > 0, do: bump(:snapshot_tail_restarts)
    if report.reconciliation == :accepted, do: bump(:reconciliations)
    %{run | rt: recovered, owners: owners}
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
