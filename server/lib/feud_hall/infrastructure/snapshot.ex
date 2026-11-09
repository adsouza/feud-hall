defmodule FeudHall.Infrastructure.Snapshot do
  @moduledoc """
  Versioned, checksummed snapshots of the hall state at a complete committed
  batch boundary. A snapshot is a cache: an incompatible or corrupt snapshot
  is rejected so recovery falls back to an earlier one or to genesis replay;
  it never justifies skipping authoritative events.
  """

  alias FeudHall.Domain.Hall

  # Bump when the shape of evolved state changes.
  @evolution_version 1

  @doc "The evolved-state shape version this module writes and accepts."
  def evolution_version, do: @evolution_version

  def take(state, position) do
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

  @doc "Restores state from a snapshot plus the committed batches after it."
  def restore(snapshot_binary, batches) do
    with {:ok, %{position: position, state: state}} <- load(snapshot_binary) do
      tail = batches |> Enum.filter(&(&1.position > position)) |> Enum.flat_map(& &1.events)
      {:ok, Hall.replay(tail, state)}
    end
  end

  defp checksum(body), do: :crypto.hash(:sha256, body)
end
