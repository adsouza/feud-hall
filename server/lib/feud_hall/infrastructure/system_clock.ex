defmodule FeudHall.Infrastructure.SystemClock do
  @moduledoc "The runtime's monotonic clock (`System.monotonic_time(:millisecond)`); the ref is ignored."
  @behaviour FeudHall.Application.MonotonicClock

  @impl true
  def now_ms(_ref), do: System.monotonic_time(:millisecond)
end
