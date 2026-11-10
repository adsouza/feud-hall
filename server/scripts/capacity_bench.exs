# The Python launcher owns the disposable database and the process memory limit.
defmodule FeudHall.CapacityBench.Clock do
  @behaviour FeudHall.Application.MonotonicClock

  @impl true
  def now_ms(clock), do: :atomics.get(clock, 1)
end

defmodule FeudHall.CapacityBench.Samples do
  @moduledoc false
  @table __MODULE__

  def open, do: :ets.new(@table, [:named_table, :public, :duplicate_bag])

  def record(kind, value) do
    true = :ets.insert(@table, {kind, value})
    :ok
  end

  def values(kind), do: for({^kind, value} <- :ets.lookup(@table, kind), do: value)

  def distribution(kind) do
    sorted = values(kind) |> Enum.sort()
    n = length(sorted)

    if n == 0 do
      %{count: 0}
    else
      percentile = fn p -> Enum.at(sorted, div(p * n + 99, 100) - 1) end

      %{
        count: n,
        p50: percentile.(50),
        p95: percentile.(95),
        p99: percentile.(99),
        max: List.last(sorted)
      }
    end
  end

  # Collect only bounded scalar timing/failure records through the regular diagnostics boundary.
  def emit(_, %{name: :snapshot_taken, fields: %{duration_us: duration}}), do: record(:snapshot_us, duration)

  def emit(_, %{name: name, fields: fields})
      when name in [:snapshot_failed, :storage_failure, :fenced, :npc_planner_failed, :scheduler_gap],
      do: record(:diagnostic_failure, {name, Map.take(fields, [:reason, :error_class])})

  def emit(_, _record), do: :ok
end

defmodule FeudHall.CapacityBench.Store do
  @moduledoc false
  @behaviour FeudHall.Application.EventStore
  alias FeudHall.CapacityBench.Samples
  alias FeudHall.Infrastructure.PostgresEventStore, as: Store

  @impl true
  defdelegate head(store), to: Store
  @impl true
  defdelegate stream_versions(store, stream), to: Store
  @impl true
  defdelegate read_from(store, position), to: Store
  @impl true
  defdelegate receipt(store, command_id), to: Store
  @impl true
  defdelegate acquire_authority(store, scope, owner), to: Store
  @impl true
  defdelegate acquire_authority(store, scope, owner, epoch), to: Store
  @impl true
  defdelegate held_epoch(store), to: Store
  @impl true
  defdelegate save_snapshot(store, position, body), to: Store
  @impl true
  defdelegate mark_snapshot_verified(store, id), to: Store
  @impl true
  defdelegate snapshots(store), to: Store
  @impl true
  defdelegate projection(store, kind), to: Store
  @impl true
  defdelegate outbox(store), to: Store

  defdelegate prune_snapshots(store, keep), to: Store

  @impl true
  def append(store, request) do
    {us, result} = :timer.tc(Store, :append, [store, request])

    if match?({:ok, _, _}, result) do
      Samples.record(:append_us, us)

      for event <- request.events do
        case event do
          %{type: :tray_served, components: [_main, _drink]} ->
            Samples.record(:activity, :paired_trays_served)

          %{type: :tray_served, components: [_main]} ->
            Samples.record(:activity, :main_only_trays_served)

          %{type: :market_cleared, unfilled: unfilled} ->
            if Enum.any?(unfilled, &(&1.reason == :stock_exhausted)) do
              Samples.record(:activity, :stock_contended_clearings)
            end

          _ ->
            :ok
        end
      end
    end

    result
  end
end

defmodule FeudHall.CapacityBench do
  alias FeudHall.Application.CommandWorkflow
  alias FeudHall.CapacityBench.{Samples, Store}
  alias FeudHall.CapacityBench.Clock, as: InjectedClock
  alias FeudHall.Domain.{Clock, Control, Hall}
  alias FeudHall.Domain.Content.SliceCatalog
  alias FeudHall.Infrastructure.{HallAuthority, PostgresEventStore, Repo}
  alias FeudHall.Infrastructure.Postgres.DailyActivityProjector

  @scope "hall:capacity"
  @database "feud_hall_bench"
  @stall_count 150
  @equivalent_floor_millis @stall_count * 1_000
  @projector_interval 10
  @recovery_extra_ticks 299

  def run(days, report) when days in 1..7 do
    start_database!()
    Samples.open()
    clock = :atomics.new(1, [])
    store = PostgresEventStore.new(Repo, @scope)

    opts = [
      store_mod: Store,
      store: store,
      scope: @scope,
      clock: {InjectedClock, clock},
      tick_ms: :manual,
      diagnostics: {Samples, nil}
    ]

    {:ok, authority} = HallAuthority.start_link([owner: "capacity-live"] ++ opts)

    {:accepted, %{outcome: :accepted}} =
      HallAuthority.execute(authority, %{
        command_id: "capacity-initialize",
        actor: {:system, :admin},
        command: {:initialize_hall, %{hall_id: "capacity", catalog: catalog()}}
      })

    %{hall: hall, position: start_position, service_ms: 0} = HallAuthority.state(authority)
    @stall_count = map_size(hall.restaurants)
    @stall_count = map_size(hall.stalls)
    @stall_count = map_size(hall.npcs)
    IO.puts("Bootstrapped #{@stall_count} NPC restaurants at batch #{start_position}.")
    bootstrap_storage = storage()
    baseline_append_count = length(Samples.values(:append_us))
    :ets.delete(Samples, :append_us)
    ticks_per_day = div(Clock.service_ms(Clock.day()), 1_000)
    start = System.monotonic_time(:microsecond)

    {daily, {projector, last_position}} =
      Enum.map_reduce(1..days, {Task.async(fn -> DailyActivityProjector.catch_up(Repo) end), start_position}, fn day,
                                                                                                                 {projector,
                                                                                                                  previous_position} ->
        first_tick = (day - 1) * ticks_per_day + 1
        projector = drive(authority, clock, first_tick, day * ticks_per_day, projector, :wake_us)
        %{position: position, service_ms: service_ms, hall: hall} = HallAuthority.state(authority)
        true = service_ms == day * ticks_per_day * 1_000
        stats = event_stats(previous_position, position)
        1 = stats.types["day_closed"]
        1 = stats.types["hall_cleaning_started"]
        1 = stats.types["hall_cleaning_ended"]
        summary = List.last(hall.demand.summaries)

        true =
          summary.arrivals == div(hall.catalog.rules.demand.arrivals_per_equivalent * @equivalent_floor_millis, 1_000)

        IO.puts("Day #{day}/#{days}: #{stats.events} events, #{summary.arrivals} arrivals, batch #{position}.")
        {Map.merge(stats, %{day: day, summary: summary, position: position, storage: storage()}), {projector, position}}
      end)

    work_us = System.monotonic_time(:microsecond) - start
    samples = Samples.values(:wake_us)
    activity = Samples.values(:activity) |> Enum.frequencies()
    append = Samples.distribution(:append_us)
    true = append.count == last_position - start_position
    true = length(samples) == days * ticks_per_day

    for kind <- [:main_only_trays_served, :paired_trays_served, :stock_contended_clearings] do
      if Map.get(activity, kind, 0) == 0, do: raise("Workload never exercised #{kind}")
    end

    if Enum.all?(daily, &(Map.get(&1.types, "dessert_served", 0) == 0)) do
      raise "Workload never served a dessert"
    end

    workload = %{
      days: daily,
      work_us: work_us,
      bootstrap_batches: start_position,
      bootstrap_append_count: baseline_append_count,
      bootstrap_storage: bootstrap_storage,
      wake_us: Samples.distribution(:wake_us),
      append_us: append,
      wakes_over_1s: Enum.count(samples, &(&1 > 1_000_000)),
      wakes_over_5s: Enum.count(samples, &(&1 > 5_000_000)),
      slowest_wake: Samples.values(:wake_with_tick) |> Enum.max_by(& &1.duration_us),
      activity: activity,
      projector_backlog_batches: Samples.distribution(:backlog),
      projector_poll_service_seconds: @projector_interval,
      snapshot_us: Samples.distribution(:snapshot_us)
    }

    first_tail_tick = days * ticks_per_day + 1

    projector =
      drive(
        authority,
        clock,
        first_tail_tick,
        first_tail_tick + @recovery_extra_ticks - 1,
        projector,
        :recovery_tail_wake_us
      )

    live = HallAuthority.state(authority)
    :ok = GenServer.stop(authority)
    {drain_us, {:ok, position}} = :timer.tc(fn -> drain(projector) end)
    true = position == live.position
    projection_check!(position)
    IO.puts("Projection caught up at #{position}. Replaying from genesis.")
    {full_us, {:ok, full}} = :timer.tc(CommandWorkflow, :open, [PostgresEventStore, store])
    true = {full.state, full.control, full.position} === {live.hall, live.control, live.position}

    snapshots =
      for snapshot <- PostgresEventStore.snapshots(store),
          snapshot.verified,
          do: %{position: snapshot.position, body_bytes: byte_size(snapshot.body)}

    IO.puts("Genesis matches live state at #{position}. Restarting authority from snapshot.")

    {restart_us, {:ok, restarted}} =
      :timer.tc(HallAuthority, :start_link, [[owner: "capacity-restart"] ++ opts])

    recovered = HallAuthority.state(restarted)
    :ok = GenServer.stop(restarted)
    {:ok, suffix} = PostgresEventStore.read_from(store, full.position)
    true = recovered.recovery.snapshot == hd(snapshots).position
    true = recovered.recovery.tail_batches == full.position - recovered.recovery.snapshot
    true = recovered.recovery.tail_batches > 0
    true = recovered.service_ms == live.service_ms
    true = recovered.position == full.position + length(suffix)
    true = recovered.hall === Hall.replay(Enum.flat_map(suffix, & &1.events), full.state)
    true = recovered.control === Control.replay(Enum.flat_map(suffix, & &1.control_events), full.control)

    recovery = %{
      cut_position: full.position,
      events_at_cut: full.versions.hall + full.versions.control,
      extra_service_seconds: @recovery_extra_ticks,
      full_replay_us: full_us,
      snapshot_restart_us: restart_us,
      tail_batches: recovered.recovery.tail_batches,
      snapshot_position: recovered.recovery.snapshot,
      snapshots: snapshots,
      recovered_position: recovered.position,
      reconciliation: recovered.recovery.reconciliation,
      projector_drain_us: drain_us,
      projector_checkpoint: position,
      live_equals_genesis: true,
      restart_matches_replayed_suffix: true
    }

    result = %{
      workload: workload,
      recovery: recovery,
      stalls: @stall_count,
      game_days: days,
      clock_step_service_ms: 1_000,
      equivalent_floor_millis: @equivalent_floor_millis,
      arrivals_per_equivalent: hall.catalog.rules.demand.arrivals_per_equivalent,
      catalog_sha256: :crypto.hash(:sha256, :erlang.term_to_binary(hall.catalog)) |> Base.encode16(case: :lower),
      diagnostics: Samples.values(:diagnostic_failure) |> Enum.map(&inspect/1) |> Enum.frequencies(),
      elixir: System.version(),
      otp: :erlang.system_info(:system_version) |> List.to_string(),
      postgres: settings()
    }

    File.write!(report, :json.encode(result))
    IO.puts("Verified both recovery paths and the daily activity projection.")
  end

  defp start_database! do
    @database = System.fetch_env!("FEUD_HALL_CAPACITY_DATABASE")
    config = Application.fetch_env!(:feud_hall, Repo)
    Application.put_env(:feud_hall, Repo, Keyword.merge(config, database: @database, log: false))
    Logger.configure(level: :warning)
    {:ok, _apps} = Application.ensure_all_started(:feud_hall)

    %{rows: [[@database, 0]]} =
      Repo.query!("""
      select current_database(), count(*) from pg_tables where schemaname = 'public'
      """)

    _versions = Ecto.Migrator.run(Repo, :up, all: true, log: false)
  end

  defp catalog do
    catalog = SliceCatalog.catalog()
    profiles = catalog.npc_profiles

    npcs =
      for index <- 0..(@stall_count - 1) do
        profile = Enum.at(profiles, rem(index, length(profiles)))
        %{profile | id: profile.id <> "-" <> String.pad_leading(Integer.to_string(index), 3, "0")}
      end

    # Hold the workload at 150 demand equivalents even during cold start and stock-outs.
    # Scale the catalog's opening-stock caps by the same factor. Daily supply still uses
    # the previous forecast and all purchases still compete through normal clearing.
    old_floor = catalog.rules.demand.equivalent_floor_millis

    caps =
      Map.new(catalog.rules.market.replenish_cap, fn {product, cap} ->
        {product, div(cap * @equivalent_floor_millis, old_floor)}
      end)

    %{catalog | npc_profiles: npcs}
    |> put_in([:rules, :demand, :equivalent_floor_millis], @equivalent_floor_millis)
    |> put_in([:rules, :market, :replenish_cap], caps)
  end

  defp drive(authority, clock, first, last, projector, sample) do
    Enum.reduce(first..last, projector, fn tick, projector ->
      :atomics.put(clock, 1, tick * 1_000)
      {us, :ok} = :timer.tc(HallAuthority, :tick, [authority])
      Samples.record(sample, us)
      if sample == :wake_us, do: Samples.record(:wake_with_tick, %{tick: tick, duration_us: us})

      if rem(tick, @projector_interval) == 0 do
        if sample == :wake_us, do: Samples.record(:backlog, backlog())
        keep_projecting(projector)
      else
        projector
      end
    end)
  end

  defp keep_projecting(projector) do
    case Task.yield(projector, 0) do
      {:ok, {:ok, _position}} -> Task.async(fn -> DailyActivityProjector.catch_up(Repo) end)
      nil -> projector
      other -> raise "Projection failed: #{inspect(other)}"
    end
  end

  defp drain(projector) do
    {:ok, _} = Task.await(projector, 120_000)
    DailyActivityProjector.catch_up(Repo)
  end

  defp backlog do
    %{rows: [[lag]]} =
      Repo.query!("""
      select h.position - coalesce(p.position, 0)
      from append_head h left join projector_checkpoints p on p.name = 'daily_activity'
      where h.id = 1
      """)

    lag
  end

  defp projection_check!(position) do
    # Independent aggregate counts from durable event types, rather than the projector's delta code.
    %{rows: [[visits, trays]]} =
      Repo.query!(
        """
        select count(*) filter (where type = 'visit_admitted'),
               count(*) filter (where type = 'tray_accepted')
        from events where position <= $1
        """,
        [position]
      )

    %{rows: [[^visits, ^trays]]} =
      Repo.query!("""
      select coalesce(sum(visits_admitted), 0), coalesce(sum(trays_accepted), 0) from daily_activity
      """)
  end

  defp event_stats(from, to) do
    %{rows: rows} =
      Repo.query!(
        """
        select type, count(*), sum(octet_length(payload))
        from events where position > $1 and position <= $2 group by type
        """,
        [from, to],
        timeout: 60_000
      )

    %{
      batches: to - from,
      events: Enum.sum(for [_, count, _] <- rows, do: count),
      payload_bytes: Enum.sum(for [_, _, bytes] <- rows, do: bytes),
      types: Map.new(rows, fn [type, count, _bytes] -> {type, count} end)
    }
  end

  defp storage do
    %{rows: rows} =
      Repo.query!("""
      select relname, pg_table_size(relid), pg_indexes_size(relid)
      from pg_stat_user_tables order by relname
      """)

    Map.new(rows, fn [table, bytes, indexes] -> {table, %{table_bytes: bytes, index_bytes: indexes}} end)
  end

  defp settings do
    %{rows: rows} =
      Repo.query!("""
      select name, setting, coalesce(unit, '') from pg_settings
      where name in ('server_version', 'fsync', 'synchronous_commit', 'full_page_writes',
                     'shared_buffers', 'wal_compression')
      """)

    Map.new(rows, fn [name, value, unit] -> {name, String.trim(value <> " " <> unit)} end)
  end
end

[days, report] = System.argv()
FeudHall.CapacityBench.run(String.to_integer(days), report)
