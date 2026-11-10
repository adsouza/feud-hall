defmodule FeudHall.Domain.Choice do
  @moduledoc """
  Pure diner choice: which stall and dish a simulated diner picks, or why they
  leave.

  Candidates are the open stalls with queue room and, per stall, every main on
  its menu that quotes successfully for the diner's dietary requirement (the
  requirement is applied to the resolved portion inside the quote, before any
  preference scoring). A candidate must fit the budget and finish within the
  diner's patience. Each stall is represented by its best-scoring main, plus a
  capped variety bonus for the number of distinct eligible mains, scaled once by
  the stall tier's exposure. The stall (or leaving) is then drawn with
  `Random.weighted/2` over integer weights, so the result depends only on the
  state, the diner and the PRNG state.

  The diner map is
  `%{segment: segment_map, budget: integer, requirement: requirement,
  patience_hall_ms: integer, drink?: boolean}` where `segment` is a content
  segment (`rules.demand.segments`) and `requirement` is the shape returned by
  `Dietary.requirement/2`. Stalls and menu rows are visited in sorted order.

  A leave decided without any candidate draws nothing and returns the PRNG
  state unchanged.

  ## Leave reasons

  A diner who leaves records exactly one reason, the first that applies in
  this priority order:

    1. `:no_open_stall` - no stall is open and accepting new mains (closed,
       cleaning, or its queue is full);
    2. `:no_compatible_main` - open stalls offer mains, and every one of them
       is incompatible with the diner's dietary requirement over its resolved
       portion;
    3. `:nothing_available` - no main can be quoted at all: none is on a menu,
       none can be supplied from stock (a stock-out masks dietary
       compatibility, because the bill is resolved before it is checked), or
       none can finish before cleaning or within the service window;
    4. `:nothing_affordable` - quotable mains exist but none fits the budget;
    5. `:wait_too_long` - affordable mains exist but none finishes within the
       diner's patience;
    6. `:chose_to_leave` - eligible stalls existed and the weighted draw (or a
       zero total stall weight) chose leaving.

  This keeps the spec's leaving reasons in their order (no compatible main,
  nothing affordable, wait too long, chose to leave) and splits out the two
  supply-side causes that are not the diner's preference: no open stall comes
  first because without one no main is evaluated, and nothing available sits
  after dietary incompatibility because it describes what could be served,
  not what the diner would eat.
  """

  alias FeudHall.Domain.{Offers, Random}

  @type diner :: %{
          segment: map(),
          budget: integer(),
          requirement: map(),
          patience_hall_ms: integer(),
          drink?: boolean()
        }

  @type choice :: {:stall, String.t(), String.t(), String.t() | nil} | {:leave, atom()}

  @leave_reasons ~w(no_open_stall no_compatible_main nothing_available nothing_affordable wait_too_long
                    chose_to_leave)a

  @doc "Every reason `choose/3` can leave with, in priority order (see the moduledoc)."
  @spec leave_reasons() :: [atom()]
  def leave_reasons, do: @leave_reasons

  @spec choose(map(), diner(), Random.state()) :: {choice(), Random.state()}
  def choose(state, diner, rng) do
    case evaluate_all(state, diner) do
      {[], reason} -> {{:leave, reason}, rng}
      {stalls, _reason} -> draw(rng, stalls, diner.segment.leave_weight)
    end
  end

  @doc """
  The weighted stall picks `choose/3` draws from (excluding leaving), in stall
  ID order: `[{{:stall, stall_id, main_id, drink_id | nil}, weight}]`.
  """
  @spec stall_weights(map(), diner()) :: [{choice(), pos_integer()}]
  def stall_weights(state, diner), do: state |> evaluate_all(diner) |> elem(0)

  defp evaluate_all(state, diner) do
    open = open_stalls(state)
    evaluated = Enum.flat_map(open, &evaluate_stall(state, &1, diner))

    stalls =
      for(%{outcome: :candidate} = c <- evaluated, do: c)
      |> Enum.group_by(& &1.stall_id)
      |> Enum.sort()
      |> Enum.map(fn {_stall_id, candidates} -> stall_entry(state, diner, candidates) end)
      |> Enum.filter(fn {_choice, weight} -> weight > 0 end)

    {stalls, leave_reason(open, evaluated)}
  end

  defp draw(rng, stalls, leave_weight) do
    case Random.weighted(rng, stalls ++ [{:leave, leave_weight}]) do
      {:leave, rng} -> {{:leave, :chose_to_leave}, rng}
      {choice, rng} -> {choice, rng}
    end
  end

  defp open_stalls(state) do
    state.stalls
    |> Map.keys()
    |> Enum.sort()
    |> Enum.filter(&match?({:ok, _, _}, Offers.open_stall_for_main(state, &1)))
  end

  # One entry per (stall, main): a candidate with its score inputs, or the
  # reason it was not one.
  defp evaluate_stall(state, stall_id, diner) do
    {:ok, _stall, restaurant} = Offers.open_stall_for_main(state, stall_id)
    drink = drink_for(state, restaurant, diner)

    restaurant.menu
    |> Map.keys()
    |> Enum.sort()
    |> Enum.filter(&(state.catalog.recipes[&1] != nil and state.catalog.recipes[&1].kind == :main))
    |> Enum.map(&evaluate(state, stall_id, &1, drink, diner))
  end

  defp evaluate(state, stall_id, main_id, drink, diner) do
    visit = %{requirement: diner.requirement, carbs_reserved: 0, carbs_served: 0}

    limit = state.now + diner.patience_hall_ms
    fits? = fn {:ok, q} -> q.total <= diner.budget and q.earliest_completion <= limit end

    result =
      with drink when drink != nil <- drink,
           {:ok, _} = with_drink <- Offers.quote_tray(state, stall_id, main_id, drink, visit),
           true <- fits?.(with_drink) do
        {with_drink, drink}
      else
        _ -> {Offers.quote_tray(state, stall_id, main_id, nil, visit), nil}
      end

    case result do
      {{:ok, quote}, drink_id} ->
        %{
          outcome: :candidate,
          stall_id: stall_id,
          main_id: main_id,
          drink_id: drink_id,
          quote: quote,
          affordable: quote.total <= diner.budget,
          in_time: quote.earliest_completion <= limit,
          limit: limit
        }

      {{:error, reason}, _} ->
        if dietary_error?(reason), do: %{outcome: :incompatible}, else: %{outcome: :unavailable}
    end
  end

  defp dietary_error?(:carbohydrate_limit), do: true
  defp dietary_error?({:excluded_ingredient, _product, _flag}), do: true
  defp dietary_error?({:missing_metadata, _product}), do: true
  defp dietary_error?(_reason), do: false

  # The stall's drink is its first menu drink (by recipe ID) when the diner
  # wants one; whether that drink also quotes is decided per main.
  defp drink_for(_state, _restaurant, %{drink?: false}), do: nil

  defp drink_for(state, restaurant, %{drink?: true}) do
    restaurant.menu
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&(state.catalog.recipes[&1] != nil and state.catalog.recipes[&1].kind == :drink))
  end

  # {pick, weight} for a stall with at least one candidate. Only affordable,
  # in-time candidates compete; the best dish stands for the stall, so extra
  # rows of one main cannot add weight.
  defp stall_entry(state, diner, candidates) do
    rules = state.catalog.rules
    eligible = Enum.filter(candidates, &(&1.affordable and &1.in_time))

    case eligible do
      [] ->
        {nil, 0}

      _ ->
        {best_score, best} =
          eligible |> Enum.map(&{score(diner, &1), &1}) |> Enum.max_by(&elem(&1, 0))

        distinct = eligible |> Enum.map(& &1.main_id) |> Enum.uniq() |> length()
        variety = rules.demand.variety_weight * min(distinct - 1, rules.demand.variety_cap)
        exposure = Map.get(rules.exposure_permille, state.stalls[best.stall_id].tier, 0)
        restaurant = state.stalls[best.stall_id].restaurant
        cuisine = state.catalog.recipes[best.main_id].cuisine
        recognition = FeudHall.Domain.Hall.Recognition.multiplier(state, restaurant, cuisine)
        weight = div((best_score + variety) * exposure * recognition, 1_000_000)
        {{:stall, best.stall_id, best.main_id, best.drink_id}, weight}
    end
  end

  # price_weight * value + quality_weight * quality + wait_weight * slack +
  # preference, every term an integer; value and slack are in thousandths.
  defp score(%{segment: segment} = diner, c) do
    budget = max(diner.budget, 1)
    patience = max(diner.patience_hall_ms, 1)
    value = div((diner.budget - c.quote.total) * 1000, budget)
    slack = div((c.limit - c.quote.earliest_completion) * 1000, patience)
    quality = Enum.find(c.quote.components, &(&1.kind == :main)).quality
    preference = Map.get(segment.main_preference, c.main_id, 0)

    segment.price_weight * value + segment.quality_weight * quality + segment.wait_weight * slack + preference
  end

  # The priority order is documented in the moduledoc.
  defp leave_reason(open, evaluated) do
    candidates = for %{outcome: :candidate} = c <- evaluated, do: c

    cond do
      open == [] -> :no_open_stall
      evaluated != [] and Enum.all?(evaluated, &(&1.outcome == :incompatible)) -> :no_compatible_main
      candidates == [] -> :nothing_available
      not Enum.any?(candidates, & &1.affordable) -> :nothing_affordable
      not Enum.any?(candidates, &(&1.affordable and &1.in_time)) -> :wait_too_long
      true -> :chose_to_leave
    end
  end
end
