defmodule FeudHall.Application.Diagnostics do
  @moduledoc """
  The diagnostics port. A configuration is `{module, sink}` (or `nil`, which
  disables emission); `module.emit(sink, record)` receives one redacted record.

  Records are built here and nowhere else: `record/2` keeps only an allowlist
  of scalar fields, so a payload, player text, or principal ID cannot be
  copied into one by accident. Emission is best effort and can never change
  gameplay: `emit/3` swallows anything a sink raises, throws, or exits with.
  Diagnostics explain attempts; they are not evidence that anything committed.
  """

  @callback emit(sink :: term, record :: map) :: :ok

  @allowed ~w(command_id kind actor_kind outcome reason attempt position epoch hall_ms duration_us scope
              recovery_id snapshot_position skipped error_class batch_events backlog lateness_ms)a
  @max_string 128
  @errors ~w(command_rejected recovery_failed)a

  @type config :: {module(), term()} | nil

  @doc "Builds a schema-1 record. Unknown keys, nils, and non-scalar values are dropped."
  @spec record(atom(), map()) :: map()
  def record(name, fields) when is_atom(name) and is_map(fields) do
    %{
      schema: 1,
      name: name,
      severity: severity(name, fields),
      at_mono: System.monotonic_time(:microsecond),
      fields: clean(fields)
    }
  end

  @doc "Emits a record to the configured sink; never raises."
  @spec emit(config(), atom(), map()) :: :ok
  def emit(nil, _name, _fields), do: :ok

  def emit({module, sink}, name, fields) do
    module.emit(sink, record(name, fields))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # A malformed configuration disables emission rather than failing the caller.
  def emit(_malformed, _name, _fields), do: :ok

  @doc """
  Like `emit/3`, but builds the fields in `fun` inside the same isolation:
  a raising builder or a malformed config drops the record, nothing more.
  """
  @spec emit_lazy(config(), atom(), (-> map())) :: :ok
  def emit_lazy(nil, _name, _fun), do: :ok

  def emit_lazy(config, name, fun) do
    emit(config, name, fun.())
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Runs `fun`, returning `default` if it raises; for field building that feeds later records."
  @spec guard((-> term()), term()) :: term()
  def guard(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @doc "Reduces an error term to a short atom: structured detail may carry data, so only its tag survives."
  @spec reason(term()) :: atom()
  def reason(reason) when is_atom(reason), do: reason
  def reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)), do: elem(reason, 0)
  def reason(_), do: :unknown

  @doc "The kind of actor, never its identity."
  @spec actor_kind(term()) :: :principal | :system | nil
  def actor_kind({:principal, _}), do: :principal
  def actor_kind({:system, _}), do: :system
  def actor_kind(_), do: nil

  defp severity(:recovery_failed, _), do: :error
  defp severity(:command_outcome, %{outcome: outcome}) when outcome in [:unavailable, :commit_unknown], do: :error
  defp severity(:command_outcome, %{outcome: outcome}) when outcome in [:conflict, :fenced], do: :warning
  defp severity(:snapshot_skipped, _), do: :warning
  defp severity(name, _) when name in [:storage_failure, :snapshot_failed], do: :error
  defp severity(name, _) when name in [:fenced, :scheduler_gap, :tick_late, :npc_planner_failed], do: :warning
  defp severity(name, _) when name in @errors, do: :error
  defp severity(_, _), do: :info

  defp clean(fields) do
    for {key, value} <- fields, key in @allowed, key != :actor_kind or value in [:principal, :system], reduce: %{} do
      acc ->
        case scalar(value) do
          :drop -> acc
          value -> Map.put(acc, key, value)
        end
    end
  end

  defp scalar(nil), do: :drop
  defp scalar(value) when is_boolean(value) or is_atom(value) or is_integer(value), do: value
  defp scalar(value) when is_binary(value), do: truncate(value)
  defp scalar(_), do: :drop

  defp truncate(value) when byte_size(value) <= @max_string, do: value

  defp truncate(value) do
    cut = binary_part(value, 0, @max_string)
    # Never split a UTF-8 sequence.
    if String.valid?(cut), do: cut, else: trim_invalid(cut)
  end

  defp trim_invalid(<<>>), do: <<>>

  defp trim_invalid(binary) do
    size = byte_size(binary) - 1
    shorter = binary_part(binary, 0, size)
    if String.valid?(shorter), do: shorter, else: trim_invalid(shorter)
  end
end
