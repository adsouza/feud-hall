defmodule FeudHall.Domain.ChoiceTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Choice, Dietary, Random}
  alias FeudHall.Domain.Hall.Admission

  @minute 60_000

  setup_all do
    {state, _log} = stocked_world()
    %{state: state}
  end

  defp segment(state, id), do: Enum.find(state.catalog.rules.demand.segments, &(&1.id == id))

  defp diner(state, overrides \\ %{}) do
    {:ok, requirement} = Dietary.requirement(state.catalog, "unrestricted")

    Map.merge(
      %{
        segment: segment(state, "value"),
        budget: 10_000,
        requirement: requirement,
        patience_hall_ms: 40 * @minute,
        drink?: false
      },
      overrides
    )
  end

  defp requirement(state, profile) do
    {:ok, requirement} = Dietary.requirement(state.catalog, profile)
    requirement
  end

  defp only_mains(state, mains) do
    update_in(state, [:restaurants, "r1", :menu], &Map.take(&1, mains))
  end

  # A second restaurant that is a copy of r1 on its own stall of the given tier.
  defp with_rival(state, slot, tier) do
    state
    |> put_in([:restaurants, "r2"], %{state.restaurants["r1"] | id: "r2"})
    |> put_in([:stalls, slot], %{state.stalls["s001"] | id: slot, restaurant: "r2", tier: tier})
  end

  defp draws(state, diner, rng, count) do
    Enum.map_reduce(1..count, rng, fn _, rng -> Choice.choose(state, diner, rng) end)
  end

  describe "dietary compatibility" do
    test "incompatible food has zero probability even when it is the only stall and costs 1", %{state: state} do
      # Vegan diner; the only mains on offer contain meat or dairy.
      state =
        state
        |> only_mains(["chicken_tacos", "vegetable_quesadilla"])
        |> put_in([:restaurants, "r1", :menu, "chicken_tacos"], 1)

      diner = diner(state, %{requirement: requirement(state, "vegan")})

      {picks, _rng} = draws(state, diner, Random.new(7), 300)

      assert Enum.all?(picks, &(&1 == {:leave, :no_compatible_main}))
    end

    test "a cheap incompatible dish is never chosen over a compatible one", %{state: state} do
      state =
        state |> only_mains(["chicken_tacos", "bean_tacos"]) |> put_in([:restaurants, "r1", :menu, "chicken_tacos"], 1)

      diner = diner(state, %{requirement: requirement(state, "vegan")})

      {picks, _rng} = draws(state, diner, Random.new(11), 400)

      assert {:stall, "s001", "bean_tacos", nil} in picks
      assert Enum.all?(picks, &(&1 in [{:stall, "s001", "bean_tacos", nil}, {:leave, :chose_to_leave}]))
    end
  end

  describe "exposure and variety" do
    test "exposure applies once: prime draws 1.5/2.5 of non-leave picks", %{state: state} do
      state = state |> with_rival("s002", :standard) |> put_in([:stalls, "s001", :tier], :prime)
      diner = diner(state)

      {picks, _rng} = draws(state, diner, Random.new(2_026), 4_000)

      stalls = for {:stall, stall, _main, _drink} <- picks, do: stall
      prime = Enum.count(stalls, &(&1 == "s001"))
      assert Enum.count(stalls, &(&1 == "s002")) + prime == length(stalls)
      assert length(stalls) > 2_000

      share_permille = div(prime * 1000, length(stalls))
      assert share_permille in 550..650
    end

    test "a second main that is not the best dish adds exactly the variety bonus", %{state: state} do
      standard = put_in(state, [:stalls, "s001", :tier], :standard)
      one = only_mains(standard, ["bean_tacos"])
      two = only_mains(standard, ["bean_tacos", "chicken_tacos"])
      diner = diner(standard)

      [{pick_one, weight_one}] = Choice.stall_weights(one, diner)
      [{pick_two, weight_two}] = Choice.stall_weights(two, diner)

      assert pick_one == {:stall, "s001", "bean_tacos", nil}
      assert pick_two == pick_one
      assert weight_two == weight_one + state.catalog.rules.demand.variety_weight
    end

    test "drink and dessert rows add no weight", %{state: state} do
      standard = put_in(state, [:stalls, "s001", :tier], :standard)
      mains = only_mains(standard, ["bean_tacos"])
      extras = only_mains(standard, ["bean_tacos", "horchata", "arroz_con_leche"])
      diner = diner(standard)

      assert Choice.stall_weights(extras, diner) == Choice.stall_weights(mains, diner)
    end

    test "more distinct mains earn a stall the variety bonus", %{state: state} do
      state =
        state
        |> with_rival("s002", :standard)
        |> put_in([:stalls, "s001", :tier], :standard)
        |> update_in([:restaurants, "r2", :menu], &Map.take(&1, ["bean_tacos"]))

      {picks, _rng} = draws(state, diner(state), Random.new(77), 3_000)

      varied = Enum.count(picks, &match?({:stall, "s001", _, _}, &1))
      plain = Enum.count(picks, &match?({:stall, "s002", _, _}, &1))
      assert varied > plain
    end
  end

  describe "leave reasons" do
    test "no stall has a dietary-compatible main", %{state: state} do
      state = only_mains(state, ["chicken_tacos"])
      diner = diner(state, %{requirement: requirement(state, "vegan")})
      rng = Random.new(3)

      assert {{:leave, :no_compatible_main}, ^rng} = Choice.choose(state, diner, rng)
    end

    test "compatible mains exist but none fits the budget", %{state: state} do
      diner = diner(state, %{budget: 1})

      assert {{:leave, :nothing_affordable}, _} = Choice.choose(state, diner, Random.new(3))
    end

    test "affordable mains exist but none finishes within the patience", %{state: state} do
      diner = diner(state, %{patience_hall_ms: 1})

      assert {{:leave, :wait_too_long}, _} = Choice.choose(state, diner, Random.new(3))
    end

    test "a diner with viable options can still choose to leave", %{state: state} do
      leave_only = %{segment(state, "value") | leave_weight: 1_000_000_000}
      diner = diner(state, %{segment: leave_only})

      {picks, _} = draws(state, diner, Random.new(9), 20)

      assert Enum.all?(picks, &(&1 == {:leave, :chose_to_leave}))
    end

    test "a hall with no open stall is nothing a diner can choose", %{state: state} do
      closed = put_in(state, [:stalls, "s001", :mode], :closed)

      assert {{:leave, :no_compatible_main}, _} = Choice.choose(closed, diner(state), Random.new(3))
    end

    test "a stall with a full queue is not a candidate", %{state: state} do
      full = put_in(state, [:catalog, :rules, :kitchen, :queue_limit], 0)

      assert Choice.stall_weights(full, diner(state)) == []
      assert [_] = Choice.stall_weights(state, diner(state))
      assert {{:leave, :no_compatible_main}, _} = Choice.choose(full, diner(state), Random.new(3))
    end
  end

  describe "drink fit" do
    test "a budget that covers the main but not main plus drink picks the main alone", %{state: state} do
      main_only = tray_quote(state, nil)
      with_drink = tray_quote(state, "horchata")
      assert main_only.total < with_drink.total
      diner = diner(state, %{drink?: true, budget: main_only.total})

      assert [{{:stall, "s001", _main, nil}, _}] =
               Choice.stall_weights(only_mains(state, ["bean_tacos", "horchata"]), diner)

      assert {{:stall, "s001", "bean_tacos", nil}, _} =
               pick_stall(only_mains(state, ["bean_tacos", "horchata"]), diner, Random.new(4))
    end

    test "patience that the drink breaks but the main meets picks the main alone", %{state: state} do
      main_only = tray_quote(state, nil)
      with_drink = tray_quote(state, "horchata")
      assert main_only.earliest_completion < with_drink.earliest_completion
      diner = diner(state, %{drink?: true, patience_hall_ms: main_only.earliest_completion - state.now})

      assert [{{:stall, "s001", "bean_tacos", nil}, _}] =
               Choice.stall_weights(only_mains(state, ["bean_tacos", "horchata"]), diner)
    end
  end

  describe "determinism and admission" do
    test "same state and rng give the same result and next rng", %{state: state} do
      diner = diner(state, %{drink?: true})

      assert Choice.choose(state, diner, Random.new(42)) == Choice.choose(state, diner, Random.new(42))
    end

    test "the choice advances the rng when it draws", %{state: state} do
      rng = Random.new(42)
      {_pick, next} = Choice.choose(state, diner(state), rng)

      assert next != rng
    end

    test "a drink is included when requested and quotable", %{state: state} do
      {picks, _} = draws(state, diner(state, %{drink?: true}), Random.new(8), 40)

      assert Enum.any?(picks, &match?({:stall, "s001", _, "horchata"}, &1))
      assert Enum.all?(picks, &(match?({:stall, "s001", _, "horchata"}, &1) or match?({:leave, _}, &1)))
    end

    test "what choose returns is accepted by Admission.admit/3 unchanged", %{state: state} do
      diner = diner(state, %{drink?: true})
      {{:stall, stall_id, main, drink}, _rng} = pick_stall(state, diner, Random.new(1))

      assert {:ok, [%{type: :visit_admitted}, %{type: :tray_accepted}]} =
               Admission.admit(
                 state,
                 %{
                   source: :simulated,
                   principal: "sim:1",
                   budget: diner.budget,
                   stall_id: stall_id,
                   main: main,
                   drink: drink,
                   profile_id: diner.requirement.profile_id,
                   confirmed: nil,
                   deadline_cap: nil
                 },
                 "sim1"
               )
    end
  end

  defp tray_quote(state, drink) do
    {:ok, quote} =
      FeudHall.Domain.Offers.quote_tray(state, "s001", "bean_tacos", drink, %{
        requirement: requirement(state, "unrestricted"),
        carbs_reserved: 0,
        carbs_served: 0
      })

    quote
  end

  defp pick_stall(state, diner, rng) do
    case Choice.choose(state, diner, rng) do
      {{:stall, _, _, _}, _} = picked -> picked
      {{:leave, _}, rng} -> pick_stall(state, diner, rng)
    end
  end
end
