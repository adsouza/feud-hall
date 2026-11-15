defmodule FeudHall.Application.Projections.CounterService do
  @moduledoc """
  Ephemeral public animation markers for the latest completed handover at each stall.

  Fold alongside event evolution, while the retiring tray and visit still identify
  their stall. Publish markers only with a successfully committed candidate.
  Recovery starts a fresh baseline. Markers contain batch positions and event
  offsets, without customer or order identifiers.

  `fold/4` walks a batch on its own; `observe/5` and `retain/2` let a caller
  fold several projections in one evolving pass (see `CommandWorkflow`).
  """

  alias FeudHall.Domain.Hall

  def fold(events, hall, markers, position) do
    {hall, markers} =
      events
      |> Enum.with_index()
      |> Enum.reduce({hall, markers}, fn {event, offset}, {state, current} ->
        {Hall.evolve(state, event), observe(current, state, event, position, offset)}
      end)

    {hall, retain(hall, markers)}
  end

  @doc "Folds one event at `offset` in the batch at `position`; `state` is the hall just before it."
  def observe(markers, state, event, position, offset) do
    sid =
      case event do
        %{type: :tray_served, tray_id: id} -> state.trays[id].stall
        %{type: :dessert_served, order_id: id} -> state.visits[state.orders[id].visit].stall
        _ -> nil
      end

    if sid, do: Map.put(markers, sid, "#{position}:#{offset}"), else: markers
  end

  @doc "Keeps only markers for stalls that still exist in the evolved `hall`."
  def retain(hall, markers), do: if(hall, do: Map.take(markers, Map.keys(hall.stalls)), else: %{})
end
