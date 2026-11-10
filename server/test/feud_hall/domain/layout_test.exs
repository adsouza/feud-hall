defmodule FeudHall.Domain.LayoutTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.{Clock, Demand, Hall, Random}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.EventCodec

  defp ctx(actor, id), do: %{command_id: id, actor: actor}

  defp init(payload \\ %{}) do
    {:ok, state, events} =
      Hall.execute(
        nil,
        {:initialize_hall, Map.merge(%{hall_id: "h1", catalog: SliceCatalog.catalog()}, payload)},
        ctx({:system, :admin}, "init")
      )

    {state, hd(events)}
  end

  defp create(state, who, slot) do
    Hall.execute(
      state,
      {:create_restaurant, %{restaurant_id: "r-" <> who, stall_id: slot, name: "Name " <> who, cuisine: "mexican"}},
      ctx({:principal, who}, "create-" <> who)
    )
  end

  test "initialization records the 150-slot layout, the default seed, and market and demand state" do
    {state, event} = init()
    rules = SliceCatalog.rules()

    assert map_size(event.layout) == 150
    assert event.layout["s001"] == :quiet and event.layout["s150"] == :prime
    assert event.seed == rules.seed
    assert state.layout == event.layout
    assert state.npcs == %{}
    # The event records only the PRNG; the forecast fields start from defaults at the floor scale.
    assert event.demand == %{rng: Random.new(Random.derive(rules.seed, "demand"))}

    quotas = Demand.hour_quotas(rules.demand, rules.demand.equivalent_floor_millis)
    [hour0 | _] = quotas

    assert state.demand == %{
             rng: event.demand.rng,
             observed_ms: %{},
             operating: [],
             supply_scale_millis: rules.demand.equivalent_floor_millis,
             today: %{arrivals: 0, admitted: 0, left: %{}, trays_served: 0},
             summaries: [],
             next_day_at: Clock.day(),
             # Day 0's arrival quotas at the floor scale, an empty accumulator
             # anchored at 00:00, and the first arrival inside hour 0.
             hour_quotas_millis: quotas,
             acc_millis: 0,
             acc_at: 0,
             arrival_seq: 0,
             next_arrival_at: div(1000 * Clock.hour() + hour0 - 1, hour0) - 1
           }

    # Stock starts at the per-equivalent target times the three-equivalent floor.
    assert event.market.stock["corn_tortilla"] == 1_200
    assert event.market.stock["cilantro"] == 300
    assert map_size(event.market.stock) == map_size(SliceCatalog.catalog().products)

    assert state.market == %{
             stock: event.market.stock,
             requests: %{},
             by_key: %{},
             batch: 0,
             next_clear_at: rules.market.clear_every_hall_ms
           }
  end

  test "an explicit seed overrides the content seed and seeds the demand stream" do
    {state, event} = init(%{seed: 42})
    assert event.seed == 42
    assert state.demand.rng == Random.new(Random.derive(42, "demand"))
  end

  test "an invalid seed is rejected" do
    for bad <- [-1, "7", 1.5, 18_446_744_073_709_551_616] do
      assert {:error, :invalid_payload} =
               Hall.decide(
                 nil,
                 {:initialize_hall, %{hall_id: "h1", catalog: SliceCatalog.catalog(), seed: bad}},
                 ctx({:system, :admin}, "init")
               )
    end
  end

  test "the initialization event survives the codec round trip" do
    {_, event} = init()
    assert {:ok, ^event} = event |> EventCodec.encode!() |> EventCodec.decode()
  end

  test "an older initialization event without the new fields still evolves" do
    {_, event} = init()
    old = Map.drop(event, [:layout, :seed, :market, :demand])
    state = Hall.replay([old], nil)
    assert state.layout == %{}
    assert state.npcs == %{}
    assert %{rng: rng} = state.demand
    assert is_integer(rng)
    assert %{stock: %{}, requests: %{}, by_key: %{}, batch: 0} = state.market
  end

  test "an owner takes a vacant slot and the stall carries its tier" do
    {state, _} = init()
    assert {:ok, state, _} = create(state, "alice", "s141")
    assert %{tier: :prime, restaurant: "r-alice", mode: :closed} = state.stalls["s141"]
  end

  test "unknown and occupied slots are rejected" do
    {state, _} = init()
    assert {:error, :unknown_slot} = create(state, "alice", "s1")
    assert {:error, :unknown_slot} = create(state, "alice", "s151")
    {:ok, state, _} = create(state, "alice", "s010")
    assert {:error, :stall_taken} = create(state, "bob", "s010")
  end

  test "150 principals fill the hall and the 151st finds no slot" do
    {state, _} = init()
    slots = Map.keys(state.layout) |> Enum.sort()

    state =
      Enum.reduce(Enum.with_index(slots), state, fn {slot, i}, acc ->
        assert {:ok, next, _} = create(acc, "p#{i}", slot)
        next
      end)

    assert map_size(state.stalls) == 150

    for slot <- [hd(slots), List.last(slots), "s151"] do
      assert {:error, reason} = create(state, "extra", slot)
      assert reason in [:stall_taken, :unknown_slot]
    end
  end
end
