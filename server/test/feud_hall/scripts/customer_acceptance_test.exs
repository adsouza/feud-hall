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

  # The rows that pass on seed 20261109, the seed this test pins (the design's single
  # acceptance run and the seed the values were chosen on). Run A's reference stall is the
  # driver's default: the median-priced unused starter.
  @met %{
    a: [
      "A ref waiting 12:00-13:00",
      "A ref waiting 19:00-20:00",
      "A ref busy 12:00-13:00",
      "A ref busy 19:00-20:00",
      "A ref waiting 10:00-11:00",
      "A ref waiting 14:00-17:00",
      "A hall waiting per stall 00:00-03:00",
      "A ref open instants short of an ingredient",
      "A ref open during checked hours"
    ],
    b: ["B nothing_available share of left on arrival", "B mains served on day 0"]
  }

  # Rows the driver reports without a bound.
  @reported %{
    a: [@share, "A owner stalls mean waiting 12:00-13:00", "A owner stalls mean waiting 19:00-20:00"],
    b: [@share]
  }

  # Rows that a measured seed misses at the chosen tuning, as seed => row => reason. They are
  # documented, not asserted: only seed 20261109 is run here, and it meets every row. The
  # report measured four seeds (20261109, 7, 12345 and the held-out 424242); run numbers are
  # lines of the tuning log. A row missed on the pinned seed would be listed under 20261109 and
  # would then not be asserted below. The report's harder case (`--cuisine coast_salish`)
  # misses the two rush-waiting rows on every seed; it is not run here.
  @not_met %{
    7 => %{"A ref waiting 12:00-13:00" => "2.45 against 2.5 to 4.5: short by 0.05 (run 126)"},
    424_242 => %{"A ref waiting 12:00-13:00" => "2.33 against 2.5 to 4.5: short by 0.17 (run 131)"}
  }

  # Served share under today's values (`Tuning.of(LaunchCatalog.catalog())`), same run, seed and days.
  # To regenerate, run from server/ and read the "served share" verdict row:
  #   mix run --no-start scripts/customer_sim.exs -- --run a --tuning current --days 3 --seed 20261109
  #   mix run --no-start scripts/customer_sim.exs -- --run b --tuning current --days 3 --seed 20261109
  @todays_share %{a: 0.4012, b: 0.3321}

  for run <- [:a, :b] do
    test "run #{run} at the chosen tuning meets the reported rows and serves a larger share than today" do
      run = unquote(run)

      assert {:ok, result} = Hall.run(%{run: run, tuning: Tuning.chosen(), via: :init, days: @days, seed: @seed})
      GenServer.stop(result.authority)
      assert result.problems == []

      verdict = Stats.verdict(run, result.stats)
      rows = Map.new(verdict, &{&1.check, &1})

      # Every row is asserted or only reported, so a new row cannot go unclassified, and
      # every row documented as missed on some seed is a real row.
      assert Enum.sort(Map.keys(rows)) == Enum.sort(@met[run] ++ @reported[run])
      for {_seed, misses} <- @not_met, {check, _reason} <- misses, do: assert(check in (@met.a ++ @met.b))
      missed_here = Map.keys(Map.get(@not_met, @seed, %{}))

      for check <- @met[run] -- missed_here do
        assert rows[check].pass, "#{check}: #{inspect(rows[check])}"
      end

      assert rows[@share].value > @todays_share[run]
    end
  end
end
