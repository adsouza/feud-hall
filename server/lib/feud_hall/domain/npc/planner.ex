defmodule FeudHall.Domain.Npc.Planner do
  @moduledoc """
  A profile-driven NPC owner's planner. It sees exactly what a human owner
  sees: the public view (`FeudHall.Domain.PublicView`), its own restaurant, the
  catalog and its profile. It receives no hall state and returns ordinary owner
  commands in the decider's shapes; the authority submits them through the
  normal command workflow.

  Heuristics, in action order:

    1. open the stall when it is closed and the hall is not in scheduled cleaning;
    2. unlock the cheapest locked recipe of its cuisine when cash is at least
       four times the unlock cost (one per plan, priced on the next plan);
    3. price each unlocked recipe at `suggested_price * price_permille / 1000`,
       skipping lines already at that price;
    4. set the profile's substitution policy on each line with an approved
       substitute whose effective policy differs (unset means `:primary_only`);
    5. request each product the menu needs: expected use over `restock_days`,
       less usable stock on hand, capped by remaining storage room and the
       request quantity bound, with a price limit of 1.5x the published price.

  Expected use is the last day summary's admitted trays, shared evenly across
  the stalls in the view, times the menu's average per-item ingredient use.
  With no summary yet it assumes `@fallback_trays_per_day`.

  The planner draws no randomness today; the PRNG state is returned unchanged
  so later heuristics can draw without changing the interface. Iteration is
  sorted and arithmetic is integer only.
  """

  alias FeudHall.Domain.{Clock, Inventory}

  # Tuning literals not yet in content (move to the NPC profiles in a content pass).
  @unlock_cash_multiple 4
  @price_limit_permille 1_500
  @fallback_trays_per_day 10

  @max_qty 1_000_000
  @max_price_limit 1_000_000_000

  @spec plan(map(), map(), map(), map(), term()) :: {[tuple()], term()}
  def plan(view, own, profile, catalog, rng) do
    actions =
      open_stall(view, own) ++
        unlock_recipe(own, catalog) ++
        menu_prices(own, profile, catalog) ++
        substitution_policies(own, profile, catalog) ++
        purchases(view, own, profile, catalog)

    {actions, rng}
  end

  @doc """
  The first vacant slot of the profile's preferred tier by slot ID, else the
  first vacant slot of any tier; `nil` when the hall has no vacant slot.
  """
  @spec choose_slot(map(), %{String.t() => atom()}, map()) :: String.t() | nil
  def choose_slot(view, layout, profile) do
    taken = MapSet.new(view.stalls, & &1.stall_id)
    vacant = layout |> Enum.reject(fn {id, _} -> MapSet.member?(taken, id) end) |> Enum.sort()

    case Enum.find(vacant, fn {_id, tier} -> tier == profile.preferred_tier end) || List.first(vacant) do
      {id, _tier} -> id
      nil -> nil
    end
  end

  # -- opening ------------------------------------------------------------------

  defp open_stall(view, own) do
    case Enum.find(view.stalls, &(&1.restaurant_id == own.id)) do
      %{open?: false, stall_id: id} -> if Clock.cleaning?(view.now), do: [], else: [{:open_stall, %{stall_id: id}}]
      _ -> []
    end
  end

  # -- unlocking ----------------------------------------------------------------

  defp unlock_recipe(own, catalog) do
    candidate =
      catalog.recipes
      |> Map.values()
      |> Enum.filter(&(&1.cuisine == own.cuisine and &1.id not in own.unlocked))
      |> Enum.min_by(&{&1.unlock_cost, &1.id}, fn -> nil end)

    case candidate do
      %{unlock_cost: cost, id: id} when own.ledger.cash >= @unlock_cash_multiple * cost ->
        [{:unlock_recipe, %{restaurant_id: own.id, recipe_id: id}}]

      _ ->
        []
    end
  end

  # -- pricing ------------------------------------------------------------------

  defp menu_prices(own, profile, catalog) do
    for id <- Enum.sort(own.unlocked),
        price = max(1, div(catalog.recipes[id].suggested_price * profile.price_permille, 1000)),
        Map.get(own.menu, id) != price,
        do: {:set_menu_price, %{restaurant_id: own.id, recipe_id: id, price: price}}
  end

  # -- substitution policy --------------------------------------------------------

  defp substitution_policies(own, profile, catalog) do
    for id <- Enum.sort(own.unlocked),
        line <- catalog.recipes[id].lines,
        line.substitute != nil,
        effective_policy(own, id, line) != profile.policy,
        do:
          {:set_substitution_policy,
           %{restaurant_id: own.id, recipe_id: id, line_id: line.line_id, policy: profile.policy}}
  end

  # An unset line policy is the hall default, `:primary_only`.
  defp effective_policy(own, recipe_id, line), do: get_in(own.policies, [recipe_id, line.line_id]) || :primary_only

  # -- restocking -----------------------------------------------------------------

  defp purchases(view, own, profile, catalog) do
    recipes = for id <- Enum.sort(own.unlocked), do: catalog.recipes[id]

    if recipes == [] do
      []
    else
      trays = expected_trays_per_day(view)
      menu_size = length(recipes)
      uses = per_item_use(recipes, profile)
      room = catalog.rules.storage_capacity - Inventory.storage_used(own.batches, catalog)

      {requests, _room} =
        uses
        |> Enum.sort()
        |> Enum.reduce({[], room}, fn {product, use}, {acc, room} ->
          expected = div(trays * profile.restock_days * use + menu_size - 1, menu_size)
          want = expected - on_hand(own, product, view.now)
          qty = want |> min(@max_qty) |> min(fit(catalog, product, room))

          if qty > 0 do
            request = {:submit_purchase_request, request(own, view, product, qty)}
            {[request | acc], room - Inventory.storage_for(catalog, product, qty)}
          else
            {acc, room}
          end
        end)

      Enum.reverse(requests)
    end
  end

  defp request(own, view, product, qty) do
    price = view.market[product].price
    limit = price |> Kernel.*(@price_limit_permille) |> div(1000) |> max(1) |> min(@max_price_limit)
    %{restaurant_id: own.id, product: product, qty: qty, max_price_per_kunit: limit}
  end

  # Trays the stall can expect per day: the last summary's admitted trays shared
  # evenly across the hall's stalls, or a fixed fallback before any summary.
  defp expected_trays_per_day(%{demand: []}), do: @fallback_trays_per_day

  defp expected_trays_per_day(%{demand: summaries, stalls: stalls}) do
    %{admitted: admitted} = List.last(summaries)
    shares = max(length(stalls), 1)
    div(admitted + shares - 1, shares)
  end

  # Units of each product the whole menu would use for one tray of each item.
  defp per_item_use(recipes, profile) do
    for recipe <- recipes, line <- recipe.lines, reduce: %{} do
      uses ->
        {product, qty} = line_need(line, profile)
        Map.update(uses, product, qty, &(&1 + qty))
    end
  end

  defp line_need(%{substitute: nil} = line, _profile), do: {line.product, line.qty}

  defp line_need(%{substitute: sub} = line, %{policy: :prefer_substitute}),
    do: {sub.product, div(line.qty * sub.num + sub.den - 1, sub.den)}

  defp line_need(line, _profile), do: {line.product, line.qty}

  defp on_hand(own, product, now) do
    own.batches
    |> Map.values()
    |> Enum.filter(&(&1.product == product and now < &1.expires_at))
    |> Enum.reduce(0, &(&1.qty + &2))
  end

  # Largest quantity whose storage footprint fits in `room`. A product that
  # takes no storage (content allows 0) is not limited by room, as at clearing.
  defp fit(catalog, product, room) do
    case catalog.products[product].storage_per_kunit do
      0 -> @max_qty
      _per_kunit when room <= 0 -> 0
      per_kunit -> div(room * 1000, per_kunit)
    end
  end
end
