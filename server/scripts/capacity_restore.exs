# Executed only against the isolated source or restored database from capacity_bench.py.
alias FeudHall.Application.Replay
alias FeudHall.Infrastructure.{PostgresEventStore, Repo, Snapshot}
alias FeudHall.Infrastructure.Postgres.DailyActivityProjector

[database, mode] = System.argv()
true = database in ["feud_hall_bench", "feud_hall_bench_restore"]
true = mode in ["observe", "rebuild"]
true = mode != "rebuild" or database == "feud_hall_bench_restore"
true = System.get_env("FEUD_HALL_SERVE") != "1"
nil = System.get_env("DATABASE_URL")
config = Application.fetch_env!(:feud_hall, Repo)
true = config[:hostname] in ["localhost", "127.0.0.1"]
Application.put_env(:feud_hall, Repo, Keyword.merge(config, database: database, log: false))
{:ok, _} = Application.ensure_all_started(:feud_hall)

%{rows: [[^database]]} = Repo.query!("select current_database()")
store = PostgresEventStore.new(Repo, "hall:capacity")
{genesis_us, {:ok, base}} = :timer.tc(Replay, :load, [PostgresEventStore, store])
%{position: head, hall: hall, control: control, versions: versions} = base

snapshot = Enum.find(PostgresEventStore.snapshots(store), & &1.verified)
{:ok, %{state: saved, position: position} = decoded} = Snapshot.load(snapshot.body)
snapshot_base = %{position: position, hall: saved.hall, control: saved.control, versions: decoded[:versions]}
{tail_us, {:ok, tail}} = :timer.tc(Replay, :load, [PostgresEventStore, store, [base: snapshot_base, head: head]])
true = {tail.hall, tail.control, tail.versions} === {hall, control, versions}

# Include the complete canonical hall and control state in the comparison without logging any data.
fingerprint = fn value ->
  :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])) |> Base.encode16(case: :lower)
end

tables = ~w(batches events receipts content authority outbox snapshots)

counts =
  Map.new(tables, fn table ->
    %{rows: [[count]]} = Repo.query!("select count(*) from " <> table)
    {table, count}
  end)

{:ok, head} = DailyActivityProjector.catch_up(Repo)

views = fn ->
  balances = Enum.map(PostgresEventStore.projection(store, :balances), &Map.delete(&1, :position))
  stock = Enum.map(PostgresEventStore.projection(store, :stock), &Map.delete(&1, :position))
  daily = Repo.query!("select * from daily_activity order by day, restaurant_id").rows
  fingerprint.({balances, stock, daily})
end

projected = views.()

rebuild_us =
  if mode == "rebuild" do
    {elapsed, :ok} =
      :timer.tc(fn ->
        :ok = PostgresEventStore.rebuild_projections(store)
        {:ok, ^head} = DailyActivityProjector.rebuild(Repo)
        ^projected = views.()
        :ok
      end)

    elapsed
  end

IO.puts(
  "ARCHIVE_REPORT " <>
    Jason.encode!(%{
      head: head,
      stream_versions: versions,
      tables: counts,
      state_sha256: fingerprint.({hall, control}),
      projections_sha256: projected,
      genesis_us: genesis_us,
      snapshot_tail_us: tail_us,
      rebuild_us: rebuild_us
    })
)
