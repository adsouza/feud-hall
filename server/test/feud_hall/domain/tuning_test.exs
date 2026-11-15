defmodule FeudHall.Domain.TuningTest do
  use ExUnit.Case, async: true

  alias FeudHall.Domain.Content
  alias FeudHall.Domain.Content.{LaunchCatalog, SliceCatalog, Tuning}

  @catalog LaunchCatalog.catalog()

  # Recorded from the launch and slice catalogs before the tuning data existed.
  # A catalog without `rules.npc` and `rules.tuning` must keep this identity.
  @launch_hash "86fc1c12fadebfa30e2cda8badc1ad12481d18455d6c7d5a469dd18969f6b21d"

  defp base, do: Tuning.of(@catalog)

  test "a launch catalog's tuning is version 1 with today's values" do
    catalog = @catalog
    tuning = Tuning.of(catalog)
    assert tuning.version == 1
    assert tuning.demand == Map.take(catalog.rules.demand, [:arrivals_per_equivalent, :hourly_weights])
    assert tuning.market == Map.take(catalog.rules.market, [:target_stock_per_equivalent, :replenish_cap])
    assert tuning.npc == Tuning.npc_defaults()
    assert Tuning.validate(catalog, tuning) == :ok
  end

  test "the defaults are today's planner literals" do
    assert Tuning.npc_defaults() == %{
             fallback_trays_per_day: 10,
             expected_use: "even_share",
             starter_shifts: %{"budget" => [5, 17], "mainstream" => [12, 0], "premium" => [19, 7]}
           }

    assert FeudHall.Domain.Npc.Planner.expected_use_heuristics() == ["even_share"]
  end

  test "the launch catalog keeps its content hash and carries no npc or tuning rules" do
    assert Content.hash(@catalog) == @launch_hash
    refute Map.has_key?(@catalog.rules, :npc)
    refute Map.has_key?(@catalog.rules, :tuning)
    refute Map.has_key?(SliceCatalog.catalog().rules, :npc)
    refute Map.has_key?(SliceCatalog.catalog().rules, :tuning)
  end

  test "npc/1 reads the catalog's rules when present and the defaults otherwise" do
    assert Tuning.npc(@catalog) == Tuning.npc_defaults()
    custom = %{Tuning.npc_defaults() | fallback_trays_per_day: 30}
    assert Tuning.npc(put_in(@catalog, [:rules, :npc], custom)) == custom
  end

  test "put then of returns the tuning, and put changes nothing else" do
    catalog = @catalog
    tuning = Tuning.of(catalog) |> Map.put(:version, 2) |> put_in([:demand, :arrivals_per_equivalent], 180)
    changed = Tuning.put(catalog, tuning)
    assert Tuning.of(changed) == tuning
    assert changed.rules.tuning == %{version: 2}
    assert Map.delete(changed, :rules) == Map.delete(catalog, :rules)

    assert Map.drop(changed.rules, [:demand, :market, :npc, :tuning]) ==
             Map.drop(catalog.rules, [:demand, :market, :npc, :tuning])

    assert Map.drop(changed.rules.demand, [:arrivals_per_equivalent, :hourly_weights]) ==
             Map.drop(catalog.rules.demand, [:arrivals_per_equivalent, :hourly_weights])

    assert Map.drop(changed.rules.market, [:target_stock_per_equivalent, :replenish_cap]) ==
             Map.drop(catalog.rules.market, [:target_stock_per_equivalent, :replenish_cap])

    assert Content.validate(changed) == :ok
  end

  describe "validate/2 refuses" do
    defp refused(tuning), do: assert({:error, [_ | _]} = Tuning.validate(@catalog, tuning))

    test "23 hourly weights" do
      refused(update_in(base(), [:demand, :hourly_weights], &Enum.drop(&1, 1)))
    end

    test "a non-zero weight at hour 3" do
      refused(update_in(base(), [:demand, :hourly_weights], &List.replace_at(&1, 3, 1)))
    end

    test "a negative weight" do
      refused(update_in(base(), [:demand, :hourly_weights], &List.replace_at(&1, 10, -1)))
    end

    test "all weights zero" do
      refused(put_in(base(), [:demand, :hourly_weights], List.duplicate(0, 24)))
    end

    test "a negative arrivals_per_equivalent" do
      refused(put_in(base(), [:demand, :arrivals_per_equivalent], -1))
    end

    test "a product missing from target_stock_per_equivalent" do
      [product | _] = Map.keys(base().market.target_stock_per_equivalent)
      refused(update_in(base(), [:market, :target_stock_per_equivalent], &Map.delete(&1, product)))
    end

    test "an unknown product in replenish_cap" do
      refused(update_in(base(), [:market, :replenish_cap], &Map.put(&1, "no_such_product", 5)))
    end

    test "fallback_trays_per_day of 0" do
      refused(put_in(base(), [:npc, :fallback_trays_per_day], 0))
    end

    test "an unknown expected_use" do
      refused(put_in(base(), [:npc, :expected_use], "nonsense"))
    end

    test "a starter shift for an unknown profile" do
      refused(update_in(base(), [:npc, :starter_shifts], &Map.put(&1, "ghost", [1, 2])))
    end

    test "a shift hour of 24" do
      refused(put_in(base(), [:npc, :starter_shifts, "budget"], [5, 24]))
    end

    test "an extra top-level key" do
      refused(Map.put(base(), :extra, 1))
    end

    test "a tuple shift" do
      refused(put_in(base(), [:npc, :starter_shifts, "budget"], {5, 17}))
    end

    test "a non-map tuning" do
      assert {:error, _} = Tuning.validate(@catalog, nil)
    end
  end

  describe "Content.validate/1" do
    test "accepts a catalog with rules.npc and rules.tuning" do
      custom = put_in(base(), [:npc, :fallback_trays_per_day], 30)
      assert Content.validate(Tuning.put(@catalog, custom)) == :ok
    end

    test "refuses a malformed rules.npc" do
      for bad <- [%{Tuning.npc_defaults() | fallback_trays_per_day: 0}, %{Tuning.npc_defaults() | expected_use: "x"}] do
        assert {:error, _} = Content.validate(put_in(@catalog, [:rules, :npc], bad))
      end
    end
  end
end
