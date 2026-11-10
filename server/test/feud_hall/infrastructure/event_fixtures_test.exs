defmodule FeudHall.Infrastructure.EventFixturesTest do
  # Golden serialized events (`test/fixtures/events/*.json`): committed bytes produced once from real
  # domain events by `FeudHall.EventFixtureScenarios.write!/1`. They pin the wire format, so a codec or
  # event-shape change that would break reading stored history fails here instead of at recovery.
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Hall.Evolver
  alias FeudHall.EventFixtureScenarios
  alias FeudHall.Infrastructure.EventCodec

  @dir Path.expand("../../fixtures/events", __DIR__)

  # Every event type the shared simulation added (Tasks 1-15), by fixture name.
  @added ~w(
    stage_started_prep stage_started_finish stage_completed_prep stage_completed_finish handover_started
    purchase_requested purchase_request_cancelled market_cleared day_closed
    diner_arrived_admitted diner_arrived_left npc_planned
  )
  # Changed shapes of older events.
  @changed ~w(hall_initialized clock_advanced_operating clock_advanced_unchanged tray_accepted dessert_accepted
               restaurant_created_npc visit_admitted_simulated)
  # Milestone 1 / Project A events the decider no longer emits, and earlier shapes of events it
  # still emits; they must keep decoding and evolving.
  @historical ~w(stock_purchased preparation_started preparation_completed market_cleared_without_next_clear_at)

  @entries Map.new(EventFixtureScenarios.entries(), &{&1.name, &1})

  defp files, do: @dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()

  test "there is exactly one fixture per added, changed and historical event shape" do
    assert files() == Enum.map(Enum.sort(@added ++ @changed ++ @historical), &(&1 <> ".json"))
    assert @entries |> Map.keys() |> Enum.sort() == Enum.sort(@added ++ @changed ++ @historical)
  end

  test "every event type the evolver newly handles has a fixture" do
    types =
      files()
      |> Enum.map(&(@dir |> Path.join(&1) |> File.read!() |> EventCodec.decode() |> elem(1) |> Map.fetch!(:type)))
      |> MapSet.new()

    for type <- ~w(stage_started stage_completed handover_started purchase_requested purchase_request_cancelled
                   market_cleared day_closed diner_arrived npc_planned stock_purchased preparation_started
                   preparation_completed)a do
      assert type in types, "no golden fixture for #{type}"
    end
  end

  for name <- @added ++ @changed ++ @historical do
    describe name do
      test "decodes, re-encodes to the same bytes, and evolves onto its state" do
        bytes = File.read!(Path.join(@dir, unquote(name) <> ".json"))
        assert {:ok, event} = EventCodec.decode(bytes)
        assert EventCodec.encode!(event) == bytes

        %{pre: pre} = Map.fetch!(@entries, unquote(name))
        evolved = Evolver.evolve(pre, event)
        assert evolved != pre
      end
    end
  end

  # The decider no longer emits these, so their evolution is pinned field by field. Entries are
  # built at run time here, so the compile-time type checker does not see every fixture's shape.
  defp entry(name), do: Enum.find(EventFixtureScenarios.entries(), &(&1.name == name))

  describe "historical events evolve with their Milestone 1 effects" do
    test "stock_purchased receives a lot at its recorded cost, paid from cash" do
      %{event: e, pre: pre} = entry("stock_purchased")
      post = Evolver.evolve(pre, e)
      before = pre.restaurants[e.restaurant_id]
      after_ = post.restaurants[e.restaurant_id]

      refute Map.has_key?(before.batches, e.batch_id)

      assert after_.batches[e.batch_id] == %{
               id: e.batch_id,
               product: e.product,
               product_version: e.product_version,
               qty: e.qty,
               reserved: 0,
               cost: e.cost,
               expires_at: e.expires_at
             }

      assert e.cost > 0
      assert after_.ledger.cash == before.ledger.cash - e.cost
      assert after_.ledger.raw == before.ledger.raw + e.cost
    end

    test "preparation_started consumes the claims into work in progress until ready_not_before" do
      %{event: e, pre: pre} = entry("preparation_started")
      post = Evolver.evolve(pre, e)
      cost = e.consumed |> Enum.map(& &1.cost) |> Enum.sum()

      assert %{status: :queued_prep, consumed_cost: 0} = pre.orders[e.order_id]
      assert %{status: :finish, reservations: [], consumed_cost: ^cost} = post.orders[e.order_id]
      assert post.orders[e.order_id].stage_done_at == e.ready_not_before
      rid = pre.visits[pre.orders[e.order_id].visit].restaurant
      assert cost > 0
      assert post.restaurants[rid].ledger.wip == pre.restaurants[rid].ledger.wip + cost
      assert post.restaurants[rid].ledger.raw == pre.restaurants[rid].ledger.raw - cost
    end

    test "preparation_completed makes the order ready now, until expires_at" do
      %{event: e, pre: pre} = entry("preparation_completed")
      post = Evolver.evolve(pre, e)

      assert pre.orders[e.order_id].status == :finish
      assert %{status: :ready, stage_done_at: nil} = post.orders[e.order_id]
      assert post.orders[e.order_id].ready_at == pre.now
      assert post.orders[e.order_id].ready_expires_at == e.expires_at
    end
  end

  describe "recorded facts replace recomputation" do
    test "a clock_advanced without the operating list credits the last recorded list" do
      %{event: e, pre: pre} = entry("clock_advanced_unchanged")
      refute Map.has_key?(e, :operating)
      assert [_ | _] = operating = pre.demand.operating
      post = Evolver.evolve(pre, e)

      for rid <- operating,
          do: assert(post.demand.observed_ms[rid] == Map.get(pre.demand.observed_ms, rid, 0) + e.to - pre.now)

      assert post.demand.operating == operating
    end

    test "market_cleared applies its recorded next clearing; an older one without it adds the interval" do
      %{event: e, pre: pre} = entry("market_cleared")
      assert Evolver.evolve(pre, e).market.next_clear_at == e.next_clear_at

      %{event: old, pre: pre} = entry("market_cleared_without_next_clear_at")
      refute Map.has_key?(old, :next_clear_at)
      interval = pre.catalog.rules.market.clear_every_hall_ms
      assert Evolver.evolve(pre, old).market.next_clear_at == pre.market.next_clear_at + interval
      assert e.next_clear_at == pre.market.next_clear_at + interval
    end
  end

  test "every event of the whole scenario round-trips, so the allowlist covers what the domain emits" do
    {_state, log} = EventFixtureScenarios.world()
    assert length(log) > 200
    assert log |> Enum.map(& &1.type) |> Enum.uniq() |> length() >= 25

    for event <- log do
      assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
    end
  end

  test "every leave reason a simulated arrival can record round-trips" do
    {:ok, left} = @dir |> Path.join("diner_arrived_left.json") |> File.read!() |> EventCodec.decode()
    reasons = FeudHall.Domain.Choice.leave_reasons() ++ [:admission_failed]
    assert :no_open_stall in reasons and :nothing_available in reasons

    for reason <- reasons do
      event = %{left | reason: reason}
      assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
    end
  end

  test "an event naming an atom outside the allowlist is refused rather than skipped" do
    bytes = File.read!(Path.join(@dir, "npc_planned.json"))
    tampered = String.replace(bytes, "npc_planned", "launch_missiles")
    assert {:error, {:unknown_atom, "launch_missiles"}} = EventCodec.decode(tampered)
  end
end
