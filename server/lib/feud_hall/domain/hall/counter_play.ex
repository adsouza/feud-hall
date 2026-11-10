defmodule FeudHall.Domain.Hall.CounterPlay do
  @moduledoc "Exclusive counter staging and one-use handover setup credit."

  alias FeudHall.Domain.{Clock, Kitchen}
  alias FeudHall.Domain.Hall.{Management, Staff}

  @duration Clock.service_duration(2_000)
  @commands [:start_counter_staging, :yield_counter_staging]
  def commands, do: @commands

  def enable(%{management: _} = state) do
    if Map.has_key?(state, :counter_play),
      do: {:error, :already_enabled},
      else: {:ok, [%{type: :visitor_play_enabled, duration: @duration}]}
  end

  def enable(_state), do: {:error, :management_unavailable}

  def enabled?(state), do: Map.has_key?(state, :counter_play)
  def task(state, sid), do: get_in(state, [:counter_play, :tasks, sid])
  def prepared(state, sid), do: get_in(state, [:counter_play, :prepared, sid])

  def decide(state, {kind, %{shift_id: id} = payload}, %{actor: {:principal, principal}, command_id: command})
      when kind in @commands do
    with %{principal: ^principal, status: :active, stall_id: sid, presence_until: until, expires_at: expires} <-
           get_in(state, [:management, :shifts, id]),
         ^id <- get_in(state, [:management, :shift_by_stall, sid]),
         true <- state.now < min(until, expires) do
      case kind do
        :start_counter_staging ->
          case offer(state, sid, id) do
            nil -> {:error, :staging_unavailable}
            ends -> {:ok, [started(state, sid, id, ends, "S:" <> command)]}
          end

        :yield_counter_staging ->
          with %{id: claim, shift_id: ^id} <- task(state, sid),
               true <- claim == payload[:task_id] do
            yielded = ended(sid, claim, :staging_yielded)
            current = evolve(state, yielded)

            selection =
              if Kitchen.ready_items(current, sid) != [], do: Management.start_selection(current, sid)

            {:ok, [yielded | List.wrap(selection)]}
          else
            _ -> {:error, :staging_unavailable}
          end
      end
    else
      _ -> {:error, :staging_unavailable}
    end
  end

  def decide(_state, _command, _context), do: {:error, :staging_unavailable}

  def offer(%{counter_play: %{duration: duration}, access: :open} = state, sid, shift_id) do
    ends = state.now + duration
    lease = get_in(state, [:management, :leases, sid])
    shift = get_in(state, [:management, :shifts, shift_id])

    with %{mode: :open, counter: nil} <- state.stalls[sid],
         %{workers: workers} <- lease,
         true <- is_nil(shift_id) or (shift != nil and ends <= min(shift.expires_at, shift.presence_until)),
         nil <- task(state, sid),
         nil <- prepared(state, sid),
         nil <- get_in(state, [:management, :selections, sid]),
         :ok <- Management.allow_open(state, sid),
         %{id: worker} = support <- Staff.support(workers, state.now),
         true <- is_nil(shift) or worker == shift.worker_id,
         true <- ends <= Staff.ends_at(support, state.now),
         true <- ends < Clock.service_cutoff(state.now),
         [] <- Kitchen.ready_items(state, sid),
         [_ | _] = orders <- Kitchen.counter_orders(state, sid),
         true <- Enum.all?(orders, &(&1.deadline >= ends + state.catalog.rules.handover_ms)) do
      ends
    else
      _ -> nil
    end
  end

  def offer(_state, _sid, _shift_id), do: nil

  def automatic(state, sid) do
    if is_nil(get_in(state, [:management, :shift_by_stall, sid])) do
      case offer(state, sid, nil) do
        nil -> nil
        ends -> started(state, sid, nil, ends, "S:auto:#{sid}:#{state.now}")
      end
    end
  end

  defp started(state, sid, shift, ends, id) do
    worker = Staff.support(state.management.leases[sid].workers, state.now)
    %{type: :counter_staging_started, stall_id: sid, shift_id: shift, worker_id: worker.id, task_id: id, done_at: ends}
  end

  defp ended(sid, id, type), do: %{type: type, stall_id: sid, task_id: id}

  def completions(%{counter_play: play} = state) do
    for {sid, task} <- play.tasks,
        do: {max(state.now, task.done_at), sid, {:counter_staging_done, sid}}
  end

  def completions(_state), do: []

  def interruptions(%{counter_play: play} = state) do
    for {sid, task} <- play.tasks, interrupt?(state, sid, task), do: {state.now, sid, {:counter_staging_yield, sid}}
  end

  def interruptions(_state), do: []

  defp interrupt?(state, sid, task) do
    not valid?(state, sid, task, state.now) or
      case Kitchen.ready_items(state, sid) do
        [] ->
          Kitchen.counter_orders(state, sid) == []

        _ when is_nil(task.shift_id) ->
          true

        items ->
          Enum.any?(items, fn item ->
            item_deadline(state, item) < task.done_at + state.catalog.rules.handover_ms
          end)
      end
  end

  def finish(state, sid) do
    task = task(state, sid)

    outcome =
      if valid?(state, sid, task, state.now - 1) and Kitchen.counter_orders(state, sid) != [],
        do: :counter_staging_completed,
        else: :staging_yielded

    [ended(sid, task.id, outcome)]
  end

  def interrupt(state, sid), do: [ended(sid, task(state, sid).id, :staging_yielded)]

  defp valid?(state, sid, task, worked_at) do
    with :open <- state.access,
         %{mode: :open, counter: nil} <- state.stalls[sid],
         %{workers: workers} <- state.management.leases[sid],
         true <- get_in(state, [:management, :shift_by_stall, sid]) == task.shift_id do
      Enum.any?(Staff.active(workers, worked_at), &(&1.id == task.worker_id and &1.role == :counter))
    else
      _ -> false
    end
  end

  def item_orders(state, {:tray, id}), do: Enum.map(state.trays[id].components, &state.orders[&1])
  def item_orders(state, {:dessert, id}), do: [state.orders[id]]

  def item_deadline(state, item) do
    item
    |> then(&item_orders(state, &1))
    |> Enum.map(&min(&1.deadline, &1.ready_expires_at || &1.deadline))
    |> Enum.min()
  end

  def shorten(state, %{stall_id: sid} = handover) do
    case prepared(state, sid) do
      nil ->
        handover

      credit ->
        used = min(credit, max(0, handover.done_at - state.now - 1))
        Map.merge(handover, %{setup_credit: used, done_at: handover.done_at - used})
    end
  end

  def consume(state, %{stall_id: sid, setup_credit: _}) do
    update_in(state.counter_play.prepared, &Map.delete(&1, sid))
  end

  def consume(state, _event), do: state

  def clear_location(%{counter_play: _} = state, sid) do
    state
    |> update_in([:counter_play, :tasks], &Map.delete(&1, sid))
    |> update_in([:counter_play, :prepared], &Map.delete(&1, sid))
  end

  def clear_location(state, _sid), do: state

  def clear_task(%{counter_play: _} = state, sid),
    do: update_in(state.counter_play.tasks, &Map.delete(&1, sid))

  def clear_task(state, _sid), do: state

  def clear_tasks(%{counter_play: _} = state), do: put_in(state.counter_play.tasks, %{})
  def clear_tasks(state), do: state

  def clean(%{counter_play: _} = state) do
    state |> clear_tasks() |> put_in([:counter_play, :prepared], %{})
  end

  def clean(state), do: state

  def evolve(state, %{type: :visitor_play_enabled, duration: duration}),
    do: Map.put(state, :counter_play, %{duration: duration, tasks: %{}, prepared: %{}})

  def evolve(state, %{type: :counter_staging_started} = event) do
    task = %{id: event.task_id, shift_id: event.shift_id, worker_id: event.worker_id, done_at: event.done_at}
    put_in(state.counter_play.tasks[event.stall_id], task)
  end

  def evolve(state, %{type: :staging_yielded, stall_id: sid}), do: clear_task(state, sid)

  def evolve(state, %{type: :counter_staging_completed, stall_id: sid}) do
    task = task(state, sid)
    state = state |> clear_task(sid) |> put_in([:counter_play, :prepared, sid], state.counter_play.duration)

    if task.shift_id,
      do: update_in(state.management.shifts[task.shift_id], &Map.update(&1, :staged, 1, fn count -> count + 1 end)),
      else: state
  end
end
