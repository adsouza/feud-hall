defmodule FeudHall.MutationFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_opts), do: {:ok, %{assertions: [], harness: []}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, state) do
    id = Exception.format_mfa(test.module, test.name, 1)

    case Enum.find(failures, &(not behavioral_assertion?(&1, test))) do
      nil ->
        {:noreply, %{state | assertions: [id | state.assertions]}}

      {kind, reason, _stack} ->
        failure = "#{id} #{Exception.format_banner(kind, reason)}"
        {:noreply, %{state | harness: [failure | state.harness]}}
    end
  end

  def handle_cast({:test_module_finished, %ExUnit.TestModule{state: {:failed, _}} = module}, state),
    do: {:noreply, %{state | harness: ["module setup failed in #{inspect(module.name)}" | state.harness]}}

  def handle_cast({:suite_finished, _times}, state) do
    assertions = Enum.map(Enum.reverse(state.assertions), &["FEUD_HALL_MUTATION_ASSERTION ", &1, "\n"])
    harness = Enum.map(Enum.reverse(state.harness), &["FEUD_HALL_MUTATION_HARNESS ", &1, "\n"])
    IO.puts(["\n", assertions, harness, "FEUD_HALL_MUTATION_FINISHED"])
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # A setup callback can raise ExUnit.AssertionError too. Require a frame
  # from the actual test body, including closures compiled inside that body.
  defp behavioral_assertion?({:error, %ExUnit.AssertionError{}, stack}, %{module: module, name: name}) do
    Enum.any?(stack, fn
      {^module, ^name, _arity, _loc} -> true
      {^module, fun, _arity, _loc} -> String.starts_with?(Atom.to_string(fun), "-#{name}/1-")
      _ -> false
    end)
  end

  defp behavioral_assertion?(_, _test), do: false
end
