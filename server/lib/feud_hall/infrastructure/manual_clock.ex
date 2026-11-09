defmodule FeudHall.Infrastructure.ManualClock do
  @moduledoc """
  A monotonic clock that moves only when told to, so scheduling tests are
  deterministic without sleeping. Use it as `{ManualClock, pid}`.
  """
  @behaviour FeudHall.Application.MonotonicClock

  use Agent

  @doc "Starts a clock reading `start_ms`."
  def start_link(start_ms \\ 0) when is_integer(start_ms), do: Agent.start_link(fn -> start_ms end)

  @doc "Moves the clock forward by `ms` (never backwards); returns the new reading."
  def advance(clock, ms) when is_integer(ms) and ms >= 0, do: Agent.get_and_update(clock, &{&1 + ms, &1 + ms})

  @impl true
  def now_ms(clock), do: Agent.get(clock, & &1)
end
