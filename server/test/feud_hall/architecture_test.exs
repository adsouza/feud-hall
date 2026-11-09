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
