defmodule FeudHall.Domain.PublicViewTest do
  use ExUnit.Case, async: true

  import FeudHall.Fixtures

  alias FeudHall.Domain.PublicView

  defp hall_state do
    {state, _} = stocked_world(arrivals: false, unlock: false, stock: %{})
    state
  end

  test "today carries totals only" do
    state =
      put_in(hall_state().demand.today, %{arrivals: 9, admitted: 5, left: %{no_food: 3, queue_full: 2}, trays_served: 4})

    assert PublicView.build(state).today == %{arrivals: 9, admitted: 5, left: 5}
  end
end
