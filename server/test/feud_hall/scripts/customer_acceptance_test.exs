System.put_env("CUSTOMER_SIM_NO_MAIN", "1")
Code.require_file("../../../scripts/customer_sim.exs", __DIR__)

defmodule FeudHall.CustomerAcceptanceTest do
  @moduledoc """
  The Project 4 acceptance runs at the chosen tuning: runs A and B, one warm-up
  day and three measured days, seed 20261109, as
  `docs/superpowers/reports/2026-11-15-more-real-customers.md` reports them.

  Excluded from default runs (about 20 s); run it with

      mix test --only acceptance test/feud_hall/scripts/customer_acceptance_test.exs
  """
  use ExUnit.Case, async: false

  alias FeudHall.CustomerSim.{Hall, Stats}
  alias FeudHall.Domain.Content.Tuning

  @moduletag :acceptance
  @moduletag timeout: 20 * 60_000

  @seed 20_261_109
  @days 3

  @share "served share (mains served / arrivals; no bound here)"

  # The rows the report says pass on all three measured seeds (20261109, 7, 12345).
  @met %{
    a: [
      "A ref waiting 10:00-11:00",
      "A ref waiting 14:00-17:00",
      "A hall waiting per stall 00:00-03:00",
      "A ref open instants short of an ingredient",
      "A ref open during checked hours"
    ],
    b: ["B nothing_available share of left on arrival", "B mains served on day 0"]
  }

  # Rows that fail at the chosen tuning on every measured seed, with the reason.
  # They are reported, not asserted: the spec ranks served share above them, and
  # no allowed value reaches them while run B's served share stays above today's.
  @not_met %{
    a: %{
      "A ref waiting 12:00-13:00" =>
        "1.22 to 1.65 on three seeds against 2.5: the reference stall sells the dearest main open in the hall, " <>
          "so the cheaper stalls fill first; arrivals high enough to fill it too drop run B's served share below today's",
      "A ref waiting 19:00-20:00" => "1.21 to 1.50 against 2.5, for the same reason",
      "A ref busy 12:00-13:00" => "0.75 to 0.84 against 0.85, for the same reason",
      "A ref busy 19:00-20:00" => "0.74 to 0.85 against 0.85, for the same reason"
    },
    b: %{}
  }

  # Served share under today's values (`Tuning.of(LaunchCatalog.catalog())`), same run, seed and days.
  # To regenerate, run from server/ and read the "served share" verdict row:
  #   mix run --no-start scripts/customer_sim.exs -- --run a --tuning current --days 3 --seed 20261109
  #   mix run --no-start scripts/customer_sim.exs -- --run b --tuning current --days 3 --seed 20261109
  @todays_share %{a: 0.379, b: 0.3321}

  for run <- [:a, :b] do
    test "run #{run} at the chosen tuning meets the reported rows and serves a larger share than today" do
      run = unquote(run)

      assert {:ok, result} = Hall.run(%{run: run, tuning: Tuning.chosen(), via: :init, days: @days, seed: @seed})
      GenServer.stop(result.authority)
      assert result.problems == []

      verdict = Stats.verdict(run, result.stats)
      rows = Map.new(verdict, &{&1.check, &1})

      # Every row is either asserted or listed as not met, so a new row cannot go unclassified.
      assert Enum.sort(Map.keys(rows)) == Enum.sort(@met[run] ++ Map.keys(@not_met[run]) ++ [@share])

      for check <- @met[run] do
        assert rows[check].pass, "#{check}: #{inspect(rows[check])}"
      end

      assert rows[@share].value > @todays_share[run]
    end
  end
end
