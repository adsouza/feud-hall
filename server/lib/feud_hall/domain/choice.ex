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

  @spec choose(map(), diner(), Random.state()) :: {choice(), Random.state()}
  def choose(state, diner, rng) do
    segment = diner.segment
    evaluated = state |> open_stalls() |> Enum.flat_map(&evaluate_stall(state, &1, diner))

    scored =
      for %{outcome: :candidate} = c <- evaluated, do: c

    stalls =
      scored
      |> Enum.group_by(& &1.stall_id)
      |> Enum.sort()
      |> Enum.map(fn {_stall_id, candidates} -> stall_entry(state, diner, candidates) end)
      |> Enum.filter(fn {_choice, weight} -> weight > 0 end)

    case stalls do
      [] ->
        {{:leave, leave_reason(evaluated)}, rng}

      _ ->
        draw(rng, stalls, segment.leave_weight)
    end
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

    result =
      case drink && Offers.quote_tray(state, stall_id, main_id, drink, visit) do
        {:ok, _} = quoted -> {quoted, drink}
        _ -> {Offers.quote_tray(state, stall_id, main_id, nil, visit), nil}
      end

    case result do
      {{:ok, quote}, drink_id} ->
        limit = state.now + diner.patience_hall_ms

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
        {{:stall, best.stall_id, best.main_id, best.drink_id}, div((best_score + variety) * exposure, 1000)}
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

  defp leave_reason(evaluated) do
    candidates = for %{outcome: :candidate} = c <- evaluated, do: c

    cond do
      Enum.all?(evaluated, &(&1.outcome == :incompatible)) -> :no_compatible_main
      not Enum.any?(candidates, & &1.affordable) -> :nothing_affordable
      not Enum.any?(candidates, &(&1.affordable and &1.in_time)) -> :wait_too_long
      true -> :chose_to_leave
    end
  end
end
