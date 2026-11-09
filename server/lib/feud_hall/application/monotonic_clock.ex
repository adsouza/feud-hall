defmodule FeudHall.Application.MonotonicClock do
  @moduledoc """
  The monotonic-clock port. A clock is `{module, ref}`; `module.now_ms(ref)`
  returns a monotonic instant in milliseconds. Only differences between two
  readings of the same clock are meaningful: the hall authority turns them into
  elapsed available-service time while it is ready. Wall time never enters the
  domain through this port.
  """

  @callback now_ms(clock :: term()) :: integer()
end
