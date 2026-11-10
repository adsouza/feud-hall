defmodule FeudHall.Application.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias FeudHall.Application.{CommandWorkflow, Diagnostics, Recovery}
  alias FeudHall.Domain.Identity
  alias FeudHall.MexicanFixture
  alias FeudHall.Infrastructure.Diagnostics.{Exporter, MemorySink}
  alias FeudHall.Infrastructure.InMemoryEventStore

  @allowed ~w(command_id kind actor_kind outcome reason attempt position epoch hall_ms duration_us scope
              recovery_id snapshot_position skipped error_class batch_events backlog lateness_ms
              batch fills unfilled arrivals admitted left stages_started served cancelled boundary count operator
              accepted rejected)a

  defp env(id, actor, command), do: %{command_id: id, actor: actor, command: command}

  defp open(opts \\ []) do
    {:ok, rt} = CommandWorkflow.open(InMemoryEventStore, InMemoryEventStore.new(), opts)

    {:accepted, _, rt} =
      CommandWorkflow.execute(
        rt,
        env("init", {:system, :admin}, {:initialize_hall, %{hall_id: "h1", catalog: MexicanFixture.catalog()}})
      )

    rt
  end

  defp create(rt, name, id \\ "create"),
    do:
      CommandWorkflow.execute(
        rt,
        env(
          id,
          {:principal, "alice-secret-id"},
          {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: name, cuisine: "mexican"}}
        )
      )

  defp outcomes(sink), do: for(%{name: :command_outcome} = r <- MemorySink.records(sink), do: r.fields)

  setup do
    {:ok, sink} = MemorySink.start_link()
    %{sink: sink}
  end

  test "records carry schema 1 and only allowlisted fields; long strings are cut", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, _} = create(rt, "Casa")
    records = MemorySink.records(sink)
    assert records != []

    for r <- records do
      assert r.schema == 1
      assert is_integer(r.at_mono)
      assert Map.keys(r.fields) -- @allowed == []
    end

    record = Diagnostics.record(:x, %{command_id: String.duplicate("a", 500), secret: "no", actor_kind: "alice-id"})
    assert byte_size(record.fields.command_id) == 128
    refute Map.has_key?(record.fields, :secret)
    refute Map.has_key?(record.fields, :actor_kind)
    assert Diagnostics.record(:x, %{actor_kind: :principal}).fields.actor_kind == :principal
  end

  test "player text and principal IDs never reach a record", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, _} = create(rt, "sentinel-secret-🌮")

    big =
      {:submit_purchase_request,
       %{restaurant_id: "r1", product: "rice_long", qty: 2_000_000, max_price_per_kunit: 1_000}}

    {:rejected, _, _} = CommandWorkflow.execute(rt, env("big", {:principal, "alice-secret-id"}, big))
    dump = inspect(MemorySink.records(sink), limit: :infinity)
    refute dump =~ "sentinel"
    refute dump =~ "alice-secret-id"
    assert Enum.any?(outcomes(sink), &(&1.actor_kind == :principal))
  end

  test "identity and management command kinds are logged while unknown input is redacted", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    device = "owner-device"

    assert {:accepted, _, rt} =
             CommandWorkflow.execute(rt, env("managed", {:system, :admin}, {:enable_management, %{}}))

    assert {:accepted, _, rt} =
             CommandWorkflow.execute(
               rt,
               env("profile", {:device, device}, {:bootstrap_guest, %{device: device, name: "Owner"}})
             )

    principal = Identity.principal_for_device(Identity.get(rt.control), device)

    assert {:accepted, _, rt} =
             CommandWorkflow.execute(
               rt,
               env("seed", {:system, :admin}, {:seed_owner, %{principal: principal, reviewer?: true}})
             )

    assert {:accepted, _, rt} =
             CommandWorkflow.execute(
               rt,
               env("presence", {:principal, principal}, {:report_owner_presence, %{present: true}})
             )

    assert {:error, :unknown_command, ^rt} =
             CommandWorkflow.execute(rt, env("bad-kind", {:principal, principal}, {"untrusted-value", %{}}))

    records = MemorySink.records(sink)

    for {id, kind, outcome} <- [
          {"profile", :bootstrap_guest, :accepted},
          {"presence", :report_owner_presence, :accepted},
          {"bad-kind", :unknown, :rejected}
        ] do
      assert [
               %{name: :command_attempted, fields: %{kind: ^kind}},
               %{name: :command_outcome, fields: %{kind: ^kind, outcome: ^outcome}}
             ] = Enum.filter(records, &(&1.fields[:command_id] == id))
    end
  end

  test "accepted is emitted only after the append; failures map to unavailable and commit_unknown", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    before = length(outcomes(sink))

    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :before_commit)}
    assert {:error, :unavailable, _} = create(armed, "Casa")
    [last] = Enum.drop(outcomes(sink), before)
    assert last.outcome == :unavailable
    assert last.command_id == "create"
    refute Enum.any?(Enum.drop(outcomes(sink), before), &(&1.outcome == :accepted))

    armed = %{rt | store: InMemoryEventStore.fail_next(rt.store, :lost_reply)}
    assert {:uncertain, "create", _} = create(armed, "Casa")
    assert List.last(outcomes(sink)).outcome == :commit_unknown
    refute Enum.any?(Enum.drop(outcomes(sink), before), &(&1.outcome == :accepted))
  end

  test "rejection, replay, conflict, and fenced outcomes", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:accepted, _, rt} = create(rt, "Casa")
    {:replayed, _, rt} = create(rt, "Casa")
    assert List.last(outcomes(sink)).outcome == :replayed
    {:rejected, _, rt} = CommandWorkflow.execute(rt, env("dup", {:principal, "a"}, create_cmd("Casa")))
    last = List.last(outcomes(sink))
    assert last.outcome == :rejected and is_atom(last.reason) and last.batch_events == 0
    {:error, :command_id_conflict, _} = create(rt, "Other")
    last = List.last(outcomes(sink))
    assert last.outcome == :rejected and last.reason == :command_id_conflict

    fenced = %{rt | store: InMemoryEventStore.fail_next(rt.store, :fenced)}
    {:error, :fenced, _} = create(fenced, "Zed", "create-3")
    assert List.last(outcomes(sink)).outcome == :fenced
  end

  defp create_cmd(name),
    do: {:create_restaurant, %{restaurant_id: "r1", stall_id: "s001", name: name, cuisine: "mexican"}}

  test "recovery emits started, snapshot_skipped, completed", %{sink: sink} do
    rt = open()
    {:accepted, _, rt} = create(rt, "Casa")
    {:ok, store, id} = InMemoryEventStore.save_snapshot(rt.store, rt.position, "junk")
    {:ok, store} = InMemoryEventStore.mark_snapshot_verified(store, id)
    decode = fn _ -> {:error, :corrupt_snapshot} end

    assert {:ok, _, _} =
             Recovery.recover(InMemoryEventStore, store, "boot",
               scope: "hall:t",
               decode_snapshot: decode,
               diagnostics: {MemorySink, sink}
             )

    names = Enum.map(MemorySink.records(sink), & &1.name)
    assert hd(names) == :recovery_started
    assert :recovery_completed in names
    skipped = Enum.find(MemorySink.records(sink), &(&1.name == :snapshot_skipped))
    assert skipped.fields.reason == :corrupt_snapshot
    assert skipped.fields.snapshot_position == rt.position
    assert :recovery_failed not in names
  end

  test "recovery failure emits recovery_failed without payloads", %{sink: sink} do
    assert {:error, :invalid_owner, _} =
             Recovery.recover(InMemoryEventStore, InMemoryEventStore.new(), "",
               scope: "hall:t",
               diagnostics: {MemorySink, sink}
             )

    failed = Enum.find(MemorySink.records(sink), &(&1.name == :recovery_failed))
    assert failed.severity == :error
    assert failed.fields.error_class == :invalid_owner
  end

  test "a fenced recovery is not reported as a recovery failure", %{sink: sink} do
    {:ok, store, 1} = InMemoryEventStore.acquire_authority(InMemoryEventStore.new(), "hall:t", "a")
    {:ok, store, 2} = InMemoryEventStore.acquire_authority(store, "hall:t", "b")

    assert {:error, :fenced, _} =
             Recovery.recover(InMemoryEventStore, store, "a",
               scope: "hall:t",
               expected_epoch: 1,
               diagnostics: {MemorySink, sink}
             )

    names = Enum.map(MemorySink.records(sink), & &1.name)
    assert :recovery_started in names
    refute :recovery_failed in names
  end

  test "a raising sink never reaches the workflow" do
    defmodule Boom do
      @behaviour FeudHall.Application.Diagnostics
      def emit(_sink, _record), do: raise("sink down")
    end

    rt = open(diagnostics: {Boom, :x})
    assert {:accepted, _, _} = create(rt, "Casa")
  end

  test "field-building failures and malformed configs never reach the workflow", %{sink: sink} do
    assert :ok = Diagnostics.emit_lazy({MemorySink, sink}, :x, fn -> raise "builder bug" end)
    assert :ok = Diagnostics.emit_lazy({MemorySink, sink}, :x, fn -> throw(:oops) end)
    assert :ok = Diagnostics.emit(:not_a_config, :x, %{})
    assert :ok = Diagnostics.emit_lazy({1, 2, 3}, :x, fn -> %{} end)
    assert MemorySink.records(sink) == []

    for bogus <- [:not_a_config, {1, 2, 3}, {NoSuchModule, nil}] do
      rt = open(diagnostics: bogus)
      assert {:accepted, _, _} = create(rt, "Casa")
    end

    # A malformed envelope is still rejected by the workflow, not crashed by diagnostics.
    rt = open(diagnostics: {MemorySink, sink})
    assert {:error, :malformed_envelope, _} = CommandWorkflow.execute(rt, %{command_id: 7})
  end

  test "unvalidated command kinds are recorded as :unknown", %{sink: sink} do
    rt = open(diagnostics: {MemorySink, sink})
    {:error, :unknown_command, _} = CommandWorkflow.execute(rt, env("evil", {:principal, "a"}, {:"drop table", %{}}))
    records = MemorySink.records(sink)
    assert Enum.all?(Enum.filter(records, &(&1.fields[:command_id] == "evil")), &(&1.fields.kind == :unknown))
    refute inspect(records) =~ "drop table"
  end

  defp workload(diag) do
    rt = open(diagnostics: diag)
    {:accepted, _, rt} = create(rt, "Casa")

    ids = ["init", "create"]

    {rt, ids} =
      Enum.reduce(1..28, {rt, ids}, fn i, {rt, ids} ->
        id = "buy-#{rem(i, 25)}"
        qty = if rem(i, 7) == 0, do: 2_000_000, else: 10 + i

        cmd =
          {:submit_purchase_request, %{restaurant_id: "r1", product: "rice_long", qty: qty, max_price_per_kunit: 1_000}}

        {_status, _receipt, rt} = CommandWorkflow.execute(rt, env(id, {:principal, "alice-secret-id"}, cmd))
        {rt, [id | ids]}
      end)

    # The pending request fills at the next market clearing, changing balances and stock.
    clearing = {:advance_clock, %{to_service_ms: div(rt.state.market.next_clear_at, 24)}}
    {:accepted, _, rt} = CommandWorkflow.execute(rt, env("clear", {:system, :scheduler}, clearing))
    ids = ["clear" | ids]

    receipts = ids |> Enum.uniq() |> Map.new(&{&1, InMemoryEventStore.receipt(rt.store, &1)})

    %{
      state: rt.state,
      receipts: receipts,
      balances: InMemoryEventStore.projection(rt.store, :balances),
      stock: InMemoryEventStore.projection(rt.store, :stock),
      position: rt.position
    }
  end

  test "diagnostics never change hall state, receipts, or projections", %{sink: sink} do
    {:ok, exporter} =
      Exporter.start_link(export: fn _ -> raise "exporter down" end, max_queue: 5, batch: 2, timeout_ms: 1_000)

    base = workload(nil)
    assert workload({MemorySink, sink}) == base
    assert workload({Exporter, exporter}) == base
    assert length(MemorySink.records(sink)) > 30
    assert base.position > 20
  end

  describe "simulation records" do
    defp batch_events do
      [
        %{
          type: :market_cleared,
          batch: 7,
          prices: %{"rice" => 3},
          fills: [%{who: "Casa"}, %{who: "Casa"}],
          unfilled: [1]
        },
        %{type: :market_cleared, batch: 8, prices: %{}, fills: [%{}], unfilled: []},
        %{type: :diner_arrived, outcome: :admitted, reason: nil, budget: 999},
        %{type: :diner_arrived, outcome: :left, reason: :wait_too_long, budget: 5},
        %{type: :diner_arrived, outcome: :left, reason: :wait_too_long, budget: 5},
        %{type: :stage_started, order_id: "o1", stage: :prep},
        %{type: :tray_served, tray_id: "t1"},
        %{type: :dessert_served, order_id: "o1"},
        %{type: :tray_cancelled, reason: :deadline_missed},
        %{type: :dessert_cancelled, reason: :guest_cancelled},
        %{type: :hall_cleaning_started, day: 1, at: 1},
        %{type: :hall_cleaning_ended, day: 1, at: 2},
        %{type: :hall_cleaning_started, day: 2, at: 3},
        %{
          type: :npc_planned,
          operator: "budget",
          slot: 1,
          outcomes: [
            %{action: :open_stall, result: :accepted},
            %{action: :set_price, result: :rejected, reason: :nope},
            %{action: :set_price, result: :accepted}
          ]
        },
        %{type: :restaurant_created, name: "sentinel-secret-🌮"}
      ]
    end

    test "one aggregated, constant-size record per kind, from the committed events only" do
      assert [
               {:market_cleared, %{batch: 8, fills: 3, unfilled: 1}},
               {:arrivals, %{arrivals: 3, admitted: 1, left: 2}},
               {:course_lifecycle, %{stages_started: 1, served: 2, cancelled: 2}},
               {:cleaning_boundary, %{boundary: :started, count: 2}},
               {:cleaning_boundary, %{boundary: :ended, count: 1}},
               {:npc_plan, %{operator: "budget", accepted: 2, rejected: 1}}
             ] = Diagnostics.batch_summaries(batch_events())

      assert Diagnostics.batch_summaries([%{type: :restaurant_created}, %{type: :stall_opened}]) == []
    end

    test "a zero-activity clearing is suppressed; mixed NPC operators drop the operator" do
      empty = %{type: :market_cleared, batch: 3, prices: %{}, fills: [], unfilled: []}
      assert Diagnostics.batch_summaries([empty]) == []

      plans = for op <- ["a", "b"], do: %{type: :npc_planned, operator: op, slot: 1, outcomes: []}
      assert [{:npc_plan, fields}] = Diagnostics.batch_summaries(plans)
      refute Map.has_key?(Diagnostics.record(:npc_plan, fields).fields, :operator)
      assert fields.accepted == 0 and fields.rejected == 0
      assert fields.operator == nil
    end

    test "records built from a batch keep only allowlisted fields and no payload text", %{sink: sink} do
      Diagnostics.emit_batch({MemorySink, sink}, batch_events())
      records = MemorySink.records(sink)
      assert Enum.map(records, & &1.name) == ~w(market_cleared arrivals course_lifecycle cleaning_boundary
                                                cleaning_boundary npc_plan)a
      for r <- records, do: assert(Map.keys(r.fields) -- @allowed == [])
      dump = inspect(records, limit: :infinity)
      refute dump =~ "sentinel"
      refute dump =~ "Casa"
      assert :ok = Diagnostics.emit_batch({MemorySink, sink}, :not_events)
      assert :ok = Diagnostics.emit_batch({MemorySink, sink}, [%{type: :market_cleared, fills: :bad, unfilled: 1}])
      assert :ok = Diagnostics.emit_batch(nil, batch_events())
    end

    test "NPC actors report an NPC kind and never an identity" do
      assert Diagnostics.actor_kind({:npc, "budget"}) == :npc
      assert Diagnostics.record(:x, %{actor_kind: :npc}).fields.actor_kind == :npc
    end

    test "a committed clearing with fills reports a market_cleared record through the workflow", %{sink: sink} do
      workload({MemorySink, sink})
      assert [%{fields: fields} | _] = for(%{name: :market_cleared} = r <- MemorySink.records(sink), do: r)
      assert fields.fills > 0 and is_integer(fields.batch) and is_integer(fields.unfilled)
      assert Map.keys(fields) -- @allowed == []
      refute inspect(MemorySink.records(sink), limit: :infinity) =~ "sentinel"
    end

    test "an exporter whose export raises does not change what the workflow commits" do
      {:ok, exporter} =
        Exporter.start_link(export: fn _ -> raise "exporter down" end, max_queue: 5, batch: 2, timeout_ms: 1_000)

      assert workload({Exporter, exporter}) == workload(nil)
    end
  end
end
