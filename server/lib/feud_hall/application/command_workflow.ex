defmodule FeudHall.Application.CommandWorkflow do
  @moduledoc """
  The explicit economic command workflow, kept visible rather than hidden in
  interceptors:

    1. structural validation of the envelope (before any storage access);
    2. original-receipt lookup by command ID, bound to a fingerprint of the
       actor, command kind, and canonical payload: an identical retry returns
       the original receipt, changed content under the same ID is a conflict;
    3. independently due clock advancement, committed as its own batch;
    4. the pure domain decision against the caught-up head;
    5. atomic append of the batch with its receipt at the expected position,
       and only then evolution of the in-memory head.

  A rejected command records a rejection receipt and no domain events. A lost
  append response puts the runtime into `:recovery_required`; it accepts no
  new economic commands until `resolve/2` has looked up that same command ID.
  Authentication happens before this workflow: `actor` is the server-resolved
  principal or system capability, never a client-supplied ID.
  """

  alias FeudHall.Domain.{Clock, Hall}

  @commands ~w(initialize_hall advance_clock create_restaurant open_stall close_stall unlock_recipe
               set_menu_price remove_menu_item set_substitution_policy purchase_stock grant_allowance
               admit_visit cancel_tray start_preparation complete_preparation serve_tray accept_dessert
               decline_dessert cancel_dessert serve_dessert)a

  defstruct store_mod: nil, store: nil, state: nil, position: 0, mode: :ready, pending: nil

  @doc "Opens a runtime by replaying every committed batch from the store."
  def open(store_mod, store) do
    batches = store_mod.read_from(store, 0)
    state = batches |> Enum.flat_map(& &1.events) |> Hall.replay(nil)
    %__MODULE__{store_mod: store_mod, store: store, state: state, position: store_mod.head(store)}
  end

  @doc """
  Executes a command envelope `%{command_id:, actor:, command: {kind, payload}}`.
  When `observed_service_ms` is given, due clock work up to that instant is
  committed first as a separate scheduler batch.
  """
  def execute(runtime, envelope, observed_service_ms \\ nil)

  def execute(%{mode: :recovery_required}, _envelope, _observed), do: {:error, :recovery_required}

  def execute(runtime, envelope, observed_service_ms) do
    with :ok <- validate(envelope),
         fingerprint = fingerprint(envelope),
         :new <- lookup(runtime, envelope.command_id, fingerprint),
         {:ok, runtime} <- maybe_advance(runtime, envelope.command_id, observed_service_ms) do
      decide_and_append(runtime, envelope, fingerprint)
    else
      {:replayed, receipt} -> {:replayed, receipt, runtime}
      {:error, _reason} = error -> error
      {:uncertain, _id, _runtime} = uncertain -> uncertain
    end
  end

  @doc """
  Resolves an uncertain command by its original ID. A found receipt means it
  committed: the head is rebuilt from the store. No receipt means it did not.
  """
  def resolve(runtime, command_id) do
    reopened = open(runtime.store_mod, runtime.store)

    case runtime.store_mod.receipt(runtime.store, command_id) do
      {:ok, receipt} -> {:committed, receipt, reopened}
      :none -> {:not_committed, reopened}
    end
  end

  @doc "Canonical fingerprint binding a command ID to its original request."
  def fingerprint(%{actor: actor, command: {kind, payload}}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({actor, kind, payload}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp validate(%{command_id: id, actor: actor, command: {kind, payload}})
       when is_binary(id) and byte_size(id) in 1..64 and is_map(payload) do
    cond do
      not String.printable?(id) -> {:error, :malformed_command_id}
      kind not in @commands -> {:error, :unknown_command}
      not valid_actor?(actor) -> {:error, :unauthenticated}
      true -> :ok
    end
  end

  defp validate(_), do: {:error, :malformed_envelope}

  defp valid_actor?({:principal, id}), do: is_binary(id) and byte_size(id) in 1..64
  defp valid_actor?({:system, cap}), do: cap in [:admin, :scheduler, :kitchen, :demand, :visitor_fund]
  defp valid_actor?(_), do: false

  defp lookup(runtime, command_id, fingerprint) do
    case runtime.store_mod.receipt(runtime.store, command_id) do
      :none -> :new
      {:ok, %{fingerprint: ^fingerprint} = receipt} -> {:replayed, receipt}
      {:ok, _other} -> {:error, :command_id_conflict}
    end
  end

  defp maybe_advance(runtime, _id, nil), do: {:ok, runtime}

  defp maybe_advance(%{state: nil} = runtime, _id, _observed), do: {:ok, runtime}

  defp maybe_advance(runtime, command_id, observed) do
    if Clock.hall_at_service(observed) > runtime.state.now do
      envelope = %{
        command_id: "adv:" <> command_id,
        actor: {:system, :scheduler},
        command: {:advance_clock, %{to_service_ms: observed}}
      }

      case decide_and_append(runtime, envelope, fingerprint(envelope)) do
        {:accepted, _receipt, runtime} -> {:ok, runtime}
        {:rejected, _receipt, runtime} -> {:ok, runtime}
        other -> other
      end
    else
      {:ok, runtime}
    end
  end

  defp decide_and_append(runtime, envelope, fingerprint) do
    ctx = %{command_id: envelope.command_id, actor: envelope.actor}
    {kind, _} = envelope.command

    receipt = %{
      command_id: envelope.command_id,
      fingerprint: fingerprint,
      kind: kind,
      actor: envelope.actor
    }

    {events, receipt} =
      case Hall.decide(runtime.state, envelope.command, ctx) do
        {:ok, events} -> {events, Map.merge(receipt, %{outcome: :accepted, event_count: length(events)})}
        {:error, reason} -> {[], Map.merge(receipt, %{outcome: {:rejected, reason}, event_count: 0})}
      end

    case runtime.store_mod.append(runtime.store, runtime.position, envelope.command_id, events, receipt) do
      {:ok, store, position} ->
        runtime = %{runtime | store: store, position: position, state: Hall.replay(events, runtime.state)}
        receipt = Map.put(receipt, :position, position)
        status = if receipt.outcome == :accepted, do: :accepted, else: :rejected
        {status, receipt, runtime}

      {:error, :unknown_outcome, store} ->
        {:uncertain, envelope.command_id,
         %{runtime | store: store, mode: :recovery_required, pending: envelope.command_id}}

      {:error, reason, _store} ->
        {:error, reason}
    end
  end
end
