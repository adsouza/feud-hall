defmodule FeudHall.Application.Recovery do
  @moduledoc """
  Fenced recovery of a hall authority: restore the committed head, check it,
  reconcile the interrupted availability epoch, and start a new one.

  Steps, in order:

    1. `acquire_authority` for the required `opts[:scope]`. The store
       handle returned carries the new epoch, so any later append by a
       previous owner is fenced. With `opts[:expected_epoch]` (an authority
       re-recovering a hall it held), the acquisition succeeds only while that
       epoch is still current; otherwise recovery returns `{:error, :fenced}`
       before reading or appending anything, so a superseded owner never takes
       the hall back from its successor.
    2. With a snapshot decoder (`opts[:decode_snapshot]`, a function
       `binary -> {:ok, %{position:, state: %{hall:, control:}}} | {:error, reason}`,
       e.g. the infrastructure snapshot loader), try the store's verified
       snapshots newest first. A snapshot is skipped, and recorded in the
       report as `{id, reason}`, when its position is beyond the store's head
       (`:beyond_head`), when it fails to decode (the decoder's reason, such
       as `:corrupt_snapshot` or `:incompatible_snapshot`), when it decodes to
       another position (`:position_mismatch`), or when its body has the wrong
       shape (`:malformed_snapshot`). Unverified snapshots are never
       candidates. Without a usable snapshot, or without a decoder, replay
       starts at genesis. A snapshot is only a cache: it never justifies
       skipping committed history after it.
    3. `read_from/2` after the chosen position and fold the tail with the pure
       evolvers. A batch the store cannot decode aborts recovery with the
       store's `{:undecodable, position, reason}` error. The tail must hold
       every position from just after the snapshot (or genesis) up to the
       store's head, read once after acquiring authority; the first absent one
       aborts with `{:missing_batch, position}`, so a lost authoritative batch
       blocks recovery instead of being skipped.
    4. `Invariants.check/1` on the restored hall; a violation aborts with
       `{:error, {:invariants, problems}}`.
    5. If `Control.pending_recovery_id/1` names an interrupted epoch and a hall
       exists, execute `{:reconcile_recovery, %{recovery_id: id}}` with command
       ID `id` as `{:system, :authority}`. The fingerprint is the same for every
       owner, so a retry after a crash receives the original receipt
       (`:replayed`) instead of a second reconciliation. An epoch that began
       before any hall existed has no hall to resume and is not reconciled.
    6. For a hall initialized before the shared simulation, append its
       versioned simulation upgrade with the authority's fence.
    7. Execute `{:start_availability, %{epoch_id: "<owner>:<epoch>"}}` with
       command ID `"start:<owner>:<epoch>"`.

  Step 1 writes only the scope's authority row; steps 2 to 4 only read, so a
  failure before step 5 appends nothing to the log. A
  failure is `{:error, reason, store}`, where `store` is the handle as it stands
  after the last successful step: the input store if acquisition did not
  happen, otherwise the handle holding the acquired epoch (and, once appends
  have begun, the store the last append returned). A caller retrying recovery
  must use that store, and its `held_epoch/1` as the next `expected_epoch`:
  the acquisition already committed, so retrying from the older epoch would be
  fenced by its own success. Storage failures are reported as the store
  reports them (`:unavailable`); a fenced acquisition or append is `:fenced`
  (not reported as `:recovery_failed`: being superseded is expected); a lost
  append reply is `{:uncertain, command_id}`, resolved by running recovery
  again, which looks the same command ID up and replays its receipt if it
  committed.

  Replay performs no side effects: it only folds committed events, and the
  reconciliation and the new epoch are ordinary appended transitions. Recovery
  has no live side effects of its own in this milestone, so
  `opts[:side_effects]` is accepted for genuinely new live work after recovery
  (there is none yet) and is never invoked while replaying.
  """

  alias FeudHall.Application.{CommandWorkflow, Diagnostics, Replay}
  alias FeudHall.Domain.{Content, Control}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Domain.Hall.SimulationUpgrade

  @authority {:system, :authority}
  # Keeps "recovery:<owner>:<epoch>" within the workflow's 64-byte command IDs for any bigint epoch.
  @max_owner_bytes 32
  @genesis %{snapshot: :genesis, position: 0, hall: nil, control: nil}

  @type report :: %{
          snapshot: non_neg_integer() | :genesis,
          skipped: [{term(), term()}],
          tail_batches: non_neg_integer(),
          recovery_id: String.t() | nil,
          reconciliation: :accepted | :replayed | :already_reconciled | nil
        }

  @doc """
  Recovers the hall held by `store` for `owner`. Options: `:scope`
  (required; raises `KeyError` without it), `:expected_epoch`, `:decode_snapshot`,
  `:diagnostics` (passed to the runtime), and `:side_effects` (never invoked
  during replay).
  """
  @spec recover(module(), term(), String.t(), keyword()) ::
          {:ok, CommandWorkflow.t(), report()} | {:error, term(), store :: term()}
  def recover(store_mod, store, owner, opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    diagnostics = Keyword.get(opts, :diagnostics)
    Diagnostics.emit(diagnostics, :recovery_started, %{scope: scope})

    case do_recover(store_mod, store, owner, scope, opts) do
      {:ok, _runtime, report} = ok ->
        Diagnostics.emit(diagnostics, :recovery_completed, %{
          scope: scope,
          snapshot_position: if(is_integer(report.snapshot), do: report.snapshot),
          skipped: length(report.skipped),
          recovery_id: report.recovery_id
        })

        ok

      # Being superseded is not a failure of recovery; the caller reports fencing.
      {:error, :fenced, _store} = fenced ->
        fenced

      {:error, reason, _store} = error ->
        Diagnostics.emit(diagnostics, :recovery_failed, %{scope: scope, error_class: Diagnostics.reason(reason)})
        error
    end
  end

  # Failures carry the store as it stands after the last successful step: the input store
  # before acquisition, the handle holding the acquired epoch after it, and the store the last
  # append returned once appends have begun.
  defp do_recover(store_mod, store, owner, scope, opts) do
    with :ok <- validate_owner(owner),
         {:ok, acquired, epoch} <- acquire(store_mod, store, scope, owner, Keyword.get(opts, :expected_epoch)) do
      restore_and_resume(store_mod, acquired, owner, scope, epoch, opts)
    else
      {:error, reason} -> {:error, reason, store}
    end
  end

  defp restore_and_resume(store_mod, store, owner, scope, epoch, opts) do
    with head when is_integer(head) <- store_mod.head(store),
         {:ok, base, skipped} <-
           base(store_mod, store, head, Keyword.get(opts, :decode_snapshot), skip_reporter(opts, scope)),
         {:ok, restored} <- Replay.load(store_mod, store, base: base, head: head),
         :ok <- validate_live_content(restored.hall),
         {:ok, runtime} <-
           CommandWorkflow.from_state(store_mod, store, restored, epoch: epoch, diagnostics: opts[:diagnostics]),
         {:ok, runtime, recovery_id, reconciliation} <- reconcile(runtime),
         {:ok, runtime} <- upgrade(runtime, owner, epoch),
         {:ok, runtime} <- start(runtime, "#{owner}:#{epoch}") do
      {:ok, runtime,
       %{
         snapshot: base.snapshot,
         skipped: skipped,
         tail_batches: restored.tail_batches,
         recovery_id: recovery_id,
         reconciliation: reconciliation
       }}
    else
      {:error, reason} -> {:error, reason, store}
      {:error, reason, %CommandWorkflow{store: appended}} -> {:error, reason, appended}
    end
  end

  # Unconditional acquisition stays on the three-argument callback.
  defp acquire(store_mod, store, scope, owner, nil), do: store_mod.acquire_authority(store, scope, owner)

  defp acquire(store_mod, store, scope, owner, expected) when is_integer(expected),
    do: store_mod.acquire_authority(store, scope, owner, expected)

  defp validate_owner(owner) do
    if is_binary(owner) and byte_size(owner) in 1..@max_owner_bytes and String.printable?(owner),
      do: :ok,
      else: {:error, :invalid_owner}
  end

  # --- snapshot selection ------------------------------------------------------

  defp base(_store_mod, _store, _head, nil, _on_skip), do: {:ok, @genesis, []}

  defp base(store_mod, store, head, decode, on_skip) when is_function(decode, 1) do
    with snapshots when is_list(snapshots) <- store_mod.snapshots(store) do
      snapshots
      |> Enum.filter(& &1.verified)
      |> Enum.reduce_while([], fn snapshot, skipped ->
        case usable(snapshot, head, decode) do
          {:ok, base} ->
            {:halt, {:ok, base, Enum.reverse(skipped)}}

          {:skip, reason} ->
            on_skip.(snapshot, reason)
            {:cont, [{snapshot.id, reason} | skipped]}
        end
      end)
      |> case do
        {:ok, _base, _skipped} = found -> found
        skipped -> {:ok, @genesis, Enum.reverse(skipped)}
      end
    end
  end

  defp skip_reporter(opts, scope) do
    diagnostics = Keyword.get(opts, :diagnostics)

    fn snapshot, reason ->
      Diagnostics.emit(diagnostics, :snapshot_skipped, %{
        scope: scope,
        snapshot_position: snapshot.position,
        reason: Diagnostics.reason(reason)
      })
    end
  end

  defp usable(%{position: position}, head, _decode) when position > head, do: {:skip, :beyond_head}

  defp usable(%{position: position, body: body}, _head, decode) do
    case decode.(body) do
      {:ok, %{position: ^position, state: %{hall: hall, control: control}} = snapshot} ->
        {:ok, %{snapshot: position, position: position, hall: hall, control: control, versions: snapshot[:versions]}}

      {:ok, %{position: other}} when other != position ->
        {:skip, :position_mismatch}

      {:ok, _} ->
        {:skip, :malformed_snapshot}

      {:error, reason} ->
        {:skip, reason}
    end
  end

  defp validate_live_content(%{catalog: %{rules: %{kitchen: _}} = catalog}) do
    with {:error, problems} <- Content.validate(catalog), do: {:error, {:invalid_content, problems}}
  end

  defp validate_live_content(_hall), do: :ok

  # --- new transitions ---------------------------------------------------------

  defp reconcile(%{state: nil} = runtime), do: {:ok, runtime, nil, nil}

  defp reconcile(runtime) do
    case Control.pending_recovery_id(runtime.control) do
      nil ->
        {:ok, runtime, nil, nil}

      id ->
        envelope = %{command_id: id, actor: @authority, command: {:reconcile_recovery, %{recovery_id: id}}}

        case CommandWorkflow.execute(runtime, envelope) do
          {:accepted, _receipt, runtime} ->
            {:ok, runtime, id, :accepted}

          {:replayed, %{outcome: :accepted}, runtime} ->
            {:ok, runtime, id, :replayed}

          # Resumed earlier under another command ID: nothing is left to reconcile.
          {status, %{outcome: {:rejected, :already_reconciled}}, runtime} when status in [:rejected, :replayed] ->
            {:ok, runtime, id, :already_reconciled}

          {status, %{outcome: {:rejected, reason}}, runtime} when status in [:rejected, :replayed] ->
            {:error, {:reconciliation_rejected, reason}, runtime}

          other ->
            failure(other)
        end
    end
  end

  defp upgrade(runtime, owner, epoch) do
    if SimulationUpgrade.needed?(runtime.state) do
      envelope = %{
        command_id: "upgrade:#{owner}:#{epoch}",
        actor: @authority,
        command: {:upgrade_simulation, %{defaults: SliceCatalog.catalog()}}
      }

      case CommandWorkflow.execute(runtime, envelope) do
        {status, %{outcome: :accepted}, runtime} when status in [:accepted, :replayed] ->
          {:ok, runtime}

        {status, %{outcome: {:rejected, reason}}, runtime} when status in [:rejected, :replayed] ->
          {:error, {:upgrade_rejected, reason}, runtime}

        other ->
          failure(other)
      end
    else
      {:ok, runtime}
    end
  end

  defp start(runtime, epoch_id) do
    envelope = %{
      command_id: "start:" <> epoch_id,
      actor: @authority,
      command: {:start_availability, %{epoch_id: epoch_id}}
    }

    case CommandWorkflow.execute(runtime, envelope) do
      {status, %{outcome: :accepted}, runtime} when status in [:accepted, :replayed] ->
        {:ok, runtime}

      {status, %{outcome: {:rejected, reason}}, runtime} when status in [:rejected, :replayed] ->
        {:error, {:start_rejected, reason}, runtime}

      other ->
        failure(other)
    end
  end

  defp failure({:uncertain, command_id, runtime}), do: {:error, {:uncertain, command_id}, runtime}
  defp failure({:error, reason, runtime}), do: {:error, reason, runtime}
end
