defmodule FeudHall.Domain.NpcPlanTest do
  # Not async: one case swaps the planner module for a stub while it replays.
  use ExUnit.Case, async: false

  import FeudHall.Fixtures

  alias FeudHall.Domain.{Hall, PublicView, Random}
  alias FeudHall.MexicanFixture
  alias FeudHall.Domain.Npc.Planner
  alias FeudHall.Infrastructure.EventCodec

  @hour 3_600_000
  @npc {:npc, "budget"}
  @budget Enum.find(MexicanFixture.catalog().npc_profiles, &(&1.id == "budget"))
  @interval MexicanFixture.rules().market.clear_every_hall_ms

  # alice's r1 at s001 and the budget NPC's restaurant at s041; a quiet hall at time 0.
  defp world(opts \\ []) do
    [arrivals: false, unlock: false, stock: %{}]
    |> Keyword.merge(opts)
    |> stocked_world()
    |> run!(
      {:create_restaurant, %{restaurant_id: "npc-budget", stall_id: "s041", name: "NPC budget", cuisine: "mexican"}},
      @npc,
      "npc:budget:create"
    )
  end

  defp plan(slot, actions, rng \\ 5),
    do: {:npc_plan, %{operator: "budget", slot: slot, actions: actions, rng: rng}}

  defp plan_id(slot), do: "npc:budget:#{slot}"

  defp run_plan(world, slot, actions, rng \\ 5), do: run!(world, plan(slot, actions, rng), @npc, plan_id(slot))

  defp price(r, recipe, price), do: {:set_menu_price, %{restaurant_id: r, recipe_id: recipe, price: price}}

  defp new_events({_state, log}, before), do: Enum.drop(log, length(before))

  describe "NPC restaurants" do
    test "an NPC's restaurant_created opens its planning slot at the next hour and its own random stream" do
      {state, log} = world()
      seed = MexicanFixture.rules().seed

      assert state.npcs == %{
               "budget" => %{
                 restaurant_id: "npc-budget",
                 profile_id: "budget",
                 next_slot_at: @hour,
                 rng: Random.new(Random.derive(seed, "npc:budget"))
               }
             }

      created = Enum.find(log, &(&1.type == :restaurant_created and &1.owner_kind == :npc))
      assert {:ok, ^created} = created |> EventCodec.encode!() |> EventCodec.decode()

      # Created exactly on a boundary, the first slot is the following hour.
      {at_boundary, _} =
        stocked_world(arrivals: false, unlock: false, stock: %{})
        |> advance_hall(@hour)
        |> run!(
          {:create_restaurant, %{restaurant_id: "npc-x", stall_id: "s041", name: "NPC x", cuisine: "mexican"}},
          {:npc, "x"},
          "npc:x:create"
        )

      assert at_boundary.npcs["x"].next_slot_at == 2 * @hour
    end
  end

  describe "npc_plan" do
    test "a plan with one valid and one invalid action commits atomically with per-action outcomes" do
      {_, before} = world = world() |> advance_hall(@hour)

      {state, _} =
        after_plan = run_plan(world, @hour, [price("npc-budget", "bean_tacos", 777), price("r1", "bean_tacos", 1)])

      assert [planned, %{type: :menu_price_set, restaurant_id: "npc-budget", price: 777}] =
               new_events(after_plan, before)

      assert planned == %{
               type: :npc_planned,
               operator: "budget",
               slot: @hour,
               next_slot_at: 2 * @hour,
               rng: 5,
               outcomes: [
                 %{action: :set_menu_price, result: :accepted},
                 %{action: :set_menu_price, result: :rejected, reason: :forbidden}
               ]
             }

      assert {:ok, ^planned} = planned |> EventCodec.encode!() |> EventCodec.decode()
      assert state.npcs["budget"].next_slot_at == 2 * @hour
      assert state.npcs["budget"].rng == 5
      assert state.restaurants["npc-budget"].menu["bean_tacos"] == 777
      assert state.restaurants["r1"].menu["bean_tacos"] == 900
    end

    test "each action is decided against the state the earlier accepted actions produced" do
      {_, before} = world = world() |> advance_hall(@hour)

      actions = [
        price("npc-budget", "horchata", 300),
        {:unlock_recipe, %{restaurant_id: "npc-budget", recipe_id: "horchata"}},
        price("npc-budget", "horchata", 300)
      ]

      {state, _} = after_plan = run_plan(world, @hour, actions)
      [planned, unlocked, priced] = new_events(after_plan, before)

      assert planned.outcomes == [
               %{action: :set_menu_price, result: :rejected, reason: :recipe_locked},
               %{action: :unlock_recipe, result: :accepted},
               %{action: :set_menu_price, result: :accepted}
             ]

      assert %{type: :recipe_unlocked, recipe_id: "horchata"} = unlocked
      assert %{type: :menu_price_set, recipe_id: "horchata", price: 300} = priced
      assert "horchata" in state.restaurants["npc-budget"].unlocked
      assert state.restaurants["npc-budget"].menu["horchata"] == 300
    end

    test "purchase requests from a plan are named after the plan's sub-command IDs" do
      world = world() |> advance_hall(@hour)

      buy =
        {:submit_purchase_request,
         %{restaurant_id: "npc-budget", product: "sugar", qty: 10, max_price_per_kunit: 1_000_000}}

      {state, _} = run_plan(world, @hour, [buy, buy])

      # The second request replaces the first, as two separate owner commands would.
      assert Map.keys(state.market.requests) == ["PR:npc:budget:#{@hour}:1"]
    end

    test "a second plan for the same slot is :slot_already_planned" do
      world = world() |> advance_hall(@hour) |> run_plan(@hour, [])
      assert reject!(world, plan(@hour, []), @npc, plan_id(@hour)) == :slot_already_planned
    end

    test "only the latest reached hour boundary can be planned, under its own command ID" do
      world = world() |> advance_hall(3 * @hour)

      assert reject!(world, plan(2 * @hour, []), @npc, plan_id(2 * @hour)) == :stale_slot
      assert reject!(world, plan(3 * @hour + 1, []), @npc, plan_id(3 * @hour + 1)) == :slot_not_reached
      assert reject!(world, plan(4 * @hour, []), @npc, plan_id(4 * @hour)) == :slot_not_reached
      assert reject!(world, plan(3 * @hour, []), @npc, "npc:budget:other") == :invalid_command_id

      # Before its first slot an NPC has nothing to plan.
      assert reject!(world(), plan(0, []), @npc, plan_id(0)) == :slot_already_planned

      # Several crossed slots are planned once, at the latest.
      {state, _} = run_plan(world, 3 * @hour, [])
      assert state.npcs["budget"].next_slot_at == 4 * @hour
    end

    test "only the NPC itself may submit its plan" do
      world = world() |> advance_hall(@hour)
      assert reject!(world, plan(@hour, []), {:npc, "mainstream"}, plan_id(@hour)) == :unauthorized_or_malformed
      assert reject!(world, plan(@hour, []), owner(), plan_id(@hour)) == :unauthorized_or_malformed
      assert reject!(world, plan(@hour, []), {:system, :admin}, plan_id(@hour)) == :unauthorized_or_malformed

      unknown = {:npc_plan, %{operator: "ghost", slot: @hour, actions: [], rng: 5}}
      assert reject!(world, unknown, {:npc, "ghost"}, "npc:ghost:#{@hour}") == :unknown_npc
      assert reject!(world, plan(@hour, [], -1), @npc, plan_id(@hour)) == :invalid_payload
      assert reject!(world, plan(@hour, [], 18_446_744_073_709_551_616), @npc, plan_id(@hour)) == :invalid_payload
      assert reject!(world, plan(@hour, List.duplicate(:garbage, 257)), @npc, plan_id(@hour)) == :too_many_actions
    end

    test "actions an owner could not issue are rejected inside the plan, which still commits" do
      {_, before} = world = world() |> advance_hall(@hour)

      actions = [
        plan(@hour, []),
        {:initialize_hall, %{hall_id: "h2", catalog: MexicanFixture.catalog()}},
        {:create_restaurant, %{restaurant_id: "r7", stall_id: "s007", name: "Seven", cuisine: "mexican"}},
        {:advance_clock, %{to_service_ms: 999_999}},
        {:grant_allowance, %{principal: "budget", amount: 10}},
        {:open_stall, :not_a_map},
        :garbage,
        {:open_stall, %{stall_id: "s041"}}
      ]

      {state, _} = after_plan = run_plan(world, @hour, actions)
      [planned | rest] = new_events(after_plan, before)

      assert Enum.map(planned.outcomes, &Map.get(&1, :reason)) ==
               List.duplicate(:action_not_allowed, 5) ++ [:malformed_action, :malformed_action, nil]

      assert [%{type: :stall_opened, stall_id: "s041"}] = rest
      assert {:ok, ^planned} = planned |> EventCodec.encode!() |> EventCodec.decode()
      assert state.now == @hour
      assert map_size(state.restaurants) == 2
      assert state.npcs["budget"].next_slot_at == 2 * @hour
    end

    test "every reason a plan action can be rejected with is a codec-encodable atom" do
      reasons =
        ~w(unknown_stall unknown_restaurant forbidden unknown_recipe wrong_cuisine already_unlocked
           insufficient_cash recipe_locked invalid_price not_on_menu unknown_line invalid_policy
           no_approved_substitute unknown_product invalid_quantity invalid_price_limit no_pending_request
           staff_off_duty unpaid_rent owner_absent
           unauthorized_or_malformed malformed_command action_not_allowed malformed_action
           unrecognised_reason)a

      event = %{
        type: :npc_planned,
        operator: "budget",
        slot: @hour,
        next_slot_at: 2 * @hour,
        rng: 1,
        outcomes: for(r <- reasons, do: %{action: :set_menu_price, result: :rejected, reason: r})
      }

      encoded =
        try do
          EventCodec.encode!(event)
        rescue
          error in ArgumentError -> flunk("a valid NPC outcome could not be encoded: #{Exception.message(error)}")
        end

      assert {:ok, ^event} = EventCodec.decode(encoded)
    end

    test "(Review Focus 4) an NPC with no cash and no stock commits its plan; what it cannot pay for is refused with reasons" do
      catalog = put_in(MexicanFixture.catalog(), [:rules, :starter_grant], 0)
      {_, before} = world = world(catalog: catalog) |> advance_hall(@hour)
      {state, _} = world
      own = state.restaurants["npc-budget"]
      assert own.ledger.cash == 0 and own.batches == %{}

      # The planner's own plan for a penniless NPC, plus an unlock it cannot afford.
      {planned_actions, rng} =
        Planner.plan(PublicView.build(state), own, @budget, state.catalog, state.npcs["budget"].rng)

      purchases = Enum.filter(planned_actions, &match?({:submit_purchase_request, _}, &1))
      assert purchases != []
      unlock = {:unlock_recipe, %{restaurant_id: "npc-budget", recipe_id: "horchata"}}

      {state, _} = after_plan = run_plan(world, @hour, planned_actions ++ [unlock], rng)
      [planned | _] = new_events(after_plan, before)
      assert List.last(planned.outcomes) == %{action: :unlock_recipe, result: :rejected, reason: :insufficient_cash}
      assert state.npcs["budget"].next_slot_at == 2 * @hour

      # Purchase requests hold no cash when submitted (funding is decided at clearing), so they are
      # refused, with a reason, at the next clearing.
      requested = for {id, %{restaurant_id: "npc-budget"}} <- state.market.requests, do: id
      assert length(requested) == length(purchases)
      assert state.market.next_clear_at - state.now <= @interval

      cleared = advance_hall(after_plan, state.market.next_clear_at)
      assert [clearing] = cleared |> new_events(elem(after_plan, 1)) |> Enum.filter(&(&1.type == :market_cleared))
      refused = for u <- clearing.unfilled, u.request_id in requested, do: {u.request_id, u.reason}
      assert Enum.sort(refused) == Enum.sort(for id <- requested, do: {id, :insufficient_cash})
      assert Enum.filter(clearing.fills, &(&1.restaurant_id == "npc-budget")) == []
      assert elem(cleared, 0).restaurants["npc-budget"].ledger.cash == 0
    end

    test "an identical set_menu_price from a principal and from an NPC produces identical restaurant state" do
      world = world() |> advance_hall(@hour)

      {state, _} =
        world
        |> run!(price("r1", "bean_tacos", 650), owner(), "alice-price")
        |> run_plan(@hour, [price("npc-budget", "bean_tacos", 650)])

      operational = fn r -> Map.drop(r, [:id, :owner, :owner_kind, :name]) end
      assert operational.(state.restaurants["r1"]) == operational.(state.restaurants["npc-budget"])
      assert state.restaurants["r1"].menu == %{"bean_tacos" => 650}
    end

    test "replay reproduces the NPC state from the recorded facts without running the planner" do
      world = world(arrivals: true) |> advance_hall(@hour)
      {state, _} = world
      npc = state.npcs["budget"]

      {actions, rng} =
        Planner.plan(PublicView.build(state), state.restaurants["npc-budget"], @budget, state.catalog, npc.rng)

      assert actions != []

      {live, log} = world |> run_plan(@hour, actions, rng) |> advance_hall(2 * @hour)

      with_planner_stub(fn ->
        assert_raise RuntimeError, ~r/planner called/, fn -> apply(Planner, :plan, List.duplicate(nil, 5)) end
        assert Hall.replay(log) == live
      end)

      assert live.npcs["budget"].next_slot_at == 2 * @hour
    end
  end

  # Loads a planner whose every function raises, runs `fun`, then restores the real module.
  defp with_planner_stub(fun) do
    {Planner, binary, file} = :code.get_object_code(Planner)
    options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Module.create(
        Planner,
        quote do
          def plan(_view, _own, _profile, _catalog, _rng), do: raise("planner called")
          def choose_slot(_view, _layout, _profile), do: raise("planner called")
        end,
        Macro.Env.location(__ENV__)
      )

      fun.()
    after
      :code.purge(Planner)
      {:module, Planner} = :code.load_binary(Planner, file, binary)
      :code.purge(Planner)
      Code.compiler_options(ignore_module_conflict: Map.get(options, :ignore_module_conflict, false))
    end
  end
end
