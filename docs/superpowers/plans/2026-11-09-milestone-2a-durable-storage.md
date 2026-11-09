# Milestone 2A: Durable Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Milestone 1 economic core durable in the system PostgreSQL with atomic multi-stream batches, receipts, fencing, projections, snapshots, recovery, a supervised hall authority, and diagnostic logging, all proven by deterministic tests.

**Architecture:** The application-owned `EventStore` port grows to a request-shaped append that carries hall and control-stream events, receipt, outbox intents, and synchronous projection rows; the in-memory adapter and a new hand-written Ecto/Postgrex adapter both implement it and share one contract test module. `CommandWorkflow` evolves a candidate state before appending and adopts it only after commit. A pure `Control` domain owns availability epochs and recovery identities; `Recovery` and a `HallAuthority` process form the imperative shell.

**Tech Stack:** Elixir 1.20.4 / OTP 29, Ecto SQL ~> 3.14, Postgrex ~> 0.22, PostgreSQL 18 (Homebrew, already running on localhost:5432), StreamData 1.4 (test only), Elixir `JSON`.

**Spec:** `docs/superpowers/specs/2026-11-09-milestone-2-design.md` (Project A). Contracts it cites: `docs/ARCHITECTURE.md` sections *Simulation scheduling*, *Event persistence*, *Observability and diagnostic logging*, *Architecture verification*; `docs/TESTING.md` *Observability qualification*. Projects B and C get their own plans after this one lands.

## Global Constraints

- Use the PostgreSQL 18 server Homebrew already runs on port 5432. Never start Docker, another database server, or other external processes. Databases: `feud_hall_dev`, `feud_hall_test`.
- Combined RSS of BEAM + PostgreSQL backends + tooling stays under 2 GiB. Full local `mix test` is permitted (owner, 2026-11-09) only with `--max-cases 1`, memory sampled throughout, aborting above the limit. Never run `tsc`.
- Domain modules (`lib/feud_hall/domain/**`) stay pure: no Ecto, processes, Logger, ambient clocks, `:rand`. Application modules never reference `FeudHall.Infrastructure`, Ecto, or Phoenix.
- No test may sleep, wait on wall-clock time, depend on test order, or share database rows with another test. Database test modules are `async: false` and start from truncated tables.
- Current-state tables are derived only; every derived write comes from an event batch in the same transaction (synchronous) or under a checkpoint (asynchronous).
- Replay never issues commands, runs planners, or produces outbox/diagnostic side effects as new live work.
- Work on branch `milestone-2-durable-simulation` (already created, based on `milestone-1-economic-core`). Commit after each task; never push. Inspect `.git/hooks` before the first commit (none exist today).
- Money and event payloads stay exact integers; payloads are stored as the existing `EventCodec` JSON text, never through floats.
- Run backend commands from `server/`. Format with `mix format`; compile with `--warnings-as-errors`.

## Review Focus

1. **A hung writer holding the append-head lock** (crashed mid-transaction on another connection) must make a second writer fail with `{:error, :unavailable}` within the configured `lock_timeout`, not block forever. Test added to Task 5.
2. **A very large batch** (a long catch-up advance producing thousands of events) must append in one transaction without hitting PostgreSQL's 65,535 bind-parameter limit. Test added to Task 4.
3. **Player text with NUL bytes, emoji, and quotes** (a restaurant name) must round-trip exactly through the PostgreSQL store; `text` columns reject raw NUL, so it must stay JSON-escaped. Test added to Task 4.
4. **The database refusing connections** (wrong port) must surface as `{:error, :unavailable}` from append and recovery, never as a crash that loses the in-memory head. Test added to Task 4.
5. **Storage unavailable during an authority tick** must freeze the clocks at the last committed boundary; the next successful tick after more than five unobserved seconds enters recovery instead of charging the gap. Test added to Task 12.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `server/config/{config,dev,test}.exs` | Repo and database settings; reads `PGUSER`/`PGPASSWORD`/`PGHOST`/`PGPORT` with local defaults |
| `server/lib/feud_hall/app.ex` | OTP application: starts `Repo`, the diagnostics exporter, and the authority supervisor |
| `server/priv/repo/migrations/20261109000001_create_event_store.exs` | All event-store, projection, snapshot, outbox, and authority tables |
| `server/lib/feud_hall/application/event_store.ex` | Port v2 (modified) |
| `server/lib/feud_hall/application/command_workflow.ex` | Candidate-state append, control routing, diagnostics wrapper (modified) |
| `server/lib/feud_hall/application/projections/balances.ex` | Pure synchronous projection rows from `(before, after)` hall states |
| `server/lib/feud_hall/application/projections/daily_activity.ex` | Pure async projection deltas from a batch |
| `server/lib/feud_hall/application/recovery.ex` | Fenced recovery: snapshot selection, tail replay, invariant check, reconciliation |
| `server/lib/feud_hall/application/diagnostics.ex` | Diagnostics port, record schema, allowlist/redaction |
| `server/lib/feud_hall/application/monotonic_clock.ex` | Clock port used by the authority |
| `server/lib/feud_hall/domain/control.ex` | Pure control stream: availability epochs and recovery identities |
| `server/lib/feud_hall/domain/hall/invariants.ex` | Pure recovery-time invariant checks |
| `server/lib/feud_hall/infrastructure/repo.ex` | `Ecto.Repo` |
| `server/lib/feud_hall/infrastructure/postgres_event_store.ex` | PostgreSQL adapter for the port |
| `server/lib/feud_hall/infrastructure/postgres/daily_activity_projector.ex` | Async projector with checkpoint |
| `server/lib/feud_hall/infrastructure/diagnostics/{memory_sink,exporter}.ex` | Test sink; bounded async exporter |
| `server/lib/feud_hall/infrastructure/{system_clock,manual_clock}.ex` | Monotonic clock adapters (manual one is for tests and the measurement script) |
| `server/lib/feud_hall/infrastructure/hall_authority.ex` | Supervised authority process |
| `server/test/support/{postgres_case,event_store_contract,hall_trace}.ex` | DB test case, shared adapter contract, extracted trace generator |

---

### Task 1: Database dependencies, Repo, schema, and test case

**Files:**
- Modify: `server/mix.exs`, `server/.formatter.exs`, `server/test/test_helper.exs`, `.github/workflows/server.yml`
- Create: `server/config/config.exs`, `server/config/dev.exs`, `server/config/test.exs`, `server/lib/feud_hall/app.ex`, `server/lib/feud_hall/infrastructure/repo.ex`, `server/priv/repo/migrations/20261109000001_create_event_store.exs`, `server/test/support/postgres_case.ex`
- Test: `server/test/feud_hall/infrastructure/schema_test.exs`

**Interfaces:**
- Produces: `FeudHall.Infrastructure.Repo`; `FeudHall.PostgresCase` (`use FeudHall.PostgresCase` gives `async: false`, truncates every table listed in `@tables` with `RESTART IDENTITY` and re-seeds `append_head` with position 0 in `setup`); tables below.

- [ ] **Step 1: Add deps and app module.** `{:ecto_sql, "~> 3.14"}`, `{:postgrex, "~> 0.22"}`; `application: [mod: {FeudHall.App, []}, extra_applications: [:logger, :crypto]]`; aliases `test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]`. Read the alias chain once to confirm it runs nothing else. `.formatter.exs` adds `import_deps: [:ecto, :ecto_sql]` and `priv/*/migrations` inputs. Run `mix deps.get` (Hex cache already holds ecto 3.14.2, ecto_sql 3.14.0, postgrex 0.22.4) and commit the updated `mix.lock`.

- [ ] **Step 2: Configure.** `config :feud_hall, ecto_repos: [FeudHall.Infrastructure.Repo]`. Test: database `feud_hall_test`, `pool_size: 6`, `username: System.get_env("PGUSER") || System.get_env("USER")`, `password: System.get_env("PGPASSWORD")`, `hostname: System.get_env("PGHOST", "localhost")`, `port: String.to_integer(System.get_env("PGPORT", "5432"))`, `parameters: [lock_timeout: "2000"]`. Dev: same with `feud_hall_dev`. No secrets in files.

- [ ] **Step 3: Write the migration.** Tables (all `bigint` positions/versions, `text` IDs):
  - `append_head(id smallint primary key check (id = 1), position bigint not null)`
  - `stream_heads(stream text primary key, version bigint not null)`
  - `authority(scope text primary key, owner text not null, epoch bigint not null)`
  - `batches(position bigint primary key, command_id text not null unique, hall_ms bigint, inserted_at timestamptz not null default now())`
  - `events(event_id text primary key, position bigint not null references batches, batch_order int not null, stream text not null, stream_version bigint not null, type text not null, schema int not null, payload text not null, actor text not null, causation_id text not null, correlation_id text not null, content_hash text, hall_ms bigint, unique(stream, stream_version), unique(position, batch_order))`
  - `receipts(command_id text primary key, fingerprint text not null, body text not null, position bigint not null)`
  - `outbox(id bigserial primary key, dedupe_key text not null unique, command_id text not null, position bigint not null, kind text not null, payload text not null)`
  - `content(content_hash text primary key, body bytea not null)`
  - `snapshots(id bigserial primary key, position bigint not null, evolution int not null, body bytea not null, verified boolean not null default false)`
  - `restaurant_balances(restaurant_id text, account text, amount bigint not null, position bigint not null, primary key (restaurant_id, account))`
  - `restaurant_stock(restaurant_id text, product text, on_hand bigint not null, reserved bigint not null, position bigint not null, primary key (restaurant_id, product))`
  - `daily_activity(day int, restaurant_id text, visits_admitted int not null, trays_accepted int not null, primary key (day, restaurant_id))`
  - `projector_checkpoints(name text primary key, position bigint not null)`

- [ ] **Step 4: Write the failing test** `schema_test.exs` (`use FeudHall.PostgresCase`):

```elixir
test "migrations create the event store with an append head at zero" do
  assert %{rows: [[0]]} = Repo.query!("select position from append_head where id = 1")
  assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
           Repo.query("insert into append_head (id, position) values (2, 0)")
end
```

- [ ] **Step 5: Run** `mix test test/feud_hall/infrastructure/schema_test.exs` — expect FAIL before the migration/case exist, PASS after.

- [ ] **Step 6: CI.** In `server.yml` add a `postgres:18` service to both jobs (`POSTGRES_PASSWORD: postgres`, health check `pg_isready`, port 5432) and job env `PGUSER: postgres`, `PGPASSWORD: postgres`, `PGHOST: localhost`. Keep the comment that the full suite runs in CI, and add that local full runs need the owner's permission.

- [ ] **Step 7: Confirm Milestone 1 still passes** by running each existing test file on its own (`mix test <file> --max-cases 1`).

- [ ] **Step 8: Commit** — `git commit -m "Add Ecto, the event-store schema, and a PostgreSQL test case"`

### Task 2: Port v2, in-memory adapter, and candidate-state workflow

**Files:**
- Modify: `server/lib/feud_hall/application/event_store.ex`, `server/lib/feud_hall/infrastructure/in_memory_event_store.ex`, `server/lib/feud_hall/application/command_workflow.ex`, `server/test/feud_hall/application/command_workflow_test.exs`
- Create: `server/lib/feud_hall/application/projections/balances.ex`, `server/test/support/event_store_contract.ex`
- Test: `server/test/feud_hall/infrastructure/in_memory_event_store_test.exs`, `server/test/feud_hall/application/balances_projection_test.exs`

**Interfaces:**
- Produces (port v2, exact):

```elixir
@type batch :: %{position: pos_integer(), command_id: String.t(), hall_ms: non_neg_integer() | nil,
                 events: [map()], control_events: [map()]}
@type append_request :: %{
        command_id: String.t(), expected_position: non_neg_integer(),
        expected_versions: %{hall: non_neg_integer(), control: non_neg_integer()},
        hall_stream: String.t() | nil, events: [map()], control_events: [map()],
        receipt: map(), outbox: [%{dedupe_key: String.t(), kind: atom(), payload: map()}],
        projection_rows: [FeudHall.Application.Projections.Balances.row()],
        context: %{actor: term(), correlation_id: String.t(), content_hash: String.t() | nil, hall_ms: non_neg_integer() | nil}}
@callback head(store) :: non_neg_integer()
@callback stream_versions(store, hall_stream :: String.t() | nil) :: %{hall: non_neg_integer(), control: non_neg_integer()}
@callback read_from(store, after_position :: non_neg_integer()) :: {:ok, [batch]} | {:error, {:undecodable, pos_integer(), term()}}
@callback receipt(store, command_id :: String.t()) :: {:ok, map()} | :none
@callback append(store, append_request) ::
            {:ok, store, non_neg_integer()} | {:error, :conflict | :fenced | :unavailable, store} | {:error, :unknown_outcome, store}
@callback acquire_authority(store, scope :: String.t(), owner :: String.t()) :: {:ok, store, pos_integer()} | {:error, :unavailable}
@callback save_snapshot(store, position :: non_neg_integer(), binary()) :: {:ok, snapshot_id :: term()} | {:error, :unavailable}
@callback mark_snapshot_verified(store, snapshot_id :: term()) :: :ok
@callback snapshots(store) :: [%{id: term(), position: non_neg_integer(), body: binary(), verified: boolean()}]   # newest first
@callback projection(store, :balances | :stock) :: [map()]
```

- `Balances.changes(before :: Hall.state(), after :: Hall.state(), position) :: [row]` where `row :: {:balance, restaurant_id, account, amount} | {:stock, restaurant_id, product, on_hand, reserved} | {:delete_stock, restaurant_id, product}` (position is stamped by the adapter). Only restaurants whose ledger or batch totals changed produce rows.
- `CommandWorkflow` keeps `execute/3`, `resolve/2`, `fingerprint/1`; `open(store_mod, store, opts \\ [])` now returns `{:ok, runtime} | {:error, reason}` (callers in tests updated; `opts` gains `diagnostics:` in Task 11). The runtime struct gains `versions: %{hall: 0, control: 0}`, `control: nil`, `epoch: nil`, `diagnostics: nil`.
- `FeudHall.EventStoreContract`: `use FeudHall.EventStoreContract, adapter: Mod, fresh: fn -> store end` injects the sequential contract cases (this task: appends advance position, rejection receipts append no batch, retry/conflict via receipts, `read_from` ordering, projection rows readable, `stream_versions` advance per stream only when that stream gets events). Tasks 3–9 add cases to it.

- [ ] **Step 1: Write the failing projection test** — `balances_projection_test.exs`: after `stocked_world()` buying 100 g of rice, `Balances.changes(before, after, 7)` contains `{:balance, "r1", :cash, after_cash}` and `{:stock, "r1", "rice_long", 100, 0}` and no rows for unchanged accounts; `changes(s, s, 7) == []`.
- [ ] **Step 2: Write the failing contract module and its in-memory use** (`in_memory_event_store_test.exs` = `use FeudHall.EventStoreContract, adapter: InMemoryEventStore, fresh: &InMemoryEventStore.new/0`).
- [ ] **Step 3: Run both** — FAIL (undefined functions).
- [ ] **Step 4: Implement port v2 in the in-memory adapter.** It keeps one implicit authority (epoch always valid), stores snapshots in a list, applies `projection_rows` to two maps, and keeps `fail_next/2` (`:before_commit | :lost_reply`).
- [ ] **Step 5: Change `CommandWorkflow.decide_and_append/3`** to compute `candidate = Hall.replay(events, state)` and `Balances.changes(state, candidate, ...)` before appending, pass `hall_stream: "hall:" <> hall_id` (hall_id from state, or from the `initialize_hall` payload), and adopt `candidate` only on `{:ok, ...}`. `{:error, :fenced, _}` returns `{:error, :fenced}` and sets `mode: :fenced`, which rejects all later `execute/3` calls with `{:error, :fenced}`.
- [ ] **Step 6: Update `command_workflow_test.exs`** for `open/2` returning `{:ok, rt}` and the new append shape (the stale-position test builds an `append_request` map). Add: `test "a fenced append stops the runtime"` using an in-memory store armed with `fail_next(store, :fenced)` (add `:fenced` to the allowed failure modes).
- [ ] **Step 7: Run** the two new test files, `command_workflow_test.exs`, and the property test — all PASS.
- [ ] **Step 8: Commit** — `git commit -m "Grow the event-store port to request-shaped appends with projections"`

### Task 3: Control stream domain and multi-stream routing

**Files:**
- Create: `server/lib/feud_hall/domain/control.ex`
- Modify: `server/lib/feud_hall/application/command_workflow.ex`, `server/lib/feud_hall/domain/hall/evolver.ex`, `server/lib/feud_hall/infrastructure/event_codec.ex`, `server/test/support/event_store_contract.ex`
- Test: `server/test/feud_hall/domain/control_test.exs`, `server/test/feud_hall/application/command_workflow_test.exs`

**Interfaces:**
- Produces: `FeudHall.Domain.Control.decide(control_state, hall_state, command, ctx) :: {:ok, %{control: [event], hall: [event]}} | {:error, term}`; `Control.evolve(control_state, event)`; `Control.replay(events, state \\ nil)`.
  - Commands: `{:start_availability, %{epoch_id: String.t()}}` (actor `{:system, :authority}`) → control `%{type: :availability_started, epoch_id:}`; `{:reconcile_recovery, %{recovery_id: String.t(), epoch_id: String.t()}}` (actor `{:system, :authority}`) → control `%{type: :availability_resumed, recovery_id:, epoch_id:, hall_ms: hall.now}` plus hall `%{type: :hall_resumed, recovery_id:, epoch_id:}`; a second reconcile with the same `recovery_id` → `{:error, :already_reconciled}`.
  - Control state: `%{current_epoch: id | nil, epochs: [id], reconciled: MapSet}`. `Control.pending_recovery_id(state) :: String.t() | nil` returns `"recovery:" <> current_epoch` when the current epoch has not been resumed by a later epoch.
- Hall evolver: `:hall_resumed` sets `state.availability_epoch` (new key, initialised `nil` at `hall_initialized`).
- Workflow: control kinds `start_availability reconcile_recovery` route through `Control.decide/4`; runtime fields `control` and `versions.control` maintained; actor capability `:authority` accepted for `{:system, _}`.
- Codec allowlist adds the new event types and keys (`availability_started availability_resumed hall_resumed epoch_id recovery_id hall_ms availability_epoch`).

- [ ] **Step 1: Failing domain tests** (`control_test.exs`): start → pending id is `"recovery:e1"`; reconcile `r` → both streams' events; repeat → `{:error, :already_reconciled}`; non-authority actor → `{:error, :forbidden}`.
- [ ] **Step 2: Failing workflow test** `test "reconciliation appends control and hall events in one batch"`: after `start_availability`, `reconcile_recovery` yields one batch whose `events` has `:hall_resumed`, whose `control_events` has `:availability_resumed`, and `rt.versions` advanced by one on each stream.
- [ ] **Step 3: Add contract case** `"a batch touching both streams advances both versions or neither"` (in-memory with `fail_next(:before_commit)` leaves both versions unchanged).
- [ ] **Step 4: Run** — FAIL; **implement**; **run** domain, workflow, contract, codec round-trip tests — PASS.
- [ ] **Step 5: Commit** — `git commit -m "Add the control stream for availability epochs and recovery identities"`

### Task 4: PostgreSQL adapter: append, read, receipts, content

**Files:**
- Create: `server/lib/feud_hall/infrastructure/postgres_event_store.ex`
- Test: `server/test/feud_hall/infrastructure/postgres_event_store_test.exs`

**Interfaces:**
- Produces: `%FeudHall.Infrastructure.PostgresEventStore{repo: module, scope: String.t(), owner: String.t() | nil, epoch: pos_integer() | nil, hooks: %{before_commit: (-> any) | nil, lost_reply: boolean}}`; `PostgresEventStore.new(repo, scope, opts \\ [])`; implements every port v2 callback.
- Append algorithm (one `repo.transaction`):
  1. `select position from append_head where id = 1 for update`; mismatch with `expected_position` → rollback `:conflict`.
  2. `select epoch from authority where scope = $1 for share`; mismatch with `store.epoch` → rollback `:fenced`.
  3. Lock `stream_heads` rows for the hall and `control` streams in that fixed order (`insert ... on conflict do nothing` then `select ... for update`); mismatch with `expected_versions` → `:conflict`.
  4. If any events: insert `batches` row at `position + 1`; insert events in chunks of 1,000 rows with `event_id = "#{position}:#{order}"`, `causation_id = command_id`, payload `EventCodec.encode!/1`. For `:hall_initialized`, replace `catalog` in the stored payload with `catalog_ref: content_hash` and `insert into content ... on conflict do nothing` with `:erlang.term_to_binary(catalog, [:deterministic])`.
  5. Upsert projection rows stamped with the new position; insert outbox rows; insert the receipt (`body` = `:erlang.term_to_binary(receipt)` encoded Base64 in text — receipts never hold player text beyond the fingerprint); advance heads.
  6. Call `hooks.before_commit` if set, then commit. If `hooks.lost_reply`, return `{:error, :unknown_outcome, store}` after a successful commit.
  - `DBConnection.ConnectionError`/`Postgrex.Error` with lock-timeout code → `{:error, :unavailable, store}`; unique violation on `receipts`/`batches` → `:conflict`.
- `read_from/2` decodes in position/stream/batch-order; rehydrates `catalog_ref` from `content`; missing content or `EventCodec.decode/1` error → `{:error, {:undecodable, position, reason}}`.
- `FeudHall.PostgresCase.fresh_store/0` — test support only: `PostgresEventStore.new(Repo, "hall:test")` with authority acquired.

- [ ] **Step 1: Write the failing test** `postgres_event_store_test.exs`: `use FeudHall.PostgresCase` and `use FeudHall.EventStoreContract, adapter: PostgresEventStore, fresh: &FeudHall.PostgresCase.fresh_store/0` — every contract case from Tasks 2–3 must pass on PostgreSQL. Add PostgreSQL-only cases:

```elixir
test "content is stored once by hash and rehydrated on read" do
  # initialize two halls with the same catalog in separate scopes; one content row; read_from returns full catalogs
end

test "an unknown stored event type blocks reading with its position" do
  # append one batch, then: Repo.query!("update events set payload = $1", [~s({"v":1,"e":{"type":{"$a":"launch_missiles"}}})])
  assert {:error, {:undecodable, 1, {:unknown_atom, "launch_missiles"}}} = PostgresEventStore.read_from(store, 0)
end

test "a 10,000-event batch commits in one transaction" do
  events = for i <- 1..10_000, do: %{type: :clock_advanced, to: i * 24}
  assert {:ok, _, 1} = PostgresEventStore.append(store, request(events: events))
  assert {:ok, [%{events: read}]} = PostgresEventStore.read_from(store, 0)
  assert length(read) == 10_000
end

test "player text with NUL, emoji, and quotes round-trips exactly" do
  name = "Casa \u0000 \"Ñ\" 🌮"
  # initialize the hall and create_restaurant "r1" with this name through CommandWorkflow on this store, then:
  assert {:ok, reopened} = CommandWorkflow.open(PostgresEventStore, store)
  assert reopened.state.restaurants["r1"].name == name
end

test "a refused connection is reported as unavailable" do
  # start a second Repo-like module pointed at port 1 (`FeudHall.UnreachableRepo` in test/support, started in the test with start_supervised)
  assert {:error, :unavailable, _} = PostgresEventStore.append(unreachable_store, request())
end
```

- [ ] **Step 2: Run** `mix test test/feud_hall/infrastructure/postgres_event_store_test.exs --max-cases 1` — FAIL.
- [ ] **Step 3: Implement** the adapter per the algorithm above.
- [ ] **Step 4: Run** — PASS. Also run `command_workflow_test.exs` once with the workflow pointed at PostgreSQL by adding `describe "on PostgreSQL"` cases for receipts/retries/lost reply that reuse the existing helpers with `fresh_store/0`.
- [ ] **Step 5: Commit** — `git commit -m "Add the PostgreSQL event-store adapter"`

### Task 5: Concurrency, crashes, lost replies, and fencing on PostgreSQL

**Files:**
- Modify: `server/lib/feud_hall/infrastructure/postgres_event_store.ex`
- Test: `server/test/feud_hall/infrastructure/postgres_atomicity_test.exs`

**Interfaces:**
- Consumes: `PostgresEventStore.new/3` `hooks` option; `acquire_authority/3` (upsert `authority` with `epoch = epoch + 1`, returns the new epoch in the store struct).

- [ ] **Step 1: Write the failing tests** (each synchronises with messages, never timing):

```elixir
test "two writers from the same head: exactly one commits" do
  # writer A runs append in a Task with hooks.before_commit = fn -> send(test, :a_locked); receive do :go -> :ok end end
  # after :a_locked, writer B's append runs in another Task (blocks on the head row)
  # send :go to A; assert A {:ok, _, 1}; assert B {:error, :conflict, _}; one batch in table
end

test "killing the writer mid-transaction leaves nothing" do
  # before_commit hook sends :locked then blocks; Process.exit(writer, :kill) after :locked
  # assert receipts, batches, events, outbox, restaurant_balances all empty; head still 0; next append at expected 0 succeeds
end

test "a lost reply after commit resolves by the same command id" do
  # hooks.lost_reply = true; workflow returns {:uncertain, id, rt}; CommandWorkflow.resolve(rt, id) -> {:committed, receipt, _}
end

test "a superseded owner cannot append" do
  {:ok, a, 1} = PostgresEventStore.acquire_authority(base, "hall:test", "node-a")
  {:ok, _b, 2} = PostgresEventStore.acquire_authority(base, "hall:test", "node-b")
  assert {:error, :fenced, _} = PostgresEventStore.append(a, request())
  assert %{rows: [[0]]} = Repo.query!("select position from append_head")
end

test "a hung lock holder makes the next writer unavailable within lock_timeout" do
  # A blocks in before_commit holding the head lock; B uses a store whose repo session sets lock_timeout to 200ms
  assert {:error, :unavailable, _} = b_result
end
```

- [ ] **Step 2: Run** `mix test test/feud_hall/infrastructure/postgres_atomicity_test.exs --max-cases 1` — FAIL; **implement** any missing error mapping and the per-store `lock_timeout` option (`SET LOCAL lock_timeout` at transaction start); **run** — PASS. Run the file 10 times in a row (`for i in $(seq 10); do mix test <file> --max-cases 1 --seed $i || break; done`) — all PASS.
- [ ] **Step 3: Commit** — `git commit -m "Prove atomic, fenced appends against concurrent and crashing writers"`

### Task 6: Synchronous projection rebuild

**Files:**
- Modify: `server/lib/feud_hall/infrastructure/postgres_event_store.ex`
- Test: `server/test/feud_hall/infrastructure/projection_test.exs`

**Interfaces:**
- Produces: `PostgresEventStore.rebuild_projections(store) :: :ok` — inside one transaction truncate `restaurant_balances`/`restaurant_stock`, fold all batches with `Hall.replay`, and write `Balances.changes(nil_state_equivalent, state, head)` (treat `nil` before as "every account and product changed"; extend `Balances.changes/3` to accept `nil`).

- [ ] **Step 1: Failing tests**: after a stocked world plus several visits through the workflow on PostgreSQL, `projection(store, :balances)` equals the fold's ledger for every restaurant; after `rebuild_projections/1` the projection rows are identical (sorted) to before; deleting only projection rows and rebuilding restores them while `events`, `receipts`, and `outbox` row counts are unchanged.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Rebuild synchronous projections from the event log"`

### Task 7: Asynchronous daily-activity projector

**Files:**
- Create: `server/lib/feud_hall/application/projections/daily_activity.ex`, `server/lib/feud_hall/infrastructure/postgres/daily_activity_projector.ex`
- Test: `server/test/feud_hall/application/daily_activity_test.exs`, `server/test/feud_hall/infrastructure/daily_activity_projector_test.exs`

**Interfaces:**
- Produces: `DailyActivity.deltas(batch) :: [%{day: non_neg_integer(), restaurant_id: String.t(), visits_admitted: non_neg_integer(), trays_accepted: non_neg_integer()}]`, day = `Clock.day_of(batch.hall_ms)`, from `:visit_admitted` and `:tray_accepted` events.
- `DailyActivityProjector.catch_up(repo, opts \\ []) :: {:ok, applied_position}`: reads batches after the `projector_checkpoints` row `"daily_activity"`, and for each batch in its own transaction: `update projector_checkpoints set position = $new where name = 'daily_activity' and position = $old` (0 rows → skip, already applied), then upsert-add the deltas. `opts[:before_checkpoint]` is a test hook called after the deltas are written and before commit. `rebuild(repo)` truncates `daily_activity`, resets the checkpoint to 0, and catches up.

- [ ] **Step 1: Failing tests**: pure deltas for a batch with two admissions; projector totals equal a direct count over events; running `catch_up` twice changes nothing; delivering the same batch twice (call the per-batch apply directly) adds once; killing the projector inside `before_checkpoint` leaves both the deltas and the checkpoint unapplied; `rebuild` reproduces the same rows.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Add a checkpointed asynchronous daily-activity projector"`

### Task 8: Outbox intents

**Files:**
- Modify: `server/lib/feud_hall/infrastructure/postgres_event_store.ex`, `server/test/support/event_store_contract.ex`
- Test: contract cases (run by both adapter test files)

**Interfaces:**
- Produces: `outbox(store) :: [%{dedupe_key, command_id, position, kind, payload}]` callback on both adapters (add to the port).

- [ ] **Step 1: Contract cases**: an accepted append with two outbox intents stores both with the batch position; a `:before_commit` failure stores none; a second append reusing a `dedupe_key` is a `:conflict` and writes nothing; a rejection receipt can carry no outbox intents (`append` with `events: []` and non-empty `outbox` returns `{:error, :invalid_request, store}`).
- [ ] **Step 2: Run** both adapter files — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Write outbox intents atomically with their batch"`

### Task 9: Snapshots in PostgreSQL

**Files:**
- Modify: `server/lib/feud_hall/infrastructure/snapshot.ex`, `server/lib/feud_hall/infrastructure/postgres_event_store.ex`
- Test: `server/test/feud_hall/infrastructure/snapshot_store_test.exs`

**Interfaces:**
- Produces: `Snapshot.take(%{hall: hall_state, control: control_state}, position)` (evolution version bumped to 2; `load/1` returns `%{position:, evolution:, state: %{hall:, control:}}`); `PostgresEventStore.prune_snapshots(store, keep_verified \\ 2)`.

- [ ] **Step 1: Failing tests**: save → unverified; `mark_snapshot_verified` → listed first among verified; pruning keeps the two newest verified and every unverified newer one; a snapshot whose body has one flipped byte fails `Snapshot.load/1` with `:corrupt_snapshot`; a snapshot with `evolution: 1` fails with `:incompatible_snapshot`; `save_snapshot` runs in its own transaction and does not take the append-head lock (assert by holding the head lock in a blocked writer and saving a snapshot successfully meanwhile).
- [ ] **Step 2: Run** — FAIL; **implement**; update the Milestone 1 property test's and `command_workflow_test.exs`'s `Snapshot.take/2` calls to the `%{hall:, control:}` shape; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Store verified snapshots in PostgreSQL"`

### Task 10: Recovery and reconciliation

**Files:**
- Create: `server/lib/feud_hall/application/recovery.ex`, `server/lib/feud_hall/domain/hall/invariants.ex`
- Test: `server/test/feud_hall/application/recovery_test.exs`, `server/test/feud_hall/domain/invariants_test.exs`

**Interfaces:**
- Produces: `Invariants.check(hall_state) :: :ok | {:error, [term]}` — trial balance per restaurant, batch reserved ≤ quantity and equal to the sum of reserved orders' claims, every tray component exists, access matches `Clock.cleaning?/1`.
- `Recovery.recover(store_mod, store, owner :: String.t(), opts) :: {:ok, CommandWorkflow.t(), report} | {:error, reason}` with `report :: %{snapshot: position | :genesis, skipped: [{id, reason}], tail_batches: n, recovery_id: id | nil}`. Steps: `acquire_authority`; try verified snapshots newest first, falling back over corrupt/incompatible ones to genesis; `read_from` after the snapshot (an `{:error, {:undecodable, ...}}` aborts with that error); `Invariants.check`; if `Control.pending_recovery_id/1` is non-nil, execute `{:reconcile_recovery, %{recovery_id:, epoch_id: new_epoch_id}}` with command ID `recovery_id` (so a retry by a later owner gets the original receipt); then `{:start_availability, %{epoch_id: new_epoch_id}}` with command ID `"start:" <> new_epoch_id`. `new_epoch_id = "#{owner}:#{epoch}"`. `opts[:side_effects]` must not be called during replay (test passes a function that flunks).

- [ ] **Step 1: Failing tests** (in-memory and PostgreSQL via `describe` blocks):
  - genesis and snapshot recovery produce the same hall state as the live runtime at the same position;
  - a corrupt newest snapshot falls back to the previous verified one, then to genesis, recording both skips;
  - an undecodable event aborts recovery with `{:error, {:undecodable, pos, _}}` and appends nothing;
  - recovery after an interrupted epoch appends exactly one reconciliation batch; a second recovery by another owner (newer epoch) re-runs and gets the same reconciliation receipt via `:replayed`, then starts its own epoch;
  - a broken invariant (state with a hand-corrupted ledger restored from a crafted snapshot) aborts with `{:error, {:invariants, _}}`;
  - the flunking side-effect function is never called.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Recover through fenced snapshot-tail replay and idempotent reconciliation"`

### Task 11: Diagnostics port, redaction, and bounded exporter

**Files:**
- Create: `server/lib/feud_hall/application/diagnostics.ex`, `server/lib/feud_hall/infrastructure/diagnostics/memory_sink.ex`, `server/lib/feud_hall/infrastructure/diagnostics/exporter.ex`
- Modify: `server/lib/feud_hall/application/command_workflow.ex`, `server/lib/feud_hall/application/recovery.ex`
- Test: `server/test/feud_hall/application/diagnostics_test.exs`, `server/test/feud_hall/infrastructure/exporter_test.exs`

**Interfaces:**
- Produces: `Diagnostics` behaviour `@callback emit(sink :: term, record :: map) :: :ok` and `Diagnostics.record(name :: atom, fields :: map) :: map` which builds `%{schema: 1, name:, severity:, at_mono:, fields: allowlisted}`. Allowlist: `command_id kind actor_kind outcome reason attempt position epoch hall_ms duration_us scope recovery_id snapshot_position skipped error_class batch_events backlog lateness_ms`. Any other key is dropped; string values over 128 bytes are truncated; `actor_kind` is `:principal | :system` only (never the principal ID string).
- Names emitted by the workflow: `:command_attempted`, `:command_outcome` (outcome ∈ `:accepted | :rejected | :replayed | :conflict | :fenced | :unavailable | :commit_unknown`); by recovery: `:recovery_started`, `:snapshot_skipped`, `:recovery_completed`, `:recovery_failed`. `:command_outcome` with `:accepted` is emitted only after the append returned `{:ok, ...}`.
- `MemorySink` (Agent) — `start_link/0`, `records/1`. `Exporter` (GenServer) — `start_link(export: (list -> :ok), max_queue: n, batch: n, timeout_ms: n)`, `emit/2` is a cast that drops (and counts) when the queue is full, `stats/1 :: %{queued, exported, dropped, failed}`; export runs in a monitored task with a timeout so a stalled exporter never blocks `emit/2`.
- Runtime gets `diagnostics: {module, sink} | nil`; `CommandWorkflow.open/3` accepts `diagnostics:` in opts.

- [ ] **Step 1: Failing tests**:
  - schema: every record has `schema: 1` and only allowlisted keys;
  - a `create_restaurant` with name `"sentinel-secret-🌮"` produces no record containing that string anywhere (`inspect(records) =~ "sentinel"` is false);
  - with an in-memory store armed `:before_commit`, no `:command_outcome` record has `outcome: :accepted`, and the record says `:unavailable`; with `:lost_reply`, it says `:commit_unknown`;
  - noninterference: run the same 30-command workload with diagnostics `nil`, with `MemorySink`, and with an `Exporter` whose export function raises; final hall state, receipts, and projection rows are identical;
  - exporter: with `max_queue: 3` and a blocked export function, emitting 10 records returns immediately each time and `stats.dropped == 7`; a stalled export (never returns) is cut off by `timeout_ms` and counted in `failed`.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Add bounded, redacted diagnostics around commands and recovery"`

### Task 12: Hall authority process

**Files:**
- Create: `server/lib/feud_hall/application/monotonic_clock.ex`, `server/lib/feud_hall/infrastructure/system_clock.ex`, `server/lib/feud_hall/infrastructure/manual_clock.ex`, `server/lib/feud_hall/infrastructure/hall_authority.ex`
- Modify: `server/lib/feud_hall/app.ex` (adds a `DynamicSupervisor` named `FeudHall.AuthoritySupervisor`)
- Test: `server/test/feud_hall/infrastructure/hall_authority_test.exs`

**Interfaces:**
- Produces: `MonotonicClock` behaviour `@callback now_ms(clock) :: integer`; `SystemClock` (`System.monotonic_time(:millisecond)`); `ManualClock.start_link(start_ms)`, `ManualClock.advance(clock, ms)`.
- `HallAuthority.start_link(opts)` with `store_mod`, `store`, `owner`, `clock: {mod, ref}`, `diagnostics`, `tick_ms: 1000 | :manual`, `max_gap_ms: 5000`, `snapshot_every_events: 10_000`, `snapshot_every_service_ms: 300_000`. Calls: `tick(pid) :: :ok | {:error, reason}`, `execute(pid, envelope) :: workflow result` (stamps `observed_service_ms` from the authority's own service clock, never the caller), `state(pid) :: %{hall:, control:, position:, service_ms:, mode:}`.
- Behaviour: `init` runs `Recovery.recover/4`, sets anchor = clock now, `service_ms` = hall `now / 24`. Each tick: `elapsed = now - anchor`; if `elapsed > max_gap_ms` → do not advance; re-run recovery (new epoch), reset anchor, emit `:scheduler_gap`; else append `{:advance_clock, %{to_service_ms: service_ms + elapsed}}` with command ID `"tick:#{epoch}:#{target_service_ms}"`, and on success move the anchor. On `{:error, :unavailable}` keep the anchor (clocks frozen), emit `:storage_failure`. On `:fenced` stop with `{:shutdown, :fenced}`. After each committed batch, take a snapshot when either threshold is reached, save, load and compare, mark verified, prune. Diagnostics: `:authority_acquired` (epoch), `:tick_late` when `elapsed > 1500` (lateness_ms), `:scheduler_gap`, `:storage_failure`, `:fenced`, `:snapshot_taken` (position, duration_us), and `:projection_backlog` (head minus the daily-activity checkpoint, read after each snapshot).

- [ ] **Step 1: Failing tests** (all with `tick_ms: :manual` and `ManualClock`):
  - three ticks of 1,000 ms move hall time by exactly 72,000 ms and append three batches;
  - ticks of 400 + 600 ms and a single 1,000 ms tick reach the same state (partition equivalence);
  - a 6,000 ms gap appends no advance, starts a new epoch through recovery, and hall time is unchanged by the gap;
  - **(Review Focus 5)** with the store failing the next append (`fail_next(:before_commit)` in-memory; for PostgreSQL, a store pointed at an unreachable repo for one tick), the tick returns `{:error, :unavailable}`, hall time is unchanged, and a following tick after a 6,000 ms total gap enters recovery instead of advancing 6 s;
  - a second authority acquiring the same scope makes the first stop with `{:shutdown, :fenced}` on its next append;
  - `execute/2` ignores any caller clock and stamps its own;
  - the `MemorySink` receives `:authority_acquired`, `:scheduler_gap`, `:storage_failure`, and `:fenced` records in the scenarios above, each with the epoch;
  - with `snapshot_every_events: 5`, a verified snapshot exists after enough ticks and a fresh authority recovers from it (report shows the snapshot position).
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS (in-memory and PostgreSQL `describe` blocks).
- [ ] **Step 3: Commit** — `git commit -m "Run each hall under a fenced, clock-injected authority process"`

### Task 13: PostgreSQL trace property

**Files:**
- Create: `server/test/support/hall_trace.ex`, `server/test/feud_hall/properties/postgres_trace_property_test.exs`
- Modify: `server/test/feud_hall/properties/hall_trace_property_test.exs` (uses the extracted module; behaviour unchanged)

**Interfaces:**
- Produces: `FeudHall.HallTrace.action/0` (the existing generator), `HallTrace.run(actions, opts) :: %{state:, events:, commands: [{command, ctx}], stats:}` — the existing interpreter, now also recording every decided `{command, ctx}` in order.

- [ ] **Step 1: Extract** the generator and interpreter unchanged into `HallTrace`; run the existing property — PASS with the same progress floors.
- [ ] **Step 2: Write the PostgreSQL property** (`@runs 15`, `max_actions 40`, `initial_size: 30`): generate actions, run the pure trace, then replay its `commands` through `CommandWorkflow` on PostgreSQL, inserting at generated points (a) an authority restart via `Recovery.recover/4`, (b) a `before_commit` failure followed by a retry of the same command, (c) a `lost_reply` followed by `resolve/2`. Assert the final hall state equals the pure trace's state, the receipts count equals the commands count, `Invariants.check/1` is `:ok`, `rebuild_projections/1` leaves projection rows unchanged, and genesis replay from PostgreSQL equals the live state. Progress floor: across all runs at least 10 restarts, 10 before-commit failures, and 10 lost replies were exercised.
- [ ] **Step 3: Run** `mix test test/feud_hall/properties/postgres_trace_property_test.exs --max-cases 1` with three seeds — PASS; record runtime and peak RSS.
- [ ] **Step 4: Commit** — `git commit -m "Check PostgreSQL traces with restarts and injected commit failures"`

### Task 14: Architecture boundaries and mutation cohort

**Files:**
- Modify: `server/test/feud_hall/architecture_test.exs`, `server/scripts/mutation_cohort.exs`

- [ ] **Step 1: Extend the architecture test**: domain forbids `Ecto`, `Postgrex`, `Logger` (already) and now also any `FeudHall.Application` alias (already) — add `test "application modules never call Logger or processes directly except diagnostics ports"` forbidding `Logger`, `GenServer`, `Process` in `application/**` except `diagnostics.ex`; add a planted-violation case for it.
- [ ] **Step 2: Add curated mutants** (each with the exact single-match source string and the focused test files that must kill it):
  - skip the append-head expected-position check in `postgres_event_store.ex` → `postgres_event_store_test.exs`, `postgres_atomicity_test.exs`;
  - skip the authority epoch check → `postgres_atomicity_test.exs`;
  - write events without the receipt (accept half a batch) → `postgres_event_store_test.exs`;
  - advance the projector checkpoint before writing deltas → `daily_activity_projector_test.exs`;
  - call `side_effects` during recovery replay → `recovery_test.exs`;
  - adopt the candidate state before append succeeds → `command_workflow_test.exs`;
  - emit `:accepted` before append → `diagnostics_test.exs`;
  - charge the gap instead of entering recovery (`elapsed > max_gap_ms` → `false`) → `hall_authority_test.exs`.
  The cohort's work copy must point its tests at a database named `feud_hall_mutation` (set `MIX_TEST_PARTITION`-style suffix via env `FEUD_HALL_TEST_DB` read in `config/test.exs`) so it never touches `feud_hall_test`.
- [ ] **Step 3: Run** `elixir scripts/mutation_cohort.exs <empty scratch dir>` with RSS sampled — every mutant killed, baseline re-verified.
- [ ] **Step 4: Commit** — `git commit -m "Guard storage boundaries with architecture checks and mutants"`

### Task 15: Documentation and full-suite evidence

**Files:**
- Modify: `docs/ARCHITECTURE.md` (Implementation status), `docs/TESTING.md` (Implemented backend entry points), `AGENTS.md` (verified entry points sentence only)

- [ ] **Step 1: Update docs** with the new modules, the PostgreSQL requirement (system server, `PG*` env vars, databases), how to run focused PostgreSQL tests, the mutation database, and what remains unqualified (Projects B and C, 150-stall measurements).
- [ ] **Step 2: Full-suite evidence**: run `mix test --max-cases 1 --seed <s>` for three seeds while sampling combined RSS of `beam.smp` and `postgres` processes every second (`ps -o rss=` summed), aborting above 2 GiB. Record pass/fail, durations, and peak RSS per run in the task report.
- [ ] **Step 3: Format and compile checks**: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] **Step 4: Commit** — `git commit -m "Document the durable storage slice and its verification"`
