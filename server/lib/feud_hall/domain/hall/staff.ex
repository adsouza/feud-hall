defmodule FeudHall.Domain.Hall.Staff do
  @moduledoc "The roster names one role and one duty window per worker."
  alias FeudHall.Domain.Clock

  @roles [:prep_cook, :finish_cook, :counter]
  @hire_fee 1_000
  @roster_limit 9
  @tired_after 8 * Clock.hour()
  @break_after 10 * Clock.hour()

  def hire_fee, do: @hire_fee
  def max_roster, do: @roster_limit

  def worker(id, role, start, finish, starter?) do
    %{
      id: id,
      role: role,
      start_hour: start,
      end_hour: finish,
      starter: starter?,
      fatigue_ms: 0,
      tired: false,
      break_until: nil
    }
  end

  def role?(role), do: role in @roles

  def schedule?(start, finish) when is_integer(start) and is_integer(finish),
    do: start in 0..23 and finish in 0..24 and rem(finish - start + 24, 24) in 1..12

  def schedule?(_, _), do: false

  def starter(stall, start, finish) do
    Map.new(@roles, fn role ->
      id = "#{stall}:#{role}"
      {id, worker(id, role, start, finish, true)}
    end)
  end

  def active(roster, at) do
    hour = div(rem(at, Clock.day()), Clock.hour())

    roster
    |> Map.values()
    |> Enum.filter(fn %{start_hour: start, end_hour: finish, break_until: pause} ->
      is_nil(pause) and
        if start < finish, do: hour >= start and hour < finish, else: hour >= start or hour < finish
    end)
    |> Enum.sort_by(& &1.id)
  end

  def covered?(roster, at) do
    active_roles = roster |> active(at) |> MapSet.new(& &1.role)
    Enum.all?(@roles, &MapSet.member?(active_roles, &1))
  end

  def support(roster, now), do: Enum.find(active(roster, now), &(&1.role == :counter))

  def accrue(roster, elapsed, working) do
    Map.new(roster, fn {id, worker} ->
      fatigue =
        if MapSet.member?(working, id), do: worker.fatigue_ms + elapsed, else: max(0, worker.fatigue_ms - 3 * elapsed)

      {id, %{worker | fatigue_ms: fatigue}}
    end)
  end

  def boundaries(roster, now, working) do
    Enum.flat_map(roster, fn {id, worker} ->
      case worker do
        %{break_until: at} when is_integer(at) ->
          [{at, id, :recovered}]

        %{fatigue_ms: fatigue} when fatigue >= @break_after ->
          [{now, id, :protective_break}]

        %{fatigue_ms: fatigue, tired: tired} ->
          if MapSet.member?(working, id) do
            break_at = now + @break_after - fatigue

            if tired,
              do: [{break_at, id, :protective_break}],
              else: [{max(now, now + @tired_after - fatigue), id, :tired}]
          else
            if tired, do: [{now + div(max(fatigue - @tired_after, 0) + 2, 3), id, :rested}], else: []
          end
      end
    end)
  end

  def transition(worker, :tired, _now), do: %{worker | tired: true}
  def transition(worker, :rested, _now), do: %{worker | tired: false}
  def transition(worker, :protective_break, now), do: %{worker | break_until: now + Clock.hour()}
  def transition(worker, :recovered, _now), do: %{worker | break_until: nil, tired: worker.fatigue_ms >= @tired_after}

  def adapt_course(roster, now, course) do
    staff = active(roster, now)
    prep_tired? = tired_role?(staff, :prep_cook)
    finish_tired? = tired_role?(staff, :finish_cook)
    %{course | prep_ms: slowed(course.prep_ms, prep_tired?), finish_ms: slowed(course.finish_ms, finish_tired?)}
  end

  defp tired_role?(staff, role) do
    workers = Enum.filter(staff, &(&1.role == role))
    workers != [] and Enum.all?(workers, & &1.tired)
  end

  defp slowed(ms, true), do: ms + div(ms + 9, 10)
  defp slowed(ms, false), do: ms

  def ends_at(%{end_hour: finish, fatigue_ms: fatigue}, now) do
    at = Clock.day_of(now) * Clock.day() + finish * Clock.hour()
    shift_end = if at <= now, do: at + Clock.day(), else: at
    min(shift_end, now + max(0, @break_after - fatigue))
  end
end
