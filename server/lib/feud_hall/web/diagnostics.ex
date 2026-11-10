defmodule FeudHall.Web.Diagnostics do
  @moduledoc false
  require Logger

  def export(records) do
    Enum.each(records, fn record -> Logger.info(fn -> Jason.encode!(record) end) end)
    :ok
  end
end
