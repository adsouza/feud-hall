defmodule FeudHall.Domain.Hall.Equipment do
  @moduledoc "Paid finishing techniques are installed at one physical location."

  alias FeudHall.Domain.Hall.Progression

  def ready?(state, stall, recipe) do
    method = Map.get(recipe, :technique)

    is_nil(method) or not Progression.enabled?(state) or
      method in capabilities(state, stall)
  end

  def capabilities(state, stall) do
    restaurant = state.restaurants[stall.restaurant]
    cuisine = Progression.cuisine(stall, restaurant)
    starter = get_in(state, [:catalog, :rules, :progression, :starter_techniques, cuisine])

    [starter | Map.keys(Map.get(stall, :equipment, %{}))] |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  def quote(state, restaurant, sid, recipe) do
    if Progression.enabled?(state) and Map.get(recipe, :technique) do
      sid =
        sid ||
          Enum.find(Progression.stalls(state, restaurant.id), fn sid ->
            Progression.cuisine(state.stalls[sid], restaurant) == recipe.cuisine
          end)

      with %{restaurant: owner} = stall when owner == restaurant.id <- state.stalls[sid],
           true <- Progression.cuisine(stall, restaurant) == recipe.cuisine do
        if ready?(state, stall, recipe) do
          {:ok, 0, []}
        else
          method = recipe.technique
          stored = get_in(state, [:progression, :ventures, restaurant.id, :stored_equipment, method]) || []
          basis = List.first(stored) || state.catalog.rules.progression.equipment_cost
          price = if stored == [], do: basis, else: 0

          event = %{
            type: :location_equipped,
            restaurant_id: restaurant.id,
            stall_id: sid,
            technique: method,
            cost: price,
            basis: basis,
            from_storage: stored != []
          }

          {:ok, price, [event]}
        end
      else
        _ -> {:error, :wrong_cuisine}
      end
    else
      {:ok, 0, []}
    end
  end

  def salvage_events(state, sid) do
    for {method, basis} <- Enum.sort(Map.get(state.stalls[sid], :equipment, %{})),
        do: salvage_event(state, sid, method, basis)
  end

  def salvage_event(state, sid, method, basis) do
    %{
      type: :equipment_salvaged,
      stall_id: sid,
      restaurant_id: state.stalls[sid].restaurant,
      technique: method,
      amount: div(min(basis, state.catalog.rules.progression.equipment_cost), 2)
    }
  end

  def store(state, sid) do
    id = state.stalls[sid].restaurant
    equipment = Map.get(state.stalls[sid], :equipment, %{})

    update_in(state.progression.ventures[id], fn venture ->
      Enum.reduce(equipment, venture, fn {method, basis}, current ->
        Map.update(
          current,
          :stored_equipment,
          %{method => [basis]},
          &Map.update(&1, method, [basis], fn costs -> [basis | costs] end)
        )
      end)
    end)
  end

  def evolve(state, %{type: :location_equipped} = e) do
    state =
      if e.from_storage do
        update_in(state.progression.ventures[e.restaurant_id].stored_equipment[e.technique], &tl/1)
      else
        state
      end

    state
    |> update_in([:stalls, e.stall_id], fn stall ->
      Map.update(stall, :equipment, %{e.technique => e.basis}, &Map.put(&1, e.technique, e.basis))
    end)
    |> update_in([:restaurants, e.restaurant_id, :ledger], fn ledger ->
      %{ledger | cash: ledger.cash - e.cost, capex: ledger.capex + e.cost}
    end)
  end

  def evolve(state, %{type: :equipment_salvaged} = e) do
    state
    |> update_in([:stalls, e.stall_id, :equipment], &Map.delete(&1, e.technique))
    |> update_in([:restaurants, e.restaurant_id, :ledger], fn ledger ->
      %{ledger | cash: ledger.cash + e.amount, capex: ledger.capex - e.amount}
    end)
  end
end
