defmodule FeudHall.Infrastructure.ExporterTest do
  use ExUnit.Case, async: true

  alias FeudHall.Infrastructure.Diagnostics.Exporter

  defp start(opts) do
    {:ok, pid} = Exporter.start_link(opts ++ [max_queue: 100, batch: 10, timeout_ms: 5_000, on_event: self()])
    pid
  end

  test "a full queue drops and counts new records while emit never blocks" do
    test = self()

    export = fn batch ->
      send(test, {:exporting, self(), batch})

      receive do
        :release -> :ok
      end
    end

    pid = start(export: export, max_queue: 3, batch: 10)
    for i <- 1..10, do: assert(:ok = Exporter.emit(pid, %{n: i}))
    assert_receive {:exporting, worker, batch}, 1_000
    assert length(batch) <= 3
    assert %{dropped: 7, queued: 3, exported: 0, failed: 0} = Exporter.stats(pid)

    send(worker, :release)
    assert_receive {:exporter, :exported, count}, 1_000
    assert count == length(batch)
  end

  test "records are exported in batches of at most the batch size" do
    test = self()

    export = fn batch ->
      send(test, {:batch, batch})
      :ok
    end

    pid = start(export: export, batch: 2)
    for i <- 1..5, do: Exporter.emit(pid, %{n: i})
    assert_receive {:exporter, :exported, _}, 1_000
    stats = wait_for(pid, fn s -> s.exported == 5 end)
    assert stats.queued == 0

    batches =
      for _ <- 1..3,
          do:
            (receive do
               {:batch, b} -> b
             end)

    assert Enum.all?(batches, &(length(&1) <= 2))
    assert List.flatten(batches) == for(i <- 1..5, do: %{n: i})
  end

  test "a stalled export is cut off by the timeout and counted as failed" do
    export = fn _batch ->
      receive do
        :never -> :ok
      end
    end

    pid = start(export: export, timeout_ms: 50)
    Exporter.emit(pid, %{n: 1})
    assert_receive {:exporter, :timeout, 1}, 2_000
    assert %{failed: 1, exported: 0, queued: 0} = Exporter.stats(pid)
    # still usable afterwards
    assert :ok = Exporter.emit(pid, %{n: 3})
  end

  test "a raising or non-ok export is counted as failed" do
    pid = start(export: fn _ -> raise "boom" end)
    Exporter.emit(pid, %{n: 1})
    assert_receive {:exporter, :failed, 1}, 1_000
    assert %{failed: 1} = Exporter.stats(pid)

    pid = start(export: fn _ -> :error end)
    Exporter.emit(pid, %{n: 1})
    assert_receive {:exporter, :failed, 1}, 1_000
  end

  # Bounded guard: stats become consistent only after the exporter processes its own messages.
  defp wait_for(pid, fun, tries \\ 50) do
    stats = Exporter.stats(pid)

    cond do
      fun.(stats) ->
        stats

      tries == 0 ->
        flunk("stats never settled: #{inspect(stats)}")

      true ->
        receive do
          {:exporter, _, _} -> wait_for(pid, fun, tries - 1)
        after
          100 -> wait_for(pid, fun, tries - 1)
        end
    end
  end
end
