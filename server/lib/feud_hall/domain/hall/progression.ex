defmodule FeudHall.Domain.Hall.Progression do
  @moduledoc "Venture and location transitions owned by the managed hall."

  alias FeudHall.Domain.{Market, Money}
  alias FeudHall.Domain.Hall.{CounterPlay, Equipment, Evolver, Management, Population, Recognition, Settlement}

  @commands [
    :lease_location,
    :refit_location,
    :surrender_location,
    :salvage_stock,
    :salvage_equipment,
    :pay_arrears,
    :accept_bankruptcy
  ]
  def commands, do: @commands

  def enabled?(state), do: is_map_key(state, :progression)
  def distressed?(state, id), do: get_in(state, [:progression, :distress, id]) != nil
  def retired?(state, id), do: get_in(state, [:progression, :history, id]) != nil

  def start(state) do
    if Map.has_key?(state.catalog.rules, :progression) do
      initial = Map.new(state.restaurants, fn {id, _} -> {id, %{opened_at: state.now, activity_at: state.now}} end)

      Map.put_new(state, :progression, %{
        ventures: initial,
        distress: %{},
        history: %{},
        population: Population.new(),
        recognition: Recognition.new(state)
      })
    else
      state
    end
  end

  def stalls(state, id) do
    for {sid, %{restaurant: ^id}} <- Enum.sort(state.stalls), do: sid
  end

  def cuisine(stall, restaurant), do: Map.get(stall, :cuisine, restaurant.cuisine)

  def stall_menu(state, stall, restaurant) do
    cuisine = cuisine(stall, restaurant)

    restaurant.menu
    |> Map.merge(Map.get(stall, :menu_overrides, %{}))
    |> Map.filter(fn {id, price} ->
      recipe = state.catalog.recipes[id]
      not is_nil(price) and match?(%{cuisine: ^cuisine}, recipe) and Equipment.ready?(state, stall, recipe)
    end)
  end

  def cuisines(state, restaurant) do
    [restaurant.cuisine | Enum.map(stalls(state, restaurant.id), &cuisine(state.stalls[&1], restaurant))]
    |> Enum.uniq()
  end

  def decide(state, {kind, %{restaurant_id: id} = data}, %{actor: actor}) when kind in @commands do
    with true <- enabled?(state),
         %{owner_kind: owner_kind, owner: owner} = restaurant <- state.restaurants[id],
         true <- actor == {owner_kind, owner} do
      decide_owned(state, restaurant, kind, data)
    else
      _ -> {:error, :forbidden}
    end
  end

  def decide(_state, _command, _context), do: {:error, :invalid_payload}

  defp decide_owned(state, restaurant, :lease_location, %{stall_id: sid, cuisine: cuisine}) do
    id = restaurant.id
    owner = restaurant.owner
    leased = stalls(state, id)
    own_draft = if restaurant.owner_kind == :principal, do: state.management.drafts[owner]
    reserved = match?(%{stall_id: ^sid, expires_at: at} when at > state.now, own_draft)
    starter = Enum.find(Map.values(state.catalog.recipes), &(&1.cuisine == cuisine and &1.starter))
    quote = if reserved, do: own_draft, else: Management.lease_quote(state, sid)

    cond do
      distressed?(state, id) ->
        {:error, :business_distressed}

      length(leased) >= state.catalog.rules.progression.stall_limit ->
        {:error, :stall_limit}

      not is_map(quote) or Map.has_key?(state.stalls, sid) ->
        {:error, :slot_unavailable}

      own_draft && not reserved ->
        {:error, :slot_unavailable}

      is_nil(starter) ->
        {:error, :unknown_cuisine}

      Management.available_cash(state, id) < quote.setup_fee ->
        {:error, :insufficient_cash}

      true ->
        added = %{
          type: :location_added,
          restaurant_id: id,
          stall_id: sid,
          cuisine: cuisine,
          ready_at: state.now + state.catalog.rules.progression.setup_ms
        }

        lease = Management.lease_event(state, quote, id, restaurant.owner_kind, if(reserved, do: owner))

        {:ok, [added, lease | starter_menu(restaurant, starter)]}
    end
  end

  defp decide_owned(state, restaurant, :refit_location, %{stall_id: sid, cuisine: cuisine}) do
    id = restaurant.id
    cost = state.management.rules.setup_fee
    starter = Enum.find(Map.values(state.catalog.recipes), &(&1.cuisine == cuisine and &1.starter))

    with %{restaurant: ^id, mode: :closed} = stall <- state.stalls[sid],
         false <- distressed?(state, id),
         false <- Enum.any?(state.visits, fn {_, visit} -> visit.stall == sid end),
         false <- cuisine == cuisine(stall, restaurant),
         %{id: _} <- starter,
         true <- Management.available_cash(state, id) >= cost do
      refit = %{
        type: :location_refitted,
        restaurant_id: id,
        stall_id: sid,
        cuisine: cuisine,
        cost: cost,
        ready_at: state.now + state.catalog.rules.progression.setup_ms
      }

      {:ok, Management.end_stall_shift(state, sid, :stall_closed) ++ [refit | starter_menu(restaurant, starter)]}
    else
      _ -> {:error, :refit_unavailable}
    end
  end

  defp decide_owned(state, restaurant, :surrender_location, %{stall_id: sid} = options) do
    id = restaurant.id

    with %{restaurant: ^id, mode: :closed} <- state.stalls[sid],
         false <- Enum.any?(state.visits, fn {_, visit} -> visit.stall == sid end) do
      shifts = Management.end_stall_shift(state, sid, :stall_closed)
      settled = apply_events(state, shifts)
      charge = Management.lease_charge(settled, sid)
      in_distress = distressed?(state, id)

      if in_distress or charge.arrears == 0 do
        keep = not in_distress and (length(stalls(state, id)) == 1 or Map.get(options, :keep_equipment, false))
        equipment = if keep, do: [], else: Equipment.salvage_events(settled, sid)

        released = %{
          type: :location_released,
          restaurant_id: id,
          stall_id: sid,
          keep_equipment: keep,
          released_debt: if(in_distress, do: charge.amount + charge.arrears, else: 0)
        }

        charges = if in_distress, do: [], else: [charge]
        events = charges ++ equipment ++ [released]
        after_release = apply_events(settled, events)
        cancels = if stalls(after_release, id) == [], do: cancel_purchases(after_release, id), else: []
        {:ok, shifts ++ events ++ cancels ++ Management.vacancy_events(after_release)}
      else
        {:error, :unpaid_rent}
      end
    else
      _ -> {:error, :location_not_releasable}
    end
  end

  defp decide_owned(state, restaurant, :salvage_stock, %{batch_id: bid}) do
    with true <- distressed?(state, restaurant.id),
         %{reserved: 0, cost: cost, expires_at: expiry} = batch <- restaurant.batches[bid],
         true <- expiry > state.now do
      {:ok,
       [
         %{
           type: :stock_salvaged,
           restaurant_id: restaurant.id,
           batch_id: bid,
           cost: cost,
           amount: salvage_value(state, batch)
         }
       ]}
    else
      _ -> {:error, :salvage_unavailable}
    end
  end

  defp decide_owned(state, restaurant, :salvage_equipment, %{stall_id: sid, technique: method}) do
    id = restaurant.id

    with true <- distressed?(state, id),
         %{restaurant: ^id} = stall <- state.stalls[sid],
         basis when is_integer(basis) <- get_in(stall, [:equipment, method]) do
      {:ok, [Equipment.salvage_event(state, sid, method, basis)]}
    else
      _ -> {:error, :salvage_unavailable}
    end
  end

  defp decide_owned(state, restaurant, :pay_arrears, _) do
    id = restaurant.id
    charges = Enum.map(stalls(state, id), &Management.lease_charge(state, &1))
    debt = released_debt(state, id)
    total = debt + Enum.sum(Enum.map(charges, &(&1.amount + &1.arrears)))

    if distressed?(state, id) and restaurant.ledger.cash >= total do
      {charges, _} =
        Enum.map_reduce(stalls(state, id), state, fn sid, current ->
          charge = Management.lease_charge(current, sid)
          {charge, Evolver.evolve(current, charge)}
        end)

      {:ok, charges ++ [%{type: :distress_cleared, restaurant_id: id, released_debt: debt}]}
    else
      {:error, :arrears_unpayable}
    end
  end

  defp decide_owned(state, restaurant, :accept_bankruptcy, _) do
    if distressed?(state, restaurant.id),
      do: {:ok, terminate(state, restaurant.id)},
      else: {:error, :business_not_distressed}
  end

  defp decide_owned(_state, _restaurant, _kind, _payload), do: {:error, :invalid_payload}

  def released_debt(state, id), do: get_in(state, [:progression, :ventures, id, :released_debt]) || 0

  defp starter_menu(restaurant, starter) do
    if starter.id in restaurant.unlocked do
      []
    else
      [
        %{type: :recipe_unlocked, restaurant_id: restaurant.id, recipe_id: starter.id, cost: 0},
        %{type: :menu_price_set, restaurant_id: restaurant.id, recipe_id: starter.id, price: starter.suggested_price}
      ]
    end
  end

  def salvage_value(state, batch) do
    replacement = Money.ceil_div(batch.qty * Market.price(state.catalog, state.market, batch.product), 1_000)
    div(min(batch.cost, replacement), 2)
  end

  def inspect_after_charges(state) do
    if enabled?(state) do
      {events, _} =
        state.management.leases
        |> Enum.filter(fn {_, lease} -> lease.arrears > 0 end)
        |> Enum.map(fn {sid, _} -> state.stalls[sid].restaurant end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reject(&distressed?(state, &1))
        |> Enum.map_reduce(state, fn id, current ->
          deadline = state.now + state.catalog.rules.progression.distress_ms
          distress = %{type: :distress_started, restaurant_id: id, deadline: deadline}
          events = stop_venture(current, id, :distress_started) ++ [distress]
          {events, apply_events(current, events)}
        end)

      List.flatten(events)
    else
      []
    end
  end

  def boundaries(state) do
    if enabled?(state) do
      distressed =
        for {id, deadline} <- state.progression.distress,
            do: {deadline, id, {:bankruptcy_due, id}}

      dormancy =
        for {id, venture} <- state.progression.ventures,
            restaurant = state.restaurants[id],
            restaurant.owner_kind == :principal,
            not distressed?(state, id),
            locations = stalls(state, id),
            locations != [],
            Enum.all?(locations, &(state.stalls[&1].mode == :closed)),
            do: {venture.activity_at + state.catalog.rules.progression.dormancy_ms, id, {:dormancy_due, id}}

      distressed ++ dormancy
    else
      []
    end
  end

  def dormant(state, id) do
    # Refuse to discard accrued liabilities. A retry follows the next successful
    # settlement boundary if there is temporarily insufficient liquid cash.
    {events, current} =
      Enum.reduce(stalls(state, id), {[], state}, fn sid, {events, current} ->
        case decide_owned(current, current.restaurants[id], :surrender_location, %{stall_id: sid, keep_equipment: true}) do
          {:ok, release} -> {events ++ release, apply_events(current, release)}
          {:error, _} -> {events, current}
        end
      end)

    if stalls(current, id) == [], do: events, else: events ++ [activity_event(id, state.now)]
  end

  def retire_npc(state, id) do
    if distressed?(state, id) do
      []
    else
      stopped = stop_venture(state, id, :npc_retired)
      current = apply_events(state, stopped)

      {events, current} =
        Enum.reduce(stalls(current, id), {stopped, current}, fn sid, {events, current} ->
          charge = Management.lease_charge(current, sid)
          release = %{type: :location_released, restaurant_id: id, stall_id: sid, keep_equipment: true}
          {events ++ [charge, release], apply_events(current, [charge, release])}
        end)

      if Enum.any?(events, &match?(%{type: :operating_costs_charged, arrears: arrears} when arrears > 0, &1)),
        do: [],
        else: events ++ Management.vacancy_events(current)
    end
  end

  def terminate(state, id) do
    restaurant = state.restaurants[id]
    stopped = stop_venture(state, id, :bankruptcy)
    current = apply_events(state, stopped)
    locations = stalls(current, id)
    unpaid = released_debt(current, id) + Enum.sum(Enum.map(locations, &current.management.leases[&1].arrears))

    record =
      Map.merge(Map.take(restaurant, [:id, :owner_kind, :owner, :name]), %{
        cuisines: Map.get(current.progression.ventures[id], :cuisines, cuisines(current, restaurant)),
        opened_at: current.progression.ventures[id].opened_at,
        ended_at: state.now,
        peak_stalls: Map.get(current.progression.ventures[id], :peak_stalls, length(locations)),
        final_ledger: current.restaurants[id].ledger,
        unpaid: unpaid,
        milestones: Recognition.milestones(state, id),
        awards: Recognition.awards(state, id)
      })

    releases = Enum.map(locations, &%{type: :location_released, restaurant_id: id, stall_id: &1})
    events = stopped ++ releases ++ [%{type: :business_bankrupted, restaurant_id: id, record: record}]
    events ++ Management.vacancy_events(apply_events(state, events))
  end

  defp stop_venture(state, id, reason) do
    {steps, current} =
      Enum.map_reduce(stalls(state, id), state, fn sid, current ->
        stops = Management.end_stall_shift(current, sid, :safety_stop) ++ [%{type: :stall_closed, stall_id: sid}]
        closed = apply_events(current, stops)
        stops = stops ++ Settlement.cancel_location(closed, sid, reason)
        {stops, apply_events(current, stops)}
      end)

    List.flatten(steps) ++ cancel_purchases(current, id)
  end

  defp cancel_purchases(state, id) do
    for {request, %{restaurant_id: ^id}} <- Enum.sort(state.market.requests),
        do: %{type: :purchase_request_cancelled, request_id: request}
  end

  defp apply_events(state, events), do: Enum.reduce(events, state, &Evolver.evolve(&2, &1))

  def activity_event(id, at), do: %{type: :venture_activity_recorded, restaurant_id: id, at: at}

  def track_activity(state, id, now) do
    if enabled?(state) and state.progression.ventures[id],
      do: put_in(state.progression.ventures[id].activity_at, now),
      else: state
  end

  def track_lease(state, id) do
    if enabled?(state) do
      venture = Map.get(state.progression.ventures, id, %{opened_at: state.now})
      count = length(stalls(state, id))

      venture =
        venture
        |> Map.put(:activity_at, state.now)
        |> Map.put(:cuisines, Enum.uniq(Map.get(venture, :cuisines, []) ++ cuisines(state, state.restaurants[id])))
        |> Map.put(:peak_stalls, max(Map.get(venture, :peak_stalls, 0), count))

      put_in(state.progression.ventures[id], venture)
    else
      state
    end
  end

  def observe_interval(state, at) do
    if enabled?(state) and state.access == :open do
      Enum.reduce(state.stalls, state, fn {sid, stall}, current ->
        if stall.mode == :open and state.management.leases[sid].unattended,
          do: track_activity(current, stall.restaurant, at),
          else: current
      end)
    else
      state
    end
  end

  def evolve(state, %{type: :location_added} = e) do
    stall = %{
      id: e.stall_id,
      restaurant: e.restaurant_id,
      cuisine: e.cuisine,
      tier: state.layout[e.stall_id],
      mode: :closed,
      counter: nil
    }

    put_in(state.stalls[e.stall_id], Map.put(stall, :ready_at, e.ready_at))
  end

  def evolve(state, %{type: :location_refitted} = e) do
    state
    |> Equipment.store(e.stall_id)
    |> CounterPlay.clear_location(e.stall_id)
    |> update_in([:stalls, e.stall_id], fn stall ->
      Map.merge(stall, %{cuisine: e.cuisine, ready_at: e.ready_at, menu_overrides: %{}, equipment: %{}})
    end)
    |> Management.opening_requested(e.stall_id, false)
    |> update_in([:restaurants, e.restaurant_id, :ledger], fn ledger ->
      %{ledger | cash: ledger.cash - e.cost, capex: ledger.capex + e.cost}
    end)
    |> track_lease(e.restaurant_id)
  end

  def evolve(state, %{type: :location_released, stall_id: sid} = event) do
    state = if Map.get(event, :keep_equipment, false), do: Equipment.store(state, sid), else: state
    debt = Map.get(event, :released_debt, 0)

    state =
      if debt > 0 do
        id = event.restaurant_id
        put_in(state.progression.ventures[id][:released_debt], released_debt(state, id) + debt)
      else
        state
      end

    state
    |> CounterPlay.clear_location(sid)
    |> update_in([:stalls], &Map.delete(&1, sid))
    |> update_in([:management, :leases], &Map.delete(&1, sid))
  end

  def evolve(state, %{type: :distress_started} = e), do: put_in(state.progression.distress[e.restaurant_id], e.deadline)

  def evolve(state, %{type: :distress_cleared} = e) do
    id = e.restaurant_id
    debt = Map.get(e, :released_debt, 0)

    state
    |> update_in([:restaurants, id, :ledger], fn ledger ->
      %{ledger | cash: ledger.cash - debt, operating_cost: ledger.operating_cost + debt}
    end)
    |> update_in([:progression, :ventures, id], &Map.delete(&1, :released_debt))
    |> update_in([:progression, :distress], &Map.delete(&1, id))
  end

  def evolve(state, %{type: :venture_activity_recorded} = e), do: track_activity(state, e.restaurant_id, e.at)

  def evolve(state, %{type: :stock_salvaged} = e) do
    state
    |> update_in([:restaurants, e.restaurant_id, :batches], &Map.delete(&1, e.batch_id))
    |> update_in([:restaurants, e.restaurant_id, :ledger], fn ledger ->
      %{ledger | cash: ledger.cash + e.amount, raw: ledger.raw - e.cost, waste: ledger.waste + e.cost - e.amount}
    end)
  end

  def evolve(state, %{type: :business_bankrupted, restaurant_id: id, record: record}) do
    state
    |> update_in([:restaurants], &Map.delete(&1, id))
    |> update_in([:owners], &Map.delete(&1, {record.owner_kind, record.owner}))
    |> update_in([:npcs], fn npcs -> if record.owner_kind == :npc, do: Map.delete(npcs, record.owner), else: npcs end)
    |> update_in([:progression, :ventures], &Map.delete(&1, id))
    |> update_in([:progression, :distress], &Map.delete(&1, id))
    |> update_in([:progression, :population, :closing], &Map.delete(&1, id))
    |> put_in([:progression, :history, id], record)
    |> Management.remove_venture_policies(id)
  end
end
