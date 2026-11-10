defmodule FeudHall.Web.RateLimit do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def allow?(key, limit) do
    minute = System.monotonic_time(:second) |> Integer.floor_div(60)
    :ets.update_counter(__MODULE__, {key, minute}, {2, 1}, {{key, minute}, 0}) <= limit
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, nil}
  end

  @impl true
  def handle_info(:cleanup, state) do
    minute = System.monotonic_time(:second) |> Integer.floor_div(60)
    :ets.select_delete(__MODULE__, [{{{:_, :"$1"}, :_}, [{:<, :"$1", minute - 1}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 60_000)
end
