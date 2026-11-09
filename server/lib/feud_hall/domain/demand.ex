defmodule FeudHall.Domain.Demand do
  @moduledoc """
  Pure rules for the hall's demand side: which businesses operate, how much
  business-equivalent time each accumulated, and the midnight forecast.

  Demand state (`state.demand`) holds:

    * `rng` - the demand PRNG state (drawn from by arrivals, never here);
    * `observed_ms` - `%{restaurant_id => operating hall ms}` since the last
      midnight, fed only by the `operating` list recorded in `clock_advanced`;
    * `supply_scale_millis` - the scale fixed at the previous midnight, used
      to replenish the market at the next one (a one-day delay); a new hall
      starts at the content floor;
    * `today` - `%{arrivals, admitted, left: %{reason => count}, trays_served}`
      for the day in progress, fed by visit events (simulated arrivals add to
      the same counters);
    * `summaries` - the last `@kept_summaries` published day summaries, oldest
      first;
    * `next_day_at` - the hall instant of the next midnight to close.

  An open stall counts as staffed until staff exist.
  """

  alias FeudHall.Domain.{Clock, Inventory, Market, Offers}

  @kept_summaries 7

  # No dietary restriction: no excluded origins and no carbohydrate ceiling.
  @unrestricted %{profile_id: nil, excludes: [], carb_ceiling_mg: nil}

  @doc "The counters of a day with nothing in it yet."
  def blank_day, do: %{arrivals: 0, admitted: 0, left: %{}, trays_served: 0}

  @doc """
  Demand state for a new hall: `recorded` (the `hall_initialized` demand, which
  carries the PRNG state) over the defaults for the forecast fields.
  """
  def new(catalog, recorded) do
    Map.merge(
      %{
        observed_ms: %{},
        supply_scale_millis: get_in(catalog, [:rules, :demand, :equivalent_floor_millis]) || 0,
        today: blank_day(),
        summaries: [],
        next_day_at: Clock.day()
      },
      recorded
    )
  end

  @doc """
  Restaurants operating now: an open stall in an open hall with queue room, and
  at least one main that can be quoted for the unrestricted requirement against
  current availability. Sorted by restaurant ID.
  """
  def operating(state) do
    state.stalls
    |> Enum.sort()
    |> Enum.flat_map(fn {sid, stall} -> if operating_stall?(state, sid), do: [stall.restaurant], else: [] end)
    |> Enum.uniq()
  end

  defp operating_stall?(state, sid) do
    case Offers.open_stall_for_main(state, sid) do
      {:ok, _stall, restaurant} ->
        available = Inventory.availability(restaurant.batches, state.now)

        state.catalog.recipes
        |> Enum.any?(fn {id, recipe} ->
          recipe.kind == :main and
            match?(
              {:ok, _},
              Offers.quote_course(state, restaurant, id, :main, @unrestricted, 0, available)
            )
        end)

      {:error, _} ->
        false
    end
  end

  @doc "Adds `elapsed` hall ms to every restaurant in `operating`."
  def observe(demand, operating, elapsed) do
    observed = Enum.reduce(operating, demand.observed_ms, &Map.update(&2, &1, elapsed, fn ms -> ms + elapsed end))
    %{demand | observed_ms: observed}
  end

  @doc """
  Business equivalents in thousandths: each restaurant's observed time as a
  share of the day's accessible hours, capped at one equivalent, summed.
  """
  def equivalents_millis(rules, observed_ms) do
    observed_ms
    |> Map.values()
    |> Enum.map(&min(div(&1 * 1000, rules.operating_hours_ms), 1000))
    |> Enum.sum()
  end

  @doc """
  Median of a non-empty list of integers. An even count takes the floor of the
  mean of the two middle values.
  """
  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
  end

  @doc "Median current menu price per recipe across restaurants."
  def menu_prices_median(state) do
    state.restaurants
    |> Map.values()
    |> Enum.flat_map(&Map.to_list(&1.menu))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {recipe, prices} -> {recipe, median(prices)} end)
  end

  @doc """
  The `day_closed` fact for the midnight at `state.now`: the completed day's
  equivalents, the scale for the day now starting, the market replenishment
  (computed with the scale fixed at the previous midnight), and the summary.
  """
  def close_day(state) do
    rules = state.catalog.rules.demand
    day = Clock.day_of(state.now) - 1
    equivalents = equivalents_millis(rules, state.demand.observed_ms)

    %{
      type: :day_closed,
      day: day,
      equivalents_millis: equivalents,
      scale_millis: max(equivalents, rules.equivalent_floor_millis),
      replenishment: Market.replenish(state.catalog, state.market, state.demand.supply_scale_millis),
      summary: Map.merge(%{day: day, menu_prices_median: menu_prices_median(state)}, state.demand.today)
    }
  end

  @doc "Applies a `day_closed` fact: starts the next day and keeps the summary."
  def close(demand, event) do
    %{
      demand
      | observed_ms: %{},
        supply_scale_millis: event.scale_millis,
        today: blank_day(),
        summaries: Enum.take(demand.summaries ++ [event.summary], -@kept_summaries),
        next_day_at: demand.next_day_at + Clock.day()
    }
  end

  @doc "Counts a visit admission (an arrival that was admitted)."
  def count_admitted(demand),
    do: update_in(demand.today, &%{&1 | arrivals: &1.arrivals + 1, admitted: &1.admitted + 1})

  @doc "Counts a served tray."
  def count_tray_served(demand), do: update_in(demand.today, &%{&1 | trays_served: &1.trays_served + 1})

  @doc "Counts a finalized visit under its reason when none of its courses was served."
  def count_finalized(demand, %{reason: reason, components: components}) do
    if Enum.any?(components, &(&1.outcome == :served)),
      do: demand,
      else: update_in(demand.today.left, &Map.update(&1, reason, 1, fn n -> n + 1 end))
  end
end
