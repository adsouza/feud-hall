defmodule FeudHall.Application.CommandWorkflow do
  @moduledoc """
  The explicit economic command workflow, kept visible rather than hidden in
  interceptors:

    1. structural validation of the envelope (before any storage access);
    2. original-receipt lookup by command ID, bound to a fingerprint of the
       actor, command kind, and canonical payload: an identical retry returns
       the original receipt, changed content under the same ID is a conflict;
    3. independently due clock advancement, committed as its own batch;
    4. the pure domain decision against the caught-up head, evolved into a
       candidate state from which the synchronous projection rows are derived;
    5. atomic append of the batch, its receipt, and those rows at the expected
       position and stream versions, and only then adoption of the candidate
       as the in-memory head.

  A rejected command records a rejection receipt and no domain events. A lost
  append response puts the runtime into `:recovery_required`; it accepts no
  new economic commands until `resolve/2` has looked up that same command ID.
  A fenced append (another owner holds the hall's authority) puts the runtime
  into `:fenced`; it refuses all later commands and never becomes ready again.
  Every fenced result, first or later, is `{:error, :fenced, runtime}`.
  Authentication happens before this workflow: `actor` is the server-resolved
  principal or system capability, never a client-supplied ID.
  """

  alias FeudHall.Application.Projections.Balances
  alias FeudHall.Domain.{Clock, Control, Hall}

  @commands ~w(initialize_hall advance_clock create_restaurant open_stall close_stall unlock_recipe
               set_menu_price remove_menu_item set_substitution_policy purchase_stock grant_allowance
               admit_visit cancel_tray start_preparation complete_preparation serve_tray accept_dessert
               decline_dessert cancel_dessert serve_dessert)a
  @control_commands ~w(start_availability reconcile_recovery)a

  defstruct store_mod: nil,
            store: nil,
            state: nil,
            control: nil,
            position: 0,
            versions: %{hall: 0, control: 0},
            epoch: nil,
            mode: :ready,
            pending: nil,
            diagnostics: nil

  @doc """
  Opens a runtime by replaying every committed batch from the store. A batch
  that cannot be decoded stops the open with the store's error.
  """
  def open(store_mod, store, opts \\ []) do
    with {:ok, batches} <- store_mod.read_from(store, 0) do
      state = batches |> Enum.flat_map(& &1.events) |> Hall.replay(nil)
      control = batches |> Enum.flat_map(& &1.control_events) |> Control.replay(nil)

      {:ok,
       %__MODULE__{
         store_mod: store_mod,
         store: store,
         state: state,
         control: control,
         position: store_mod.head(store),
         versions: store_mod.stream_versions(store, hall_stream(state)),
         diagnostics: Keyword.get(opts, :diagnostics)
       }}
    end
  end

  @doc """
  Executes a command envelope `%{command_id:, actor:, command: {kind, payload}}`.
  When `observed_service_ms` is given, due clock work up to that instant is
  committed first as a separate scheduler batch.
  """
  def execute(runtime, envelope, observed_service_ms \\ nil)

  def execute(%{mode: :fenced} = runtime, _envelope, _observed), do: {:error, :fenced, runtime}
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
      {:error, :fenced, _runtime} = fenced -> fenced
      {:uncertain, _id, _runtime} = uncertain -> uncertain
    end
  end

  @doc """
  Resolves an uncertain command by its original ID. A found receipt means it
  committed: the head is rebuilt from the store. No receipt means it did not.
  """
  def resolve(%{mode: :fenced} = runtime, _command_id), do: {:error, :fenced, runtime}

  def resolve(runtime, command_id) do
    with {:ok, reopened} <- open(runtime.store_mod, runtime.store, diagnostics: runtime.diagnostics) do
      case runtime.store_mod.receipt(runtime.store, command_id) do
        {:ok, receipt} -> {:committed, receipt, reopened}
        :none -> {:not_committed, reopened}
      end
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
      kind not in @commands and kind not in @control_commands -> {:error, :unknown_command}
      not valid_actor?(actor) -> {:error, :unauthenticated}
      true -> :ok
    end
  end

  defp validate(_), do: {:error, :malformed_envelope}

  defp valid_actor?({:principal, id}), do: is_binary(id) and byte_size(id) in 1..64
  defp valid_actor?({:system, cap}), do: cap in [:admin, :authority, :scheduler, :kitchen, :demand, :visitor_fund]
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

    {events, control_events, receipt} =
      case decide(runtime, envelope.command, ctx) do
        {:ok, events, control_events} ->
          count = length(events) + length(control_events)
          {events, control_events, Map.merge(receipt, %{outcome: :accepted, event_count: count})}

        {:error, reason} ->
          {[], [], Map.merge(receipt, %{outcome: {:rejected, reason}, event_count: 0})}
      end

    candidate = Hall.replay(events, runtime.state)
    candidate_control = Control.replay(control_events, runtime.control)
    request = append_request(runtime, envelope, events, control_events, receipt, candidate)

    case runtime.store_mod.append(runtime.store, request) do
      {:ok, store, position} ->
        runtime = %{
          runtime
          | store: store,
            position: position,
            state: candidate,
            control: candidate_control,
            versions: %{
              hall: runtime.versions.hall + length(events),
              control: runtime.versions.control + length(control_events)
            }
        }

        receipt = Map.put(receipt, :position, position)
        status = if receipt.outcome == :accepted, do: :accepted, else: :rejected
        {status, receipt, runtime}

      {:error, :unknown_outcome, store} ->
        {:uncertain, envelope.command_id,
         %{runtime | store: store, mode: :recovery_required, pending: envelope.command_id}}

      {:error, :fenced, store} ->
        {:error, :fenced, %{runtime | store: store, mode: :fenced}}

      {:error, reason, _store} ->
        {:error, reason}
    end
  end

  # Control commands see the hall state (nil before initialisation) read-only;
  # hall commands never touch the control stream.
  defp decide(runtime, {kind, _} = command, ctx) when kind in @control_commands do
    with {:ok, %{control: control, hall: hall}} <- Control.decide(runtime.control, runtime.state, command, ctx) do
      {:ok, hall, control}
    end
  end

  defp decide(runtime, command, ctx) do
    with {:ok, events} <- Hall.decide(runtime.state, command, ctx), do: {:ok, events, []}
  end

  defp append_request(runtime, envelope, events, control_events, receipt, candidate) do
    %{
      command_id: envelope.command_id,
      expected_position: runtime.position,
      expected_versions: runtime.versions,
      hall_stream: hall_stream(runtime.state || candidate),
      events: events,
      control_events: control_events,
      receipt: receipt,
      outbox: [],
      projection_rows: Balances.changes(runtime.state, candidate, runtime.position + 1),
      context: %{
        actor: envelope.actor,
        correlation_id: envelope.command_id,
        content_hash: candidate && candidate.content_hash,
        hall_ms: candidate && candidate.now
      }
    }
  end

  defp hall_stream(nil), do: nil
  defp hall_stream(state), do: "hall:" <> state.hall_id
end
