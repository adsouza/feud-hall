defmodule FeudHall.Application.Replay do
  @moduledoc "Restores a complete committed cut without running live transitions."

  alias FeudHall.Domain.{Control, Hall}
  alias FeudHall.Domain.Hall.Invariants

  @genesis %{position: 0, hall: nil, control: nil}
  @page_size 128

  def load(store_mod, store, opts \\ []) do
    base = Keyword.get(opts, :base, @genesis)
    initial = {base.hall, base.control, %{hall: 0, control: 0}}

    with head when is_integer(head) <- Keyword.get_lazy(opts, :head, fn -> store_mod.head(store) end),
         {:ok, {hall, control, counts}} <- restore(store_mod, store, base.position, head, initial),
         :ok <- check(hall),
         %{} = versions <- store_mod.stream_versions(store, hall_stream(hall)),
         :ok <- same_head(store_mod.head(store), head),
         :ok <- check_versions(base, counts, versions) do
      {:ok, %{hall: hall, control: control, position: head, versions: versions, tail_batches: head - base.position}}
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

  defp restore(store_mod, store, after_position, head, state) do
    if function_exported?(store_mod, :read_page, 4) do
      page(store_mod, store, after_position, head, state)
    else
      with {:ok, batches} <- store_mod.read_from(store, after_position),
           :ok <- contiguous(batches, after_position + 1, head),
           do: {:ok, fold(batches, state)}
    end
  end

  defp page(_store_mod, _store, head, head, state), do: {:ok, state}
  defp page(_store_mod, _store, cursor, head, _state) when cursor > head, do: {:error, :conflict}

  defp page(store_mod, store, cursor, head, state) do
    with {:ok, [_ | _] = batches} <- store_mod.read_page(store, cursor, head, @page_size),
         %{position: last} when last <= head <- List.last(batches),
         :ok <- contiguous(batches, cursor + 1, last) do
      page(store_mod, store, last, head, fold(batches, state))
    else
      {:ok, []} -> {:error, {:missing_batch, cursor + 1}}
      %{position: beyond} -> {:error, {:batch_beyond_head, beyond}}
      {:error, _} = error -> error
    end
  end

  defp fold(batches, state) do
    Enum.reduce(batches, state, fn batch, {hall, control, counts} ->
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
