defmodule FeudHall.Domain.Hall.Recognition do
  @moduledoc "Bounded simulated-service reputation, periodic recognition, and optional venture milestones."

  alias FeudHall.Domain.Clock
  alias FeudHall.Domain.Hall.Progression

  @recent_limit 64
  @neutral 7_500

  def new(state) do
    interval = interval(state)
    next = (div(state.now, interval) + 1) * interval
    %{next_review: next, window: %{}, value: %{}, recent: %{}, service: %{}, awards: %{}, active: %{}, milestones: %{}}
  end

  def boundaries(%{progression: %{recognition: %{next_review: at}}}), do: [{at, "awards", {:award_review}}]
  def boundaries(_state), do: []

  def observe(%{progression: %{recognition: _}} = state, %{source: :simulated} = visit, event) do
    id = visit.restaurant
    cuisine = Progression.cuisine(state.stalls[visit.stall], state.restaurants[id])
    served = Enum.find(event.components, &(&1.kind == :main and &1.outcome == :served))

    state =
      if event.competitive do
        update_in(state.progression.recognition.recent, fn recent ->
          Map.update(recent, id, [event.score], &Enum.take([event.score | &1], @recent_limit))
        end)
      else
        state
      end

    if served && event.competitive do
      main = state.orders[Map.get(served, :order_id)]
      on_time = on_time(main)
      value = value_score(state, main, event.score)

      state
      |> update_in([:progression, :recognition, :window], fn window ->
        window
        |> tally({id, nil}, event.score)
        |> tally({id, cuisine}, event.score)
      end)
      |> update_in([:progression, :recognition, :value], fn totals ->
        if value, do: tally(totals, id, value), else: totals
      end)
      |> update_in([:progression, :recognition, :service], fn service ->
        service
        |> tally({id, nil}, event.score)
        |> tally({id, cuisine}, event.score)
        |> tally({id, :timeliness}, on_time)
        |> tally({id, {:stall, visit.stall}}, event.score)
      end)
    else
      state
    end
  end

  def observe(state, _visit, _event), do: state

  defp on_time(%{served_at: served, estimated_completion: expected}) when is_integer(expected),
    do: if(served <= expected, do: 1_000, else: 0)

  defp on_time(_), do: 0

  defp value_score(state, %{price: price, recipe_id: id}, score) do
    baseline = state.catalog.recipes[id].suggested_price
    min(10_000, div(score * baseline, max(price, 1)))
  end

  defp value_score(_state, _main, _score), do: nil

  defp tally(counts, key, score),
    do: Map.update(counts, key, {1, score}, fn {count, sum} -> {count + 1, sum + score} end)

  def reputation(state, id) do
    recent = get_in(state, [:progression, :recognition, :recent, id]) || []
    div(@neutral * 8 + Enum.sum(recent), 8 + length(recent))
  end

  def multiplier(%{progression: %{recognition: recognition}} = state, id, cuisine) do
    active = Map.get(recognition.active, id, [])

    bonus =
      if Enum.any?(active, &(&1.cuisine in [nil, cuisine])),
        do: state.catalog.rules.progression.award_bonus,
        else: 0

    # Recent outcomes change the preference weight by at most five percent.
    1_000 + max(-50, min(50, div(reputation(state, id) - @neutral, 50))) + bonus
  end

  def multiplier(_state, _id, _cuisine), do: 1_000

  def review(state) do
    tuning = state.catalog.rules.progression
    book = state.progression.recognition

    awarded =
      for {{id, cuisine}, {visits, score}} <- Enum.sort(book.window),
          Map.has_key?(state.restaurants, id),
          visits >= tuning.award_visits,
          score >= visits * tuning.award_score do
        %{
          restaurant_id: id,
          cuisine: cuisine,
          distinction: if(cuisine, do: "cuisine_distinction", else: "service_excellence"),
          visits: visits,
          score: div(score, visits),
          expires_at: book.next_review + interval(state)
        }
      end

    value =
      for {id, {visits, score}} <- Enum.sort(book.value),
          Map.has_key?(state.restaurants, id),
          visits >= tuning.award_visits,
          score >= visits * tuning.award_score do
        %{
          restaurant_id: id,
          cuisine: nil,
          distinction: "outstanding_value",
          visits: visits,
          score: div(score, visits),
          expires_at: book.next_review + interval(state)
        }
      end

    %{
      type: :award_reviewed,
      at: book.next_review,
      next_review: book.next_review + interval(state),
      awarded: awarded ++ value
    }
  end

  defp interval(state), do: state.catalog.rules.progression.award_days * Clock.day()

  def daily_milestones(%{progression: _} = state, reports) do
    tuning = state.catalog.rules.progression

    Enum.flat_map(reports, fn %{restaurant_id: id, delta: delta, at: at} ->
      costs = delta.cost_of_sales + delta.waste + delta.operating_cost
      full_period = at - state.progression.ventures[id].opened_at >= Clock.day()

      [
        {"first_profitable_day", full_period and delta.revenue > costs},
        {"waste_conscious",
         full_period and delta.revenue >= tuning.waste_min_sales and
           delta.waste * 1_000 <= delta.revenue * tuning.waste_share}
      ]
      |> earned(state, id)
    end)
  end

  def daily_milestones(_state, _reports), do: []

  def service_milestones(%{progression: %{recognition: recognition}} = state) do
    tuning = state.catalog.rules.progression

    Enum.flat_map(Enum.sort(Map.keys(state.restaurants)), fn id ->
      {count, on_time} = Map.get(recognition.service, {id, :timeliness}, {0, 0})

      cuisines =
        for {{^id, cuisine}, _} <- recognition.service, is_binary(cuisine), do: cuisine

      locations = Enum.count(Progression.stalls(state, id), &Map.has_key?(recognition.service, {id, {:stall, &1}}))

      specialist =
        Enum.any?(cuisines, fn cuisine ->
          {visits, score} = recognition.service[{id, cuisine}]
          visits >= tuning.award_visits and score >= visits * tuning.award_score
        end)

      [
        {"reliable_kitchen", count >= tuning.reliable_meals and on_time >= count * tuning.reliable_rate},
        {"cuisine_specialist", specialist},
        {"second_counter", locations >= 2},
        {"across_the_menu", length(cuisines) >= 2}
      ]
      |> earned(state, id)
    end)
  end

  def service_milestones(_state), do: []

  def milestones(state, id), do: get_in(state, [:progression, :recognition, :milestones, id]) || []
  def awards(state, id), do: get_in(state, [:progression, :recognition, :awards, id]) || []
  def active_awards(state, id), do: get_in(state, [:progression, :recognition, :active, id]) || []

  defp earned(conditions, state, id) do
    existing = milestones(state, id)

    for {milestone, true} <- conditions,
        not Enum.any?(existing, &(&1.milestone == milestone)),
        do: %{type: :milestone_earned, restaurant_id: id, milestone: milestone, at: state.now}
  end

  def evolve(state, %{type: :award_reviewed} = event) do
    active = Enum.group_by(event.awarded, & &1.restaurant_id)
    book = state.progression.recognition
    awards = Map.merge(book.awards, active, fn _, prior, next -> next ++ prior end)

    put_in(state.progression.recognition, %{
      book
      | window: %{},
        value: %{},
        active: active,
        awards: awards,
        next_review: event.next_review
    })
  end

  def evolve(state, %{type: :milestone_earned} = event) do
    earned = Map.take(event, [:milestone, :at])

    update_in(
      state.progression.recognition.milestones,
      &Map.update(&1, event.restaurant_id, [earned], fn entries -> [earned | entries] end)
    )
  end
end
