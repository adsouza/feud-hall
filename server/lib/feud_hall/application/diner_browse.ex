defmodule FeudHall.Application.DinerBrowse do
  @moduledoc "Read-only dining options and private tasting history."

  alias FeudHall.Application.Replay
  alias FeudHall.Domain.{Dietary, Identity, Inventory, Money, Offers, PublicView, Substitution}

  @limit 12

  @doc "Available mains and their compatible drinks for one stall and dietary profile."
  def checkout_menu(state, stall_id, profile_id) when is_binary(stall_id) and is_binary(profile_id) do
    mains =
      with {:ok, requirement} <- Dietary.requirement(state.catalog, profile_id),
           {:ok, _stall, restaurant} <- Offers.open_stall_for_main(state, stall_id) do
        terms = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
        recipes = state.catalog.recipes
        menu = Enum.sort(Map.keys(restaurant.menu))
        drinks = Enum.filter(menu, &match?(%{kind: :drink}, recipes[&1]))

        for main <- menu,
            match?(%{kind: :main}, recipes[main]),
            match?({:ok, _}, Offers.quote_tray(state, stall_id, main, nil, terms)),
            into: %{} do
          available = Enum.filter(drinks, &match?({:ok, _}, Offers.quote_tray(state, stall_id, main, &1, terms)))
          {main, available}
        end
      else
        {:error, _} -> %{}
      end

    %{stall_id: stall_id, profile_id: profile_id, mains: mains}
  end

  def checkout_menu(_state, _stall_id, _profile_id), do: nil

  def compare(%{state: nil}, _device, _params), do: {:error, :hall_not_initialized}

  def compare(runtime, device, params) do
    state = runtime.state
    profile = Map.get(params, "profile_id", "unrestricted")
    sort = Map.get(params, "sort", "wait")
    include_drink = Map.get(params, "include_drink") == "1"
    new_to_me = Map.get(params, "new_to_me") == "1"
    stall_id = params["stall_id"]

    with true <- sort in ["wait", "price"],
         {:ok, budget} <- budget(params["budget"]),
         {:ok, requirement} <- Dietary.requirement(state.catalog, profile),
         {:ok, tasted} <- tasting(runtime, device) do
      terms = %{requirement: requirement, carbs_reserved: 0, carbs_served: 0}
      seen = MapSet.new(tasted)
      items = options(state, terms, include_drink, budget, new_to_me, seen, stall_id)
      options = items |> Enum.sort_by(&rank(&1, sort)) |> Enum.take(@limit) |> Enum.map(&encode/1)

      {:ok,
       %{at: state.now, options: options, tasted: tasted, matched: length(items), sold_out: sold_out(state, stall_id)}}
    else
      false -> {:error, :invalid_dining_filters}
      {:error, _} = error -> error
    end
  end

  defp budget(nil), do: {:ok, nil}

  defp budget(value) do
    case Money.parse(value) do
      {:ok, amount} when amount >= 0 -> {:ok, amount}
      _ -> {:error, :invalid_dining_filters}
    end
  end

  defp tasting(runtime, device) do
    principal = Identity.principal_for_device(Identity.get(runtime.control), device)

    if principal && function_exported?(runtime.store_mod, :guest_tasted_recipes, 4) do
      with {:ok, ids} <-
             runtime.store_mod.guest_tasted_recipes(
               runtime.store,
               Replay.hall_stream(runtime.state),
               principal,
               runtime.versions.hall
             ) do
        cuisines =
          ids
          |> Enum.flat_map(fn id ->
            case runtime.state.catalog.recipes[id] do
              %{cuisine: cuisine} -> [cuisine]
              nil -> []
            end
          end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, cuisines}
      end
    else
      {:ok, []}
    end
  end

  defp options(%{access: :open} = state, terms, include_drink, budget, new_to_me, seen, stall_id) do
    for stall <- PublicView.stalls(state),
        is_nil(stall_id) or stall.stall_id == stall_id,
        stall.open?,
        include <- [if(include_drink, do: drink(stall.menu, state.catalog.recipes), else: nil)],
        not include_drink or include != nil,
        {main, _} <- stall.menu,
        %{kind: :main, cuisine: cuisine} <- [state.catalog.recipes[main]],
        not new_to_me or not MapSet.member?(seen, cuisine),
        {:ok, quote} <- [Offers.quote_tray(state, stall.stall_id, main, include, terms)],
        is_nil(budget) or quote.total <= budget do
      %{
        stall_id: stall.stall_id,
        name: state.restaurants[stall.restaurant_id].name,
        cuisine: cuisine,
        main: main,
        drink: include,
        total: quote.total,
        completion: quote.earliest_completion
      }
    end
  end

  defp options(_state, _terms, _include_drink, _budget, _new_to_me, _seen, _stall_id), do: []

  defp sold_out(_state, nil), do: []

  defp sold_out(state, stall_id) do
    case Offers.open_stall(state, stall_id) do
      {:ok, _stall, restaurant} ->
        available = Inventory.availability(restaurant.batches, state.now)

        for id <- Enum.sort(Map.keys(restaurant.menu)),
            recipe = state.catalog.recipes[id],
            policies = Map.get(restaurant.policies, id, %{}),
            {:error, :unavailable} == Substitution.resolve(state.catalog, recipe, policies, available),
            do: id

      _ ->
        []
    end
  end

  defp drink(menu, recipes) do
    menu |> Map.keys() |> Enum.sort() |> Enum.find(&match?(%{kind: :drink}, recipes[&1]))
  end

  defp rank(row, "price"), do: {row.total, row.completion, row.stall_id, row.main}
  defp rank(row, "wait"), do: {row.completion, row.total, row.stall_id, row.main}

  defp encode(row), do: %{row | total: Money.to_canonical(row.total)}
end
