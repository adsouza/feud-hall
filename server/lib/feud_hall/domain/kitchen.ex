defmodule FeudHall.Domain.Kitchen do
  @moduledoc """
  Pure model of a stall's automatic kitchen: the queue-aware completion
  estimate shared by quotes, acceptance and diner choice, and the dispatch
  decisions the clock advance takes. Both read the same FIFO keys, so the
  estimate is exact for the work already queued. It stays exact afterwards
  only while no later order overtakes: the finish queue is ordered by prep
  completion and the counter by ready time, so a later order with a shorter
  prep (or, with several finish stations, a shorter finish) can be served
  ahead of an earlier quoted one and push it back.

  A live order's `status` is its work stage: `:queued_prep | :prep |
  :queued_finish | :finish | :ready` (then `:served` or `:cancelled`). It
  carries `queued_at` (when it joined its current queue: acceptance for prep,
  prep completion for finish), an acceptance sequence number `seq`, `prep_ms`
  and `finish_ms` bound at acceptance, `stage_done_at` while it occupies a
  station, and `ready_at` once finished. A stall has `counter: nil |
  %{item: {:tray, tray_id} | {:dessert, order_id}, done_at}` for the handover
  in progress. Station counts, handover time and the queue limit come from
  validated catalog content.

  FIFO rules: each stage queue is served by `{queued_at, seq}` on the
  earliest-free station; the counter takes the item whose last component
  became ready first, ties by its first component's `seq`. A new order's
  `seq` is the hall's `order_seq`, the counter the evolver numbers accepted
  orders with, so it sorts after every order already accepted and no number
  is reused after finished orders leave live state.
  """

  @stages [:queued_prep, :prep, :queued_finish, :finish, :ready]

  @doc "The live work stages, in order."
  def stages, do: @stages

  @doc """
  Earliest hall time a new tray (or dessert) made of `new_components`
  (`%{prep_ms, finish_ms}`) finishes its handover at `stall_id`.

  A deterministic list-scheduling simulation of the stall from its current
  state, using the same FIFO keys as `next_start/2`.
  """
  def estimate(state, stall_id, new_components, now) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    handover = state.catalog.rules.handover_ms
    orders = live_orders(state, stall_id)
    next = next_seq(state)

    new =
      new_components
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        %{
          id: {:new, i},
          item: :new,
          status: :queued_prep,
          seq: next + i,
          queued_at: now,
          prep_ms: c.prep_ms,
          finish_ms: c.finish_ms
        }
      end)

    # 1. Prep stations.
    prep_free = pad(for(o <- orders, o.status == :prep, do: o.stage_done_at), prep_n, now)
    prep_queue = fifo(Enum.filter(orders, &(&1.status == :queued_prep)) ++ new, & &1.queued_at)
    prep_end = schedule(prep_queue, prep_free, & &1.queued_at, & &1.prep_ms)

    # 2. Finish stations, released when prep ends.
    finish_free = pad(for(o <- orders, o.status == :finish, do: o.stage_done_at), finish_n, now)

    release = fn o ->
      case o.status do
        :prep -> o.stage_done_at
        :queued_finish -> o.queued_at
        :queued_prep -> prep_end[o.id]
      end
    end

    finish_queue = fifo(Enum.filter(orders, &(&1.status in [:queued_prep, :prep, :queued_finish])) ++ new, release)
    finish_end = schedule(finish_queue, finish_free, release, & &1.finish_ms)

    done_at = fn o ->
      case o.status do
        :finish -> o.stage_done_at
        :ready -> o.ready_at
        _ -> finish_end[o.id]
      end
    end

    # 3. Counter: an item is ready when its last component is.
    counter = Map.get(state.stalls[stall_id], :counter)
    in_hand = counter && counter.item

    items =
      (orders ++ new)
      |> Enum.group_by(&item_key/1)
      |> Map.delete(in_hand)
      |> Enum.map(fn {key, os} -> %{key: key, ready: os |> Enum.map(done_at) |> Enum.max(), seq: min_seq(os)} end)
      |> fifo(& &1.ready)

    {ends, _free} =
      Enum.reduce(items, {%{}, if(counter, do: counter.done_at, else: now)}, fn item, {ends, free} ->
        finish_at = max(free, item.ready) + handover
        {Map.put(ends, item.key, finish_at), finish_at}
      end)

    %{earliest_completion: ends[:new]}
  end

  @doc """
  The next piece of work the stall can start at hall time `state.now`, or
  `nil`: `{:prep, order_id}` or `{:finish, order_id}` when a station is free
  and its queue is not empty, otherwise `{:handover, item}` when the counter
  is free and an item has all components ready. Callers apply the started
  work and ask again until `nil`.
  """
  def next_start(state, stall_id) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    orders = live_orders(state, stall_id)
    count = fn status -> Enum.count(orders, &(&1.status == status)) end

    cond do
      count.(:prep) < prep_n and count.(:queued_prep) > 0 ->
        {:prep, head(orders, :queued_prep).id}

      count.(:finish) < finish_n and count.(:queued_finish) > 0 ->
        {:finish, head(orders, :queued_finish).id}

      Map.get(state.stalls[stall_id], :counter) == nil ->
        orders
        |> Enum.group_by(&item_key/1)
        |> Enum.filter(fn {_key, os} -> Enum.all?(os, &(&1.status == :ready)) end)
        |> Enum.map(fn {key, os} ->
          %{key: key, ready: os |> Enum.map(& &1.ready_at) |> Enum.max(), seq: min_seq(os)}
        end)
        |> fifo(& &1.ready)
        |> case do
          [first | _] -> {:handover, first.key}
          [] -> nil
        end

      true ->
        nil
    end
  end

  @doc "Stall IDs holding live kitchen work, sorted."
  def busy_stalls(state) do
    state.orders
    |> Map.values()
    |> Enum.filter(&(&1.status in @stages))
    |> Enum.map(&stall_of(state, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The sequence number the evolver gives the next accepted order."
  def next_seq(state), do: state.order_seq

  @doc """
  Whether the stall can take another customer order: accepted-but-unserved
  trays plus unfinished desserts must stay below the content's queue limit.
  """
  def accepting?(state, stall_id) do
    trays = Enum.count(state.trays, fn {_id, t} -> t.stall == stall_id and t.status == :accepted end)

    desserts =
      Enum.count(state.orders, fn {_id, o} ->
        o.kind == :dessert and o.status in @stages and stall_of(state, o) == stall_id
      end)

    trays + desserts < state.catalog.rules.kitchen.queue_limit
  end

  # -- helpers -------------------------------------------------------------

  defp live_orders(state, stall_id) do
    state.orders
    |> Map.values()
    |> Enum.filter(&(&1.status in @stages and stall_of(state, &1) == stall_id))
  end

  defp stall_of(state, order), do: get_in(state, [:visits, order.visit, :stall])

  defp head(orders, status), do: orders |> Enum.filter(&(&1.status == status)) |> fifo(& &1.queued_at) |> hd()

  # The one FIFO order every queue uses: by time, then acceptance sequence.
  defp fifo(jobs, time), do: Enum.sort_by(jobs, &{time.(&1), &1.seq})

  defp min_seq(orders), do: orders |> Enum.map(& &1.seq) |> Enum.min()

  defp item_key(%{item: :new}), do: :new
  defp item_key(%{kind: :dessert, id: id}), do: {:dessert, id}
  defp item_key(%{tray: tray}), do: {:tray, tray}

  # Station free times, padded with `now` up to the station count.
  defp pad(free, n, now), do: free ++ List.duplicate(now, max(n - length(free), 0))

  # Runs FIFO-ordered jobs on the earliest-free station, each not before its
  # release; returns each job's end time.
  defp schedule(jobs, free, release, duration) do
    {ends, _free} =
      Enum.reduce(jobs, {%{}, free}, fn job, {ends, free} ->
        {earliest, rest} = pop_min(free)
        finish_at = max(earliest, release.(job)) + duration.(job)
        {Map.put(ends, job.id, finish_at), [finish_at | rest]}
      end)

    ends
  end

  defp pop_min(list) do
    min = Enum.min(list)
    {min, List.delete(list, min)}
  end
end
