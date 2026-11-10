defmodule FeudHall.Application.Projections.DailyActivity do
  @moduledoc """
  Pure per-batch deltas for the asynchronous daily-activity projection.

  Count visits and trays at their recorded hall time. A clock batch can span
  midnight. Start at the preceding committed clock, then apply its clock
  markers in event order. A command batch with no markers uses its own time.
  """

  alias FeudHall.Domain.Clock

  @type delta :: %{
          day: non_neg_integer(),
          restaurant_id: String.t(),
          visits_admitted: non_neg_integer(),
          trays_accepted: non_neg_integer()
        }

  @spec deltas(map()) :: [delta()]
  def deltas(%{hall_ms: nil}), do: []

  def deltas(%{hall_ms: hall_ms, events: events} = batch) do
    initial =
      if Enum.any?(events, &(&1.type == :clock_advanced)),
        do: Map.get(batch, :start_hall_ms) || 0,
        else: hall_ms

    {_time, counts} =
      Enum.reduce(events, {initial, %{}}, fn
        %{type: :clock_advanced, to: to}, {_time, counts} ->
          {to, counts}

        %{type: :visit_admitted, restaurant_id: id}, {time, counts} ->
          {time, bump(counts, {Clock.day_of(time), id}, :visits_admitted)}

        %{type: :tray_accepted, restaurant_id: id}, {time, counts} ->
          {time, bump(counts, {Clock.day_of(time), id}, :trays_accepted)}

        _other, acc ->
          acc
      end)

    counts
    |> Enum.sort()
    |> Enum.map(fn {{day, id}, counts} ->
      Map.merge(%{day: day, restaurant_id: id, visits_admitted: 0, trays_accepted: 0}, counts)
    end)
  end

  defp bump(counts, key, field),
    do: Map.update(counts, key, %{field => 1}, &Map.update(&1, field, 1, fn n -> n + 1 end))
end
