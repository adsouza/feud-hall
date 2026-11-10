defmodule FeudHall.Infrastructure.HallAuthorityTest do
  # Not async: the PostgreSQL cases share the test database.
  use ExUnit.Case, async: false

  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock, PostgresEventStore, Repo}
  alias FeudHall.Infrastructure.Diagnostics.MemorySink

  @scope "hall:test"
  @alice {:principal, "alice"}
  # Player text that must never reach status output or crash reports.
  @sentinel "Sentinel Bistro 7f3a"

  defmodule FaultyStore do
    @moduledoc """
    Wraps either adapter to inject faults the adapters do not offer: `:corrupt_snapshot` (one-shot;
    the next saved snapshot body has a flipped byte), `:raise_on_save` (every snapshot save raises a
    connection error, as a dropped database would), `:undecodable` (every log read reports an
    undecodable batch, as damaged history would), and `:unavailable_after_acquire` (the next
    acquisition succeeds, then snapshot and log reads are unavailable until the acquisition after
    it), `:head_unavailable_after_acquire` (likewise for `head/1`, the first read after acquiring),
    and `{:lost_acquire_reply, once}` (the next acquisition commits but reports `:unavailable`, as a
    reply lost after the database committed would; `once` is an `:atomics` flag, since a lost reply
    hands back no store to disarm). `{:nth_append, n, fault}` arms the wrapped adapter's `fault` for
    the `n`-th append from now; `:lost_reply_then_unreadable` makes the next append commit with a
    lost reply and then makes log and snapshot reads unavailable until `:clear`;
    `{:raise_on_append, exception}` raises `exception` from the next append. Other faults go to the
    wrapped adapter.
    """
    defstruct [:mod, :inner, fault: nil]

    @own [:corrupt_snapshot, :raise_on_save, :undecodable, :unavailable_after_acquire, :head_unavailable_after_acquire]

    def wrap({mod, inner}), do: {__MODULE__, %__MODULE__{mod: mod, inner: inner}}

    def fail_next(s, fault) when fault in @own, do: %{s | fault: fault}
    def fail_next(s, {:lost_acquire_reply, _once} = fault), do: %{s | fault: fault}
    def fail_next(s, {:nth_append, n, _inner_fault} = fault) when n >= 1, do: %{s | fault: fault}
    def fail_next(s, {:raise_on_append, _exception} = fault), do: %{s | fault: fault}
    def fail_next(s, :lost_reply_then_unreadable), do: %{s | fault: :lost_reply_then_unreadable}
    def fail_next(s, :clear), do: %{s | fault: nil}
    def fail_next(s, fault), do: %{s | inner: s.mod.fail_next(s.inner, fault)}

    def head(%{fault: :head_unavailable}), do: {:error, :unavailable}
    def head(s), do: s.mod.head(s.inner)
    def stream_versions(s, stream), do: s.mod.stream_versions(s.inner, stream)
    def receipt(s, id), do: s.mod.receipt(s.inner, id)
    def held_epoch(s), do: s.mod.held_epoch(s.inner)

    def snapshots(%{fault: :reads_unavailable}), do: {:error, :unavailable}
    def snapshots(s), do: s.mod.snapshots(s.inner)

    def read_from(%{fault: :reads_unavailable}, _after), do: {:error, :unavailable}
    def read_from(%{fault: :undecodable}, _after), do: {:error, {:undecodable, 1, :injected}}
    def read_from(s, after_position), do: s.mod.read_from(s.inner, after_position)

    def append(%{fault: {:raise_on_append, exception}}, _request), do: raise(exception)

    def append(%{fault: {:nth_append, 1, inner_fault}} = s, request),
      do: append(%{s | fault: nil, inner: s.mod.fail_next(s.inner, inner_fault)}, request)

    def append(%{fault: {:nth_append, n, inner_fault}} = s, request),
      do: append_inner(%{s | fault: {:nth_append, n - 1, inner_fault}}, request)

    def append(%{fault: :lost_reply_then_unreadable} = s, request) do
      {:error, :unknown_outcome, inner} = s.mod.append(s.mod.fail_next(s.inner, :lost_reply), request)
      {:error, :unknown_outcome, %{s | inner: inner, fault: :reads_unavailable}}
    end

    def append(s, request), do: append_inner(s, request)

    defp append_inner(s, request) do
      case s.mod.append(s.inner, request) do
        {:ok, inner, position} -> {:ok, %{s | inner: inner}, position}
        {:error, reason, inner} -> {:error, reason, %{s | inner: inner}}
      end
    end

    def acquire_authority(s, scope, owner, expected \\ nil) do
      acquired =
        if expected,
          do: s.mod.acquire_authority(s.inner, scope, owner, expected),
          else: s.mod.acquire_authority(s.inner, scope, owner)

      fault =
        case s.fault do
          :unavailable_after_acquire -> :reads_unavailable
          :head_unavailable_after_acquire -> :head_unavailable
          stale when stale in [:reads_unavailable, :head_unavailable] -> nil
          other -> other
        end

      case {acquired, s.fault} do
        {{:ok, _inner, _epoch}, {:lost_acquire_reply, once}} when is_reference(once) ->
          if :atomics.compare_exchange(once, 1, 0, 1) == :ok,
            do: {:error, :unavailable},
            else: {:ok, %{s | inner: elem(acquired, 1), fault: nil}, elem(acquired, 2)}

        {{:ok, inner, epoch}, _} ->
          {:ok, %{s | inner: inner, fault: fault}, epoch}

        {error, _} ->
          error
      end
    end

    def save_snapshot(%{fault: :raise_on_save}, _position, _body),
      do: raise(DBConnection.ConnectionError, "injected snapshot save failure")

    def save_snapshot(%{fault: :corrupt_snapshot} = s, position, <<first, rest::binary>>),
      do: save_snapshot(%{s | fault: nil}, position, <<Bitwise.bxor(first, 1), rest::binary>>)

    def save_snapshot(s, position, body) do
      with {:ok, inner, id} <- s.mod.save_snapshot(s.inner, position, body), do: {:ok, %{s | inner: inner}, id}
    end

    def mark_snapshot_verified(s, id) do
      with {:ok, inner} <- s.mod.mark_snapshot_verified(s.inner, id), do: {:ok, %{s | inner: inner}}
    end

    def prune_snapshots(s, keep) do
      with {:ok, inner} <- s.mod.prune_snapshots(s.inner, keep), do: {:ok, %{s | inner: inner}}
    end
  end

  # --- helpers ---------------------------------------------------------------

  setup context do
    if context[:adapter] == :postgres, do: FeudHall.PostgresCase.reset!()
    {:ok, clock} = start_supervised({ManualClock, 0}, id: :clock)
    {:ok, sink} = start_supervised(MemorySink, id: :sink)
    %{clock: clock, sink: sink}
  end

  defp store_for(:memory), do: {InMemoryEventStore, InMemoryEventStore.new()}
  defp store_for(:postgres), do: {PostgresEventStore, PostgresEventStore.new(Repo, @scope)}

  defp start_authority(ctx, opts \\ []) do
    {store_mod, store} = Keyword.get_lazy(opts, :store, fn -> store_for(ctx.adapter) end)

    opts =
      Keyword.merge(
        [
          store_mod: store_mod,
          store: store,
          owner: "node-a",
          scope: @scope,
          clock: {ManualClock, ctx.clock},
          diagnostics: {MemorySink, ctx.sink},
          tick_ms: :manual
        ],
        Keyword.delete(opts, :store)
      )

    {restart, opts} = Keyword.pop(opts, :restart, :transient)
    start_supervised!(Supervisor.child_spec({HallAuthority, opts}, id: make_ref(), restart: restart))
  end

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp initialize(pid) do
    init = env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})
    assert {:accepted, _receipt} = HallAuthority.execute(pid, init)
    pid
  end

  defp create_sentinel,
    do:
      env(
        "create-sentinel",
        @alice,
        {:create_restaurant, %{restaurant_id: "r9", stall_id: "s009", name: @sentinel, cuisine: "mexican"}}
      )

  defp grant(id), do: env(id, {:system, :visitor_fund}, {:grant_allowance, %{principal: "bob", amount: 100}})

  defp command_ids(pid), do: pid |> batches() |> Enum.map(& &1.command_id)

  defp tick_after(ctx, pid, ms) do
    ManualClock.advance(ctx.clock, ms)
    HallAuthority.tick(pid)
  end

  defp batches(pid) do
    {store_mod, store} = HallAuthority.store(pid)
    {:ok, batches} = store_mod.read_from(store, 0)
    batches
  end

  # Two gap recoveries ran (the first failed after acquiring): the authority holds the second
  # acquired epoch, never fenced itself, and resumes from unchanged hall time.
  defp assert_recovered_twice(ctx, pid, before, ref, epochs \\ 2) do
    state = HallAuthority.state(pid)
    assert state.epoch == before.epoch + epochs
    assert state.mode == :ready
    assert state.hall.now == before.hall.now
    assert records(ctx, :fenced) == []
    assert length(records(ctx, :scheduler_gap)) == 1

    if ctx.adapter == :postgres do
      assert %{rows: [["node-a", epoch]]} = Repo.query!("select owner, epoch from authority where scope = $1", [@scope])
      assert epoch == state.epoch
    end

    assert :ok = tick_after(ctx, pid, 1_000)
    assert HallAuthority.state(pid).hall.now == before.hall.now + 1_000 * Clock.ratio()
    refute_received {:DOWN, ^ref, :process, ^pid, _}
  end

  defp records(ctx, name), do: ctx.sink |> MemorySink.records() |> Enum.filter(&(&1.name == name))

  # --- both adapters ---------------------------------------------------------

  for adapter <- [:memory, :postgres] do
    describe "#{adapter} adapter" do
      @describetag adapter: adapter

      test "three ticks of 1,000 ms move hall time by exactly 72,000 ms in three batches", ctx do
        pid = ctx |> start_authority() |> initialize()
        before = HallAuthority.state(pid)
        assert before.hall.now == 0

        for _ <- 1..3, do: assert(:ok = tick_after(ctx, pid, 1_000))

        after_ticks = HallAuthority.state(pid)
        assert after_ticks.hall.now == 72_000
        assert after_ticks.service_ms == 3_000
        assert after_ticks.position == before.position + 3

        epoch = after_ticks.epoch

        assert pid |> batches() |> Enum.take(-3) |> Enum.map(& &1.command_id) ==
                 ["tick:#{epoch}:1000", "tick:#{epoch}:2000", "tick:#{epoch}:3000"]

        assert [%{fields: %{epoch: ^epoch}}] = records(ctx, :authority_acquired)
        assert records(ctx, :tick_late) == []
      end

      test "ticks of 400 + 600 ms reach the same hall as one 1,000 ms tick", ctx do
        split = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, split, 400)
        assert :ok = tick_after(ctx, split, 600)
        split_state = HallAuthority.state(split)
        stop_supervised_authority(split, ctx)
        if ctx.adapter == :postgres, do: FeudHall.PostgresCase.reset!()

        whole = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, whole, 1_000)
        whole_state = HallAuthority.state(whole)

        assert split_state.hall.now == 24_000
        assert split_state.hall == whole_state.hall
        assert split_state.service_ms == whole_state.service_ms
      end

      test "a 6,000 ms gap appends no advance, recovers into a new epoch, and leaves hall time unchanged", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)

        assert :ok = tick_after(ctx, pid, 6_000)
        after_gap = HallAuthority.state(pid)

        assert after_gap.hall.now == before.hall.now
        assert after_gap.service_ms == before.service_ms
        assert after_gap.epoch == before.epoch + 1
        assert after_gap.mode == :ready

        new_batches = pid |> batches() |> Enum.filter(&(&1.position > before.position))
        refute Enum.any?(new_batches, &String.starts_with?(&1.command_id, "tick:"))
        assert Enum.any?(new_batches, &(&1.command_id == "start:node-a:#{after_gap.epoch}"))

        assert [%{fields: %{epoch: epoch, lateness_ms: 5_000}}] = records(ctx, :scheduler_gap)
        assert epoch == after_gap.epoch
        assert Enum.map(records(ctx, :authority_acquired), & &1.fields.epoch) == [before.epoch, after_gap.epoch]

        # The anchor was reset at the recovery: the next ordinary tick charges only its own interval.
        assert :ok = tick_after(ctx, pid, 1_000)
        assert HallAuthority.state(pid).hall.now == before.hall.now + 24_000
      end

      test "exactly the maximum gap still advances, and is reported late", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 5_000)
        state = HallAuthority.state(pid)
        assert state.hall.now == 5_000 * Clock.ratio()
        assert [%{fields: %{lateness_ms: 4_000, epoch: epoch}}] = records(ctx, :tick_late)
        assert epoch == state.epoch
        assert records(ctx, :scheduler_gap) == []
      end

      test "storage unavailable for one tick freezes the clocks; a gap past the limit then recovers", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)

        assert :ok = HallAuthority.inject_fault(pid, :before_commit)
        assert {:error, :unavailable} = tick_after(ctx, pid, 1_000)

        frozen = HallAuthority.state(pid)
        assert frozen.hall.now == before.hall.now
        assert frozen.position == before.position
        assert [%{fields: %{epoch: epoch, error_class: :unavailable}}] = records(ctx, :storage_failure)
        assert epoch == before.epoch

        # 6,000 ms unobserved since the last committed boundary: recovery, not a 6 s catch-up.
        assert :ok = tick_after(ctx, pid, 5_000)
        recovered = HallAuthority.state(pid)
        assert recovered.hall.now == before.hall.now
        assert recovered.epoch == before.epoch + 1
        assert [%{fields: %{lateness_ms: 5_000}}] = records(ctx, :scheduler_gap)

        refute pid |> batches() |> Enum.any?(&(&1.command_id == "tick:#{before.epoch}:3000"))
        refute pid |> batches() |> Enum.any?(&(&1.command_id == "tick:#{before.epoch}:7000"))
      end

      test "a lost tick reply is resolved before the next tick and is charged once", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = HallAuthority.inject_fault(pid, :lost_reply)
        assert {:error, :unknown_outcome} = tick_after(ctx, pid, 1_000)
        assert HallAuthority.state(pid).mode == :recovery_required

        assert :ok = tick_after(ctx, pid, 1_000)
        state = HallAuthority.state(pid)
        assert state.mode == :ready
        assert state.hall.now == 2_000 * Clock.ratio()
      end

      test "a command whose catch-up reply was lost commits, and same-ID retries replay it", ctx do
        pid = ctx |> start_authority() |> initialize()
        ManualClock.advance(ctx.clock, 500)

        # The lost reply belongs to the catch-up batch, which the workflow resolves itself.
        assert :ok = HallAuthority.inject_fault(pid, :lost_reply)
        assert {:accepted, receipt} = HallAuthority.execute(pid, grant("grant-1"))
        assert HallAuthority.state(pid).mode == :ready
        assert HallAuthority.state(pid).hall.now == 500 * Clock.ratio()

        for _ <- 1..3 do
          ManualClock.advance(ctx.clock, 300)
          assert {:replayed, ^receipt} = HallAuthority.execute(pid, grant("grant-1"))
        end

        ManualClock.advance(ctx.clock, 300)
        assert {:accepted, _} = HallAuthority.execute(pid, grant("grant-2"))
        assert Enum.filter(command_ids(pid), &String.starts_with?(&1, "adv:")) == ["adv:500", "adv:1700"]
      end

      test "a catch-up that committed before its command's append failed does not block a retry", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        ManualClock.advance(ctx.clock, 500)

        assert :ok = HallAuthority.inject_fault(pid, {:nth_append, 2, :unavailable})
        assert {:error, :unavailable} = HallAuthority.execute(pid, grant("grant-1"))
        assert HallAuthority.state(pid).hall.now == 500 * Clock.ratio()

        # The same ID, observed later, catches up to its own target and commits.
        ManualClock.advance(ctx.clock, 300)
        assert {:accepted, _} = HallAuthority.execute(pid, grant("grant-1"))
        assert HallAuthority.state(pid).hall.now == 800 * Clock.ratio()
        assert Enum.take(command_ids(pid), -3) == ["adv:500", "adv:800", "grant-1"]

        # A lost reply on the command's own append is reported under the caller's own ID.
        ManualClock.advance(ctx.clock, 300)
        assert :ok = HallAuthority.inject_fault(pid, {:nth_append, 2, :lost_reply})
        assert {:uncertain, "grant-2"} = HallAuthority.execute(pid, grant("grant-2"))
        ManualClock.advance(ctx.clock, 300)
        assert {:replayed, %{outcome: :accepted}} = HallAuthority.execute(pid, grant("grant-2"))
      end

      test "a lost catch-up reply that cannot be resolved reports the command unavailable", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        ManualClock.advance(ctx.clock, 500)

        assert :ok = HallAuthority.inject_fault(pid, :lost_reply_then_unreadable)
        assert {:error, :unavailable} = HallAuthority.execute(pid, grant("grant-1"))
        assert HallAuthority.state(pid).mode == :recovery_required
        assert [%{fields: %{error_class: :unavailable}}] = records(ctx, :storage_failure)

        # Once the store is readable, the pending catch-up is resolved before the retry runs.
        assert :ok = HallAuthority.inject_fault(pid, :clear)
        ManualClock.advance(ctx.clock, 300)
        assert {:accepted, _} = HallAuthority.execute(pid, grant("grant-1"))
        assert HallAuthority.state(pid).hall.now == 800 * Clock.ratio()
        assert Enum.take(command_ids(pid), -3) == ["adv:500", "adv:800", "grant-1"]
      end

      test "execute/2 ignores any caller clock and stamps the authority's own", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        ManualClock.advance(ctx.clock, 700)

        create =
          env(
            "create",
            @alice,
            {:create_restaurant, %{restaurant_id: "r1", stall_id: "s002", name: "Casa", cuisine: "mexican"}}
          )
          |> Map.merge(%{observed_service_ms: 9_000_000, hall_ms: 9_000_000})

        assert {:accepted, _receipt} = HallAuthority.execute(pid, create)

        state = HallAuthority.state(pid)
        assert state.hall.now == 1_700 * Clock.ratio()
        assert state.service_ms == 1_700
        assert Map.has_key?(state.hall.restaurants, "r1")
        assert "adv:1700" in command_ids(pid)

        # The command's advance moved the anchor: the next tick charges only the time after it.
        assert :ok = tick_after(ctx, pid, 300)
        assert HallAuthority.state(pid).hall.now == 2_000 * Clock.ratio()
      end

      test "before the hall is initialised a tick only moves the anchor", ctx do
        pid = start_authority(ctx)
        position = HallAuthority.state(pid).position
        assert :ok = tick_after(ctx, pid, 3_000)
        assert HallAuthority.state(pid).hall == nil
        assert HallAuthority.state(pid).position == position

        initialize(pid)
        assert :ok = tick_after(ctx, pid, 1_000)
        assert HallAuthority.state(pid).hall.now == 1_000 * Clock.ratio()
      end

      test "snapshots are taken, verified, and pruned; a fresh authority recovers from one", ctx do
        pid = ctx |> start_authority(snapshot_every_events: 5) |> initialize()
        for _ <- 1..12, do: assert(:ok = tick_after(ctx, pid, 1_000))

        {store_mod, store} = HallAuthority.store(pid)
        snapshots = store_mod.snapshots(store)
        verified = Enum.filter(snapshots, & &1.verified)
        assert verified != []
        assert length(verified) <= 2
        assert length(snapshots) == length(verified)

        taken = records(ctx, :snapshot_taken)
        assert taken != []
        assert Enum.all?(taken, &(is_integer(&1.fields.snapshot_position) and is_integer(&1.fields.duration_us)))
        latest = hd(verified).position
        assert List.last(taken).fields.snapshot_position == latest

        if ctx.adapter == :postgres do
          assert [_ | _] = backlog = records(ctx, :projection_backlog)
          assert Enum.all?(backlog, &is_integer(&1.fields.backlog))
        else
          assert records(ctx, :projection_backlog) == []
        end

        hall = HallAuthority.state(pid).hall
        stop_supervised_authority(pid, ctx)

        fresh_store = if ctx.adapter == :memory, do: {store_mod, store}, else: store_for(:postgres)
        fresh = start_authority(ctx, store: fresh_store, owner: "node-b")
        state = HallAuthority.state(fresh)
        assert state.recovery.snapshot == latest
        assert state.hall.now == hall.now
        assert state.hall.restaurants == hall.restaurants

        assert Enum.any?(records(ctx, :recovery_completed), &(&1.fields[:snapshot_position] == latest))
      end

      test "a failed snapshot check verifies nothing and waits a full threshold before retrying", ctx do
        pid =
          ctx
          |> start_authority(
            store: FaultyStore.wrap(store_for(ctx.adapter)),
            snapshot_every_events: 1_000_000,
            snapshot_every_service_ms: 3_000
          )
          |> initialize()

        assert :ok = HallAuthority.inject_fault(pid, :corrupt_snapshot)
        for _ <- 1..3, do: assert(:ok = tick_after(ctx, pid, 1_000))

        {mod, store} = HallAuthority.store(pid)
        assert [%{verified: false}] = mod.snapshots(store)
        assert [%{fields: %{error_class: :corrupt_snapshot}}] = records(ctx, :snapshot_failed)
        assert records(ctx, :snapshot_taken) == []
        assert records(ctx, :storage_failure) == []

        # The failed attempt reset the baseline: the next two commits do not retry.
        for _ <- 1..2, do: assert(:ok = tick_after(ctx, pid, 1_000))
        {mod, store} = HallAuthority.store(pid)
        assert length(mod.snapshots(store)) == 1
        assert length(records(ctx, :snapshot_failed)) == 1

        # A full threshold later the next attempt is made, and it succeeds.
        assert :ok = tick_after(ctx, pid, 1_000)
        position = HallAuthority.state(pid).position
        {mod, store} = HallAuthority.store(pid)
        assert [%{position: ^position, verified: true}, %{verified: false}] = mod.snapshots(store)
        assert [%{fields: %{snapshot_position: ^position}}] = records(ctx, :snapshot_taken)
      end

      test "a snapshot save that raises is a storage failure that neither stops nor hurries the authority", ctx do
        pid =
          ctx
          |> start_authority(
            store: FaultyStore.wrap(store_for(ctx.adapter)),
            snapshot_every_events: 1_000_000,
            snapshot_every_service_ms: 3_000
          )
          |> initialize()

        assert :ok = HallAuthority.inject_fault(pid, :raise_on_save)
        for _ <- 1..5, do: assert(:ok = tick_after(ctx, pid, 1_000))
        assert [%{fields: %{error_class: :unavailable}}] = records(ctx, :storage_failure)

        assert :ok = tick_after(ctx, pid, 1_000)
        assert length(records(ctx, :storage_failure)) == 2
        assert records(ctx, :snapshot_failed) == []

        {mod, store} = HallAuthority.store(pid)
        assert mod.snapshots(store) == []
        assert Process.alive?(pid)
        assert HallAuthority.state(pid).hall.now == 6_000 * Clock.ratio()
      end

      test "a lost reply during gap recovery is retried by the next tick from the epoch it acquired", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)
        ref = Process.monitor(pid)

        assert :ok = HallAuthority.inject_fault(pid, :lost_reply)
        assert {:error, :unknown_outcome} = tick_after(ctx, pid, 6_000)

        # Still more than the maximum gap since the last committed boundary: recovery runs again.
        assert :ok = HallAuthority.tick(pid)
        assert_recovered_twice(ctx, pid, before, ref)
      end

      test "storage unavailable after a gap recovery's acquisition is retried from the acquired epoch", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)
        ref = Process.monitor(pid)

        assert :ok = HallAuthority.inject_fault(pid, :unavailable_after_acquire)
        assert {:error, :unavailable} = tick_after(ctx, pid, 6_000)
        assert [%{fields: %{error_class: :unavailable}}] = records(ctx, :storage_failure)

        assert :ok = HallAuthority.tick(pid)
        assert_recovered_twice(ctx, pid, before, ref)
      end

      test "head unavailable right after a gap recovery's acquisition is retried from the acquired epoch", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)
        ref = Process.monitor(pid)

        assert :ok = HallAuthority.inject_fault(pid, :head_unavailable_after_acquire)
        assert {:error, :unavailable} = tick_after(ctx, pid, 6_000)
        assert [%{fields: %{error_class: :unavailable}}] = records(ctx, :storage_failure)

        assert :ok = HallAuthority.tick(pid)
        assert_recovered_twice(ctx, pid, before, ref)
      end

      test "a lost reply to the gap recovery's own acquisition is recognised on retry", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)
        ref = Process.monitor(pid)

        once = :atomics.new(1, [])
        assert :ok = HallAuthority.inject_fault(pid, {:lost_acquire_reply, once})
        assert {:error, :unavailable} = tick_after(ctx, pid, 6_000)

        # PostgreSQL committed the lost acquisition, so the retry bumps past it; the in-memory store is
        # a value, so a lost reply there loses the acquisition itself.
        assert :ok = HallAuthority.tick(pid)
        assert_recovered_twice(ctx, pid, before, ref, if(ctx.adapter == :postgres, do: 2, else: 1))
      end

      test "a recovery that fails after a gap shuts the authority down", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        ref = Process.monitor(pid)
        assert :ok = HallAuthority.inject_fault(pid, :undecodable)

        reason = {:recovery_failed, {:undecodable, 1, :injected}}
        assert {:error, ^reason} = tick_after(ctx, pid, 6_000)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, ^reason}}
        assert [%{fields: %{error_class: :undecodable}}] = records(ctx, :recovery_failed)
      end

      test "status shows scalar authority fields, never the hall, the store, or player text", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert {:accepted, _} = HallAuthority.execute(pid, create_sentinel())
        %{position: position, epoch: epoch} = HallAuthority.state(pid)

        status = pid |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
        refute status =~ @sentinel
        # Neither the catalog nor the store handle appears.
        refute status =~ "rice_long"
        refute status =~ "Store"
        assert status =~ "position: #{position}"
        assert status =~ "epoch: #{epoch}"
        assert status =~ "mode: :ready"
      end

      test "a raised driver error with an unavailable code freezes the clocks", ctx do
        pid = ctx |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        before = HallAuthority.state(pid)

        error = Postgrex.Error.exception(postgres: %{code: "57P01", severity: "FATAL", message: "injected shutdown"})
        assert error.postgres.code == :admin_shutdown
        assert :ok = HallAuthority.inject_fault(pid, {:raise_on_append, error})
        assert {:error, :unavailable} = tick_after(ctx, pid, 1_000)

        frozen = HallAuthority.state(pid)

        assert {frozen.hall.now, frozen.position, frozen.service_ms} ==
                 {before.hall.now, before.position, before.service_ms}

        assert [%{fields: %{error_class: :unavailable}}] = records(ctx, :storage_failure)

        # The next tick charges the whole frozen interval once the store accepts appends again.
        assert :ok = HallAuthority.inject_fault(pid, :clear)
        assert :ok = tick_after(ctx, pid, 1_000)
        assert HallAuthority.state(pid).hall.now == before.hall.now + 2_000 * Clock.ratio()
      end

      test "any other raised driver error is not swallowed, and its crash report omits player text", ctx do
        pid =
          ctx
          |> start_authority(store: FaultyStore.wrap(store_for(ctx.adapter)), restart: :temporary)
          |> initialize()

        assert {:accepted, _} = HallAuthority.execute(pid, create_sentinel())
        ref = Process.monitor(pid)

        error = Postgrex.Error.exception(postgres: %{code: "42P01", severity: "ERROR", message: "injected bug"})
        assert error.postgres.code == :undefined_table
        assert :ok = HallAuthority.inject_fault(pid, {:raise_on_append, error})

        # Crash reports include the process state only at debug level.
        level = Logger.level()
        Logger.configure(level: :debug)
        on_exit(fn -> Logger.configure(level: level) end)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {{%Postgrex.Error{}, _stack}, _call} = catch_exit(tick_after(ctx, pid, 1_000))
            assert_receive {:DOWN, ^ref, :process, ^pid, {%Postgrex.Error{postgres: %{code: :undefined_table}}, _}}
          end)

        assert log =~ "injected bug"
        refute log =~ @sentinel
        refute log =~ "rice_long"
        assert log =~ "State: %{"
        assert log =~ "position:"
      end

      test "a fenced append stops the authority with {:shutdown, :fenced}", ctx do
        pid = ctx |> start_authority() |> initialize()
        epoch = HallAuthority.state(pid).epoch
        ref = Process.monitor(pid)
        assert :ok = HallAuthority.inject_fault(pid, :fenced)
        assert {:error, :fenced} = tick_after(ctx, pid, 1_000)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :fenced}}
        assert [%{fields: %{epoch: ^epoch}}] = records(ctx, :fenced)
      end
    end
  end

  # --- NPCs ------------------------------------------------------------------------

  # Service milliseconds per game hour, so one tick of this length crosses exactly one boundary.
  @hour_service div(Clock.hour(), Clock.ratio())
  @operators ~w(budget mainstream premium)

  # Long ticks need a gap limit above the tick length.
  defp npc_authority(ctx, opts \\ []), do: start_authority(ctx, Keyword.merge([max_gap_ms: 10 * @hour_service], opts))

  defp initialize_with(pid, catalog) do
    init = env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: catalog}})
    assert {:accepted, _receipt} = HallAuthority.execute(pid, init)
    pid
  end

  defp events(pid), do: pid |> batches() |> Enum.flat_map(& &1.events)
  defp planned(pid), do: pid |> events() |> Enum.filter(&(&1.type == :npc_planned))
  defp planned_slots(pid), do: pid |> planned() |> Enum.map(&{&1.operator, &1.slot})
  defp npc_ids(pid), do: pid |> command_ids() |> Enum.filter(&String.starts_with?(&1, "npc:"))

  defp restart(ctx, pid, owner) do
    {store_mod, store} = HallAuthority.store(pid)
    stop_supervised_authority(pid, ctx)
    fresh_store = if ctx.adapter == :memory, do: {store_mod, store}, else: FaultyStore.wrap(store_for(:postgres))
    npc_authority(ctx, store: fresh_store, owner: owner)
  end

  for adapter <- [:memory, :postgres] do
    describe "#{adapter} adapter NPCs" do
      @describetag adapter: adapter

      test "initializing the hall creates one NPC restaurant per profile in its preferred tier", ctx do
        pid = ctx |> npc_authority() |> initialize()
        hall = HallAuthority.state(pid).hall

        for {op, tier} <- Enum.zip(@operators, [:quiet, :standard, :prime]) do
          rid = hall.owners[{:npc, op}]
          name = "NPC " <> op
          assert %{owner_kind: :npc, owner: ^op, name: ^name} = hall.restaurants[rid]
          assert [%{tier: ^tier, mode: :closed}] = for({_, s} <- hall.stalls, s.restaurant == rid, do: s)
          assert %{restaurant_id: ^rid, profile_id: ^op, next_slot_at: 3_600_000} = hall.npcs[op]
        end

        assert map_size(hall.restaurants) == 3
        assert npc_ids(pid) == Enum.map(@operators, &"npc:#{&1}:create")
        assert records(ctx, :npc_planner_failed) == []
      end

      test "a hall initialised without NPC profiles has no NPCs", ctx do
        pid = ctx |> npc_authority() |> initialize_with(%{SliceCatalog.catalog() | npc_profiles: []})
        assert :ok = tick_after(ctx, pid, @hour_service)
        hall = HallAuthority.state(pid).hall
        assert hall.restaurants == %{} and hall.npcs == %{}
        assert npc_ids(pid) == []
      end

      test "each crossed hour boundary is planned once per NPC; one long advance plans only the latest", ctx do
        pid = ctx |> npc_authority() |> initialize()
        for _ <- 1..3, do: assert(:ok = tick_after(ctx, pid, @hour_service))

        expected = for h <- 1..3, op <- @operators, do: {op, h * Clock.hour()}
        assert planned_slots(pid) == expected
        assert Enum.take(npc_ids(pid), -3) == Enum.map(@operators, &"npc:#{&1}:#{3 * Clock.hour()}")

        hall = HallAuthority.state(pid).hall
        assert Enum.all?(@operators, &(hall.npcs[&1].next_slot_at == 4 * Clock.hour()))
        # The first plan opened every NPC stall.
        assert hall.stalls |> Map.values() |> Enum.all?(&(&1.mode == :open))

        # A tick inside the hour plans nothing more.
        assert :ok = tick_after(ctx, pid, 1_000)
        assert length(planned(pid)) == 9
        stop_supervised_authority(pid, ctx)
        if ctx.adapter == :postgres, do: FeudHall.PostgresCase.reset!()

        long = ctx |> npc_authority() |> initialize()
        assert :ok = tick_after(ctx, long, 3 * @hour_service)
        assert planned_slots(long) == for(op <- @operators, do: {op, 3 * Clock.hour()})
        assert records(ctx, :npc_planner_failed) == []
      end

      test "planning continues during cleaning", ctx do
        pid = ctx |> npc_authority() |> initialize()
        for _ <- 1..4, do: assert(:ok = tick_after(ctx, pid, @hour_service))

        hall = HallAuthority.state(pid).hall
        assert hall.access == :cleaning
        cleaning = for {op, slot} <- planned_slots(pid), Clock.cleaning?(slot), do: {op, slot}
        assert cleaning == for(h <- 3..4, op <- @operators, do: {op, h * Clock.hour()})
        assert Enum.all?(@operators, &(hall.npcs[&1].next_slot_at == 5 * Clock.hour()))
      end

      test "(Review Focus 4) an NPC with no cash and no stock commits its plan and the authority keeps running",
           ctx do
        catalog = put_in(SliceCatalog.catalog(), [:rules, :starter_grant], 0)
        pid = ctx |> npc_authority() |> initialize_with(catalog)
        assert :ok = tick_after(ctx, pid, @hour_service)

        hall = HallAuthority.state(pid).hall
        assert Enum.all?(@operators, &(hall.npcs[&1].next_slot_at == 2 * Clock.hour()))
        assert Enum.all?(Map.values(hall.restaurants), &(&1.ledger.cash == 0 and &1.batches == %{}))

        # The plan's purchase requests carry no cash; the next clearing refuses each with a reason.
        requested = Map.keys(hall.market.requests)
        assert requested != []
        assert Enum.all?(requested, &String.starts_with?(&1, "PR:npc:"))

        interval = catalog.rules.market.clear_every_hall_ms
        assert :ok = tick_after(ctx, pid, div(interval, Clock.ratio()))
        clearing = pid |> events() |> Enum.filter(&(&1.type == :market_cleared)) |> List.last()
        refused = for u <- clearing.unfilled, u.request_id in requested, do: {u.request_id, u.reason}
        assert Enum.sort(refused) == Enum.sort(for id <- requested, do: {id, :insufficient_cash})

        assert :ok = tick_after(ctx, pid, @hour_service)
        assert Process.alive?(pid)
        assert HallAuthority.state(pid).hall.npcs["budget"].next_slot_at == 3 * Clock.hour()
        assert records(ctx, :npc_planner_failed) == []
      end

      test "an NPC without a profile is reported once per slot and does not stop the others", ctx do
        pid = ctx |> npc_authority() |> initialize()

        ghost =
          env(
            "npc:ghost:create",
            {:npc, "ghost"},
            {:create_restaurant, %{restaurant_id: "npc-ghost", stall_id: "s050", name: "Ghost", cuisine: "mexican"}}
          )

        assert {:accepted, _} = HallAuthority.execute(pid, ghost)
        assert :ok = tick_after(ctx, pid, @hour_service)
        assert :ok = tick_after(ctx, pid, 1_000)

        assert [%{fields: %{command_id: "npc:ghost:3600000", reason: :unknown_npc_profile}} = failed] =
                 records(ctx, :npc_planner_failed)

        assert failed.severity == :warning
        assert planned_slots(pid) == for(op <- @operators, do: {op, Clock.hour()})

        assert :ok = tick_after(ctx, pid, @hour_service - 1_000)

        assert Enum.map(records(ctx, :npc_planner_failed), & &1.fields.command_id) == [
                 "npc:ghost:3600000",
                 "npc:ghost:7200000"
               ]

        assert HallAuthority.state(pid).hall.npcs["ghost"].next_slot_at == Clock.hour()
        assert Process.alive?(pid)
      end

      test "a bootstrap create whose reply was lost is not duplicated after a restart", ctx do
        pid = npc_authority(ctx, store: FaultyStore.wrap(store_for(ctx.adapter)))
        assert :ok = HallAuthority.inject_fault(pid, {:nth_append, 2, :lost_reply})
        initialize(pid)

        assert HallAuthority.state(pid).mode == :recovery_required

        assert [%{fields: %{command_id: "npc:budget:create", reason: :unknown_outcome}}] =
                 records(ctx, :npc_planner_failed)

        fresh = restart(ctx, pid, "node-b")
        hall = HallAuthority.state(fresh).hall
        assert Enum.sort(Map.keys(hall.npcs)) == @operators
        assert map_size(hall.restaurants) == 3
        assert npc_ids(fresh) == Enum.map(@operators, &"npc:#{&1}:create")

        # The committed create's own ID and payload return its original receipt.
        stall = hall.stalls |> Map.values() |> Enum.find(&(&1.restaurant == hall.owners[{:npc, "budget"}]))

        retry =
          env(
            "npc:budget:create",
            {:npc, "budget"},
            {:create_restaurant,
             %{restaurant_id: hall.owners[{:npc, "budget"}], stall_id: stall.id, name: "NPC budget", cuisine: "mexican"}}
          )

        assert {:replayed, %{outcome: :accepted, command_id: "npc:budget:create"}} = HallAuthority.execute(fresh, retry)
        assert npc_ids(fresh) == Enum.map(@operators, &"npc:#{&1}:create")

        if ctx.adapter == :postgres do
          %{rows: rows} = Repo.query!("select distinct actor from events where causation_id like 'npc:%' order by 1")
          assert rows == Enum.map(@operators, &["npc:#{&1}"])
        end
      end

      test "a plan whose reply was lost is not planned again after a restart", ctx do
        pid = ctx |> npc_authority(store: FaultyStore.wrap(store_for(ctx.adapter))) |> initialize()
        assert :ok = HallAuthority.inject_fault(pid, {:nth_append, 2, :lost_reply})
        assert :ok = tick_after(ctx, pid, @hour_service)
        assert HallAuthority.state(pid).mode == :recovery_required

        fresh = restart(ctx, pid, "node-b")
        slot = Clock.hour()
        assert planned_slots(fresh) == for(op <- @operators, do: {op, slot})

        # The planner, rerun on the state its command saw, rebuilds the same command: its ID replays.
        id = "npc:budget:#{slot}"
        before = fresh |> batches() |> Enum.take_while(&(&1.command_id != id)) |> Enum.flat_map(& &1.events)
        state = FeudHall.Domain.Hall.replay(before)
        npc = state.npcs["budget"]
        profile = Enum.find(state.catalog.npc_profiles, &(&1.id == "budget"))
        own = state.restaurants[npc.restaurant_id]
        view = FeudHall.Domain.PublicView.build(state)
        {actions, rng} = FeudHall.Domain.Npc.Planner.plan(view, own, profile, state.catalog, npc.rng)
        plan = {:npc_plan, %{operator: "budget", slot: slot, actions: actions, rng: rng}}

        assert {:replayed, %{outcome: :accepted, command_id: ^id}} =
                 HallAuthority.execute(fresh, env(id, {:npc, "budget"}, plan))

        assert planned_slots(fresh) == for(op <- @operators, do: {op, slot})
      end
    end
  end

  # --- PostgreSQL only ---------------------------------------------------------

  # A value-typed in-memory store cannot be shared between two processes, so a real takeover by a
  # second authority is exercised on PostgreSQL only.
  describe "postgres takeover" do
    @describetag adapter: :postgres

    test "a second authority acquiring the scope makes the first stop on its next append", ctx do
      a = ctx |> start_authority() |> initialize()
      a_epoch = HallAuthority.state(a).epoch
      ref = Process.monitor(a)

      b = start_authority(ctx, store: store_for(:postgres), owner: "node-b")
      b_epoch = HallAuthority.state(b).epoch
      assert b_epoch == a_epoch + 1

      assert {:error, :fenced} = tick_after(ctx, a, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^a, {:shutdown, :fenced}}

      assert [%{fields: %{epoch: ^a_epoch}}] = records(ctx, :fenced)
      assert Enum.map(records(ctx, :authority_acquired), & &1.fields.epoch) == [a_epoch, b_epoch]

      # The new owner keeps advancing the committed hall.
      assert :ok = HallAuthority.tick(b)
      assert HallAuthority.state(b).hall.now == 1_000 * Clock.ratio()
    end

    test "a paused authority does not take the hall back from its successor after a gap", ctx do
      a = ctx |> start_authority() |> initialize()
      a_epoch = HallAuthority.state(a).epoch
      ref = Process.monitor(a)

      # A is suspended for more than the maximum gap; meanwhile B takes over.
      ManualClock.advance(ctx.clock, 6_000)
      b = start_authority(ctx, store: store_for(:postgres), owner: "node-b")
      b_epoch = HallAuthority.state(b).epoch

      assert {:error, :fenced} = HallAuthority.tick(a)
      assert_receive {:DOWN, ^ref, :process, ^a, {:shutdown, :fenced}}
      assert [%{fields: %{epoch: ^a_epoch}}] = records(ctx, :fenced)
      assert records(ctx, :scheduler_gap) == []
      assert records(ctx, :recovery_failed) == []

      # B still holds the hall and keeps advancing it under its own epoch.
      assert :ok = tick_after(ctx, b, 1_000)
      state = HallAuthority.state(b)
      assert state.epoch == b_epoch
      assert state.hall.now == 1_000 * Clock.ratio()
      assert %{rows: [[^b_epoch]]} = Repo.query!("select epoch from authority where scope = $1", [@scope])
    end
  end

  describe "postgres stored terms" do
    @describetag adapter: :postgres

    test "a retry whose stored receipt cannot be decoded is an error reply, not a crash", ctx do
      pid = ctx |> start_authority() |> initialize()

      # A receipt naming an atom this build does not define (as a newer release could write).
      name = "feud_hall_never_defined_" <> Integer.to_string(System.unique_integer([:positive]))
      body = Base.encode64(<<131, 119, byte_size(name), name::binary>>)
      Repo.query!("update receipts set body = $1 where command_id = 'init'", [body])

      init = env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})
      assert {:error, {:undecodable_receipt, "init"}} = HallAuthority.execute(pid, init)
      assert Process.alive?(pid)
      assert :ok = tick_after(ctx, pid, 1_000)
    end
  end

  describe "supervision" do
    test "the application runs an authority supervisor" do
      assert is_pid(Process.whereis(FeudHall.AuthoritySupervisor))
      assert %{active: _} = DynamicSupervisor.count_children(FeudHall.AuthoritySupervisor)
    end
  end

  defp stop_supervised_authority(pid, _ctx) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
