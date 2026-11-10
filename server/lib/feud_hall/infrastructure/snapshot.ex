defmodule FeudHall.Infrastructure.Snapshot do
  @moduledoc """
  Versioned, checksummed snapshots of the hall and control states at a complete
  committed batch boundary. A snapshot is a cache: an incompatible or corrupt snapshot
  is rejected so recovery falls back to an earlier one or to genesis replay;
  it never justifies skipping authoritative events.
  """

  alias FeudHall.Domain.{Control, Hall}

  # Bump when the shape of evolved state changes.
  @evolution_version 3

  @doc "The evolved-state shape version this module writes and accepts."
  def evolution_version, do: @evolution_version

  @doc """
  Encodes `%{hall: hall_state, control: control_state}` at `position`. Evolution version 2 added
  the control state; version 3 the shared simulation's hall state (layout, seed, NPCs, market
  requests, stall counters, order stage fields, demand bookkeeping, simulated-arrival stats).
  Older snapshots are rejected as incompatible, so recovery replays from genesis instead.
  """
  def take(%{hall: _, control: _} = state, position) do
    body = :erlang.term_to_binary(%{position: position, evolution: @evolution_version, state: state}, [:deterministic])
    <<checksum(body)::binary, body::binary>>
  end

  @doc """
  Loads a snapshot binary. A checksum mismatch, a body that is not an external term, or a
  term of the wrong shape is `:corrupt_snapshot`; another evolution version, or a body naming
  an atom this build does not define (as a newer release could write), is
  `:incompatible_snapshot`. It never raises, so recovery can fall back.
  """
  def load(<<sum::binary-size(32), body::binary>>) do
    with true <- sum == checksum(body) || {:error, :corrupt_snapshot},
         {:ok, term} <- decode(body),
         %{evolution: @evolution_version, position: position, state: %{hall: _, control: _}} = snapshot
         when is_integer(position) <- term do
      {:ok, snapshot}
    else
      %{evolution: evolution} when is_integer(evolution) and evolution != @evolution_version ->
        {:error, :incompatible_snapshot}

      {:error, _} = error ->
        error

      _wrong_shape ->
        {:error, :corrupt_snapshot}
    end
  end

  def load(_), do: {:error, :corrupt_snapshot}

  # A body that is not in the external term format at all is corrupt. With a valid checksum,
  # a well-formed body that `[:safe]` still refuses names atoms this build does not define:
  # it was written by another release, so it is incompatible. Atoms are never created here.
  defp decode(<<131, _::binary>> = body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    ArgumentError -> {:error, :incompatible_snapshot}
  end

  defp decode(_body), do: {:error, :corrupt_snapshot}

  @doc "The evolution version recorded in a checksummed snapshot binary, or `nil` when it is unreadable."
  def evolution_of(binary) do
    with <<sum::binary-size(32), body::binary>> <- binary,
         true <- sum == checksum(body),
         %{evolution: evolution} when is_integer(evolution) <- :erlang.binary_to_term(body, [:safe]) do
      evolution
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Restores state from a snapshot plus the committed batches after it."
  def restore(snapshot_binary, batches) do
    with {:ok, %{position: position, state: %{hall: hall, control: control}}} <- load(snapshot_binary) do
      tail = Enum.filter(batches, &(&1.position > position))
      hall_events = Enum.flat_map(tail, & &1.events)
      control_events = Enum.flat_map(tail, &Map.get(&1, :control_events, []))
      {:ok, %{hall: Hall.replay(hall_events, hall), control: Control.replay(control_events, control)}}
    end
  end

  defp checksum(body), do: :crypto.hash(:sha256, body)
end
