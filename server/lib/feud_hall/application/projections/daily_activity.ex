defmodule FeudHall.Application.Projections.DailyActivity do
  @moduledoc """
  Pure per-batch deltas for the asynchronous daily-activity projection.

  `deltas/1` counts the `:visit_admitted` and `:tray_accepted` hall events of one batch per
  `{day, restaurant_id}`, where the day is the game day of the batch's `hall_ms`. A batch without
  `hall_ms` has no hall activity. Keys with no counted event never appear.
  """

  alias FeudHall.Domain.Clock

  @type delta :: %{
          day: non_neg_integer(),
          restaurant_id: String.t(),
          visits_admitted: non_neg_integer(),
          trays_accepted: non_neg_integer()
        }

  @spec deltas(%{hall_ms: non_neg_integer() | nil, events: [map()]}) :: [delta()]
  def deltas(%{hall_ms: nil}), do: []

  def deltas(%{hall_ms: hall_ms, events: events}) do
    day = Clock.day_of(hall_ms)

    events
    |> Enum.reduce(%{}, fn
      %{type: :visit_admitted, restaurant_id: id}, acc -> bump(acc, id, :visits_admitted)
      %{type: :tray_accepted, restaurant_id: id}, acc -> bump(acc, id, :trays_accepted)
      _other, acc -> acc
    end)
    |> Enum.sort()
    |> Enum.map(fn {id, counts} ->
      Map.merge(%{day: day, restaurant_id: id, visits_admitted: 0, trays_accepted: 0}, counts)
    end)
  end

  defp bump(acc, id, field), do: Map.update(acc, id, %{field => 1}, &Map.update(&1, field, 1, fn n -> n + 1 end))
end
