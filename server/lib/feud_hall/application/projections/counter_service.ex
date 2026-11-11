defmodule FeudHall.Application.Projections.CounterService do
  @moduledoc """
  Ephemeral public animation markers for the latest completed handover at each stall.

  Fold alongside event evolution, while the retiring tray and visit still identify
  their stall. Publish markers only with a successfully committed candidate.
  Recovery starts a fresh baseline. Markers contain batch positions and event
  offsets, without customer or order identifiers.
  """

  alias FeudHall.Domain.Hall

  def fold(events, hall, markers, position) do
    {hall, markers} =
      events
      |> Enum.with_index()
      |> Enum.reduce({hall, markers}, fn {event, offset}, {state, current} ->
        sid =
          case event do
            %{type: :tray_served, tray_id: id} -> state.trays[id].stall
            %{type: :dessert_served, order_id: id} -> state.visits[state.orders[id].visit].stall
            _ -> nil
          end

        current = if sid, do: Map.put(current, sid, "#{position}:#{offset}"), else: current
        {Hall.evolve(state, event), current}
      end)

    {hall, if(hall, do: Map.take(markers, Map.keys(hall.stalls)), else: %{})}
  end
end
