# Milestone 2: Durable Shared Simulation — Implementation Design

Status: approved by the owner, 2026-11-09.

This document scopes Milestone 2 of the
[implementation sequence](../../GAME_DESIGN.md#implementation-sequence) as a
build plan for the existing `server/` Elixir project. It does not restate or
change gameplay rules or technical contracts: the
[game design](../../GAME_DESIGN.md) owns rules and proposed tuning, and the
[architecture](../../ARCHITECTURE.md) owns persistence, scheduling, and
verification contracts. Where this document says "per X", X is authoritative.
Decisions marked **(builder's call)** were made while scoping and were not
chosen by the owner; they may be revisited without reopening the owner's
decisions.

## Intent

Milestone 1 delivered a pure, in-memory economic core: one cuisine, explicit
kitchen commands, purchases at list price, and no persistence. Milestone 2 makes
that core durable and gives it a living hall: committed facts survive crashes in
PostgreSQL, a market and a stream of simulated diners replace the stand-ins, the
kitchen runs on its own, and NPC owners compete through the same commands as a
human.

There is still no UI, network API, or Phoenix. **The owner's acceptance bar is a
thorough test suite for the new functionality that passes reliably**, plus a
separately recorded 150-stall measurement.

## Goals

The milestone exit condition, per the implementation sequence: human and NPC
rules agree; crash and snapshot/genesis recovery preserve committed facts; and
recorded 150-stall append/replay measurements qualify (or disqualify) the
storage approach. The work is three projects, built in this order.

### Project A: durable storage

A PostgreSQL adapter for the existing `FeudHall.Application.EventStore` port,
meeting the [streams and atomic append](../../ARCHITECTURE.md#streams-and-atomic-append)
contract. The domain, `CommandWorkflow`, and their tests keep working against
both the in-memory and PostgreSQL adapters.

- **Atomic batch commit.** One transaction writes the complete event batch, the
  command receipt, any outbox intents, and the required synchronous
  projections. Any failure writes none of them.
- **Global commit order.** The transaction locks a single append-head row first,
  then stream heads in a fixed order, checks expected versions and the fencing
  epoch, appends, advances heads, and allocates a global batch position. Unique
  constraints on stream version and event ID back up the checks. An independent
  SQL sequence is not used as commit order.
- **Two streams.** `hall:{id}` carries gameplay. A service-level `control`
  stream carries availability epochs and recovery identities (the identity
  stream's other duties arrive with accounts in Milestone 3). A batch touching
  both commits atomically or not at all; recovery reconciliation is the first
  real user. **(builder's call:** the hall keeps Milestone 1's single master
  tick as its clock; control-stream availability facts record epochs rather
  than a second clock.)
- **Receipts.** Same semantics as Milestone 1: bound to actor, kind, and
  canonical payload fingerprint; retries return the original receipt; a changed
  payload under the same ID is a conflict; a lost reply is resolved by the same
  ID before new commands are admitted.
- **Fencing.** A hall-authority ownership record with a monotonically increasing
  epoch. Acquiring ownership bumps the epoch; every append verifies it. A
  superseded owner's append is refused and appends nothing.
- **Event envelopes** carry the fields listed in the architecture (event ID,
  type, schema version, stream/version, batch ID and order, actor, causation and
  correlation IDs, content hash, clock context). Payloads use the existing
  allowlisted `EventCodec`; unknown types or versions block recovery.
- **Immutable content** is stored by content hash; `HallInitialized` references
  it, and recovery loads it by hash.
- **Snapshots** in PostgreSQL, per the
  [snapshot contract](../../ARCHITECTURE.md#snapshots-replay-and-historical-compatibility):
  taken at a complete batch boundary without holding the append lock, verified
  before becoming the default, at least one previous valid snapshot retained,
  corrupt or incompatible ones skipped in favour of an earlier one or genesis.
  Cadence per the tuning register (10,000 events or five service minutes).
- **Projections.** **(builder's call:** one synchronous projection — current
  restaurant ledger balances and stock positions — written in the append
  transaction; and one asynchronous projector — a per-day sales/visit report —
  that applies whole batches and its checkpoint in one transaction and ignores
  duplicate deliveries.) Both can be dropped and rebuilt from the log.
- **Outbox.** The table and its atomic write exist and are covered by store
  tests. No delivery worker is built, because nothing in this milestone sends
  external messages.
- **Recovery.** Acquire fenced ownership; load the newest valid snapshot (or
  genesis); apply later batches with no commands or side effects; validate
  balances, claims, and clocks; then append one idempotent reconciliation batch
  keyed by a durable recovery identity before accepting commands. An unobserved
  gap over five real seconds enters recovery instead of charging the gap as
  play time, per [clock continuity](../../ARCHITECTURE.md#recorded-decisions-and-clock-continuity).
- **Hall authority process.** A supervised process owns one hall's runtime:
  it wakes once per real second, advances the clocks from monotonic elapsed
  time, runs due boundary work, and serializes commands through
  `CommandWorkflow`. The clock source is injected so tests drive time
  explicitly.
- **Diagnostic logging.** The architecture requires structured diagnostic
  logging [alongside each application slice](../../ARCHITECTURE.md#observability-and-diagnostic-logging),
  and this is the first slice with a shell, so it is in scope. Wrappers (never
  the pure domain) emit versioned, allowlisted records for command attempts and
  terminal outcomes (including commit-unknown and receipt replay), the authority
  lifecycle and scheduler lateness, fencing changes, storage failures,
  replay/recovery, projection backlog, market fills, and NPC planner failures,
  with command, batch, epoch, and clock context. Export is bounded and
  asynchronous, with drop counters, and can never block the authority or change
  an outcome. Milestone 1's `CommandWorkflow` gains the same wrapper. The
  [observability qualification](../../TESTING.md#observability-qualification)
  items that need Phoenix, clients, helpers, licensing, or a release
  environment wait for those slices.

### Project B: shared simulation

New gameplay, built in the pure domain first and then wired through the
authority. Rules and tuning follow the cited game-design sections; tuning values
are authored as versioned content, not hardcoded.

- **Wholesale market** per [competing for supplies](../../GAME_DESIGN.md#8-competing-for-supplies).
  Purchases become pending requests that clear in batches every ten real
  seconds (240 hall seconds). Finite stock per product; one published
  scarcity price per batch, clamped between a positive minimum and finite
  maximum; consolidation per restaurant and product; budget and storage
  reserved in the restaurant's ingredient priority (stable default order);
  proportional allocation with integer largest remainders and a rotating
  deterministic tie-break; atomic fill; unfilled quantities expire. Replenishment
  on a schedule, scaled to the same previous-day business forecast as demand.
  This replaces Milestone 1's instant list-price purchase. **(builder's call:**
  stock held by the wholesale market does not age; a fill starts the product's
  full shelf life at the fill time, as Milestone 1 purchases do. Only unfilled
  requests expire.)
- **Simulated diners** per [a finite pool of diners](../../GAME_DESIGN.md#a-finite-pool-of-diners)
  and [customer segments](../../GAME_DESIGN.md#customer-segments-and-decisions).
  One hall-wide arrival stream: about 90 arrivals per game day per operating
  business equivalent (floor three), distributed by a meal-period curve that is
  zero during cleaning, with a fractional accumulator carried forward. Each
  arrival gets a segment, budget, patience, and dietary profile from seeded
  draws, then a bounded weighted choice among eligible stalls (best eligible
  dish plus bounded variety, location exposure applied once) or leaving. The
  seeded drink attachment and later dessert decision reuse Milestone 1's tray
  and dessert flow. Choices and the random continuation are recorded in events;
  replay never draws again.
- **Kitchen jobs.** **(builder's call:** "jobs" in the milestone table is read
  as automatic production jobs.) Each stall gets a fixed station capacity from
  content. Accepted work queues FIFO, starts when capacity frees, finishes at
  its scheduled ready time, and ready trays are handed over FIFO by the final
  component's ready time. This replaces the `{:system, :kitchen}` commands;
  Milestone 1 tests are migrated to advance time instead. Staff, coverage,
  fatigue, and wages remain Milestone 3.
- **Basic NPC owners** per [NPC competition](../../GAME_DESIGN.md#14-npc-competition-and-population-changes).
  Hall initialization creates three NPC restaurants (budget volume, dependable
  mainstream, premium quality) with the same starter capital as a human. About
  once per game hour, a pure planner reads only public information and
  the NPC's own books and returns ordinary commands (prices, menu, substitution
  policy, purchase requests), which go through the same `CommandWorkflow`,
  validation, and receipts as a human's. Replay applies the recorded facts and
  never reruns the planner. Retirement and restoration remain Milestone 4.
  **(builder's call:** "public information" is a named public projection that
  Milestone 3 must also show human owners: published market prices and
  available market stock, each open stall's menu, prices, and exposure tier,
  and hall-wide demand summaries from completed days. It excludes rivals' cash,
  inventory, orders, and costs, and any undrawn random state. The planner
  receives only that projection plus its own restaurant, enforced by its
  function signature and a test.)
- **Location exposure.** **(builder's call:** the hall layout records each slot's
  exposure tier at initialization and stalls keep it; diner choice uses it.
  Rent and holding charges arrive with leases in Milestone 3.)
- **One cuisine.** **(builder's call, owner-reviewed:** every restaurant, human
  or NPC, stays Mexican; they compete on price, quality, exposure, and
  availability. The other nineteen cuisines arrive in Milestone 4.)

### Project C: the 150-stall measurement

A script, not a test: it creates its own disposable database, runs a
150-stall workload (three NPC profiles plus planner-driven stand-in owners, so
no sessions or helpers yet) through the authority and the PostgreSQL store for
a stated number of game days, and writes a report: append latency
percentiles, events and bytes per second and per day, table and index growth,
snapshot size and time, full replay time, and snapshot-tail replay time. The
numbers are recorded for the owner to judge; nothing passes or fails on them.
The report states its machine, PostgreSQL version, and workload limits.

**(builder's call:** the run uses an accelerated injected clock that still
steps one available-service second per wake-up, so each batch has the same
shape as in production while wake-ups run back to back. The report gives
per-append latency and sustained throughput and labels the run accelerated.
The number of game days is a script option; the default covers several
complete game days, including cleaning and both meal peaks. The architecture's
30-real-day (720-game-day) full-replay measurement is not attempted locally in
this milestone; the report says so and extrapolates nothing.)

## Non-goals

Phoenix, channels, HTTP, or any UI; staff, wages, helpers, and guest helper
shifts; leases, rent, and holding costs; accounts, invitations, licensing, and
authentication; owner absence and unattended operation; NPC retirement and
restoration; cuisines beyond Mexican; reports beyond the one async projection;
outbox delivery workers; backups, archival, and Render deployment; the full
450-session peak workload.

## Anti-goals

The milestone fails, even if features work, if any of these hold:

- A test depends on real elapsed time, sleeps, scheduling luck, test order, or
  shared database state, so it can pass or fail without a code change.
- Current-state tables become a second source of truth, or a derived write
  bypasses events.
- Replay draws new diners, reruns the NPC planner, or produces side effects.
- NPCs gain information or resources a human owner would not have.
- A rejected, conflicted, or fenced append leaves a partial batch, receipt, or
  projection row.

## Constraints

- **Database:** use the PostgreSQL 18 server Homebrew already runs locally on
  port 5432. Do not start Docker, extra database servers, or other external
  processes. Tests and the measurement script use their own databases inside
  that server (for example `feud_hall_test`, `feud_hall_bench`). CI declares its
  own PostgreSQL service because hosted runners have none.
- **Stack:** Ecto and Postgrex per AGENTS.md. **(builder's call:** a minimal
  hand-written adapter rather than the EventStore library, which the
  architecture says has not been shown to meet the cross-stream and fencing
  contract.)
- **Local resources:** combined memory of the BEAM, PostgreSQL backends, and
  tooling stays under 2 GiB. On 2026-11-09 the owner gave the advance
  permission AGENTS.md requires for full local `mix test` runs within that
  limit; run them serially with memory sampled throughout and abort above the
  limit. The mutation cohort keeps running in an isolated scratch copy, as in
  Milestone 1, under the same limit. No `tsc`.
- **Git:** work on a new local branch based on `milestone-1-economic-core`.
  Nothing is pushed; CI cannot provide evidence, so local runs must.
- **Purity:** domain modules stay free of Ecto, processes, and ambient clocks;
  the architecture test is extended to the new modules. Randomness uses an
  explicit, persisted generator state **(builder's call:** a small pure PRNG
  implemented in the domain rather than `:rand`, so its state is a plain
  integer and its sequence cannot drift with OTP releases.)

## Verification

The owner's bar is "thorough and reliable". Concretely:

- **Determinism.** Every test drives time through explicit advances or an
  injected clock and randomness through fixed seeds. No `Process.sleep` or
  wall-clock waits in assertions.
- **Isolation.** Database tests own their data: each test creates or truncates
  what it uses; concurrency and crash tests use real separate connections and
  transactions (not the Ecto SQL sandbox, which would hide commit behaviour).
  The suite runs serially.
- **Store contract tests** run the same cases against the in-memory and
  PostgreSQL adapters: expected-version conflicts, two concurrent writers from
  one head, multi-stream atomicity, receipts and retries, fencing, a crash before
  commit (killing the Elixir process holding the transaction), a lost reply
  after commit, unknown events blocking recovery, snapshot fallback, and
  projection checkpoints never ahead of their writes.
- **Simulation examples** for each rule, including exact boundaries: market
  allocation with contention, partial fills, budget and storage limits, price
  clamps, replenishment, request splitting gaining nothing; arrival totals
  preserved across clock partitioning and with no catch-up after cleaning;
  incompatible food never chosen; duplicate menu rows not multiplying demand;
  exposure applied once; station capacity and handover order; and an identical
  command from a human and an NPC producing identical outcomes.
- **Property traces** extend the Milestone 1 property test with market, arrival,
  kitchen, and NPC actions, keeping progress floors so traces are not vacuous,
  and compare live, genesis, snapshot-tail, and codec round-trip state. A smaller
  sampled set runs the same traces through PostgreSQL with restarts and injected
  commit failures.
- **Diagnostics** follow the applicable observability qualification items: an
  in-memory sink checks schema, reason codes, and correlation; no
  committed-success record precedes the append; sentinel secrets are redacted;
  and a failing or full exporter leaves events, receipts, and balances identical
  to a run with diagnostics disabled.
- **Oracles** gain market conservation (initial stock + replenishment = filled +
  remaining), arrival accounting (arrivals = admitted + left, per source), and
  projection-versus-fold agreement.
- **Mutation cohort** adds curated faults from the
  [architecture list](../../ARCHITECTURE.md#early-qualification-and-ongoing-tests):
  skip the expected-version or fencing check, accept half a batch, advance a
  checkpoint before its writes, side effects during replay, plus market and
  arrival faults. Every mutant must be killed by a behavioural assertion.
- **Evidence.** At the end of each project, the full suite runs locally several
  times with different seeds under the memory limit, and the results are
  reported exactly, including anything not verified.

## Documentation updates

Update the implementation status in `docs/ARCHITECTURE.md`, the implemented
entry points in `docs/TESTING.md`, and `AGENTS.md` as commands become real, and
record the measurement run's results and limits.

## Left to the builder

Module and table layout, event names beyond those the architecture names, the
exact scarcity curve, arrival curve, segment weights, NPC heuristics, station
capacities, and snapshot serialization, provided they are authored as validated
versioned content where they are tuning, and stay within the cited contracts.
