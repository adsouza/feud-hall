defmodule FeudHall.Domain.Clock do
  @moduledoc """
  The hall's two gameplay clocks and the fixed daily calendar.

  * **Hall time** runs at 24x real time while the service is available and
    drives cooking, freshness, opening hours, cleaning, and calendar boundaries.
  * **Available-service time** runs at 1x while the service is available and
    pauses during platform downtime. Player-rights windows such as the dessert
    choice window are declared in it.

  Both clocks advance only while the service is ready and both pause during
  downtime, so they stay exactly proportional. The domain therefore keeps one
  master tick, `hall_ms`, and converts service-time quantities explicitly with
  `service_duration/1` and `service_ms/1`. A duration cannot silently cross
  clocks: content declares hall durations, and service durations must pass
  through this module. Wall/monotonic time never enters the domain; the shell
  turns observed elapsed time into an explicit service-time target.

  A new hall starts at day 0, 00:00 hall time and 0 service time.
  """

  @ratio 24
  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour
  @cleaning_start 3 * @hour
  @cleaning_end 5 * @hour

  def ratio, do: @ratio
  def minute, do: @minute
  def hour, do: @hour
  def day, do: @day

  @doc "Converts an available-service duration (ms) into hall-time ticks."
  @spec service_duration(non_neg_integer()) :: non_neg_integer()
  def service_duration(service_ms) when is_integer(service_ms) and service_ms >= 0,
    do: service_ms * @ratio

  @doc "Hall tick at a given available-service instant."
  @spec hall_at_service(non_neg_integer()) :: non_neg_integer()
  def hall_at_service(service_ms), do: service_duration(service_ms)

  @doc "Available-service instant (ms, rounded down) at a hall tick."
  @spec service_ms(non_neg_integer()) :: non_neg_integer()
  def service_ms(hall_ms), do: div(hall_ms, @ratio)

  @doc "Game day index of a hall timestamp."
  def day_of(hall_ms), do: div(hall_ms, @day)

  @doc "Milliseconds since the most recent 00:00."
  def time_of_day(hall_ms), do: rem(hall_ms, @day)

  @doc "Hall cleaning is the half-open window [03:00, 05:00) every game day."
  @spec cleaning?(non_neg_integer()) :: boolean()
  def cleaning?(hall_ms) do
    tod = time_of_day(hall_ms)
    tod >= @cleaning_start and tod < @cleaning_end
  end

  @doc "03:00 of the given day."
  def cleaning_start_of(day), do: day * @day + @cleaning_start

  @doc "05:00 of the given day."
  def cleaning_end_of(day), do: day * @day + @cleaning_end

  @doc "The first 03:00 cutoff strictly after `hall_ms`."
  def next_cleaning_start(hall_ms), do: next_boundary(hall_ms, @cleaning_start)

  @doc "The first 05:00 reopening strictly after `hall_ms`."
  def next_cleaning_end(hall_ms), do: next_boundary(hall_ms, @cleaning_end)

  @doc """
  The 03:00 cutoff that bounds customer service starting at `hall_ms`: the
  next one, or `hall_ms` itself when it is exactly 03:00.
  """
  def service_cutoff(hall_ms) do
    if time_of_day(hall_ms) == @cleaning_start,
      do: hall_ms,
      else: next_cleaning_start(hall_ms)
  end

  defp next_boundary(hall_ms, offset) do
    candidate = day_of(hall_ms) * @day + offset
    if candidate > hall_ms, do: candidate, else: candidate + @day
  end

  @doc "Format a hall timestamp as `day D HH:MM` for messages and debugging."
  def format(hall_ms) do
    tod = time_of_day(hall_ms)
    "day #{day_of(hall_ms)} #{pad(div(tod, @hour))}:#{pad(div(rem(tod, @hour), @minute))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
