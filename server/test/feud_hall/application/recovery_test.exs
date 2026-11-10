defmodule FeudHall.Application.RecoveryTest do
  # Not async: the PostgreSQL cases share the test database.
  use ExUnit.Case, async: false

  alias FeudHall.Application.{CommandWorkflow, Recovery}
  alias FeudHall.Domain.{Clock, Control, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.Invariants
  alias FeudHall.Infrastructure.{HallAuthority, InMemoryEventStore, ManualClock, PostgresEventStore, Repo, Snapshot}

  @scope "hall:test"
  @authority {:system, :authority}
  @alice {:principal, "alice"}

  defmodule DamagedStore do
    @moduledoc """
    The in-memory store with one damaged batch, as a durable log could be damaged:
    `{:undecodable, position}` makes reads that reach it stop with the adapter's
    `{:undecodable, ...}` error; `{:missing, position}` silently drops that batch from reads.
    """
    alias FeudHall.Infrastructure.InMemoryEventStore, as: Inner

    def acquire_authority({store, damage}, scope, owner) do
      {:ok, store, epoch} = Inner.acquire_authority(store, scope, owner)
      {:ok, {store, damage}, epoch}
    end

    def read_from({store, damage}, after_position) do
      {:ok, batches} = Inner.read_from(store, after_position)

      case damage do
        {:undecodable, position} ->
          if Enum.any?(batches, &(&1.position == position)),
            do: {:error, {:undecodable, position, {:unknown_atom, "launch_missiles"}}},
            else: {:ok, batches}

        {:missing, position} ->
          {:ok, Enum.reject(batches, &(&1.position == position))}
      end
    end

    def snapshots({store, _}), do: Inner.snapshots(store)
    def head({store, _}), do: Inner.head(store)
    def stream_versions({store, _}, stream), do: Inner.stream_versions(store, stream)
    def receipt({store, _}, id), do: Inner.receipt(store, id)

    def append({store, damage}, request) do
      case Inner.append(store, request) do
        {:ok, store, head} -> {:ok, {store, damage}, head}
        {:error, reason, store} -> {:error, reason, {store, damage}}
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp no_side_effects, do: fn effect -> flunk("recovery performed a side effect: #{inspect(effect)}") end

  defp recover(mod, store, owner, opts \\ []),
    do: Recovery.recover(mod, store, owner, [scope: @scope, side_effects: no_side_effects()] ++ opts)

  defp recover_from_snapshots(mod, store, owner), do: recover(mod, store, owner, decode_snapshot: &Snapshot.load/1)

  defp adapter(:memory), do: {InMemoryEventStore, InMemoryEventStore.new()}

  defp adapter(:postgres) do
    FeudHall.PostgresCase.reset!()
    {PostgresEventStore, PostgresEventStore.new(Repo, @scope)}
  end

  defp purchase(product, qty),
    do:
      {:submit_purchase_request, %{restaurant_id: "r1", product: product, qty: qty, max_price_per_kunit: 1_000_000_000}}

  defp first_commands do
    [
      {env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}}), nil},
      {env(
         "create",
         @alice,
         {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: "Casa", cuisine: "mexican"}}
       ), nil},
      {env("buy-rice", @alice, purchase("rice_long", 100)), 1_000}
    ]
  end

  defp later_commands do
    [
      {env("buy-milk", @alice, purchase("milk_whole", 200)), 2_000},
      {env("buy-sugar", @alice, purchase("sugar", 50)), nil},
      # Observed past the first market clearing (10 s of service): the pending requests fill.
      {env("buy-rice-2", @alice, purchase("rice_long", 30)), 11_000}
    ]
  end

  defp run(rt, commands) do
    Enum.reduce(commands, rt, fn {envelope, observed}, rt ->
      assert {:accepted, _, rt} = CommandWorkflow.execute(rt, envelope, observed)
      rt
    end)
  end

  # A hall whose availability epoch "boot:1" was started by recovery and which then ran
  # commands; the authority that held it is gone (its epoch is interrupted).
  defp live({mod, store}) do
    assert {:ok, rt, %{recovery_id: nil}} = recover(mod, store, "boot")
    assert rt.control.current_epoch == "boot:1"
    run(rt, first_commands())
  end

  defp save_snapshot(rt, body, position, verified? \\ true) do
    mod = rt.store_mod
    {:ok, store, id} = mod.save_snapshot(rt.store, position, body)
    {:ok, store} = if verified?, do: mod.mark_snapshot_verified(store, id), else: {:ok, store}
    {%{rt | store: store}, id}
  end

  defp snapshot(rt), do: Snapshot.take(%{hall: rt.state, control: rt.control}, rt.position)

  defp corrupt(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>

  defp incompatible(position) do
    body = :erlang.term_to_binary(%{position: position, evolution: 1, state: nil}, [:deterministic])
    :crypto.hash(:sha256, body) <> body
  end

  # A checksummed snapshot whose state names an atom this build has never defined, as a
  # snapshot written by a newer release could. The placeholder atom has the same length as
  # the unknown text, so swapping the bytes keeps the external term format valid.
  defp unknown_atom_snapshot(rt) do
    body =
      :erlang.term_to_binary(
        %{position: rt.position, evolution: Snapshot.evolution_version(), state: %{hall: :recovery_test_placeholder}},
        [:deterministic]
      )

    body = :binary.replace(body, "recovery_test_placeholder", "zz_never_defined_atom_qqq")
    :crypto.hash(:sha256, body) <> body
  end

  # An evolution 2 snapshot as the previous release wrote it: the hall state lacks everything the shared
  # simulation added (layout, seed, NPCs, market requests, stall counters, stage fields, demand
  # bookkeeping, simulated-arrival stats). Loading it would crash the evolver on the next event.
  defp evolution_2_snapshot(rt) do
    hall =
      rt.state
      |> Map.drop([:layout, :seed, :npcs])
      |> update_in([:market], &Map.drop(&1, [:requests, :by_key, :next_clear_at]))
      |> update_in([:demand], &Map.drop(&1, [:observed_ms, :next_day_at, :acc_millis, :acc_at, :arrival_seq]))
      |> update_in([:stats], &Map.drop(&1, [:arrivals_simulated, :admitted_simulated, :left_simulated]))
      |> update_in([:stalls], &Map.new(&1, fn {id, stall} -> {id, Map.delete(stall, :counter)} end))

    body =
      :erlang.term_to_binary(
        %{position: rt.position, evolution: 2, state: %{hall: hall, control: rt.control}},
        [:deterministic]
      )

    :crypto.hash(:sha256, body) <> body
  end

  # An evolution 3 snapshot as the shared simulation's first release wrote it: its demand state
  # lacks the last recorded operating list, which `clock_advanced` events without the key need.
  defp evolution_3_snapshot(rt) do
    hall = update_in(rt.state, [:demand], &Map.delete(&1, :operating))

    body =
      :erlang.term_to_binary(
        %{position: rt.position, evolution: 3, state: %{hall: hall, control: rt.control}},
        [:deterministic]
      )

    :crypto.hash(:sha256, body) <> body
  end

  defp resumed(state, id), do: Hall.replay([%{type: :hall_resumed, recovery_id: id}], state)

  defp batches_after(mod, store, position) do
    {:ok, batches} = mod.read_from(store, position)
    batches
  end

  defp resumed_batches(mod, store) do
    store |> batches_after_all(mod) |> Enum.filter(&Enum.any?(&1.events, fn e -> e.type == :hall_resumed end))
  end

  defp batches_after_all(store, mod), do: batches_after(mod, store, 0)

  # --- shared scenarios ---------------------------------------------------------

  for adapter <- [:memory, :postgres] do
    describe "#{adapter}" do
      setup do
        {mod, store} = adapter(unquote(adapter))
        %{adapter: unquote(adapter), mod: mod, store: store}
      end

      test "genesis and snapshot recovery reach the live state at the same position", %{adapter: a, mod: mod} do
        build = fn ->
          rt = live(adapter(a))
          {rt, _id} = save_snapshot(rt, snapshot(rt), rt.position)
          {run(rt, later_commands()), rt.position}
        end

        {live, snap_position} = build.()
        assert {:ok, genesis, report} = recover(mod, live.store, "b")

        assert report == %{
                 snapshot: :genesis,
                 skipped: [],
                 tail_batches: live.position,
                 recovery_id: "recovery:boot:1",
                 reconciliation: :accepted
               }

        {live_again, ^snap_position} = build.()
        assert live_again.state == live.state
        assert {:ok, from_snapshot, report} = recover_from_snapshots(mod, live_again.store, "b")
        assert report.snapshot == snap_position
        assert report.tail_batches == live.position - snap_position
        assert report.skipped == []

        for rt <- [genesis, from_snapshot] do
          assert rt.state == resumed(live.state, "recovery:boot:1")
          assert rt.position == live.position + 2
          assert rt.epoch == 2
          assert rt.mode == :ready
          assert rt.control.current_epoch == "b:2"
          assert MapSet.member?(rt.control.reconciled, "recovery:boot:1")
        end

        assert from_snapshot.control == genesis.control
        assert from_snapshot.versions == genesis.versions

        # The recovered runtime is the genesis replay of what the store now holds, and it accepts work.
        assert {:ok, reopened} = CommandWorkflow.open(mod, from_snapshot.store)

        assert {reopened.state, reopened.control, reopened.versions, reopened.position} ==
                 {from_snapshot.state, from_snapshot.control, from_snapshot.versions, from_snapshot.position}

        assert {:accepted, _, _} =
                 CommandWorkflow.execute(from_snapshot, env("buy-after", @alice, purchase("sugar", 5)))
      end

      test "unusable snapshots fall back to the previous verified one, recording each skip", %{mod: mod, store: store} do
        rt = live({mod, store})
        {rt, _} = save_snapshot(rt, snapshot(rt), rt.position)
        good = rt.position
        rt = run(rt, later_commands())
        {rt, corrupt_id} = save_snapshot(rt, corrupt(snapshot(rt)), rt.position)
        # Unverified snapshots are never candidates, even when newer and intact.
        {rt, _} = save_snapshot(rt, snapshot(rt), rt.position, false)
        # A snapshot claiming a position beyond the durable head cannot describe committed state.
        beyond = rt.position + 5
        {rt, beyond_id} = save_snapshot(rt, Snapshot.take(%{hall: rt.state, control: rt.control}, beyond), beyond)

        assert {:ok, recovered, report} = recover_from_snapshots(mod, rt.store, "b")
        assert report.snapshot == good
        assert report.skipped == [{beyond_id, :beyond_head}, {corrupt_id, :corrupt_snapshot}]
        assert report.tail_batches == rt.position - good
        assert recovered.state == resumed(rt.state, "recovery:boot:1")
      end

      test "with no usable snapshot recovery replays from genesis, recording both skips", %{mod: mod, store: store} do
        rt = live({mod, store})
        {rt, older} = save_snapshot(rt, incompatible(rt.position), rt.position)
        rt = run(rt, later_commands())
        {rt, unknown} = save_snapshot(rt, unknown_atom_snapshot(rt), rt.position)
        {rt, newer} = save_snapshot(rt, corrupt(snapshot(rt)), rt.position)

        assert {:ok, recovered, report} = recover_from_snapshots(mod, rt.store, "b")
        assert report.snapshot == :genesis

        assert report.skipped == [
                 {newer, :corrupt_snapshot},
                 {unknown, :incompatible_snapshot},
                 {older, :incompatible_snapshot}
               ]

        assert report.tail_batches == rt.position
        assert recovered.state == resumed(rt.state, "recovery:boot:1")
      end

      test "an evolution 3 snapshot is skipped as incompatible and never loaded", %{mod: mod, store: store} do
        assert Snapshot.evolution_version() == 4

        rt = live({mod, store})
        {rt, old} = save_snapshot(rt, evolution_3_snapshot(rt), rt.position)
        assert Snapshot.evolution_of(evolution_3_snapshot(rt)) == 3
        assert {:error, :incompatible_snapshot} = Snapshot.load(evolution_3_snapshot(rt))
        rt = run(rt, later_commands())

        assert {:ok, recovered, report} = recover_from_snapshots(mod, rt.store, "b")
        assert report.snapshot == :genesis
        assert report.skipped == [{old, :incompatible_snapshot}]
        assert report.tail_batches == rt.position
        assert recovered.state == resumed(rt.state, "recovery:boot:1")
      end

      test "an evolution 2 snapshot is skipped as incompatible and never loaded", %{mod: mod, store: store} do
        assert Snapshot.evolution_version() == 4

        rt = live({mod, store})
        {rt, old} = save_snapshot(rt, evolution_2_snapshot(rt), rt.position)
        assert Snapshot.evolution_of(evolution_2_snapshot(rt)) == 2
        assert {:error, :incompatible_snapshot} = Snapshot.load(evolution_2_snapshot(rt))
        rt = run(rt, later_commands())

        assert {:ok, recovered, report} = recover_from_snapshots(mod, rt.store, "b")
        assert report.snapshot == :genesis
        assert report.skipped == [{old, :incompatible_snapshot}]
        assert report.tail_batches == rt.position
        assert recovered.state == resumed(rt.state, "recovery:boot:1")
      end

      test "recovery of an interrupted epoch appends exactly one reconciliation batch", %{mod: mod, store: store} do
        live = live({mod, store})
        assert {:ok, a, report} = recover(mod, live.store, "a")
        assert %{recovery_id: "recovery:boot:1", reconciliation: :accepted} = report

        assert [reconciliation, start] = batches_after(mod, a.store, live.position)
        assert reconciliation.command_id == "recovery:boot:1"
        assert reconciliation.events == [%{type: :hall_resumed, recovery_id: "recovery:boot:1"}]

        assert reconciliation.control_events == [
                 %{type: :availability_resumed, recovery_id: "recovery:boot:1", hall_ms: live.state.now}
               ]

        assert start.command_id == "start:a:2"
        assert start.control_events == [%{type: :availability_started, epoch_id: "a:2"}]
        assert length(resumed_batches(mod, a.store)) == 1

        # The next owner reconciles the epoch "a" left behind, not "boot" again.
        assert {:ok, b, %{recovery_id: "recovery:a:2", reconciliation: :accepted}} = recover(mod, a.store, "b")
        assert b.control.current_epoch == "b:3"
        assert length(resumed_batches(mod, b.store)) == 2
      end

      test "an owner retrying a reconciliation that already committed gets the original receipt",
           %{mod: mod, store: store} do
        live = live({mod, store})

        # Owner "c" reconciles the interrupted epoch exactly as recovery does, then stops
        # before starting its own epoch.
        {:ok, store, 2} = mod.acquire_authority(live.store, @scope, "c")
        {:ok, c} = CommandWorkflow.open(mod, store, epoch: 2)
        reconcile = env("recovery:boot:1", @authority, {:reconcile_recovery, %{recovery_id: "recovery:boot:1"}})
        assert {:accepted, receipt, c} = CommandWorkflow.execute(c, reconcile)
        head = c.position

        assert {:ok, d, report} = recover(mod, c.store, "d")
        assert %{recovery_id: "recovery:boot:1", reconciliation: :replayed} = report
        assert mod.receipt(d.store, "recovery:boot:1") == {:ok, receipt}
        assert [%{command_id: "start:d:3"}] = batches_after(mod, d.store, head)
        assert d.position == head + 1
        assert d.control.current_epoch == "d:3"
        assert length(resumed_batches(mod, d.store)) == 1
      end

      test "with an expected epoch, recovery re-acquires only if that epoch is still current",
           %{mod: mod, store: store} do
        assert {:ok, a, _} = recover(mod, store, "a")
        assert {:ok, b, _} = recover(mod, a.store, "b", expected_epoch: a.epoch)
        assert b.epoch == a.epoch + 1
        head = mod.head(b.store)

        # "b" superseded the epoch "a" held: recovery is fenced before it reads or appends anything.
        assert {:error, :fenced, _store} = recover(mod, b.store, "a", expected_epoch: a.epoch)
        assert mod.head(b.store) == head
      end

      test "a failure after acquisition returns the store holding the acquired epoch", %{mod: mod, store: store} do
        live = live({mod, store})
        armed = mod.fail_next(live.store, :lost_reply)

        assert {:error, {:uncertain, "recovery:boot:1"}, held} = recover(mod, armed, "c", expected_epoch: live.epoch)
        assert mod.held_epoch(held) == live.epoch + 1

        # Retrying from the epoch actually held succeeds and replays the committed reconciliation.
        assert {:ok, c, %{reconciliation: :replayed}} = recover(mod, held, "c", expected_epoch: live.epoch + 1)
        assert c.epoch == live.epoch + 2
        assert c.state.now == live.state.now
      end

      test "a failure before acquisition returns the store it was given", %{mod: mod, store: store} do
        assert {:error, :invalid_owner, ^store} = recover(mod, store, "")
      end

      test "a store with no hall starts an epoch without reconciling", %{mod: mod, store: store} do
        assert {:ok, a, %{snapshot: :genesis, tail_batches: 0, recovery_id: nil, reconciliation: nil}} =
                 recover(mod, store, "a")

        assert a.state == nil
        assert a.control.current_epoch == "a:1"

        # The epoch "a" began before any hall existed, so there is no hall to resume.
        assert {:ok, b, %{recovery_id: nil, reconciliation: nil}} = recover(mod, a.store, "b")
        assert b.control.current_epoch == "b:2"
        assert b.position == 2
      end

      test "a broken invariant in the recovered state aborts recovery and appends nothing", %{mod: mod, store: store} do
        rt = live({mod, store})
        broken = update_in(rt.state, [:restaurants, "r1", :ledger, :cash], &(&1 + 1))
        {rt, _} = save_snapshot(rt, Snapshot.take(%{hall: broken, control: rt.control}, rt.position), rt.position)

        assert {:error, {:invariants, [{"r1", :trial_balance}]}, _} = recover_from_snapshots(mod, rt.store, "b")
        assert mod.head(rt.store) == rt.position
        assert mod.receipt(rt.store, "recovery:boot:1") == :none

        # The same log replayed from genesis is consistent: the snapshot was the damaged copy.
        assert {:ok, _, %{snapshot: :genesis}} = recover(mod, rt.store, "b")
      end

      test "replay never invokes the side-effect function", %{mod: mod, store: store} do
        rt = live({mod, store})
        {rt, _} = save_snapshot(rt, snapshot(rt), rt.position)
        snap_position = rt.position
        rt = run(rt, later_commands())
        test = self()
        effects = fn effect -> send(test, {:side_effect, effect}) end

        assert {:ok, _, %{snapshot: ^snap_position, tail_batches: tail}} =
                 Recovery.recover(mod, rt.store, "b",
                   scope: @scope,
                   decode_snapshot: &Snapshot.load/1,
                   side_effects: effects
                 )

        assert tail == rt.position - snap_position
        refute_received {:side_effect, _}
      end
    end
  end

  # --- a hall recovered mid-day --------------------------------------------------

  describe "a hall with NPCs, customers and pending purchases" do
    # Service milliseconds in a quarter of a game hour.
    @quarter div(Clock.hour(), 4 * Clock.ratio())

    defp start_hall(store, owner) do
      {:ok, clock} = start_supervised({ManualClock, 0}, id: {:clock, owner})

      opts = [
        store_mod: InMemoryEventStore,
        store: store,
        owner: owner,
        scope: @scope,
        clock: {ManualClock, clock},
        tick_ms: :manual,
        max_gap_ms: 10 * div(Clock.hour(), Clock.ratio()),
        # Only the snapshot this test takes: the authority never takes its own.
        snapshot_every_events: 1_000_000_000,
        snapshot_every_service_ms: 1_000_000_000_000
      ]

      pid = start_supervised!(Supervisor.child_spec({HallAuthority, opts}, id: {:authority, owner}))
      %{pid: pid, clock: clock}
    end

    defp tick(%{pid: pid, clock: clock}, ms) do
      ManualClock.advance(clock, ms)
      assert :ok = HallAuthority.tick(pid)
    end

    # Every hall event after `position`, in order, without the recovery marker.
    defp hall_events_after(%{pid: pid}, position) do
      {mod, store} = HallAuthority.store(pid)
      {:ok, batches} = mod.read_from(store, position)
      batches |> Enum.flat_map(& &1.events) |> Enum.reject(&(&1.type == :hall_resumed))
    end

    defp live_orders(hall),
      do:
        hall.orders
        |> Map.values()
        |> Enum.filter(&(&1.status in [:queued_prep, :prep, :queued_finish, :finish, :ready]))

    test "recovery from a snapshot taken mid-day reproduces the live state and then the same events as an uninterrupted run" do
      a = start_hall(InMemoryEventStore.new(), "node-a")

      init =
        env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog()}})

      assert {:accepted, _} = HallAuthority.execute(a.pid, init)

      # Ten game hours of NPC planning and diners, then two game minutes into the next hour: the NPCs
      # have just filed that hour's purchase requests and the market has not yet cleared them.
      for _ <- 1..39, do: tick(a, @quarter)
      tick(a, @quarter + 5_000)

      mid = HallAuthority.state(a.pid)
      assert rem(mid.hall.now, Clock.hour()) == 120_000
      assert map_size(mid.hall.market.requests) > 0
      assert live_orders(mid.hall) != []
      # An order at a station, so the snapshot really carries kitchen stage fields.
      assert Enum.any?(live_orders(mid.hall), &(&1.status in [:prep, :finish] and is_integer(&1.stage_done_at)))
      assert mid.hall.demand.arrival_seq > 0 and mid.hall.demand.next_arrival_at > mid.hall.now
      assert mid.hall.stats.arrivals_simulated > 0
      assert map_size(mid.hall.npcs) == 3
      assert Enum.all?(mid.hall.npcs, fn {_op, npc} -> npc.next_slot_at == 11 * Clock.hour() end)
      assert Invariants.check(mid.hall) == :ok

      snapshot = Snapshot.take(%{hall: mid.hall, control: mid.control}, mid.position)

      # The hall carries on past the snapshot: requests clear, diners are served.
      for ms <- [2_000, 3_000, @quarter], do: tick(a, ms)
      live = HallAuthority.state(a.pid)
      assert live.position > mid.position
      assert live.hall.market.requests == %{}

      # The same log in stores of their own: with the mid-day snapshot (and the tail after it), with a
      # snapshot at the head (no tail, so nothing replayed can mask what the snapshot dropped), and with none.
      {mod, head_store} = HallAuthority.store(a.pid)
      head_snapshot = Snapshot.take(%{hall: live.hall, control: live.control}, live.position)

      with_snapshot = fn store, body, position ->
        {:ok, store, id} = mod.save_snapshot(store, position, body)
        {:ok, store} = mod.mark_snapshot_verified(store, id)
        store
      end

      mid_store = with_snapshot.(head_store, snapshot, mid.position)
      head_snapshot_store = with_snapshot.(head_store, head_snapshot, live.position)

      assert {:ok, _, %{snapshot: snapshot_position, tail_batches: tail}} =
               recover_from_snapshots(mod, mid_store, "probe")

      assert snapshot_position == mid.position
      assert tail == live.position - mid.position

      b = start_hall(mid_store, "node-b")
      c = start_hall(head_store, "node-c")
      d = start_hall(head_snapshot_store, "node-d")
      [b_state, c_state, d_state] = for hall <- [b, c, d], do: HallAuthority.state(hall.pid)

      assert b_state.recovery.snapshot == mid.position
      assert c_state.recovery.snapshot == :genesis
      assert c_state.recovery.tail_batches == live.position
      assert d_state.recovery.snapshot == live.position
      assert d_state.recovery.tail_batches == 0

      # Live, genesis replay, snapshot-tail and head-snapshot state agree at the same committed position.
      resumed_live = resumed(live.hall, "recovery:node-a:1")
      assert b_state.hall == resumed_live
      assert c_state.hall == resumed_live
      assert d_state.hall == resumed_live
      assert b_state.control.current_epoch == "node-b:2"
      assert Invariants.check(b_state.hall) == :ok

      # Afterwards all four, driven identically across the next NPC slot, produce identical events.
      halls = [a, b, c, d]
      for ms <- [@quarter, @quarter, @quarter, @quarter + 7_000], hall <- halls, do: tick(hall, ms)

      from_live = hall_events_after(a, live.position)

      recovered =
        for {hall, state} <- [{b, b_state}, {c, c_state}, {d, d_state}],
            do: hall_events_after(hall, state.position)

      types = from_live |> Enum.map(& &1.type) |> MapSet.new()

      for type <- ~w(npc_planned purchase_requested market_cleared diner_arrived clock_advanced)a,
          do: assert(type in types, "the continuation never produced #{type}")

      for events <- recovered, do: assert(events == from_live)

      [final | finals] = for hall <- halls, do: Map.delete(HallAuthority.state(hall.pid).hall, :last_recovery_id)
      for other <- finals, do: assert(other == final)
    end
  end

  # --- adapter-specific ---------------------------------------------------------

  describe "an undecodable event" do
    test "aborts in-memory recovery with the store's error and appends nothing" do
      rt = live(adapter(:memory))
      damaged = {rt.store, {:undecodable, 3}}

      assert {:error, {:undecodable, 3, {:unknown_atom, "launch_missiles"}}, _} =
               Recovery.recover(DamagedStore, damaged, "b", scope: @scope, side_effects: no_side_effects())
    end

    test "aborts PostgreSQL recovery with the store's error and appends nothing" do
      rt = live(adapter(:postgres))

      Repo.query!("update events set payload = $1 where position = 3", [
        ~s({"v":1,"e":{"type":{"$a":"launch_missiles"}}})
      ])

      assert {:error, {:undecodable, 3, _}, _} = recover(PostgresEventStore, rt.store, "b")
      assert PostgresEventStore.head(rt.store) == rt.position
      assert PostgresEventStore.receipt(rt.store, "recovery:boot:1") == :none
      assert PostgresEventStore.receipt(rt.store, "start:b:2") == :none
    end
  end

  describe "a missing batch" do
    test "in memory, a gap in the tail aborts recovery on the genesis and snapshot paths" do
      rt = live(adapter(:memory))
      {rt, _} = save_snapshot(rt, snapshot(rt), rt.position)
      snap_position = rt.position
      rt = run(rt, later_commands())

      for {missing, opts} <- [{3, []}, {snap_position + 2, [decode_snapshot: &Snapshot.load/1]}, {rt.position, []}] do
        damaged = {rt.store, {:missing, missing}}

        assert {:error, {:missing_batch, ^missing}, _} =
                 Recovery.recover(DamagedStore, damaged, "b", [scope: @scope, side_effects: no_side_effects()] ++ opts)
      end
    end

    test "on PostgreSQL, a deleted batch row aborts recovery and appends nothing" do
      for which <- [:middle, :last] do
        rt = live(adapter(:postgres))
        position = if which == :middle, do: 3, else: rt.position
        Repo.query!("delete from events where position = $1", [position])
        Repo.query!("delete from batches where position = $1", [position])

        assert {:error, {:missing_batch, ^position}, _} = recover(PostgresEventStore, rt.store, "b")
        assert PostgresEventStore.head(rt.store) == rt.position
        assert PostgresEventStore.receipt(rt.store, "start:b:2") == :none
      end
    end

    test "on PostgreSQL, a batch that lost event rows aborts recovery" do
      rt = live(adapter(:postgres))
      Repo.query!("delete from events where position = 3 and batch_order = 0")

      assert {:error, {:undecodable, 3, {:event_count_mismatch, expected, found}}, _} =
               recover(PostgresEventStore, rt.store, "b")

      assert found == expected - 1
      assert PostgresEventStore.receipt(rt.store, "start:b:2") == :none
    end
  end

  test "the authority scope is required" do
    assert_raise KeyError, fn ->
      Recovery.recover(InMemoryEventStore, InMemoryEventStore.new(), "a", side_effects: no_side_effects())
    end
  end

  describe "unavailable storage" do
    test "in memory, a failing snapshot listing or log read is unavailable" do
      rt = live(adapter(:memory))
      down = InMemoryEventStore.fail_next(rt.store, :unavailable)

      assert {:error, :unavailable, _} = recover(InMemoryEventStore, down, "b")
      assert {:error, :unavailable, _} = recover_from_snapshots(InMemoryEventStore, down, "b")
    end

    @tag :capture_log
    test "on PostgreSQL, a refused connection is unavailable" do
      start_supervised!(FeudHall.UnreachableRepo)
      unreachable = PostgresEventStore.new(FeudHall.UnreachableRepo, @scope)

      assert {:error, :unavailable, _} = recover(PostgresEventStore, unreachable, "b")
      assert {:error, :unavailable, _} = recover_from_snapshots(PostgresEventStore, unreachable, "b")
    end
  end

  test "an owner that would make the next recovery's command ID malformed is refused before storage" do
    store = InMemoryEventStore.fail_next(InMemoryEventStore.new(), :unavailable)

    for owner <- ["", String.duplicate("o", 33), "bad\u0000owner", :atom] do
      assert {:error, :invalid_owner, ^store} = recover(InMemoryEventStore, store, owner)
    end

    # The longest accepted owner still yields a valid reconciliation command ID later.
    longest = String.duplicate("o", 32)
    assert {:ok, a, _} = recover(InMemoryEventStore, InMemoryEventStore.new(), longest)
    a = run(a, Enum.take(first_commands(), 1))
    assert {:ok, _, %{recovery_id: id, reconciliation: :accepted}} = recover(InMemoryEventStore, a.store, "b")
    assert id == "recovery:#{longest}:1"
  end

  describe "a lost reply on PostgreSQL" do
    test "leaves the reconciliation to the next recovery, which replays its receipt" do
      live = live(adapter(:postgres))
      armed = PostgresEventStore.fail_next(live.store, :lost_reply)

      assert {:error, {:uncertain, "recovery:boot:1"}, _} = recover(PostgresEventStore, armed, "c")
      assert {:ok, receipt} = PostgresEventStore.receipt(live.store, "recovery:boot:1")
      assert PostgresEventStore.receipt(live.store, "start:c:2") == :none

      assert {:ok, d, %{reconciliation: :replayed}} = recover(PostgresEventStore, live.store, "d")
      assert PostgresEventStore.receipt(d.store, "recovery:boot:1") == {:ok, receipt}
      assert d.control.current_epoch == "d:3"
      assert Control.pending_recovery_id(d.control) == "recovery:d:3"
    end
  end
end
