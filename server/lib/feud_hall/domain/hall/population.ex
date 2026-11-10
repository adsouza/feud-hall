defmodule FeudHall.Domain.Hall.Population do
  @moduledoc "Recorded population windows and one-direction NPC evaluations."

  alias FeudHall.Domain.{Clock, Demand, PublicView}
  alias FeudHall.Domain.Hall.{Decider, Evolver, Management, Progression}
  alias FeudHall.Domain.Npc.Planner

  @floor 3
  @high 13
  @low 8
  @high_window Clock.service_duration(300_000)
  @low_window Clock.service_duration(600_000)
  @short_window @low_window

  def new do
    %{high: 0, low: 0, short: 0, eligible: false, last_retirement: nil, last_restoration: nil, closing: %{}}
  end

  def recovered(%{progression: %{population: p}} = state) do
    put_in(state.progression.population, %{p | high: 0, low: 0, eligible: false})
  end

  def recovered(state), do: state

  def observe(%{progression: %{population: p}, access: :open} = state, elapsed, operating) do
    occupied =
      for {sid, stall} <- state.stalls,
          state.management.leases[sid].arrears == 0,
          into: MapSet.new(),
          do: stall.restaurant

    owners =
      Enum.count(state.management.presence, fn {principal, expires} ->
        expires > state.now and MapSet.member?(occupied, state.owners[{:principal, principal}])
      end)

    high = if owners >= @high, do: min(@high_window, p.high + elapsed), else: 0
    low = if owners < @low, do: min(@low_window, p.low + elapsed), else: 0
    short = if length(operating) < @floor, do: min(@short_window, p.short + elapsed), else: 0
    eligible = (p.eligible or high >= @high_window) and low < @low_window
    put_in(state.progression.population, %{p | high: high, low: low, short: short, eligible: eligible})
  end

  def observe(state, _elapsed, _operating), do: state

  def evaluate(%{progression: %{population: p}, access: :open} = state) do
    operating = Demand.operating(state)
    day = Clock.day_of(state.now)
    hour = div(state.now, Clock.hour())

    cond do
      length(operating) < @floor and p.short >= @short_window and p.last_restoration != hour ->
        restore(state, hour)

      length(operating) >= @floor and p.eligible and p.last_retirement != day ->
        retire(state, operating, day)

      true ->
        []
    end
  end

  def evaluate(_state), do: []

  def closing?(state, id), do: get_in(state, [:progression, :population, :closing, id]) != nil

  def boundaries(%{progression: %{population: population}} = state) do
    for {id, deadline} <- population.closing do
      busy? = Enum.any?(state.visits, fn {_, visit} -> visit.restaurant == id end)
      {if(busy?, do: deadline, else: state.now), id, {:npc_retirement_due, id}}
    end
  end

  def boundaries(_state), do: []

  def finish_retirement(state, id) do
    events = if state.restaurants[id], do: Progression.retire_npc(state, id), else: []
    events ++ [%{type: :npc_retirement_finished, restaurant_id: id}]
  end

  defp retire(state, operating, day) do
    state.npcs
    |> Enum.sort()
    |> Enum.find_value([], fn {operator, npc} ->
      id = npc.restaurant_id
      locations = Progression.stalls(state, id)

      if locations != [] and not closing?(state, id) and not Progression.distressed?(state, id) and
           length(List.delete(operating, id)) >= @floor do
        schedule_retirement(state, operator, id, locations, day)
      end
    end)
  end

  defp schedule_retirement(state, operator, id, locations, day) do
    {closes, current} =
      Enum.map_reduce(locations, state, fn sid, current ->
        command = {:close_stall, %{stall_id: sid}}
        {:ok, events} = Decider.decide(current, command, %{actor: {:npc, operator}, command_id: "retire:#{day}"})
        {events, Enum.reduce(events, current, &Evolver.evolve(&2, &1))}
      end)

    deadline =
      current.orders
      |> Map.values()
      |> Enum.filter(&(current.visits[&1.visit].restaurant == id))
      |> Enum.map(& &1.deadline)
      |> Enum.max(fn -> state.now end)

    List.flatten(closes) ++ [%{type: :npc_retirement_scheduled, restaurant_id: id, deadline: deadline, day: day}]
  end

  defp restore(state, hour) do
    view = PublicView.build(state)
    layout = Map.reject(state.layout, fn {sid, _} -> Management.reserved?(state, sid) end)

    state.catalog.npc_profiles
    |> Enum.sort_by(& &1.id)
    |> Enum.find_value([], fn profile ->
      actor = {:npc, profile.id}
      existing = state.owners[actor]

      if is_nil(existing) or (Progression.stalls(state, existing) == [] and not closing?(state, existing)) do
        with sid when is_binary(sid) <- Planner.choose_slot(view, layout, profile),
             {id, kind, payload} <- restoration(state, existing, profile.id, sid, hour),
             {:ok, events} <- Decider.decide(state, {kind, payload}, %{actor: actor, command_id: "population:#{hour}"}) do
          events ++ [%{type: :npc_population_changed, action: :restoration, at: hour, restaurant_id: id}]
        else
          _ -> nil
        end
      end
    end)
  end

  defp restoration(state, nil, operator, sid, hour) do
    starters =
      for recipe <- Map.values(state.catalog.recipes), recipe.starter, do: recipe.cuisine

    starters = Enum.sort(starters)
    cuisine = Enum.at(starters, rem(hour, length(starters)))
    id = "npc-#{operator}-#{hour}"
    {id, :create_restaurant, %{restaurant_id: id, stall_id: sid, name: "NPC #{operator}", cuisine: cuisine}}
  end

  defp restoration(state, id, _operator, sid, _hour),
    do: {id, :lease_location, %{restaurant_id: id, stall_id: sid, cuisine: state.restaurants[id].cuisine}}

  def evolve(state, %{type: :npc_retirement_scheduled} = event) do
    state
    |> put_in([:progression, :population, :last_retirement], event.day)
    |> put_in([:progression, :population, :closing, event.restaurant_id], event.deadline)
  end

  def evolve(state, %{type: :npc_retirement_finished, restaurant_id: id}),
    do: update_in(state.progression.population.closing, &Map.delete(&1, id))

  def evolve(state, %{action: :restoration, at: hour}), do: put_in(state.progression.population.last_restoration, hour)
end
