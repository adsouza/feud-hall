defmodule FeudHall.Application.Replay do
  @moduledoc "Restores a complete committed cut without running live transitions."

  alias FeudHall.Domain.{Control, Hall}
  alias FeudHall.Domain.Hall.Invariants

  @genesis %{position: 0, hall: nil, control: nil}

  def load(store_mod, store, opts \\ []) do
    base = Keyword.get(opts, :base, @genesis)

    with head when is_integer(head) <- Keyword.get_lazy(opts, :head, fn -> store_mod.head(store) end),
         {:ok, batches} <- store_mod.read_from(store, base.position),
         :ok <- contiguous(batches, base.position + 1, head),
         {hall, control, counts} <- fold(base, batches),
         :ok <- check(hall),
         %{} = versions <- store_mod.stream_versions(store, hall_stream(hall)),
         :ok <- same_head(store_mod.head(store), head),
         :ok <- check_versions(base, counts, versions) do
      {:ok, %{hall: hall, control: control, position: head, versions: versions, tail_batches: length(batches)}}
    end
  end

  def hall_stream(nil), do: nil
  def hall_stream(%{hall_id: id}), do: "hall:" <> id

  defp contiguous([], next, head) when next == head + 1, do: :ok
  defp contiguous([], next, _head), do: {:error, {:missing_batch, next}}

  defp contiguous([%{position: position} | _], _, head) when position > head,
    do: {:error, {:batch_beyond_head, position}}

  defp contiguous([%{position: next} | rest], next, head), do: contiguous(rest, next + 1, head)
  defp contiguous(_, next, _head), do: {:error, {:missing_batch, next}}

  defp fold(base, batches) do
    Enum.reduce(batches, {base.hall, base.control, %{hall: 0, control: 0}}, fn batch, {hall, control, counts} ->
      {Hall.replay(batch.events, hall), Control.replay(batch.control_events, control),
       %{hall: counts.hall + length(batch.events), control: counts.control + length(batch.control_events)}}
    end)
  end

  defp check(hall) do
    with {:error, problems} <- Invariants.check(hall), do: {:error, {:invariants, problems}}
  end

  defp same_head(head, head), do: :ok
  defp same_head({:error, _} = error, _head), do: error
  defp same_head(_observed, _head), do: {:error, :conflict}

  defp check_versions(%{position: 0}, counts, counts), do: :ok

  defp check_versions(%{versions: %{hall: hall, control: control}}, counts, versions)
       when is_integer(hall) and hall >= 0 and is_integer(control) and control >= 0 and
              hall + counts.hall == versions.hall and control + counts.control == versions.control,
       do: :ok

  # Older verified snapshots lack prefix counters. Check the tail and ensure
  # at least one stream event accounts for each batch covered by the snapshot.
  defp check_versions(%{position: position, versions: nil}, counts, versions)
       when position > 0 and counts.hall <= versions.hall and counts.control <= versions.control and
              versions.hall + versions.control - counts.hall - counts.control >= position,
       do: :ok

  defp check_versions(_base, _counts, _versions), do: {:error, :stream_version_mismatch}
end
