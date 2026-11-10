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
    {earliest, _valid_for} = estimate_at(state, stall_id, new_components, now)
    %{earliest_completion: earliest}
  end

  @doc """
  For a single hypothetical course at `now`, returns
  `{completion, rate, valid_for}`: completion at that instant, how many ms
  it moves for every ms the order is delayed (0 or 1), and the number of ms
  this forecast is valid while the existing kitchen state stays fixed.
  """
  def completion_forecast(state, stall_id, course, now) do
    {time, valid_for} = estimate_at(state, stall_id, [course], {now, 1})
    {at(time), rate(time), valid_for}
  end

  defp estimate_at(state, stall_id, new_components, now) do
    %{prep_stations: prep_n, finish_stations: finish_n} = state.catalog.rules.kitchen
    handover = state.catalog.rules.handover_ms
    orders = live_orders(state, stall_id)
    next = next_seq(state)
    forecast? = is_tuple(now)

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

    prep_free = pad(for(o <- orders, o.status == :prep, do: o.stage_done_at), prep_n, now)

    {prep_queue, prep_order} =
      forecast_fifo(Enum.filter(orders, &(&1.status == :queued_prep)) ++ new, & &1.queued_at, forecast?)

    {prep_end, prep_assignment} = schedule(prep_queue, prep_free, & &1.queued_at, & &1.prep_ms, forecast?)

    finish_free = pad(for(o <- orders, o.status == :finish, do: o.stage_done_at), finish_n, now)

    release = fn o ->
      case o.status do
        :prep -> o.stage_done_at
        :queued_finish -> o.queued_at
        :queued_prep -> prep_end[o.id]
      end
    end

    {finish_queue, finish_order} =
      forecast_fifo(
        Enum.filter(orders, &(&1.status in [:queued_prep, :prep, :queued_finish])) ++ new,
        release,
        forecast?
      )

    {finish_end, finish_assignment} = schedule(finish_queue, finish_free, release, & &1.finish_ms, forecast?)

    done_at = fn o ->
      case o.status do
        :finish -> o.stage_done_at
        :ready -> o.ready_at
        _ -> finish_end[o.id]
      end
    end

    counter = Map.get(state.stalls[stall_id], :counter)
    in_hand = counter && counter.item

    {items, readiness} =
      (orders ++ new)
      |> Enum.group_by(&item_key/1)
      |> Map.delete(in_hand)
      |> Enum.map_reduce(:infinity, fn {key, os}, bound ->
        {ready, stable} = latest(Enum.map(os, done_at))
        {%{key: key, ready: ready, seq: min_seq(os)}, min(stable, bound)}
      end)

    {items, counter_order} = forecast_fifo(items, & &1.ready, forecast?)
    initial = if(counter, do: counter.done_at, else: now)

    {ends, _free, counter_assignment} =
      Enum.reduce(items, {%{}, initial, :infinity}, fn item, {ends, free, bound} ->
        {start, stable} = later(free, item.ready)
        finish_at = add(start, handover)
        {Map.put(ends, item.key, finish_at), finish_at, min(bound, stable)}
      end)

    bound =
      Enum.min([
        prep_order,
        prep_assignment,
        finish_order,
        finish_assignment,
        readiness,
        counter_order,
        counter_assignment
      ])

    {ends[:new], bound}
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

  # Legacy combined preparations can temporarily exceed the finish station
  # count. The extra stations retire as they free up.
  defp pad(free, n, now) do
    if length(free) > n,
      do: free |> Enum.sort() |> Enum.take(-n),
      else: free ++ List.duplicate(now, n - length(free))
  end

  # Track when an affine time can change the result of a comparison.
  # `nil` is never a time, and the :infinity atom sorts after integer bounds.
  defp at({value, _rate}), do: value
  defp at(value), do: value

  defp rate({_value, rate}), do: rate
  defp rate(_value), do: 0

  defp add({value, rate}, duration), do: {value + duration, rate}
  defp add(value, duration), do: value + duration

  defp ordered_through(a, b, tie_ok?) do
    if rate(a) > rate(b), do: at(b) - at(a) - if(tie_ok?, do: 0, else: 1), else: :infinity
  end

  defp forecast_fifo(items, release, false), do: {fifo(items, release), :infinity}

  defp forecast_fifo(items, release, true) do
    sorted = Enum.sort_by(items, &{at(release.(&1)), &1.seq})

    stable =
      sorted
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(:infinity, fn [a, b], bound ->
        min(bound, ordered_through(release.(a), release.(b), a.seq < b.seq))
      end)

    {sorted, stable}
  end

  defp later(a, b) when is_integer(a) and is_integer(b), do: {max(a, b), :infinity}

  defp later(a, b) do
    {earlier, later} = if {at(a), rate(a)} <= {at(b), rate(b)}, do: {a, b}, else: {b, a}
    {later, ordered_through(earlier, later, true)}
  end

  defp latest([first | rest]) do
    Enum.reduce(rest, {first, :infinity}, fn time, {latest, bound} ->
      {last, stable} = later(time, latest)
      {last, min(bound, stable)}
    end)
  end

  # FIFO jobs take the earliest-free station, each no earlier than its release.
  defp schedule(jobs, free, release, duration, false) do
    {ends, _free} =
      Enum.reduce(jobs, {%{}, free}, fn job, {ends, free} ->
        earliest = Enum.min(free)
        finish_at = max(earliest, release.(job)) + duration.(job)
        {Map.put(ends, job.id, finish_at), [finish_at | List.delete(free, earliest)]}
      end)

    {ends, :infinity}
  end

  defp schedule(jobs, free, release, duration, true) do
    {ends, _free, bound} =
      Enum.reduce(jobs, {%{}, free, :infinity}, fn job, {ends, free, bound} ->
        earliest = Enum.min_by(free, &{at(&1), rate(&1)})
        rest = List.delete(free, earliest)
        assignment = Enum.reduce(rest, bound, &min(&2, ordered_through(earliest, &1, true)))
        {start, stable} = later(earliest, release.(job))
        finish_at = add(start, duration.(job))
        {Map.put(ends, job.id, finish_at), [finish_at | rest], min(assignment, stable)}
      end)

    {ends, bound}
  end
end
