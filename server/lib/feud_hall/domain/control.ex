defmodule FeudHall.Domain.Control do
  @moduledoc """
  The service-level control stream: availability epochs and recovery identities.

  The control stream records that availability started (a new epoch begins)
  and that a recovery was reconciled. It is separate from the hall stream so
  that an authority can start an epoch before any hall exists. A recovery is
  identified by `"recovery:" <> epoch_id`, derived from the interrupted
  epoch, so every owner retrying the same interrupted epoch issues the same
  `reconcile_recovery` payload and receives the original receipt.

  `decide/4` is pure. `hall_state` is read-only context (nil until the hall
  is initialised); a reconciliation also yields the hall-stream event that
  marks the hall resumed, so both commit in one batch. Only the identity
  `pending_recovery_id/1` names may be reconciled (`:not_pending` otherwise),
  so no command can mark an unrelated or superseded epoch resumed.

  State: `%{current_epoch: id | nil, epochs: [id], reconciled: MapSet}`, or
  nil before any event.
  """

  alias FeudHall.Domain.Identity
  alias FeudHall.Domain.Hall.Management

  @type state :: %{current_epoch: String.t() | nil, epochs: [String.t()], reconciled: MapSet.t()} | nil

  @doc "Decides a control command; only the authority capability may issue them."
  def decide(control, hall_state, command, ctx)

  def decide(_control, _hall, _command, %{actor: actor}) when actor != {:system, :authority},
    do: {:error, :forbidden}

  def decide(control, _hall, {:start_availability, %{epoch_id: id}}, _ctx) when is_binary(id) and id != "" do
    if id in epochs(control),
      do: {:error, :epoch_exists},
      else: {:ok, %{control: [%{type: :availability_started, epoch_id: id}], hall: []}}
  end

  def decide(_control, nil, {:reconcile_recovery, %{recovery_id: id}}, _ctx) when is_binary(id) and id != "",
    do: {:error, :hall_not_initialized}

  def decide(control, hall, {:reconcile_recovery, %{recovery_id: id}}, _ctx) when is_binary(id) and id != "" do
    cond do
      id != pending_recovery_id(control) ->
        {:error, :not_pending}

      MapSet.member?(reconciled(control), id) ->
        {:error, :already_reconciled}

      true ->
        {:ok,
         %{
           control: [%{type: :availability_resumed, recovery_id: id, hall_ms: hall.now}],
           hall: [%{type: :hall_resumed, recovery_id: id} | Management.recovery_events(hall)]
         }}
    end
  end

  def decide(_control, _hall, _command, _ctx), do: {:error, :invalid_command}

  @doc "Applies one committed control event."
  def evolve(nil, event), do: evolve(%{current_epoch: nil, epochs: [], reconciled: MapSet.new()}, event)

  def evolve(state, %{type: :availability_started, epoch_id: id}),
    do: %{state | current_epoch: id, epochs: state.epochs ++ [id]}

  def evolve(state, %{type: :availability_resumed, recovery_id: id}),
    do: %{state | reconciled: MapSet.put(state.reconciled, id)}

  def evolve(state, event), do: Map.put(state, :identity, Identity.evolve(Identity.get(state), event))

  @doc "Folds control events from genesis (or a snapshot state)."
  def replay(events, state \\ nil), do: Enum.reduce(events, state, &evolve(&2, &1))

  @doc """
  The recovery identity of the current epoch, until a newer epoch starts;
  nil when no epoch has started. It is returned whether or not that recovery
  was already reconciled.
  """
  @spec pending_recovery_id(state()) :: String.t() | nil
  def pending_recovery_id(nil), do: nil
  def pending_recovery_id(%{current_epoch: nil}), do: nil
  def pending_recovery_id(%{current_epoch: epoch}), do: "recovery:" <> epoch

  defp epochs(nil), do: []
  defp epochs(state), do: state.epochs
  defp reconciled(nil), do: MapSet.new()
  defp reconciled(state), do: state.reconciled
end
