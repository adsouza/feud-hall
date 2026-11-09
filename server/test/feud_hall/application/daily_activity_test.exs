defmodule FeudHall.Application.DailyActivityTest do
  use ExUnit.Case, async: true

  alias FeudHall.Application.Projections.DailyActivity
  alias FeudHall.Domain.Clock

  @day Clock.day_of(3 * 24 * 3_600_000 * 24)

  defp batch(hall_ms, events), do: %{position: 1, command_id: "c", hall_ms: hall_ms, events: events, control_events: []}

  test "a batch with two admissions in one restaurant yields one delta with both counted" do
    events = [
      %{type: :visit_admitted, restaurant_id: "r1"},
      %{type: :tray_accepted, restaurant_id: "r1"},
      %{type: :visit_admitted, restaurant_id: "r1"},
      %{type: :tray_accepted, restaurant_id: "r1"},
      %{type: :stock_purchased, restaurant_id: "r1"}
    ]

    hall_ms = 3 * 24 * 3_600_000 * 24

    assert [%{day: @day, restaurant_id: "r1", visits_admitted: 2, trays_accepted: 2}] =
             DailyActivity.deltas(batch(hall_ms, events))
  end

  test "restaurants aggregate separately and uncounted keys never appear" do
    events = [
      %{type: :visit_admitted, restaurant_id: "r2"},
      %{type: :tray_accepted, restaurant_id: "r1"},
      %{type: :restaurant_created, restaurant_id: "r3"}
    ]

    assert [
             %{restaurant_id: "r1", visits_admitted: 0, trays_accepted: 1},
             %{restaurant_id: "r2", visits_admitted: 1, trays_accepted: 0}
           ] = DailyActivity.deltas(batch(0, events))
  end

  test "a batch without hall time, or without counted events, has no deltas" do
    assert DailyActivity.deltas(batch(nil, [%{type: :visit_admitted, restaurant_id: "r1"}])) == []
    assert DailyActivity.deltas(batch(5, [])) == []
  end
end
