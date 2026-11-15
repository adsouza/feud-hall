defmodule FeudHall.Domain.RetuneTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Clock, Content, Demand, Hall}
  alias FeudHall.Domain.Content.{LaunchCatalog, SliceCatalog, Tuning}
  alias FeudHall.Domain.Hall.Retune

  @catalog LaunchCatalog.catalog()
  @admin {:system, :admin}
  @npc {:npc, "budget"}
  @hour Clock.hour()
  @day Clock.day()

  # A managed launch hall with one computer-run restaurant open at s001 and simulated diners arriving.
  defp launch_world(catalog \\ @catalog) do
    {nil, []}
    |> run!({:initialize_hall, %{hall_id: "launch", catalog: catalog, managed: true}}, @admin, "init")
    |> run!(
      {:create_restaurant, %{stall_id: "s001", restaurant_id: "r1", name: "Launch counter", cuisine: "levantine"}},
      @npc,
      "create"
    )
    |> run!({:open_stall, %{stall_id: "s001"}}, @npc, "open")
  end

  defp launch_hall, do: elem(launch_world(), 0)

  defp retune(tuning), do: {:retune_rules, %{tuning: tuning}}

  defp decide(state, tuning), do: Hall.decide(state, retune(tuning), ctx(@admin, "retune"))

  defp double(map), do: Map.new(map, fn {k, v} -> {k, v * 2} end)

  # Version 2, 180 arrivals per equivalent, every market target and cap doubled.
  defp doubled(catalog) do
    base = Tuning.of(catalog)

    %{
      base
      | version: 2,
        demand: %{base.demand | arrivals_per_equivalent: 180},
        market: %{
          target_stock_per_equivalent: double(base.market.target_stock_per_equivalent),
          replenish_cap: double(base.market.replenish_cap)
        }
    }
  end

  defp versioned(catalog, version), do: %{Tuning.of(catalog) | version: version}

  defp events_after(log, before), do: Enum.drop(log, length(before))
  defp day_closed(events), do: for(%{type: :day_closed} = e <- events, do: e)
  defp arrivals_of_day(events, day), do: Enum.filter(events, &match?(%{type: :diner_arrived}, &1)) |> of_day(day)
  defp of_day(arrivals, day), do: Enum.filter(arrivals, &String.starts_with?(&1.arrival_id, "A#{day}-"))

  test "a retune replaces the tunable values and nothing else" do
    state = launch_hall()
    tuning = doubled(state.catalog)
    assert tuning.demand.arrivals_per_equivalent == 2 * state.catalog.rules.demand.arrivals_per_equivalent
    assert {:ok, [event]} = Retune.decide(state, tuning)
    assert event.type == :hall_rules_retuned and event.tuning == tuning
    assert Map.keys(event) |> Enum.sort() == [:content_hash, :tuning, :type]

    after_state = Retune.evolve(state, event)
    assert Tuning.of(after_state.catalog) == tuning
    assert after_state.content_hash == Content.hash(after_state.catalog)
    assert after_state.content_hash != state.content_hash
    assert Map.drop(after_state, [:catalog, :content_hash]) == Map.drop(state, [:catalog, :content_hash])

    # The hall's decider and evolver route the command and event to the same place.
    assert {:ok, [^event]} = decide(state, tuning)
    assert Hall.evolve(state, event) == after_state
  end

  test "today keeps its recorded quotas; the next midnight uses the new values" do
    {noon_state, _} = world = launch_world() |> advance_hall(14 * @hour)
    day0_quotas = noon_state.demand.hour_quotas_millis
    tuning = doubled(noon_state.catalog)

    {retuned, retuned_log} = retuned_world = run!(world, retune(tuning), @admin, "retune:2")
    assert retuned.demand == noon_state.demand
    assert retuned.market == noon_state.market

    {final, log} = advance_hall(retuned_world, @day)
    {_plain, plain_log} = advance_hall(world, @day)
    advanced = events_after(log, retuned_log)

    # Day 0's arrivals follow its recorded quotas exactly as without the retune; every
    # milli-arrival of day 0 either arrived or is carried into day 1.
    day0 = arrivals_of_day(log, 0)
    assert day0 != []
    assert day0 == arrivals_of_day(plain_log, 0)
    assert 1000 * length(day0) + final.demand.acc_millis == Enum.sum(day0_quotas)

    # The midnight records the new day's quotas from the new rules.
    assert [closed] = day_closed(advanced)
    new_rules = final.catalog.rules.demand
    assert new_rules.arrivals_per_equivalent == 180
    assert closed.hour_quotas_millis == Demand.hour_quotas(new_rules, closed.scale_millis)
    assert closed.hour_quotas_millis != Demand.hour_quotas(noon_state.catalog.rules.demand, closed.scale_millis)
    assert final.demand.hour_quotas_millis == closed.hour_quotas_millis

    # Its replenishment fills each product to min(new target, new cap), computed here from the formula.
    at_close = Hall.replay(Enum.take_while(advanced, &(&1.type != :day_closed)), retuned)
    floor = new_rules.equivalent_floor_millis
    open = for {_, %{mode: :open, restaurant: r}} <- at_close.stalls, uniq: true, do: r
    cap_scale = max(floor, length(open) * 1000)
    market = final.catalog.rules.market

    expected =
      Map.new(at_close.market.stock, fn {product, stock} ->
        target = div(market.target_stock_per_equivalent[product] * at_close.demand.supply_scale_millis, 1000)
        cap = div(market.replenish_cap[product] * cap_scale, floor)
        {product, max(0, min(target, cap) - stock)}
      end)

    assert closed.replenishment == expected
    assert Enum.all?(expected, fn {_, qty} -> qty > 0 end)
    assert [plain_closed] = day_closed(plain_log)
    assert Enum.all?(plain_closed.replenishment, fn {_, qty} -> qty == 0 end)
  end

  test "stock above a lowered target is kept" do
    {state, log} = launch_world()
    product = state.catalog.products |> Map.keys() |> Enum.min()
    state = put_in(state.market.stock[product], 500)

    old_target =
      div(state.catalog.rules.market.target_stock_per_equivalent[product] * state.demand.supply_scale_millis, 1000)

    assert old_target > 500
    base = Tuning.of(state.catalog)

    lowered = fn target, cap ->
      %{
        base
        | version: 2,
          market: %{
            target_stock_per_equivalent: Map.put(base.market.target_stock_per_equivalent, product, target),
            replenish_cap: Map.put(base.market.replenish_cap, product, cap)
          }
      }
    end

    # Content requires a positive target with a cap of at least three times it, so 0 is refused;
    # the lowest valid target and cap stand in for it.
    assert {:error, {:invalid_content, problems}} = decide(state, lowered.(0, 0))
    assert {:market, product, :missing_target} in problems

    {final, final_log} =
      {state, log} |> run!(retune(lowered.(1, 3)), @admin, "retune:2") |> advance_hall(@day)

    assert [closed] = day_closed(final_log)
    assert closed.replenishment[product] == 0
    assert final.market.stock[product] == 500
  end

  describe "refusals record nothing" do
    test "a slice hall" do
      {state, _} =
        run!({nil, []}, {:initialize_hall, %{hall_id: "slice", catalog: SliceCatalog.catalog()}}, @admin, "init")

      assert decide(state, versioned(state.catalog, 2)) == {:error, :retune_unavailable}
    end

    test "a hall whose catalog has no demand rules" do
      state = launch_hall()
      tuning = doubled(state.catalog)
      state = update_in(state.catalog.rules, &Map.delete(&1, :demand))
      assert decide(state, tuning) == {:error, :retune_unavailable}
    end

    test "a hall not yet initialised" do
      assert decide(nil, doubled(@catalog)) == {:error, :hall_not_initialized}
    end

    test "version 1" do
      state = launch_hall()
      assert decide(state, versioned(state.catalog, 1)) == {:error, :retune_unavailable}
    end

    test "the same version again after it was applied" do
      {state, _} = run!(launch_world(), retune(doubled(@catalog)), @admin, "retune:2")
      assert Tuning.of(state.catalog).version == 2
      assert decide(state, doubled(@catalog)) == {:error, :retune_unavailable}
      assert decide(state, versioned(state.catalog, 2)) == {:error, :retune_unavailable}
    end

    test "an older version after a newer one" do
      {state, _} = run!(launch_world(), retune(versioned(@catalog, 3)), @admin, "retune:3")
      assert decide(state, doubled(@catalog)) == {:error, :retune_unavailable}
      assert Tuning.of(state.catalog).version == 3
    end

    test "each malformed tuning is invalid content" do
      state = launch_hall()
      base = versioned(state.catalog, 2)
      weights = base.demand.hourly_weights
      [product | _] = base.market.target_stock_per_equivalent |> Map.keys() |> Enum.sort()

      malformed = [
        put_in(base.demand.hourly_weights, Enum.take(weights, 23)),
        put_in(base.demand.hourly_weights, List.replace_at(weights, 3, 1)),
        put_in(base.demand.hourly_weights, List.replace_at(weights, 12, -1)),
        put_in(base.demand.arrivals_per_equivalent, -1),
        put_in(
          base.market.target_stock_per_equivalent,
          Map.put(base.market.target_stock_per_equivalent, "nonsense", 1)
        ),
        put_in(base.market.replenish_cap, Map.delete(base.market.replenish_cap, product)),
        put_in(base.demand, Map.put(base.demand, :equivalent_floor_millis, 1_000)),
        Map.put(base, :kitchen, %{}),
        put_in(base.npc.starter_shifts["budget"], {5, 17}),
        # Valid as a tuning, but the resulting catalog breaks content's cap rule.
        put_in(base.market.replenish_cap[product], base.market.target_stock_per_equivalent[product]),
        :not_a_tuning
      ]

      for tuning <- malformed do
        assert {:error, {:invalid_content, [_ | _]}} = decide(state, tuning), inspect(tuning, limit: 5)
      end
    end
  end
end
