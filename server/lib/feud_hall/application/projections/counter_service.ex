defmodule FeudHall.Application.Projections.CounterService do
  @moduledoc """
  Ephemeral public animation markers for the latest completed handover at each stall.

  Fold alongside event evolution, while the retiring tray and visit still identify
  their stall. Publish markers only with a successfully committed candidate.
  Recovery starts a fresh baseline. Only the marker ID goes to the public view.
  The diner can see their own pickup until the next handover starts.

  `observe/5` and `retain/2` fold it in the one evolving pass that
  `CommandWorkflow` makes over a batch.
  """

  alias FeudHall.Domain.Clock

  @pickup_window Clock.service_duration(30_000)

  @doc "Folds one event at `offset` in the batch at `position`; `state` is the hall just before it."
  def observe(markers, state, event, position, offset) do
    case event do
      %{type: :tray_served, tray_id: id} ->
        served(markers, state.visits[state.trays[id].visit], state.now, position, offset)

      %{type: :dessert_served, order_id: id} ->
        served(markers, state.visits[state.orders[id].visit], state.now, position, offset)

      %{type: type, stall_id: sid} when type in [:handover_started, :stall_closed] ->
        case markers[sid] do
          %{principal: principal} when not is_nil(principal) -> put_in(markers[sid].principal, nil)
          _ -> markers
        end

      _ ->
        markers
    end
  end

  defp served(markers, visit, now, position, offset) do
    principal = if visit.source == :guest, do: visit.principal
    Map.put(markers, visit.stall, %{id: "#{position}:#{offset}", principal: principal, at: now})
  end

  @doc "Current counter pickups for the authenticated diner."
  def pickups(markers, %{access: :open} = hall, principal) when is_binary(principal) do
    for {stall, %{id: id, principal: ^principal, at: at}} <- markers,
        hall.now - at <= @pickup_window,
        match?(%{mode: :open, counter: nil}, hall.stalls[stall]),
        do: %{id: id, stall: stall}
  end

  def pickups(_markers, _hall, _principal), do: []

  @doc "Keeps only markers for stalls that still exist in the evolved `hall`."
  def retain(hall, markers), do: if(hall, do: Map.take(markers, Map.keys(hall.stalls)), else: %{})
end
