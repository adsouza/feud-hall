defmodule FeudHall.ArchitectureTest do
  @moduledoc """
  Enforces dependency direction from source, not module names: the domain may
  not reference frameworks, persistence, processes, ambient clocks, global
  configuration, randomness without explicit state, or outer layers; the
  application layer may not reference infrastructure adapters.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../lib/feud_hall", __DIR__)

  # Module prefixes (as alias segments) and Erlang modules the domain must not touch.
  @domain_forbidden_aliases [
    ~w(Phoenix),
    ~w(Ecto),
    ~w(Postgrex),
    ~w(GenServer),
    ~w(Agent),
    ~w(Task),
    ~w(Process),
    ~w(Logger),
    ~w(IO),
    ~w(File),
    ~w(Application),
    ~w(DateTime),
    ~w(NaiveDateTime),
    ~w(System),
    ~w(FeudHall Application),
    ~w(FeudHall Infrastructure)
  ]
  # Application use cases emit through the diagnostics port and never touch logging or processes.
  @application_process_aliases [~w(Logger), ~w(GenServer), ~w(Process)]
  @domain_forbidden_erlang [:rand, :os, :ets, :persistent_term, :timer, :erlang_time]
  @domain_forbidden_calls [{:erlang, :monotonic_time}, {:erlang, :system_time}, {:erlang, :now}]

  test "domain modules have no outer-layer, framework, clock, or process dependencies" do
    for file <- Path.wildcard(Path.join(@root, "domain/**/*.ex")) do
      assert violations(File.read!(file), @domain_forbidden_aliases, @domain_forbidden_erlang, @domain_forbidden_calls) ==
               [],
             "#{Path.relative_to_cwd(file)} breaks the domain boundary"
    end
  end

  test "application use cases depend on ports, not infrastructure adapters" do
    for file <- Path.wildcard(Path.join(@root, "application/**/*.ex")) do
      assert violations(File.read!(file), [~w(FeudHall Infrastructure), ~w(Ecto), ~w(Phoenix)], [], []) == [],
             "#{Path.relative_to_cwd(file)} depends on an adapter"
    end
  end

  test "application modules never call Logger or processes directly except diagnostics ports" do
    files = Path.wildcard(Path.join(@root, "application/**/*.ex"))
    assert Enum.any?(files, &(Path.basename(&1) == "diagnostics.ex"))

    for file <- files, Path.basename(file) != "diagnostics.ex" do
      assert violations(File.read!(file), @application_process_aliases, [], []) == [],
             "#{Path.relative_to_cwd(file)} calls Logger or a process API directly; route it through a port"
    end
  end

  # The planner and the public view see only their inputs: never the decider, evolver, or admission.
  @decision_internals [
    ~w(FeudHall Domain Hall Decider),
    ~w(FeudHall Domain Hall Evolver),
    ~w(FeudHall Domain Hall Admission),
    ~w(Hall Decider),
    ~w(Hall Evolver),
    ~w(Hall Admission),
    ~w(Decider),
    ~w(Evolver),
    ~w(Admission)
  ]

  test "the NPC planner and public view do not reference the decider, evolver, or admission" do
    files = [Path.join(@root, "domain/npc/planner.ex"), Path.join(@root, "domain/public_view.ex")]

    for file <- files do
      assert File.exists?(file), "#{file} moved; update this check"

      assert violations(File.read!(file), @decision_internals, [], []) == [],
             "#{Path.relative_to_cwd(file)} reaches into the decision internals"
    end
  end

  test "the decision-internals rule detects planted references" do
    planted = """
    defmodule PlantedPlanner do
      alias FeudHall.Domain.Hall
      alias FeudHall.Domain.Hall.Admission
      def a(state), do: Hall.Decider.decide(state, :x, %{})
      def b(state), do: Hall.Evolver.evolve(state, %{})
      def c(state), do: Admission.accept_dessert(state, %{})
    end
    """

    found = violations(planted, @decision_internals, [], [])
    assert {:alias, ["FeudHall", "Domain", "Hall", "Admission"]} in found
    assert {:alias, ["Hall", "Decider"]} in found
    assert {:alias, ["Hall", "Evolver"]} in found
    assert {:alias, ["Admission"]} in found
  end

  test "the scanner detects planted violations (sensitivity check)" do
    planted = """
    defmodule Planted do
      alias FeudHall.Infrastructure.Snapshot
      def a, do: DateTime.utc_now()
      def b, do: :rand.uniform(3)
      def c, do: :erlang.monotonic_time()
      def d, do: Snapshot.take(nil, 0)
    end
    """

    found = violations(planted, @domain_forbidden_aliases, @domain_forbidden_erlang, @domain_forbidden_calls)
    assert {:alias, ["FeudHall", "Infrastructure", "Snapshot"]} in found
    assert {:alias, ["DateTime"]} in found
    assert {:erlang, :rand} in found
    assert {:call, :erlang, :monotonic_time} in found
  end

  test "the application process rule detects planted Logger, GenServer, and Process use" do
    planted = """
    defmodule PlantedUseCase do
      require Logger
      def a, do: Logger.info("x")
      def b, do: GenServer.call(self(), :x)
      def c, do: Process.sleep(1)
    end
    """

    found = violations(planted, @application_process_aliases, [], [])
    assert {:alias, ["Logger"]} in found
    assert {:alias, ["GenServer"]} in found
    assert {:alias, ["Process"]} in found

    assert violations(
             "defmodule Clean do\n  def a, do: System.monotonic_time()\nend\n",
             @application_process_aliases,
             [],
             []
           ) == []
  end

  defp violations(source, aliases, erlang_modules, calls) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _, parts} = node, acc when is_list(parts) ->
          names = Enum.map(parts, &to_string/1)
          hit = Enum.any?(aliases, &List.starts_with?(names, &1))
          {node, if(hit, do: [{:alias, names} | acc], else: acc)}

        {{:., _, [mod, fun]}, _, _} = node, acc when is_atom(mod) ->
          acc = if mod in erlang_modules, do: [{:erlang, mod} | acc], else: acc
          acc = if {mod, fun} in calls, do: [{:call, mod, fun} | acc], else: acc
          {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end
end
