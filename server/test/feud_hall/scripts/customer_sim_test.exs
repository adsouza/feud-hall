System.put_env("CUSTOMER_SIM_NO_MAIN", "1")
Code.require_file("../../../scripts/customer_sim.exs", __DIR__)

defmodule FeudHall.CustomerSimTest do
  use ExUnit.Case, async: false

  alias FeudHall.Application.Management
  alias FeudHall.CustomerSim.{CLI, Hall, Stats}
  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}
  alias FeudHall.Domain.Hall.Rooms
  alias FeudHall.Infrastructure.HallAuthority

  @seed 20_261_109

  defp sample(day, hour, stalls, fields \\ %{}) do
    day |> Stats.blank_observation(hour) |> Map.merge(%{stalls: stalls}) |> Map.merge(fields)
  end

  defp stall(waiting, busy?), do: %{waiting: waiting, cooking: if(busy?, do: 1, else: 0), handover: false, open: true}

  # `values` gives one sample each for the reference stall "ref" in `hour` of day 1.
  defp feed(stats, hour, values) do
    Enum.reduce(values, stats, fn {waiting, busy?}, acc ->
      Stats.add(acc, sample(1, hour, %{"ref" => stall(waiting, busy?)}))
    end)
  end

  defp row(verdict, check), do: Enum.find(verdict, &(&1.check == check)) || flunk("no #{check} in #{inspect(verdict)}")

  defp run!(opts) do
    defaults = %{run: :b, tuning: Tuning.of(LaunchCatalog.catalog()), via: :init, days: 0, seed: @seed}
    assert {:ok, result} = Hall.run(Map.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(result.authority), do: GenServer.stop(result.authority) end)
    result
  end

  test "Stats averages waiting over time and counts busy share" do
    stats = Stats.new(%{measured_days: 1, reference: "ref"})

    stats =
      Enum.reduce([{2, 1, false}, {4, 0, true}, {4, 0, false}, {2, 1, false}], stats, fn {w, c, h}, acc ->
        Stats.add(acc, sample(1, 12, %{"ref" => %{waiting: w, cooking: c, handover: h, open: true}}))
      end)

    hour = Stats.stall_hour(stats, 1, 12, "ref")
    assert hour.samples == 4
    assert hour.waiting == 3.0
    assert hour.busy == 0.75
    assert hour.cooking == 0.5
    assert hour.handover == 0.25
  end

  test "the verdict applies the spec's bounds" do
    base = Stats.new(%{measured_days: 1, reference: "ref"})
    # 2.4 = (2 + 2 + 3 + 2 + 3) / 5
    low = feed(base, 12, [{2, true}, {2, true}, {3, true}, {2, true}, {3, true}])
    assert %{value: 2.4, low: 2.5, high: 4.5, pass: false} = row(Stats.verdict(:a, low), "A ref waiting 12:00-13:00")

    for {values, pass} <- [
          {[{2, true}, {3, true}], true},
          {[{4, true}, {5, true}], true},
          {[{4, true}, {5, true}, {5, true}, {4, true}, {5, true}], false}
        ] do
      stats = feed(base, 12, values)
      assert row(Stats.verdict(:a, stats), "A ref waiting 12:00-13:00").pass == pass, inspect(values)
    end

    busy = fn n -> feed(base, 19, for(i <- 1..1000, do: {3, i <= n})) end

    assert %{value: 0.85, low: 0.85, high: nil, pass: true} =
             row(Stats.verdict(:a, busy.(850)), "A ref busy 19:00-20:00")

    assert %{value: 0.849, pass: false} = row(Stats.verdict(:a, busy.(849)), "A ref busy 19:00-20:00")

    left = fn nothing, other ->
      Stats.add(base, sample(1, 12, %{}, %{left_on_arrival: %{nothing_available: nothing, nothing_affordable: other}}))
    end

    assert %{value: 0.25, low: nil, high: 0.25, pass: true} =
             row(Stats.verdict(:b, left.(25, 75)), "B nothing_available share of left on arrival")

    assert %{value: 0.26, pass: false} =
             row(Stats.verdict(:b, left.(26, 74)), "B nothing_available share of left on arrival")
  end

  @tag timeout: 180_000
  test "a run is deterministic and acts only through commands" do
    first = run!(%{})
    second = run!(%{})
    args = %{run: :b, tuning: :current, via: :init, days: 0, seed: @seed, set: []}
    assert CLI.json(first, args) == CLI.json(second, args)

    {store_mod, store} = HallAuthority.store(first.authority)
    {:ok, batches} = store_mod.read_from(store, 0)
    events = Enum.sum(for batch <- batches, do: length(batch.events) + length(batch.control_events))
    assert events > 1_000

    receipts =
      for batch <- batches do
        assert {:ok, receipt} = store_mod.receipt(store, batch.command_id)
        receipt.event_count
      end

    assert Enum.sum(receipts) == events
  end

  @tag timeout: 180_000
  test "run A's reference stall is a standard spot in room 1, open 09:00 to 21:00, with three staff" do
    result = run!(%{run: :a})
    state = HallAuthority.state(result.authority).hall
    sid = result.reference.stall_id
    assert state.layout[sid] == :standard
    assert Rooms.room(state, sid) == 1
    lease = state.management.leases[sid]
    assert {lease.start_hour, lease.end_hour} == {9, 21}
    assert map_size(lease.workers) == 3
    assert lease.unattended
    restaurant = state.restaurants[state.stalls[sid].restaurant]
    assert restaurant.owner_kind == :principal
    [{recipe_id, price}] = Map.to_list(restaurant.menu)
    recipe = state.catalog.recipes[recipe_id]
    assert recipe.starter and recipe.kind == :main and recipe.cuisine == result.reference.cuisine
    assert price == recipe.suggested_price
    npc_cuisines = for {_, %{owner_kind: :npc, cuisine: c}} <- state.restaurants, do: c
    refute result.reference.cuisine in npc_cuisines
    assert map_size(state.stalls) == 4
    assert Stats.day_served(result.stats, 0) > 0
  end

  @tag timeout: 180_000
  test "the view's waiting and the sampled waiting agree" do
    parent = self()
    instants = MapSet.new(for i <- 0..19, do: 10 * 150 + i * 75)

    observer = fn tick, authority ->
      if MapSet.member?(instants, tick) do
        state = HallAuthority.state(authority).hall
        {:ok, view} = HallAuthority.management_view(authority, "observer-device")
        {observation, _} = Stats.observe(state, Stats.counters(), nil)
        send(parent, {:compared, tick, view.hall.stalls, Management.queue_activity(state), observation.stalls})
      end
    end

    _ = run!(%{run: :a, observer: observer})

    compared =
      for _ <- 1..20 do
        assert_received {:compared, _tick, view_stalls, activity, sampled}
        assert map_size(sampled) == length(view_stalls)

        for stall <- view_stalls do
          assert stall.activity.waiting == activity[stall.stall_id].waiting
          assert stall.activity.waiting == sampled[stall.stall_id].waiting
          assert stall.activity.cooking == sampled[stall.stall_id].cooking
          assert stall.activity.handover == sampled[stall.stall_id].handover
          stall.activity.waiting
        end
      end

    assert compared |> List.flatten() |> Enum.any?(&(&1 > 0))
  end

  @tag timeout: 180_000
  test "--via retune reaches the same rules as --via init by the first measured midnight" do
    {:ok, tuning} = CLI.tuning("current", ["version=2", "demand.arrivals_per_equivalent=120"])
    init = run!(%{tuning: tuning, via: :init})
    retune = run!(%{tuning: tuning, via: :retune})
    init_state = HallAuthority.state(init.authority).hall
    retune_state = HallAuthority.state(retune.authority).hall
    assert init_state.now == Clock.day()
    assert retune_state.now == Clock.day()
    assert Tuning.of(init_state.catalog) == tuning
    assert Tuning.of(retune_state.catalog) == tuning
    assert init_state.demand.hour_quotas_millis == retune_state.demand.hour_quotas_millis

    default =
      FeudHall.Domain.Demand.hour_quotas(LaunchCatalog.catalog().rules.demand, init_state.demand.supply_scale_millis)

    refute init_state.demand.hour_quotas_millis == default
  end
end
