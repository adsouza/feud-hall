defmodule FeudHall.Domain.Kitchen do
  @moduledoc """
  Pure model of a stall's kitchen queue, shared by quotes, acceptance and
  diner choice so they all see the same wait.

  Each live order carries a work stage: `:queued_prep | :prep | :queued_finish
  | :finish | :ready`, with `queued_at`, `prep_ms` and `finish_ms` copied from
  the accepted quote, and `stage_done_at` while it occupies a station. A stall
  has `counter: nil | %{item: {:tray, tray_id} | {:dessert, order_id}, done_at}`
  for the handover in progress. Station counts, handover time and the queue
  limit come from validated catalog content.

  Orders without a `:stage` key are not part of the model and are ignored, so
  an empty kitchen estimates `now + prep + finish + handover` for one main.
  """

  @finished [:served, :cancelled]

  @doc """
  Earliest hall time a new tray (or dessert) made of `new_components`
  (`%{prep_ms, finish_ms}`) finishes its handover at `stall_id`.

  A deterministic list-scheduling simulation: prep stations, then finish
  stations (each served FIFO by release time then ID), then the single
  counter (FIFO by ready time), starting from the stall's current state.
  """
  def estimate(state, stall_id, new_components, now) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    handover = state.catalog.rules.handover_ms
    orders = live_orders(state, stall_id)

    new =
      new_components
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> %{key: {:new, i}, prep_ms: c.prep_ms, finish_ms: c.finish_ms} end)

    # 1. Prep stations.
    prep_free = pad(for(o <- orders, o.stage == :prep, do: o.stage_done_at), prep_n, now)

    prep_queue =
      orders
      |> Enum.filter(&(&1.stage == :queued_prep))
      |> Enum.sort_by(&{&1.queued_at, &1.id})
      |> Enum.map(&%{key: &1.id, prep_ms: &1.prep_ms})

    {prep_end, _} =
      Enum.reduce(prep_queue ++ new, {%{}, prep_free}, fn job, {ends, free} ->
        {finish_at, free} = assign(free, now, job.prep_ms)
        {Map.put(ends, job.key, finish_at), free}
      end)

    # 2. Finish stations.
    finish_free = pad(for(o <- orders, o.stage == :finish, do: o.stage_done_at), finish_n, now)

    released =
      Enum.flat_map(orders, fn o ->
        case o.stage do
          :prep -> [{o.stage_done_at, 0, o.id, o.id, o.finish_ms}]
          :queued_prep -> [{prep_end[o.id], 0, o.id, o.id, o.finish_ms}]
          :queued_finish -> [{now, 0, o.id, o.id, o.finish_ms}]
          _ -> []
        end
      end) ++ Enum.map(new, &{prep_end[&1.key], 1, "", &1.key, &1.finish_ms})

    {finish_end, _} =
      released
      |> Enum.sort_by(fn {release, rank, id, _key, _ms} -> {release, rank, id} end)
      |> Enum.reduce({%{}, finish_free}, fn {release, _rank, _id, key, ms}, {ends, free} ->
        {finish_at, free} = assign(free, release, ms)
        {Map.put(ends, key, finish_at), free}
      end)

    done_at = fn o ->
      case o.stage do
        :finish -> o.stage_done_at
        :ready -> now
        _ -> finish_end[o.id]
      end
    end

    # 3. Counter: items are ready when their last component is.
    counter = state.stalls[stall_id] |> Map.get(:counter)
    in_hand = counter && counter.item

    existing_items =
      orders
      |> Enum.group_by(&item_key/1)
      |> Map.delete(in_hand)
      |> Enum.map(fn {key, os} -> {os |> Enum.map(done_at) |> Enum.max(), 0, key} end)

    new_ready = new |> Enum.map(&finish_end[&1.key]) |> Enum.max()

    counter_free = if counter, do: counter.done_at, else: now

    {handover_end, _} =
      [{new_ready, 1, :new} | existing_items]
      |> Enum.sort_by(fn {ready, rank, key} -> {ready, rank, key} end)
      |> Enum.reduce({%{}, counter_free}, fn {ready, _rank, key}, {ends, free} ->
        finish_at = max(free, ready) + handover
        {Map.put(ends, key, finish_at), finish_at}
      end)

    %{earliest_completion: handover_end[:new]}
  end

  @doc """
  Whether the stall can take another customer order: accepted-but-unserved
  trays plus unfinished desserts must stay below the content's queue limit.
  """
  def accepting?(state, stall_id) do
    trays = Enum.count(state.trays, fn {_id, t} -> t.stall == stall_id and t.status == :accepted end)

    desserts =
      Enum.count(state.orders, fn {_id, o} ->
        o.kind == :dessert and o.status not in @finished and stall_of(state, o) == stall_id
      end)

    trays + desserts < state.catalog.rules.kitchen.queue_limit
  end

  # -- helpers -------------------------------------------------------------

  defp live_orders(state, stall_id) do
    state.orders
    |> Map.values()
    |> Enum.filter(&(Map.has_key?(&1, :stage) and &1.status not in @finished and stall_of(state, &1) == stall_id))
  end

  defp stall_of(state, order), do: get_in(state, [:visits, order.visit, :stall])

  defp item_key(%{kind: :dessert, id: id}), do: {:dessert, id}
  defp item_key(%{tray: tray}), do: {:tray, tray}

  # Station free times, padded with `now` up to the station count.
  defp pad(free, n, now), do: free ++ List.duplicate(now, max(n - length(free), 0))

  # Starts a job at the earliest-free station (not before `release`); returns
  # its end and the updated station free times.
  defp assign(free, release, duration) do
    {earliest, rest} = pop_min(free)
    finish_at = max(earliest, release) + duration
    {finish_at, [finish_at | rest]}
  end

  defp pop_min(list) do
    min = Enum.min(list)
    {min, List.delete(list, min)}
  end
end
