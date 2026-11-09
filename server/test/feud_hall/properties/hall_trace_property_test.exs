defmodule FeudHall.Properties.HallTraceTest do
  @moduledoc """
  Model-based property: random command traces against the pure hall.

  Budgets are explicit (runs, trace length, advance sizes). The generator and
  interpreter live in `FeudHall.HallTrace`: symbolic actions pick concrete
  targets from current state by index, so shrinking removes actions without
  leaving dangling IDs, and after every accepted command the independent
  oracle must report no violations. At the end, genesis replay,
  snapshot-plus-tail replay, and a JSON codec round trip must reproduce the
  live state exactly, and splitting the final clock advance must not change
  the outcome. Aggregate progress counters guard against vacuous passes.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import FeudHall.Fixtures, only: [ctx: 2]

  alias FeudHall.Domain.{Clock, Hall}
  alias FeudHall.HallTrace
  alias FeudHall.Infrastructure.{EventCodec, Snapshot}
  alias FeudHall.Oracle

  @runs 100
  @max_actions 70

  property "random traces keep every invariant and replay exactly" do
    Process.put(:progress, %{
      served_trays: 0,
      desserts_served: 0,
      cleanings: 0,
      cancellations: 0,
      spoiled: 0,
      stale_rejected: 0,
      trace_fills: 0,
      requests_cancelled: 0
    })

    # A large initial size yields long traces while still letting shrinking
    # reduce a counterexample to its minimal prefix.
    check all(
            actions <- list_of(HallTrace.action(), max_length: @max_actions),
            cut <- integer(0..1_000),
            split <- integer(1..59_999),
            max_runs: @runs,
            initial_size: 40
          ) do
      %{state: state, batches: batches, events: events, stats: stats} = HallTrace.run(actions)
      bump(:stale_rejected, stats.stale_rejected)

      # Genesis replay.
      assert Hall.replay(events) == state

      # Snapshot at a complete batch boundary plus the remaining tail.
      k = rem(cut, length(batches) + 1)
      {prefix, tail} = Enum.split(batches, k)
      snapshot = Snapshot.take(%{hall: Hall.replay(Enum.concat(prefix)), control: nil}, k)
      positioned = tail |> Enum.with_index(k + 1) |> Enum.map(fn {evs, pos} -> %{position: pos, events: evs} end)
      assert {:ok, %{hall: ^state, control: nil}} = Snapshot.restore(snapshot, positioned)

      # Serialized history decodes and replays to the same state.
      decoded =
        Enum.map(events, fn e ->
          {:ok, d} = e |> EventCodec.encode!() |> EventCodec.decode()
          d
        end)

      assert Hall.replay(decoded) == state

      # Partitioning one declared available interval preserves the outcome.
      base = Clock.service_ms(state.now) + 1
      target = base + 60_000
      {:ok, one} = Hall.decide(state, {:advance_clock, %{to_service_ms: target}}, ctx({:system, :scheduler}, "one"))

      {:ok, first} =
        Hall.decide(state, {:advance_clock, %{to_service_ms: base + split}}, ctx({:system, :scheduler}, "a"))

      mid = Hall.replay(first, state)
      {:ok, second} = Hall.decide(mid, {:advance_clock, %{to_service_ms: target}}, ctx({:system, :scheduler}, "b"))
      whole = Hall.replay(one, state)
      assert Hall.replay(second, mid) == whole
      Oracle.assert_settled!(whole, events ++ one)

      record_progress(events)
    end

    progress = Process.get(:progress)
    # Non-vacuity: the generated traces must exercise the lifecycles we claim.
    for {key, min} <- [
          served_trays: 25,
          desserts_served: 3,
          cleanings: 10,
          cancellations: 10,
          spoiled: 10,
          stale_rejected: 10,
          trace_fills: 25,
          requests_cancelled: 5
        ] do
      assert progress[key] >= min, "too little #{key} across runs: #{inspect(progress)}"
    end
  end

  defp record_progress(events) do
    count = fn type -> Enum.count(events, &(&1.type == type)) end
    bump(:served_trays, count.(:tray_served))
    bump(:desserts_served, count.(:dessert_served))
    bump(:cleanings, count.(:hall_cleaning_started))
    bump(:cancellations, count.(:tray_cancelled) + count.(:dessert_cancelled))
    bump(:spoiled, count.(:stock_spoiled))
    bump(:requests_cancelled, count.(:purchase_request_cancelled))

    # Fills of requests the trace submitted (IDs "PR:c<n>"), not the fixture's opening stock.
    fills = for %{type: :market_cleared, fills: fs} <- events, %{request_id: "PR:c" <> _} <- fs, do: 1
    bump(:trace_fills, length(fills))
  end

  defp bump(key, by), do: Process.put(:progress, Map.update!(Process.get(:progress), key, &(&1 + by)))
end
