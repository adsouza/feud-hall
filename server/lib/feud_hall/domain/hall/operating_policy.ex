defmodule FeudHall.Domain.Hall.OperatingPolicy do
  @moduledoc "Hourly bounded policies. Every generated purchase and price uses the owner rules."
  alias FeudHall.Domain.{Clock, Inventory, Market, Money}
  alias FeudHall.Domain.Hall.{Decider, Evolver, Management, Progression}

  def starter_stock_offer(state, rid, stall_id \\ nil) do
    restaurant = state.restaurants[rid]
    stall = state.stalls[stall_id]

    cond do
      Progression.distressed?(state, rid) ->
        %{items: [], budget: 0}

      stall_id != nil and not match?(%{restaurant: ^rid}, stall) ->
        %{items: [], budget: 0}

      Progression.enabled?(state) and Progression.stalls(state, rid) == [] ->
        %{items: [], budget: 0}

      true ->
        cuisine = if stall, do: Progression.cuisine(stall, restaurant), else: restaurant.cuisine
        recipe = Enum.find(Map.values(state.catalog.recipes), &(&1.cuisine == cuisine and &1.starter))
        stock_for_recipe(state, restaurant, recipe)
    end
  end

  defp stock_for_recipe(state, restaurant, recipe) do
    rid = restaurant.id
    available = Inventory.availability(restaurant.batches, state.now)

    items =
      recipe.lines
      |> Enum.reduce(%{}, fn line, totals -> Map.update(totals, line.product, line.qty * 6, &(&1 + line.qty * 6)) end)
      |> Enum.sort()
      |> Enum.flat_map(fn {product, target} ->
        qty = min(target - Map.get(available, product, 0), Map.get(state.market.stock, product, 0))
        price = Market.price(state.catalog, state.market, product)

        if qty > 0 and not Map.has_key?(state.market.by_key, {rid, product}) do
          [%{product: product, qty: qty, max_price_per_kunit: price}]
        else
          []
        end
      end)

    total = Enum.reduce(items, 0, fn item, sum -> sum + Money.ceil_div(item.qty * item.max_price_per_kunit, 1000) end)
    %{items: items, budget: total}
  end

  def decide(state, {:request_starter_stock, %{restaurant_id: id, budget: budget} = payload}, ctx) do
    with %{owner_kind: kind, owner: owner} <- state.restaurants[id],
         true <- ctx.actor == {kind, owner},
         %{budget: total, items: [_ | _] = items} <- starter_stock_offer(state, id, payload[:stall_id]),
         true <- Money.non_negative?(budget) and total <= budget and total <= Management.available_cash(state, id) do
      events =
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} ->
          command = {:submit_purchase_request, Map.put(item, :restaurant_id, id)}
          {:ok, events} = Decider.decide(state, command, %{ctx | command_id: "#{ctx.command_id}:#{index}"})
          events
        end)

      {:ok, events}
    else
      _ -> {:error, :starter_stock_unavailable}
    end
  end

  def decide(
        state,
        {:set_restock_policy,
         %{restaurant_id: id, product: product, target: target, max_price_per_kunit: limit, daily_budget: budget}},
        %{actor: actor}
      ) do
    with %{owner_kind: kind, owner: owner} <- state.restaurants[id],
         true <- actor == {kind, owner},
         true <- is_binary(product) and Map.has_key?(state.catalog.products, product),
         true <- is_integer(target) and target in 0..1_000_000,
         true <- Money.non_negative?(limit) and limit <= 1_000_000_000 and Money.non_negative?(budget) do
      {:ok,
       [
         %{
           type: :restock_policy_set,
           restaurant_id: id,
           product: product,
           target: target,
           max_price_per_kunit: limit,
           daily_budget: budget
         }
       ]}
    else
      _ -> {:error, :invalid_restock_policy}
    end
  end

  def decide(
        state,
        {:set_pricing_policy,
         %{
           restaurant_id: id,
           recipe_id: recipe,
           min_price: low,
           max_price: high,
           markup_permille: markup,
           interval_hours: interval
         }},
        %{actor: actor}
      ) do
    with %{owner_kind: kind, owner: owner, unlocked: unlocked} <- state.restaurants[id],
         true <- actor == {kind, owner} and recipe in unlocked,
         true <- Money.menu_price?(low) and Money.menu_price?(high) and low <= high,
         true <- is_integer(markup) and markup in 0..10_000 and is_integer(interval) and interval in 0..24 do
      {:ok,
       [
         %{
           type: :pricing_policy_set,
           restaurant_id: id,
           recipe_id: recipe,
           min_price: low,
           max_price: high,
           markup_permille: markup,
           interval_hours: interval
         }
       ]}
    else
      _ -> {:error, :invalid_pricing_policy}
    end
  end

  def evolve(state, %{type: :restock_policy_set} = event) do
    policy = Map.take(event, [:target, :max_price_per_kunit, :daily_budget])
    update_in(state.management.restock, &Map.put(&1, {event.restaurant_id, event.product}, policy))
  end

  def evolve(state, %{type: :pricing_policy_set} = event) do
    policy = event |> Map.take([:min_price, :max_price, :markup_permille, :interval_hours]) |> Map.put(:last_at, nil)
    update_in(state.management.pricing, &Map.put(&1, {event.restaurant_id, event.recipe_id}, policy))
  end

  def evolve(state, %{type: :restock_budget_reserved} = event) do
    key = {event.restaurant_id, event.product}
    update_in(state.management.restock_budget, &Map.update(&1, key, event.amount, fn spent -> spent + event.amount end))
  end

  def evolve(state, %{type: :pricing_policy_applied} = event),
    do: put_in(state.management.pricing[{event.restaurant_id, event.recipe_id}].last_at, event.at)

  def hourly(state) do
    steps = Enum.sort(state.management.restock) |> Enum.map(&{:restock, &1})
    steps = steps ++ (Enum.sort(state.management.pricing) |> Enum.map(&{:price, &1}))

    {chunks, _} =
      Enum.map_reduce(steps, state, fn action, current ->
        events = plan(current, action)
        {events, Enum.reduce(events, current, &Evolver.evolve(&2, &1))}
      end)

    List.flatten(chunks)
  end

  defp plan(state, {:restock, {{rid, product} = key, policy}}) do
    restaurant = state.restaurants[rid]
    price = Market.price(state.catalog, state.market, product)
    remaining = policy.daily_budget - Map.get(state.management.restock_budget, key, 0)
    unit_limit = policy.max_price_per_kunit
    available = Inventory.availability(restaurant.batches, state.now)

    if automatic?(state, rid) and unit_limit > 0 and price <= unit_limit and remaining > 0 and
         not Map.has_key?(state.market.by_key, key) do
      budget = min(remaining, automation_cash(state, rid))
      qty = min(policy.target - Map.get(available, product, 0), div(budget * 1000, unit_limit))

      if qty > 0 do
        command =
          {:submit_purchase_request, %{restaurant_id: rid, product: product, qty: qty, max_price_per_kunit: unit_limit}}

        id = "policy:#{rid}:#{product}:#{state.now}"
        cost = Money.ceil_div(qty * unit_limit, 1000)

        issue(state, restaurant, command, id, %{
          type: :restock_budget_reserved,
          restaurant_id: rid,
          product: product,
          amount: cost
        })
      else
        []
      end
    else
      []
    end
  end

  defp plan(state, {:price, {{rid, recipe_id}, policy}}) do
    recipe = state.catalog.recipes[recipe_id]
    restaurant = state.restaurants[rid]

    if automatic?(state, rid) and policy.interval_hours > 0 and
         (is_nil(policy.last_at) or state.now - policy.last_at >= policy.interval_hours * Clock.hour()) and
         Map.has_key?(restaurant.menu, recipe_id) do
      cost =
        Enum.reduce(recipe.lines, 0, fn line, total ->
          total + Money.ceil_div(line.qty * Market.price(state.catalog, state.market, line.product), 1000)
        end)

      price = div(cost * (1000 + policy.markup_permille), 1000) |> max(policy.min_price) |> min(policy.max_price)
      command = {:set_menu_price, %{restaurant_id: rid, recipe_id: recipe_id, price: price}}
      marker = %{type: :pricing_policy_applied, restaurant_id: rid, recipe_id: recipe_id, at: state.now}
      issue(state, restaurant, command, "policy:#{rid}:#{recipe_id}:#{state.now}", marker)
    else
      []
    end
  end

  defp issue(state, restaurant, command, id, marker) do
    actor = {restaurant.owner_kind, restaurant.owner}

    case Decider.decide(state, command, %{actor: actor, command_id: id}) do
      {:ok, events} ->
        events =
          Enum.map(events, fn
            %{type: :purchase_requested} = event -> Map.put(event, :automated, true)
            event -> event
          end)

        [marker | events]

      {:error, _} ->
        []
    end
  end

  def cancel_open_requests(state, stall) do
    rid = state.stalls[stall].restaurant

    another_location? =
      Enum.any?(state.stalls, fn {sid, location} ->
        sid != stall and location.restaurant == rid and location.mode == :open and
          Management.allow_open(state, sid) == :ok
      end)

    if another_location? do
      []
    else
      for {id, %{restaurant_id: ^rid, automated: true}} <- Enum.sort(state.market.requests),
          do: %{type: :purchase_request_cancelled, request_id: id}
    end
  end

  defp automation_cash(state, rid), do: automation_cash(state, rid, Management.available_cash(state, rid))

  defp automatic?(state, rid), do: automation_cash(state, rid) > 0

  def automation_cash(state, rid, cash) do
    floor =
      if state.access == :open do
        Enum.find_value(state.stalls, fn
          {sid, %{restaurant: ^rid, mode: :open}} ->
            lease = state.management.leases[sid]
            if lease.unattended and Management.allow_open(state, sid) == :ok, do: lease.cash_floor

          _ ->
            nil
        end)
      end

    if is_integer(floor), do: max(0, cash - floor), else: 0
  end
end
