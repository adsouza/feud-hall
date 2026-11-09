defmodule FeudHall.Domain.Hall do
  @moduledoc """
  The hall aggregate boundary: the initial atomic commit unit for the
  economic core.

  `decide/3` and `evolve/2` are the only entry points. Both are pure: no
  database, process, ambient clock, or global configuration access. Decisions
  receive an explicit context (command ID and authenticated actor) and return
  domain events; evolution is the sole way to obtain the next authoritative
  state, in live execution and in replay alike.

  The hall state holds separately owned facts (restaurants, visits, trays,
  component orders, dining wallets) under one map because the hall is the
  shared transaction boundary; the owning root of each fact is documented in
  `FeudHall.Domain.Hall.Evolver`.
  """

  alias FeudHall.Domain.Hall.{Decider, Evolver}

  @type state :: map() | nil
  @type event :: map()
  @type actor :: {:principal, String.t()} | {:system, atom()}
  @type context :: %{command_id: String.t(), actor: actor()}

  @doc "Decides a command against the current head state."
  @spec decide(state(), {atom(), map()}, context()) :: {:ok, [event()]} | {:error, term()}
  defdelegate decide(state, command, context), to: Decider

  @doc "Applies one committed event."
  @spec evolve(state(), event()) :: state()
  defdelegate evolve(state, event), to: Evolver

  @doc "Folds a sequence of events from genesis (or a snapshot state)."
  @spec replay([event()], state()) :: state()
  def replay(events, state \\ nil), do: Enum.reduce(events, state, &evolve(&2, &1))

  @doc "Decides and applies, returning the new state and its events."
  def execute(state, command, context) do
    with {:ok, events} <- decide(state, command, context) do
      {:ok, replay(events, state), events}
    end
  end
end
