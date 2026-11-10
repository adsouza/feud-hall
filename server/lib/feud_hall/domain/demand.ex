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
    * `next_day_at` - the hall instant of the next midnight to close;
    * `hour_quotas_millis` - the current day's arrival quota per hall hour, in
      thousandths of an arrival (fixed at initialization for day 0 and
      recorded by each midnight's `day_closed` for the day it starts);
    * `acc_millis`, `acc_at` - the arrival accumulator's anchor: the
      milli-arrivals carried (not yet arrived) at `acc_at`, the start of the
      current day;
    * `arrival_seq` - simulated arrivals so far in the current day;
    * `next_arrival_at` - the hall instant of the next simulated arrival, or
      `nil` until the next midnight records new quotas.

  ## Arrival schedule

  Within hour `h` the accumulator grows linearly by `hour_quotas_millis[h]`
  over the hour, as integers: by the end of hall millisecond `d` of the hour
  (counted from 0) the hour has added `div(q * (d + 1), hour_ms)`. An arrival
  falls at the start of the millisecond during which the accumulator reaches
  the next multiple of 1000, so every arrival lies inside an hour with a
  positive quota: none at or during cleaning (quota 0 from 03:00), none
  deferred into the 05:00 reopening, and one due at 00:00 belongs to the new
  day and its quotas. The fractional remainder carries exactly across hours
  and days, so the schedule does not depend on how an advance is partitioned.

  An open stall counts as staffed until staff exist.
  """

  alias FeudHall.Domain.{Clock, Inventory, Market, Offers, Random}

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
    rules = get_in(catalog, [:rules, :demand])
    scale = (rules && rules.equivalent_floor_millis) || 0

    Map.merge(
      %{
        observed_ms: %{},
        supply_scale_millis: scale,
        today: blank_day(),
        summaries: [],
        next_day_at: Clock.day(),
        hour_quotas_millis: if(rules, do: hour_quotas(rules, scale), else: []),
        acc_millis: 0,
        acc_at: 0,
        arrival_seq: 0
      },
      recorded
    )
    |> schedule()
  end

  @doc """
  The day's arrival quota per hall hour in milli-arrivals: the day's
  `arrivals_per_equivalent * scale_millis` split by `hourly_weights` with
  integer largest remainders (ties to the earlier hour), so the hours sum
  exactly to the day.
  """
  def hour_quotas(rules, scale_millis) do
    total = rules.arrivals_per_equivalent * scale_millis
    weights = rules.hourly_weights
    weight_total = Enum.sum(weights)
    shares = Enum.map(weights, &{div(total * &1, weight_total), rem(total * &1, weight_total)})
    leftover = total - (shares |> Enum.map(&elem(&1, 0)) |> Enum.sum())

    bonus =
      shares
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_q, r}, h} -> {-r, h} end)
      |> Enum.take(leftover)
      |> MapSet.new(fn {_, h} -> h end)

    shares
    |> Enum.with_index()
    |> Enum.map(fn {{q, _r}, h} -> if MapSet.member?(bonus, h), do: q + 1, else: q end)
  end

  @doc """
  The hall instant of the next simulated arrival (see the moduledoc), or `nil`
  when the current day's quotas hold no further whole arrival.
  """
  def next_arrival_at(%{hour_quotas_millis: quotas, acc_millis: carried, acc_at: day_start, arrival_seq: seq}),
    do: crossing(quotas, 1000 * (seq + 1) - carried, 0, day_start)

  defp crossing([], _need, _h, _day_start), do: nil

  defp crossing([q | rest], need, h, day_start) when q == 0 or need > q,
    do: crossing(rest, need - q, h + 1, day_start)

  defp crossing([q | _], need, h, day_start),
    do: day_start + h * Clock.hour() + max(div(need * Clock.hour() + q - 1, q) - 1, 0)

  defp schedule(demand), do: Map.put(demand, :next_arrival_at, next_arrival_at(demand))

  @doc """
  Draws one simulated diner from the demand PRNG, in order: segment (by
  weight), budget, patience in available-service ms (converted to hall ms),
  dietary profile (over enabled profiles by `profile_mix`, in profile ID
  order), drink attachment and dessert appetite (`uniform(1000) < permille`).
  Returns `{%{segment, budget, patience_hall_ms, profile_id, drink?,
  dessert_appetite?}, rng}`.
  """
  def draw_diner(catalog, rng) do
    rules = catalog.rules.demand
    {segment, rng} = Random.weighted(rng, Enum.map(rules.segments, &{&1, &1.weight}))
    [budget_lo, budget_hi] = segment.budget
    {budget, rng} = Random.range(rng, budget_lo, budget_hi)
    [patience_lo, patience_hi] = segment.patience_service_ms
    {patience, rng} = Random.range(rng, patience_lo, patience_hi)

    profiles =
      for {id, w} <- Enum.sort(rules.profile_mix), catalog.profiles[id].enabled, do: {id, w}

    {profile_id, rng} = Random.weighted(rng, profiles)
    {drink, rng} = Random.uniform(rng, 1000)
    {dessert, rng} = Random.uniform(rng, 1000)

    {%{
       segment: segment,
       budget: budget,
       patience_hall_ms: Clock.service_duration(patience),
       profile_id: profile_id,
       drink?: drink < segment.drink_attach_permille,
       dessert_appetite?: dessert < segment.dessert_appetite_permille
     }, rng}
  end

  @doc """
  Applies a `diner_arrived` fact: takes the recorded PRNG continuation, moves
  to the next arrival, and counts an arrival that left without a visit (an
  admitted one is counted by its `visit_admitted`).
  """
  def arrive(demand, event) do
    demand = schedule(%{demand | rng: event.rng, arrival_seq: demand.arrival_seq + 1})

    case event.outcome do
      :admitted ->
        demand

      :left ->
        update_in(demand.today, fn today ->
          %{today | arrivals: today.arrivals + 1, left: Map.update(today.left, event.reason, 1, &(&1 + 1))}
        end)
    end
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

    scale = max(equivalents, rules.equivalent_floor_millis)

    %{
      type: :day_closed,
      day: day,
      equivalents_millis: equivalents,
      scale_millis: scale,
      hour_quotas_millis: hour_quotas(rules, scale),
      replenishment: Market.replenish(state.catalog, state.market, state.demand.supply_scale_millis),
      summary: Map.merge(%{day: day, menu_prices_median: menu_prices_median(state)}, state.demand.today)
    }
  end

  @doc """
  Applies a `day_closed` fact: starts the next day and keeps the summary. The
  accumulator re-anchors at this midnight, carrying the day's unarrived
  remainder, under the recorded quotas for the new day (events recorded
  before quotas existed fall back to the catalog at the recorded scale).
  """
  def close(demand, event, catalog) do
    quotas = Map.get_lazy(event, :hour_quotas_millis, fn -> hour_quotas(catalog.rules.demand, event.scale_millis) end)
    carried = demand.acc_millis + Enum.sum(demand.hour_quotas_millis) - 1000 * demand.arrival_seq

    schedule(%{
      demand
      | observed_ms: %{},
        supply_scale_millis: event.scale_millis,
        today: blank_day(),
        summaries: Enum.take(demand.summaries ++ [event.summary], -@kept_summaries),
        next_day_at: demand.next_day_at + Clock.day(),
        hour_quotas_millis: quotas,
        acc_millis: carried,
        acc_at: demand.next_day_at,
        arrival_seq: 0
    })
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
