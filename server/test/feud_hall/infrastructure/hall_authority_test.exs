defmodule FeudHall.Infrastructure.HallAuthorityTest do
  # Not async: the PostgreSQL cases share the test database.
  use ExUnit.Case, async: false

  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock, PostgresEventStore, Repo}
  alias FeudHall.Infrastructure.Diagnostics.MemorySink

  @scope "hall:test"
  @alice {:principal, "alice"}

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

    start_supervised!(Supervisor.child_spec({HallAuthority, opts}, id: make_ref()))
  end

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp initialize(pid) do
    init = env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})
    assert {:accepted, _receipt} = HallAuthority.execute(pid, init)
    pid
  end

  defp tick_after(ctx, pid, ms) do
    ManualClock.advance(ctx.clock, ms)
    HallAuthority.tick(pid)
  end

  defp batches(pid) do
    {store_mod, store} = HallAuthority.store(pid)
    {:ok, batches} = store_mod.read_from(store, 0)
    batches
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

      test "execute/2 ignores any caller clock and stamps the authority's own", ctx do
        pid = ctx |> start_authority() |> initialize()
        assert :ok = tick_after(ctx, pid, 1_000)
        ManualClock.advance(ctx.clock, 700)

        create =
          env(
            "create",
            @alice,
            {:create_restaurant, %{restaurant_id: "r1", stall_id: "s1", name: "Casa", cuisine: "mexican"}}
          )
          |> Map.merge(%{observed_service_ms: 9_000_000, hall_ms: 9_000_000})

        assert {:accepted, _receipt} = HallAuthority.execute(pid, create)

        state = HallAuthority.state(pid)
        assert state.hall.now == 1_700 * Clock.ratio()
        assert state.service_ms == 1_700
        assert Map.has_key?(state.hall.restaurants, "r1")
        assert pid |> batches() |> Enum.any?(&(&1.command_id == "adv:create"))

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
