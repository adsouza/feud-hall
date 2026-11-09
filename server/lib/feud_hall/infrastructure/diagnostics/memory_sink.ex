defmodule FeudHall.Infrastructure.Diagnostics.MemorySink do
  @moduledoc "Keeps emitted diagnostic records in order, for tests."
  @behaviour FeudHall.Application.Diagnostics

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end)

  @impl true
  def emit(sink, record) do
    Agent.cast(sink, &[record | &1])
    :ok
  end

  @doc "Records in emission order."
  def records(sink), do: sink |> Agent.get(& &1) |> Enum.reverse()
end
