defmodule FeudHall.Domain.Offers do
  @moduledoc """
  Pure quote calculations shared by read-side offers and write-side
  acceptance. A query that shows a tray or dessert quote and a command that
  accepts it call the same functions against the same state, so they agree at
  unchanged-state boundaries by construction; acceptance additionally compares
  the guest's confirmed terms with the recomputed quote.

  A quote resolves the full ingredient bill under the owner's substitution
  policies, applies dietary compatibility to that resolved bill before
  anything else can make the item attractive, and checks the 03:00 cutoff:
  expected completion must fall strictly before it and the bound deadline may
  not pass it.
  """

  alias FeudHall.Domain.{Clock, Dietary, Inventory, Kitchen, Money, Substitution}

  alias FeudHall.Domain.Hall.{Management, Progression}

  @doc """
  Quotes an initial main/optional-drink tray for a stall.

  `visit` supplies the pinned requirement and current carbohydrate
  commitments (`%{requirement:, carbs_reserved:, carbs_served:}`).
  """
  def quote_tray(state, stall_id, main_id, drink_id, visit) do
    with {:ok, stall, restaurant} <- open_stall_for_main(state, stall_id),
         available = Inventory.availability(restaurant.batches, state.now),
         committed = visit.carbs_reserved + visit.carbs_served,
         {:ok, main} <- quote_course(state, restaurant, main_id, :main, visit.requirement, committed, available),
         available = Substitution.subtract(available, Substitution.demand(main.lines)),
         committed = committed + (main.carbs_mg || 0),
         {:ok, drink} <- maybe_drink(state, restaurant, drink_id, visit.requirement, committed, available),
         components = [main, drink] |> Enum.reject(&is_nil/1) |> Enum.map(&Management.adapt_course(state, stall_id, &1)),
         {:ok, timing} <- timing(state, stall.id, components) do
      {:ok,
       Map.merge(timing, %{
         content_hash: state.content_hash,
         requirement: visit.requirement,
         stall_id: stall.id,
         restaurant_id: restaurant.id,
         components: components,
         total: components |> Enum.map(& &1.price) |> Enum.sum()
       })}
    end
  end

  @doc "Quotes the optional same-stall dessert for a visit after main service."
  def quote_dessert(state, visit) do
    with {:ok, stall, restaurant} <- open_stall(state, visit.stall),
         {:ok, dessert_id} <- dessert_recipe(state, restaurant),
         available = Inventory.availability(restaurant.batches, state.now),
         committed = visit.carbs_reserved + visit.carbs_served,
         {:ok, dessert} <-
           quote_course(state, restaurant, dessert_id, :dessert, visit.requirement, committed, available),
         dessert = Management.adapt_course(state, stall.id, dessert),
         {:ok, timing} <- timing(state, stall.id, [dessert]) do
      {:ok,
       Map.merge(timing, %{
         content_hash: state.content_hash,
         requirement: visit.requirement,
         stall_id: stall.id,
         restaurant_id: restaurant.id,
         visit_id: Map.get(visit, :id),
         components: [dessert],
         total: dessert.price
       })}
    end
  end

  @doc """
  Public terms a guest confirms: stall and visit scope, pinned dietary
  requirement, content and recipe identity, price, resolved ingredients, and
  the maximum service deadline.
  """
  def terms(quote) do
    quote
    |> Map.take([:content_hash, :requirement, :stall_id, :restaurant_id, :visit_id, :deadline])
    |> Map.put(
      :components,
      Enum.map(quote.components, fn component ->
        Map.take(component, [:kind, :recipe_id, :recipe_version, :price, :variant, :lines, :carbs_mg])
      end)
    )
  end

  @doc """
  Compares confirmed guest terms with a fresh quote. Item terms must match
  exactly; the confirmed deadline may not exceed the server's current offer
  and must still allow the work to finish. Returns the deadline to bind.
  """
  def check_confirmation(quote, confirmed) do
    current = terms(quote)

    cond do
      not is_map(confirmed) -> {:error, :confirmation_required}
      Map.delete(confirmed, :deadline) != Map.delete(current, :deadline) -> {:error, :stale_terms}
      not is_integer(Map.get(confirmed, :deadline)) -> {:error, :stale_terms}
      confirmed.deadline > current.deadline -> {:error, :stale_terms}
      confirmed.deadline < quote.earliest_completion -> {:error, :stale_terms}
      true -> {:ok, confirmed.deadline}
    end
  end

  @doc "Shared stall eligibility for new customer orders (main trays and desserts)."
  def open_stall(state, stall_id) do
    case state.stalls[stall_id] do
      nil ->
        {:error, :unknown_stall}

      _ when state.access != :open ->
        {:error, :hall_cleaning}

      %{mode: :open} = stall ->
        with :ok <- Management.allow_open(state, stall_id) do
          business = state.restaurants[stall.restaurant]
          menu = Progression.stall_menu(state, stall, business)
          {:ok, stall, %{business | cuisine: Progression.cuisine(stall, business), menu: menu}}
        end

      _ ->
        {:error, :stall_not_accepting_orders}
    end
  end

  @doc """
  Eligibility for a new main tray: `open_stall/2` plus the content queue
  limit. A diner whose main was served can still take a dessert at a full
  queue, so the limit gates only new mains.
  """
  def open_stall_for_main(state, stall_id) do
    with {:ok, _stall, _restaurant} = open <- open_stall(state, stall_id) do
      if Kitchen.accepting?(state, stall_id), do: open, else: {:error, :queue_full}
    end
  end

  @doc """
  Quotes one course: unlocked, offered, correct kind, compatible with the
  visit's requirement over the resolved bill, and reservable.
  """
  def quote_course(state, restaurant, recipe_id, kind, requirement, committed, available) do
    catalog = state.catalog
    recipe = catalog.recipes[recipe_id]
    policies = Map.get(restaurant.policies, recipe_id, %{})

    with :ok <- check(recipe != nil, :unknown_recipe),
         :ok <- check(recipe.kind == kind, :wrong_course_kind),
         :ok <- check(recipe.cuisine == restaurant.cuisine, :not_on_menu),
         :ok <- check(recipe_id in restaurant.unlocked, :recipe_locked),
         {:ok, price} <- menu_price(restaurant, recipe_id),
         {:ok, resolved} <- Substitution.resolve(catalog, recipe, policies, available),
         {:ok, carbs} <- Dietary.check(catalog, requirement, resolved.lines, committed) do
      {:ok,
       %{
         kind: kind,
         recipe_id: recipe_id,
         recipe_version: recipe.version,
         price: price,
         lines: resolved.lines,
         variant: Enum.map(resolved.lines, & &1.product),
         penalty: resolved.penalty,
         quality: Substitution.quality(catalog, resolved.penalty),
         carbs_mg: carbs,
         prep_ms: recipe.prep_ms,
         finish_ms: recipe.finish_ms
       }}
    end
  end

  defp maybe_drink(_state, _restaurant, nil, _req, _committed, _available), do: {:ok, nil}

  defp maybe_drink(state, restaurant, drink_id, req, committed, available),
    do: quote_course(state, restaurant, drink_id, :drink, req, committed, available)

  defp dessert_recipe(state, restaurant) do
    state.catalog.recipes
    |> Map.values()
    |> Enum.find(&(&1.kind == :dessert and &1.cuisine == restaurant.cuisine))
    |> case do
      nil -> {:error, :no_dessert}
      recipe -> {:ok, recipe.id}
    end
  end

  defp menu_price(restaurant, recipe_id) do
    case Map.fetch(restaurant.menu, recipe_id) do
      {:ok, price} -> if Money.menu_price?(price), do: {:ok, price}, else: {:error, :invalid_price}
      :error -> {:error, :not_on_menu}
    end
  end

  @doc "Start intervals [from, to) during which a stocked main meets both service deadlines."
  def main_start_ranges(state, stall_id, course, to, busy?) do
    course = Management.adapt_course(state, stall_id, course)
    cutoff = Clock.service_cutoff(state.now)
    window = state.catalog.rules.service_window_ms

    if busy? do
      ranges(state, stall_id, course, state.now, min(to, cutoff), cutoff, window, [])
    else
      duration = course.prep_ms + course.finish_ms + state.catalog.rules.handover_ms
      last = min(to, cutoff - duration)
      if duration <= window and state.now < last, do: [{state.now, last}], else: []
    end
  end

  defp ranges(_state, _sid, _course, from, to, _cutoff, _window, acc) when from >= to, do: Enum.reverse(acc)

  defp ranges(state, sid, course, from, to, cutoff, window, acc) do
    {completion, rate, stable} = Kitchen.completion_forecast(state, sid, course, from)
    length = if stable == :infinity, do: to - from, else: min(to - from, stable + 1)

    # On this segment completion either stays fixed or rises one-for-one.
    # The service window moves with the order while the cleaning cutoff is fixed.
    {first, last} =
      case rate do
        0 when completion < cutoff -> {max(from, completion - window), from + length}
        1 when completion - from <= window -> {from, min(from + length, from + cutoff - completion)}
        _ -> {from, from}
      end

    acc = if first < last, do: [{first, last} | acc], else: acc
    ranges(state, sid, course, from + length, to, cutoff, window, acc)
  end

  # The expected completion comes from the stall's kitchen queue, so quotes,
  # acceptance and diner choice all see the same wait.
  defp timing(state, stall_id, components) do
    rules = state.catalog.rules
    %{earliest_completion: earliest} = Kitchen.estimate(state, stall_id, components, state.now)
    cutoff = Clock.service_cutoff(state.now)
    deadline = min(state.now + rules.service_window_ms, cutoff)

    cond do
      earliest >= cutoff -> {:error, :cannot_finish_before_cleaning}
      earliest > deadline -> {:error, :cannot_finish_before_deadline}
      true -> {:ok, %{deadline: deadline, earliest_completion: earliest}}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
