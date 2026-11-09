defmodule FeudHall.Infrastructure.Snapshot do
  @moduledoc """
  Versioned, checksummed snapshots of the hall and control states at a complete
  committed batch boundary. A snapshot is a cache: an incompatible or corrupt snapshot
  is rejected so recovery falls back to an earlier one or to genesis replay;
  it never justifies skipping authoritative events.
  """

  alias FeudHall.Domain.{Control, Hall}

  # Bump when the shape of evolved state changes.
  @evolution_version 2

  @doc "The evolved-state shape version this module writes and accepts."
  def evolution_version, do: @evolution_version

  @doc """
  Encodes `%{hall: hall_state, control: control_state}` at `position`. Evolution version 2 added
  the control state; version 1 snapshots (hall state only) are rejected as incompatible.
  """
  def take(%{hall: _, control: _} = state, position) do
    body = :erlang.term_to_binary(%{position: position, evolution: @evolution_version, state: state}, [:deterministic])
    <<checksum(body)::binary, body::binary>>
  end

  def load(<<sum::binary-size(32), body::binary>>) do
    with true <- sum == checksum(body) || {:error, :corrupt_snapshot},
         %{evolution: @evolution_version} = snapshot <- :erlang.binary_to_term(body, [:safe]) do
      {:ok, snapshot}
    else
      %{evolution: _} -> {:error, :incompatible_snapshot}
      {:error, _} = error -> error
    end
  end

  def load(_), do: {:error, :corrupt_snapshot}

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
