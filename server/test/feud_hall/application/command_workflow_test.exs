defmodule FeudHall.Application.CommandWorkflowTest do
  # Not async: the "on PostgreSQL" cases share the test database.
  use ExUnit.Case, async: false

  alias FeudHall.Application.CommandWorkflow, as: Workflow
  alias FeudHall.Application.Recovery
  alias FeudHall.MexicanFixture
  alias FeudHall.Domain.{Control, Money}
  alias FeudHall.Infrastructure.{EventCodec, InMemoryEventStore, PostgresEventStore, Repo, Snapshot}

  defmodule SecondAppend do
    @moduledoc "Wraps the in-memory store so that only the second append from now fails with `fault`."
    alias FeudHall.Infrastructure.InMemoryEventStore, as: Inner

    defstruct [:inner, :fault, appends: 0]

    def wrap(inner, fault), do: %__MODULE__{inner: inner, fault: fault}

    def append(%{appends: 1} = s, request) do
      {:error, reason, inner} = Inner.append(Inner.fail_next(s.inner, s.fault), request)
      {:error, reason, %{s | inner: inner, appends: 2}}
    end

    def append(s, request) do
      case Inner.append(s.inner, request) do
        {:ok, inner, position} -> {:ok, %{s | inner: inner, appends: s.appends + 1}, position}
        {:error, reason, inner} -> {:error, reason, %{s | inner: inner, appends: s.appends + 1}}
      end
    end

    def read_from(s, after_position), do: Inner.read_from(s.inner, after_position)
    def receipt(s, id), do: Inner.receipt(s.inner, id)
    def head(s), do: Inner.head(s.inner)
    def stream_versions(s, stream), do: Inner.stream_versions(s.inner, stream)
  end

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp runtime(store_mod \\ InMemoryEventStore, store \\ InMemoryEventStore.new()) do
    {:ok, rt} = Workflow.open(store_mod, store)

    {:accepted, _, rt} =
      Workflow.execute(
        rt,
        env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: MexicanFixture.catalog()}})
      )

    {:accepted, _, rt} =
      Workflow.execute(
        rt,
        env(
          "create",
          {:principal, "alice"},
          {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: "Casa", cuisine: "mexican"}}
        )
      )

    rt
  end

  defp purchase(qty),
    do: {:submit_purchase_request, %{restaurant_id: "r1", product: "rice_long", qty: qty, max_price_per_kunit: 1_000}}

  test "reserved command-ID prefixes are refused for principals and NPCs except npc: for NPCs" do
    rt = runtime()

    for id <- ~w(adv:500 tick:1:2 recovery:x start:x npc:a:1) do
      assert {:error, :reserved_command_id, _} = Workflow.execute(rt, env(id, {:principal, "alice"}, purchase(10)))
    end

    for id <- ~w(adv:500 tick:1:2 recovery:x start:x) do
      assert {:error, :reserved_command_id, _} = Workflow.execute(rt, env(id, {:npc, "budget"}, purchase(10)))
    end

    assert Workflow.reserved_prefix?("npc:a:1")
    refute Workflow.reserved_prefix?("buy-1")
  end

  # The clock advance mints these itself, so system actors are refused them too: with receipts
  # binding every other command ID, no visit, tray or order ID is minted twice over history.
  test "simulated arrivals' entity IDs are refused as command IDs to every actor" do
    rt = runtime()

    for actor <- [{:principal, "alice"}, {:npc, "budget"}, {:system, :demand}, {:system, :scheduler}] do
      assert {:error, :reserved_command_id, _} = Workflow.execute(rt, env("A0-12", actor, purchase(10)))
    end

    assert Workflow.arrival_id?("A12-0")
    refute Workflow.arrival_id?("A12-0x")
    refute Workflow.arrival_id?("buy-A1-2")
    assert {:accepted, _, _} = Workflow.execute(rt, env("A-1", {:principal, "alice"}, purchase(10)))
  end

  # The clock advance derives a simulated diner's dessert order from `"DS:" <> visit_id`; a client
  # accepting its own dessert under that ID would mint the same order ID first.
  test "a simulated diner's dessert entity ID is refused as a command ID to every actor" do
    rt = runtime()
    accept = {:accept_dessert, %{visit_id: "V:g1", confirmed: nil}}

    for actor <- [{:principal, "bob"}, {:npc, "budget"}, {:system, :demand}] do
      assert {:error, :reserved_command_id, _} = Workflow.execute(rt, env("DS:V:A0-1", actor, accept))
    end

    assert Workflow.reserved_prefix?("DS:V:A0-1")

    assert {:rejected, %{outcome: {:rejected, :unknown_visit}}, _} =
             Workflow.execute(rt, env("D:V:A0-1", {:principal, "bob"}, accept))
  end

  test "system actors may use reserved prefixes" do
    rt = runtime()

    assert {:accepted, _, _} =
             Workflow.execute(rt, env("tick:1:24", {:system, :scheduler}, {:advance_clock, %{to_service_ms: 1_000}}))
  end

  test "an NPC actor with an npc: command ID is accepted by validation" do
    rt = runtime()

    {:accepted, _, rt} =
      Workflow.execute(
        rt,
        env(
          "npc:budget:1",
          {:npc, "budget"},
          {:create_restaurant, %{restaurant_id: "r2", stall_id: "s002", name: "Budget", cuisine: "mexican"}}
        )
      )

    assert rt.state.restaurants["r2"].owner_kind == :npc
  end

  test "NPC operator IDs must be printable and 1..32 bytes" do
    rt = runtime()

    for bad <- ["", String.duplicate("a", 33), <<0, 1>>, 7] do
      assert {:error, :unauthenticated, _} = Workflow.execute(rt, env("x1", {:npc, bad}, purchase(10)))
    end

    # Valid actor: passes validation and is refused by the domain (it owns nothing).
    assert {:rejected, %{outcome: {:rejected, :forbidden}}, _} =
             Workflow.execute(rt, env("x2", {:npc, String.duplicate("a", 32)}, purchase(10)))
  end

  test "an identical retry returns the original receipt without a second purchase" do
    rt = runtime()
    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    cash = rt.state.restaurants["r1"].ledger.cash

    assert {:replayed, ^receipt, rt2} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert rt2.state.restaurants["r1"].ledger.cash == cash
    assert rt2.position == rt.position
  end

  test "changed content or actor under the same command ID is a conflict" do
    rt = runtime()
    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert {:error, :command_id_conflict, _} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(101)))
    assert {:error, :command_id_conflict, _} = Workflow.execute(rt, env("buy-1", {:principal, "bob"}, purchase(100)))
  end

  test "rejections keep their original result and append no domain events" do
    rt = runtime()
    head = rt.position
    {:rejected, receipt, rt} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(2_000_000)))
    assert receipt.outcome == {:rejected, :invalid_quantity}
    assert rt.position == head
    assert {:replayed, ^receipt, _} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(2_000_000)))
  end

  describe "control stream" do
    @authority {:system, :authority}

    defp started(rt) do
      {:accepted, _, rt} =
        Workflow.execute(rt, env("start:e1", @authority, {:start_availability, %{epoch_id: "e1"}}))

      rt
    end

    defp reconcile(id), do: env(id, @authority, {:reconcile_recovery, %{recovery_id: "recovery:e1"}})

    test "reconciliation appends control and hall events in one batch" do
      rt = started(runtime())
      before = rt.versions

      assert {:accepted, receipt, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert receipt.event_count == 2
      assert {:ok, batches} = InMemoryEventStore.read_from(rt.store, rt.position - 1)
      assert [%{events: [%{type: :hall_resumed}], control_events: [%{type: :availability_resumed}]}] = batches
      assert rt.versions == %{hall: before.hall + 1, control: before.control + 1}
      assert rt.state.last_recovery_id == "recovery:e1"
      assert Control.pending_recovery_id(rt.control) == "recovery:e1"
    end

    test "owners retrying the same recovery get the original receipt; a new command ID is already reconciled" do
      rt = started(runtime())
      {:accepted, receipt, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:replayed, ^receipt, _} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:rejected, %{outcome: {:rejected, :already_reconciled}}, _} = Workflow.execute(rt, reconcile("rec-2"))
    end

    test "start_availability works on an empty store and reconcile there is rejected" do
      {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())
      rt = started(rt)
      assert rt.versions == %{hall: 0, control: 1}
      assert Control.pending_recovery_id(rt.control) == "recovery:e1"

      assert {:rejected, %{outcome: {:rejected, :hall_not_initialized}}, _} = Workflow.execute(rt, reconcile("rec-1"))
    end

    test "a non-authority actor is refused and reopening replays the control stream" do
      rt = runtime()

      assert {:rejected, %{outcome: {:rejected, :forbidden}}, _} =
               Workflow.execute(rt, env("s", {:system, :admin}, {:start_availability, %{epoch_id: "e9"}}))

      rt = started(rt)
      {:accepted, _, rt} = Workflow.execute(rt, reconcile("rec-1"))
      assert {:ok, reopened} = Workflow.open(InMemoryEventStore, rt.store)
      assert reopened.control == rt.control
      assert reopened.versions == rt.versions
      assert reopened.state == rt.state
    end
  end

  test "malformed envelopes and unknown commands never reach the domain or storage" do
    rt = runtime()
    assert {:error, :unknown_command, _} = Workflow.execute(rt, env("x", {:principal, "alice"}, {:drop_tables, %{}}))
    assert {:error, :unauthenticated, _} = Workflow.execute(rt, env("x", {:principal, ""}, purchase(1)))
    assert {:error, :malformed_envelope, _} = Workflow.execute(rt, %{command_id: 7})
    assert {:error, :unauthenticated, _} = Workflow.execute(rt, env("x", {:system, :root}, purchase(1)))
  end

  test "a failure before commit leaves nothing; retrying the same ID then succeeds once" do
    rt = runtime()
    failing = %{rt | store: InMemoryEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable, _} = Workflow.execute(failing, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert InMemoryEventStore.receipt(failing.store, "buy-1") == :none

    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert Map.keys(rt.state.market.requests) == ["PR:buy-1"]
  end

  @tag :capture_log
  test "an unreachable PostgreSQL store makes lookup, open, and resolve unavailable instead of raising" do
    start_supervised!(FeudHall.UnreachableRepo)
    store = PostgresEventStore.new(FeudHall.UnreachableRepo, "hall:test", epoch: 1)
    head = %{hall: nil, control: nil, position: 0, versions: %{hall: 0, control: 0}}
    {:ok, rt} = Workflow.from_state(PostgresEventStore, store, head)
    init = env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: MexicanFixture.catalog()}})

    assert {:error, :unavailable, ^rt} = Workflow.execute(rt, init)
    assert {:error, :unavailable} = Workflow.open(PostgresEventStore, store)
    assert {:error, :unavailable, ^rt} = Workflow.resolve(rt, "init")
  end

  test "every append outcome adopts the returned store, so a consumed one-shot fault stays cleared" do
    rt = runtime()
    down = %{rt | store: InMemoryEventStore.fail_next(rt.store, :unavailable)}
    assert {:error, :unavailable, _} = Recovery.recover(InMemoryEventStore, down.store, "b", scope: "hall:test")

    assert {:error, :unavailable, after_fault} =
             Workflow.execute(down, env("buy-1", {:principal, "alice"}, purchase(100)))

    assert after_fault.store.fail_next == nil
    assert {after_fault.state, after_fault.position, after_fault.versions} == {rt.state, rt.position, rt.versions}

    assert {:accepted, _, after_fault} =
             Workflow.execute(after_fault, env("buy-1", {:principal, "alice"}, purchase(100)))

    assert {:ok, _, %{tail_batches: 3}} =
             Recovery.recover(InMemoryEventStore, after_fault.store, "b", scope: "hall:test")

    # A conflict also returns the runtime holding the store the adapter returned.
    conflicting = %{rt | store: after_fault.store}

    assert {:error, :conflict, ^conflicting} =
             Workflow.execute(conflicting, env("buy-2", {:principal, "alice"}, purchase(1)))
  end

  test "a lost reply is uncertain, blocks new commands, and resolves by the same ID" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :lost_reply)}
    {:uncertain, "buy-1", stuck} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
    # The in-memory head did not apply the batch, and new work is refused.
    assert stuck.state.market.requests == %{}

    assert {:error, :recovery_required, ^stuck} =
             Workflow.execute(stuck, env("buy-2", {:principal, "alice"}, purchase(5)))

    # A store that cannot be read leaves the runtime waiting for resolution.
    unreadable = %{stuck | store: InMemoryEventStore.fail_next(stuck.store, :unavailable)}
    assert {:error, :unavailable, ^unreadable} = Workflow.resolve(unreadable, "buy-1")

    assert {:committed, receipt, recovered} = Workflow.resolve(stuck, "buy-1")
    assert receipt.outcome == :accepted
    assert Map.keys(recovered.state.market.requests) == ["PR:buy-1"]
    # Retrying the original ID returns the original receipt, not a second fill.
    assert {:replayed, _, _} = Workflow.execute(recovered, env("buy-1", {:principal, "alice"}, purchase(100)))
  end

  test "a stale expected position conflicts instead of appending a competing batch" do
    rt = runtime()
    store = rt.store

    request = fn store, id, to ->
      %{
        command_id: id,
        expected_position: rt.position,
        expected_versions: rt.versions,
        hall_stream: "hall:h1",
        events: [%{type: :clock_advanced, to: to}],
        control_events: [],
        receipt: %{fingerprint: "x", outcome: :accepted},
        outbox: [],
        projection_rows: [],
        context: %{actor: {:system, :scheduler}, correlation_id: id, content_hash: nil, hall_ms: to}
      }
      |> then(&InMemoryEventStore.append(store, &1))
    end

    assert {:ok, store2, _} = request.(store, "a", 24)

    # A second writer that read the old head must not append.
    assert {:error, :conflict, _} = request.(store2, "b", 48)

    # A workflow holding the stale head reports the conflict without evolving.
    stale = %{rt | store: store2}
    assert {:error, :conflict, _} = Workflow.execute(stale, env("buy-9", {:principal, "alice"}, purchase(1)))
  end

  test "a fenced append stops the runtime" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}

    assert {:error, :fenced, fenced} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert fenced.mode == :fenced
    assert fenced.state == rt.state
    assert fenced.position == rt.position
    assert fenced.versions == rt.versions
    assert InMemoryEventStore.receipt(fenced.store, "buy-1") == :none

    # The injected failure was one-shot, so only the runtime's mode refuses further work,
    # and every later fenced result has the same shape and leaves the runtime unchanged.
    assert {:error, :fenced, ^fenced} = Workflow.execute(fenced, env("buy-1", {:principal, "alice"}, purchase(100)))

    assert {:error, :fenced, ^fenced} =
             Workflow.execute(fenced, env("buy-2", {:principal, "alice"}, purchase(5)), 60_000)

    assert {:error, :fenced, ^fenced} = Workflow.resolve(fenced, "buy-1")
  end

  test "a fenced clock advance stops the runtime before the command is decided" do
    rt = runtime()
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}

    assert {:error, :fenced, fenced} =
             Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)), 60_000)

    assert fenced.mode == :fenced
    assert fenced.position == rt.position
    assert fenced.versions == rt.versions
    assert InMemoryEventStore.receipt(fenced.store, "adv:60000") == :none
  end

  test "an accepted command commits its projection rows and stream versions with the batch" do
    rt = runtime()
    assert rt.versions.hall == length(Enum.flat_map(elem(InMemoryEventStore.read_from(rt.store, 0), 1), & &1.events))

    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
    assert InMemoryEventStore.projection(rt.store, :stock) == []

    # The request fills at the next market clearing, inside the clock advance.
    clearing = div(rt.state.market.next_clear_at, 24)
    tick = env("tick", {:system, :scheduler}, {:advance_clock, %{to_service_ms: clearing}})
    {:accepted, receipt, rt} = Workflow.execute(rt, tick)
    ledger = rt.state.restaurants["r1"].ledger
    assert ledger.raw > 0

    assert %{restaurant_id: "r1", account: :cash, amount: ledger.cash, position: receipt.position} in InMemoryEventStore.projection(
             rt.store,
             :balances
           )

    assert [%{restaurant_id: "r1", product: "rice_long", on_hand: 100, reserved: 0}] =
             InMemoryEventStore.projection(rt.store, :stock)

    assert InMemoryEventStore.stream_versions(rt.store, "hall:h1") == rt.versions
    assert {:ok, [_ | _] = batches} = InMemoryEventStore.read_from(rt.store, 0)
    assert List.last(batches).hall_ms == rt.state.now
  end

  test "a rejected initialization against an empty store records only its receipt" do
    {:ok, rt} = Workflow.open(InMemoryEventStore, InMemoryEventStore.new())
    {:rejected, _receipt, rt} = Workflow.execute(rt, env("buy-0", {:principal, "alice"}, purchase(1)))
    assert rt.state == nil
    assert rt.position == 0
    assert rt.versions == %{hall: 0, control: 0}
  end

  test "due clock work commits as its own batch before the command is decided" do
    rt = runtime()
    head = rt.position
    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 60_000)
    assert {:ok, %{kind: :advance_clock}} = InMemoryEventStore.receipt(rt.store, "adv:60000")
    assert receipt.position == head + 2
    assert rt.state.now == 60_000 * 24
  end

  test "a catch-up is keyed by its target, so commands observed at one instant share it" do
    rt = runtime()
    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 60_000)
    head = rt.position

    # The hall is already at 60,000 ms of service: nothing is due, so no second catch-up is appended.
    {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-2", {:principal, "alice"}, purchase(10)), 60_000)
    assert receipt.position == head + 1
    assert {:ok, batches} = InMemoryEventStore.read_from(rt.store, 0)
    assert Enum.count(batches, &String.starts_with?(&1.command_id, "adv:")) == 1
  end

  test "a catch-up whose reply was lost is resolved inside the workflow, and the command still runs" do
    rt = runtime()
    head = rt.position
    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :lost_reply)}

    # The lost reply belongs to the catch-up batch: the caller never sees its internal ID.
    assert {:accepted, receipt, rt} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(10)), 60_000)
    assert rt.mode == :ready
    assert receipt.position == head + 2
    assert rt.state.now == 60_000 * 24
    assert {:ok, %{kind: :advance_clock, position: catch_up}} = InMemoryEventStore.receipt(rt.store, "adv:60000")
    assert catch_up == head + 1

    # A retry of the same ID, observed later, returns the original receipt and appends nothing.
    assert {:replayed, ^receipt, again} =
             Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 90_000)

    assert again.position == rt.position
  end

  test "a catch-up that committed before its command failed lets the same ID retry later" do
    rt = runtime()
    store = SecondAppend.wrap(rt.store, :unavailable)
    rt = %{rt | store_mod: SecondAppend, store: store}

    # The catch-up committed; the command's own append was refused, so it is not recorded.
    assert {:error, :unavailable, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 60_000)
    assert rt.mode == :ready
    assert rt.state.now == 60_000 * 24
    assert SecondAppend.receipt(rt.store, "buy-1") == :none

    # Retried with the same ID at a later instant, the command commits after a new catch-up.
    assert {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 61_000)
    assert rt.state.now == 61_000 * 24
    assert {:ok, %{position: catch_up}} = SecondAppend.receipt(rt.store, "adv:61000")
    assert receipt.position == catch_up + 1
  end

  test "a runtime built from a recovered state continues from that head with its epoch" do
    rt = runtime()
    versions = InMemoryEventStore.stream_versions(rt.store, "hall:h1")
    base = %{hall: rt.state, control: rt.control, position: rt.position, versions: versions}

    assert {:ok, built} = Workflow.from_state(InMemoryEventStore, rt.store, base, epoch: 7)
    assert {built.state, built.control, built.position, built.versions} == {rt.state, rt.control, rt.position, versions}
    assert built.epoch == 7
    assert built.mode == :ready

    assert {:accepted, _, built} = Workflow.execute(built, env("buy-1", {:principal, "alice"}, purchase(10)))
    assert built.position == rt.position + 1

    # Resolving an uncertain command reopens the runtime without losing its epoch.
    armed = %{built | store: InMemoryEventStore.fail_next(built.store, :lost_reply)}
    {:uncertain, "buy-2", stuck} = Workflow.execute(armed, env("buy-2", {:principal, "alice"}, purchase(5)))
    assert {:committed, _, resolved} = Workflow.resolve(stuck, "buy-2")
    assert resolved.epoch == 7
  end

  test "the store replays to the same head the workflow holds" do
    rt = runtime()
    {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 1_000)
    assert {:ok, reopened} = Workflow.open(InMemoryEventStore, rt.store)
    assert reopened.state == rt.state
    assert reopened.versions == rt.versions
    assert reopened.position == rt.position
  end

  describe "on PostgreSQL" do
    setup do
      FeudHall.PostgresCase.reset!()
    end

    defp pg_runtime, do: runtime(PostgresEventStore, FeudHall.PostgresCase.fresh_store())

    test "an identical retry returns the stored receipt; changed content conflicts" do
      rt = pg_runtime()
      {:accepted, receipt, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      cash = rt.state.restaurants["r1"].ledger.cash

      assert {:ok, ^receipt} = PostgresEventStore.receipt(rt.store, "buy-1")
      assert {:replayed, ^receipt, rt2} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert rt2.state.restaurants["r1"].ledger.cash == cash
      assert rt2.position == rt.position
      assert PostgresEventStore.head(rt.store) == rt.position

      assert {:error, :command_id_conflict, _} =
               Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(101)))
    end

    test "a rejection keeps its stored receipt and appends no batch" do
      rt = pg_runtime()
      head = rt.position
      {:rejected, receipt, rt} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(2_000_000)))
      assert receipt.outcome == {:rejected, :invalid_quantity}
      assert PostgresEventStore.head(rt.store) == head
      assert {:replayed, ^receipt, _} = Workflow.execute(rt, env("buy-big", {:principal, "alice"}, purchase(2_000_000)))
    end

    test "a failure before commit leaves nothing; retrying the same ID then succeeds once" do
      rt = pg_runtime()
      failing = %{rt | store: PostgresEventStore.fail_next(rt.store, :before_commit)}
      assert {:error, :unavailable, _} = Workflow.execute(failing, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert PostgresEventStore.receipt(rt.store, "buy-1") == :none
      assert PostgresEventStore.head(rt.store) == rt.position

      {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert Map.keys(rt.state.market.requests) == ["PR:buy-1"]
    end

    test "a lost reply is uncertain, blocks new commands, and resolves by the same ID" do
      rt = pg_runtime()
      armed = %{rt | store: PostgresEventStore.fail_next(rt.store, :lost_reply)}
      {:uncertain, "buy-1", stuck} = Workflow.execute(armed, env("buy-1", {:principal, "alice"}, purchase(100)))
      assert stuck.state.market.requests == %{}
      assert {:error, :recovery_required, _} = Workflow.execute(stuck, env("buy-2", {:principal, "alice"}, purchase(5)))

      assert {:committed, receipt, recovered} = Workflow.resolve(stuck, "buy-1")
      assert receipt.outcome == :accepted
      assert Map.keys(recovered.state.market.requests) == ["PR:buy-1"]
      assert {:replayed, _, _} = Workflow.execute(recovered, env("buy-1", {:principal, "alice"}, purchase(100)))
    end

    test "a missing committed batch blocks uncertainty resolution and projection rebuild" do
      rt = pg_runtime()
      alice = {:principal, "alice"}
      price = {:set_menu_price, %{restaurant_id: "r1", recipe_id: "bean_tacos", price: 777}}
      assert {:accepted, _, priced} = Workflow.execute(rt, env("price", alice, price))
      armed = %{priced | store: PostgresEventStore.fail_next(priced.store, :lost_reply)}
      assert {:uncertain, "buy-1", pending} = Workflow.execute(armed, env("buy-1", alice, purchase(100)))

      missing = priced.position
      before = PostgresEventStore.projection(pending.store, :balances)
      Repo.query!("delete from events where position = $1", [missing])
      Repo.query!("delete from batches where position = $1", [missing])

      assert {:error, {:missing_batch, ^missing}, ^pending} = Workflow.resolve(pending, "buy-1")
      assert {:error, :recovery_required, ^pending} = Workflow.execute(pending, env("buy-2", alice, purchase(5)))
      assert {:error, {:missing_batch, ^missing}} = PostgresEventStore.rebuild_projections(pending.store)
      assert PostgresEventStore.projection(pending.store, :balances) == before
      assert PostgresEventStore.head(pending.store) == missing + 1
    end

    test "the store replays to the head and projections the in-memory workflow reaches" do
      commands = [
        {env("buy-1", {:principal, "alice"}, purchase(10)), 1_000},
        {env("start:e1", {:system, :authority}, {:start_availability, %{epoch_id: "e1"}}), nil},
        {env("buy-2", {:principal, "alice"}, purchase(20)), 2_000}
      ]

      run = fn rt ->
        Enum.reduce(commands, rt, fn {envelope, observed}, rt ->
          {:accepted, _, rt} = Workflow.execute(rt, envelope, observed)
          rt
        end)
      end

      pg = run.(pg_runtime())
      memory = run.(runtime())

      assert {:ok, reopened} = Workflow.open(PostgresEventStore, pg.store)
      assert reopened.state == memory.state
      assert reopened.control == memory.control
      assert reopened.versions == memory.versions
      assert reopened.position == memory.position
      assert PostgresEventStore.read_from(pg.store, 0) == InMemoryEventStore.read_from(memory.store, 0)

      assert PostgresEventStore.projection(pg.store, :balances) ==
               InMemoryEventStore.projection(memory.store, :balances)

      assert PostgresEventStore.projection(pg.store, :stock) == InMemoryEventStore.projection(memory.store, :stock)
    end
  end

  describe "codec and snapshots" do
    test "events round-trip through JSON exactly" do
      rt = runtime()
      {:accepted, _, rt} = Workflow.execute(rt, env("buy-1", {:principal, "alice"}, purchase(10)), 1_000)

      {:ok, batches} = InMemoryEventStore.read_from(rt.store, 0)

      for batch <- batches, event <- batch.events do
        assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
      end
    end

    test "unknown atoms and schema versions block decoding instead of being skipped" do
      assert {:error, {:unknown_atom, "launch_missiles"}} =
               EventCodec.decode(~s({"v":1,"e":{"type":{"$a":"launch_missiles"}}}))

      assert {:error, {:unsupported_schema, 2}} = EventCodec.decode(~s({"v":2,"e":{}}))
      assert_raise ArgumentError, fn -> EventCodec.encode!(%{type: :not_allowlisted}) end
    end

    test "a valid checksum around an unknown atom or the wrong shape is rejected, not raised" do
      seal = fn body -> :crypto.hash(:sha256, body) <> body end
      term = %{position: 1, evolution: Snapshot.evolution_version(), state: %{hall: :workflow_test_placeholder}}
      body = :erlang.term_to_binary(term, [:deterministic])
      unknown = :binary.replace(body, "workflow_test_placeholder", "zz_never_defined_atom_qqq")

      assert {:error, :incompatible_snapshot} = Snapshot.load(seal.(unknown))
      assert {:error, :corrupt_snapshot} = Snapshot.load(seal.(:erlang.term_to_binary([1, 2, 3])))
      assert {:error, :corrupt_snapshot} = Snapshot.load(seal.(:erlang.term_to_binary(%{position: 1})))
      assert {:error, :corrupt_snapshot} = Snapshot.load(seal.("not an external term"))
    end

    test "corrupt or incompatible snapshots are rejected for fallback" do
      rt = runtime()
      snap = Snapshot.take(%{hall: rt.state, control: nil}, rt.position)
      assert {:ok, %{position: _, state: state}} = Snapshot.load(snap)
      assert state == %{hall: rt.state, control: nil}
      <<first, rest::binary>> = snap
      assert {:error, :corrupt_snapshot} = Snapshot.load(<<Bitwise.bxor(first, 1), rest::binary>>)
      assert {:error, :corrupt_snapshot} = Snapshot.load("short")
    end

    test "money crosses the client boundary as canonical decimal strings beyond JS safe integers" do
      big = 9_007_199_254_740_993
      assert Money.to_canonical(big) == "9007199254740993"
      assert {:ok, ^big} = Money.parse("9007199254740993")

      for bad <- ["01", "+5", "1.0", "1e3", " 1", "-0", "", "99999999999999999999"],
          do: assert({:error, :invalid_money} = Money.parse(bad))
    end
  end
end
