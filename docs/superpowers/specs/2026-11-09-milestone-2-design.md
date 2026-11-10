# Milestone 2: Durable Shared Simulation — Implementation Design

Status: approved by the owner, 2026-11-09; revised 2026-11-09 after Project A
was built and the design was reviewed for consistency and completeness.
Project A is implemented on branch `milestone-2a-durable-storage`; Projects B
and C are not.

This document scopes Milestone 2 of the
[implementation sequence](../../GAME_DESIGN.md#implementation-sequence) as a
build plan for the existing `server/` Elixir project. It does not restate or
change gameplay rules or technical contracts: the
[game design](../../GAME_DESIGN.md) owns rules and proposed tuning, and the
[architecture](../../ARCHITECTURE.md) owns persistence, scheduling, and
verification contracts. Where this document says "per X", X is authoritative.

Three kinds of decision appear below:

- **(owner decision, 2026-11-09)** — chosen by the owner; changing it needs the
  owner.
- **(builder's call)** — made while scoping, within the cited contracts; it may
  be revisited without reopening an owner decision. A builder's call never
  changes a contract; anything that would is an owner decision.
- **Decisions recorded during Project A** — settled while building, listed in
  their own section so later projects build on what exists.
- **Decisions recorded during Project B** — likewise, but they were made by the
  builder's controller while implementing and are **not owner-confirmed**; each
  is a builder's call pending owner confirmation.

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
recorded 150-stall append/replay measurements qualify the storage approach.
**(owner decision, 2026-11-09:** the owner judges the Project C report. If the
owner finds the numbers inadequate, the architecture's
[qualification-failure step](../../ARCHITECTURE.md#early-qualification-and-ongoing-tests)
— investigate event granularity, batching, indexes, snapshot cadence, and
projector placement, and record the adjustment — runs before Milestone 2 is
called done.)

The work is three projects, built in this order.

### Project A: durable storage (implemented)

A PostgreSQL adapter for the application-owned `FeudHall.Application.EventStore`
port, meeting the
[streams and atomic append](../../ARCHITECTURE.md#streams-and-atomic-append)
contract. The domain, `CommandWorkflow`, and their tests work against both the
in-memory and PostgreSQL adapters. The module map and implementation decisions
are kept current in the architecture's
[implementation status](../../ARCHITECTURE.md#implementation-status).

- **Atomic batch commit.** One transaction writes the complete event batch, the
  command receipt, any outbox intents, and the required synchronous
  projections. Any failure writes none of them.
- **Global commit order.** The transaction locks a single append-head row first,
  then reads the authority epoch, then locks stream heads in a fixed order. It
  checks the fencing epoch, then the expected position and stream versions,
  appends, advances heads, and allocates a global batch position. Unique
  constraints on stream version and event ID back up the checks. An independent
  SQL sequence is not used as commit order.
- **Two streams and one clock.** `hall:{id}` carries gameplay. A service-level
  `control` stream carries availability epochs and recovery identities (the
  identity stream's other duties arrive with accounts in Milestone 3). A batch
  touching both commits atomically or not at all; recovery reconciliation is
  the first real user. **(owner decision, 2026-11-09:** the hall stores one
  master clock in hall time, and available-service time is derived as exactly
  hall time ÷ 24, because both pause together and cleaning advances both. The
  [clock-continuity contract](../../ARCHITECTURE.md#recorded-decisions-and-clock-continuity)
  is amended to match. If a future rule makes the two clocks diverge, the hall
  stores two clocks.)
- **Receipts.** Same semantics as Milestone 1: bound to actor, scope, kind, and
  canonical payload fingerprint; retries return the original receipt; a changed
  payload under the same ID is a conflict; a lost reply is resolved by the same
  ID before new commands are admitted.
- **Fencing.** A hall-authority ownership record with a monotonically increasing
  epoch. Acquiring ownership bumps the epoch; every append verifies it. A
  superseded owner's append is refused and appends nothing.
- **Event envelopes** carry the fields listed in the architecture (event ID,
  type, schema version, stream/version, batch ID and order, actor, causation and
  correlation IDs, content hash, clock context). Payloads use the allowlisted
  `EventCodec`; unknown types or versions block recovery.
- **Immutable content** is stored once by content hash; the stored
  `HallInitialized` payload references it, and reads rehydrate it by hash.
- **Snapshots** in PostgreSQL, per the
  [snapshot contract](../../ARCHITECTURE.md#snapshots-replay-and-historical-compatibility):
  taken at a complete batch boundary without holding the append lock, verified
  before becoming the default, at least one previous valid snapshot retained,
  corrupt or incompatible ones skipped in favour of an earlier one or genesis.
  Cadence per the
  [tuning register](../../GAME_DESIGN.md#21-tuning-register-and-remaining-production-decisions)
  (10,000 events or five service minutes).
- **Projections.** **(builder's call:** one synchronous projection — current
  restaurant ledger balances and stock positions — written in the append
  transaction; and one asynchronous projector — daily activity: visits admitted
  and trays accepted per restaurant per midnight-based game day — that applies
  whole batches and its checkpoint in one transaction and ignores duplicate
  deliveries.) Both can be dropped and rebuilt from the log.
- **Outbox.** The table and its atomic write exist and are covered by store
  tests. No delivery worker is built, because nothing in this milestone sends
  external messages.
- **Recovery.** Acquire fenced ownership; load the newest valid snapshot (or
  genesis); require the tail to be contiguous up to the head; apply later
  batches with no commands or side effects; validate balances, claims, jobs,
  clocks, and versions; then append one idempotent reconciliation batch keyed
  by a durable recovery identity before accepting commands. A missing batch, a
  torn batch, or an unknown event blocks recovery. An unobserved gap over five
  real seconds enters recovery instead of charging the gap as play time, per
  [clock continuity](../../ARCHITECTURE.md#recorded-decisions-and-clock-continuity).
- **Hall authority process.** A supervised process owns one hall's runtime:
  it wakes once per real second, advances the clock from monotonic elapsed
  time, runs due boundary work, and serializes commands through
  `CommandWorkflow`. The clock source is injected so tests drive time
  explicitly.
- **Diagnostic logging.** The architecture requires structured diagnostic
  logging [alongside each application slice](../../ARCHITECTURE.md#observability-and-diagnostic-logging).
  Wrappers (never the pure domain) emit versioned, allowlisted records for
  command attempts and terminal outcomes (including commit-unknown and receipt
  replay), the authority lifecycle and scheduler lateness, fencing changes,
  storage failures, snapshots, replay/recovery, and projection backlog, with
  command, batch, epoch, and clock context. Export is bounded and asynchronous,
  with drop counters, and can never block the authority or change an outcome.
  The [observability qualification](../../TESTING.md#observability-qualification)
  items that need Phoenix, clients, helpers, licensing, or a release
  environment wait for those slices.

### Decisions recorded during Project A

These were settled while building Project A. Projects B and C build on them;
details live in the architecture's
[implementation status](../../ARCHITECTURE.md#implementation-status).

- **One hall per database** for Milestone 2: `read_from/2` returns the whole
  global log. Command and receipt IDs therefore share one namespace per
  database; hosting several halls in one database is a later decision.
- **Recovery identity.** A reconciliation command carries only its recovery
  identity, so any later owner retrying the same interrupted availability
  interval sends an identical request and receives the original receipt.
  Reconciliation is accepted only for the pending recovery identity.
- **Conditional ownership.** After a pause, an authority reclaims the hall only
  if it still holds the current epoch, or the stored row shows its own
  acquisition whose reply was lost. Otherwise it stops as fenced.
- **Owner names identify one authority incarnation.** Any production code that
  starts authorities must give each incarnation a unique owner name of at most
  32 bytes (for example node plus boot identity).
- **Failure shapes.** Every failed `CommandWorkflow.execute/3` returns the
  runtime with the store the adapter handed back; a failed recovery returns the
  store as of its last successful step, so an acquired epoch is never lost.
- **Clock catch-up keys.** The clock advance committed before a command is
  keyed on its target service time (`adv:<target>`), so a retry after a partial
  commit replays it instead of conflicting; callers never see internal IDs.
- **Stored-term decoding.** The application preloads its modules at start, and
  stored receipts, outbox intents, content, and snapshots that cannot be
  decoded are error values, never crashes.
- **Command-ID namespaces** — to be implemented first in Project B: the
  prefixes `adv:`, `tick:`, `recovery:`, `start:`, and `npc:` are reserved for
  system and NPC actors; `CommandWorkflow` rejects them from other actors,
  because a client could otherwise pre-claim an internal ID. Project B adds
  `DS:` and the simulated-arrival shape `A<day>-<seq>` (see
  [Decisions recorded during Project B](#decisions-recorded-during-project-b)).

### Project B: shared simulation

New gameplay, built in the pure domain first and then wired through the
authority. Rules and tuning follow the cited game-design sections; tuning values
are authored as versioned, validated content, not hardcoded. Base the work on
branch `milestone-2a-durable-storage`.

#### How simulation work happens

- **Clock-driven work is decided inside the clock advance.** **(builder's
  call)** Replenishment, market clearing, arrival generation, simulated choice,
  tray acceptance or departure, the simulated drink and dessert decisions,
  kitchen stage starts and completions, handover, patience deadlines, and the
  midnight forecast are hall-clock boundaries handled by the domain's advance
  and recorded as advance events. Only human owners and NPC planners issue
  commands. The Milestone 1 `{:system, :demand}` admission command stops being
  used by the authority; it may remain a test fixture only if it calls the same
  decision function arrivals use.
- **Same-timestamp order** follows the architecture's
  [simulation scheduling](../../ARCHITECTURE.md#simulation-scheduling) step
  order. The midnight forecast and supply-scale reset happens before that
  timestamp's arrivals and market clearing.
- **Recovery.** **(builder's call)** Project B adds no reconciliation facts:
  market batches, arrivals, kitchen stages, and planning slots are hall-clock
  due and resume from the committed clock with no catch-up for platform gaps.
  Recovery validation extends to pending purchase requests and their
  reservations, stage queues, the arrival accumulator, and every PRNG state.
- **Events and history.** New event types and keys join the `EventCodec`
  allowlist with schema versions; the snapshot evolution version is bumped
  (older snapshots fall back to genesis); decoders for Milestone 1 and Project A
  events, including `stock_purchased`, are retained; each new event version
  gets a golden serialized fixture, per the
  [property, replay, and mutation policy](../../TESTING.md#properties-replay-and-mutation).
- **Randomness** uses an explicit, persisted generator state **(builder's call:**
  a small pure PRNG implemented in the domain rather than `:rand`, so its state
  is a plain integer and its sequence cannot drift with OTP releases). The hall
  keeps one stream for demand and one per NPC operator; replay never draws.
- **Rework this causes.** Replacing explicit kitchen commands and list-price
  purchases changes Milestone 1's fixtures, the `HallTrace` interpreter used by
  both trace properties, and the PostgreSQL trace property's closing script.
  Migrate them to drive the new mechanisms by advancing time; keep their
  progress floors.

#### Wholesale market

Per [competing for supplies](../../GAME_DESIGN.md#8-competing-for-supplies).

- Purchases become pending requests that clear in batches every ten
  available-service seconds (240 hall seconds). Finite stock per product; one
  published scarcity price per batch, clamped between a positive minimum and
  finite maximum; budget and storage reserved at clearing in the restaurant's
  ingredient priority; proportional allocation with integer largest remainders
  and a rotating deterministic tie-break; atomic fill; unfilled quantities
  expire. This replaces Milestone 1's instant list-price purchase.
- **Request lifecycle (builder's call).** A restaurant has at most one pending
  request per product; submitting again replaces it, which consolidates by
  construction (the replacing request's quantity and price limit apply). A
  pending request can be cancelled before clearing. The submit receipt records
  acceptance as pending; the fill or expiry is a separate entity found by
  request ID. No cash is held between submission and clearing. Clearing
  continues during cleaning, because manual purchasing is allowed then, per
  [daily cleaning](../../GAME_DESIGN.md#daily-cleaning-closure-and-planning).
- **Budget and priority (builder's call).** In Milestone 2 the purchasing
  budget is current cash, and ingredient priority is a fixed default order by
  product ID. Daily purchasing budgets, configurable priority, and automatic
  restock policies arrive in Milestone 3.
- **Replenishment (builder's call).** Daily at 00:00 hall time, each product is
  replenished toward a target stock scaled by the business-equivalent forecast
  fixed at the previous midnight (a one-day delay), never above a content cap.
- **Market stock does not age (builder's call).** A fill starts the product's
  full shelf life at the fill time, as Milestone 1 purchases do. Only unfilled
  requests expire.
- **Market stock is public (owner decision, 2026-11-09):** available wholesale
  stock and published prices are visible to NPC planners now and to human
  owners in Milestone 3.

#### Simulated diners

Per [a finite pool of diners](../../GAME_DESIGN.md#a-finite-pool-of-diners),
[customer segments](../../GAME_DESIGN.md#customer-segments-and-decisions),
[dietary requirements](../../GAME_DESIGN.md#dietary-requirements-and-menu-reach),
[orders and queues](../../GAME_DESIGN.md#orders-queues-and-satisfaction),
[drinks with the main](../../GAME_DESIGN.md#drinks-with-the-main), and
[dessert offers](../../GAME_DESIGN.md#dessert-offers-and-visit-outcomes).

- **Arrival volume.** One hall-wide arrival stream: about 90 arrivals per game
  day per operating business equivalent (floor three), distributed by a
  meal-period curve that is zero during cleaning, with a fractional accumulator
  carried forward. No arrivals accrue for cleaning or platform gaps.
- **Business equivalents without staff (builder's call).** Until staff exist, an
  open stall counts as staffed. A business's share of the day's 22
  customer-accessible hours is integrated over intervals bounded by recorded
  events (stall open/close, cleaning, and no orderable main), capped at one
  equivalent per business, and the next day's scale is fixed and recorded at
  00:00.
- **Arrival draws.** Each arrival gets a segment, budget, patience, and dietary
  profile from seeded draws.
- **Choice factors in Milestone 2:** dish preference by segment; price against
  budget and expected value, including the offered variant's quality; the
  stall's exposure tier, applied once; estimated wait against patience; and
  availability. A bounded weighted choice picks a stall (best eligible dish
  plus a bounded variety modifier) or leaving. Cuisine preference is trivial
  with one cuisine. **Reputation and awards are deferred (owner decision,
  2026-11-09):** every restaurant has neutral reputation in Milestone 2.
- **Patience (builder's call).** A simulated tray's deadline is the earliest of
  arrival plus seeded patience, the quote's maximum service window, and the
  03:00 cutoff. Missing it abandons the tray: a failed main scored zero.
  Patience covers the tray only.
- **Drink and dessert (builder's call).** The drink attachment is drawn at
  checkout. A simulated diner decides on dessert in the same batch as the main
  tray's service; the 30-service-second offer window applies only to guests.
- Choices and the random continuation are recorded in events; replay never
  draws again. Arrival accounting partitions arrivals into admitted and left,
  with the leaving reason (no compatible main, nothing affordable, wait too
  long, chose to leave).

#### Kitchen jobs

**(builder's call:** "jobs" in the milestone table means automatic production
jobs.) Per [production rules](../../GAME_DESIGN.md#production-rules):

- Each stall has a preparation stage and a finishing stage, each with its own
  station capacity from content, and one counter that performs selection and
  handover one tray at a time. Main and drink components queue FIFO in the same
  stage queues; a component starts when its stage has free capacity and
  finishes at its scheduled time. Ready trays are selected FIFO by the final
  component's ready time.
- Quotes use a queue-aware wait estimate, and the same pure function serves
  diner choice, acceptance, and the 03:00 completion check. A content queue
  limit per stall is part of main eligibility.
- This replaces the `{:system, :kitchen}` commands. Staff, coverage, fatigue,
  and wages remain Milestone 3.

#### Basic NPC owners

Per [NPC competition](../../GAME_DESIGN.md#14-npc-competition-and-population-changes).

- **Identity and creation (builder's call).** NPCs act as a distinct actor kind,
  `{:npc, operator_id}`, which passes the same ownership guards as a principal
  and owns one venture. Right after hall initialization the authority issues
  ordinary `create_restaurant` commands for three NPC restaurants (budget
  volume, dependable mainstream, premium quality), with the same starter
  capital as a human.
- **Planning.** Each NPC has a planning slot at each game-hour boundary,
  recorded in hall state. When a committed advance crosses one or more of an
  NPC's slots, the authority runs the pure planner once, at the latest crossed
  slot. **(builder's call:** a slot's actions — prices, menu, substitution
  policy, purchase requests — are submitted as one command with ID
  `npc:<operator>:<slot>`, decided by the same rules as the equivalent human
  commands and committed atomically, so a crash between a slot's actions cannot
  leave a partial plan or a conflicting retry.) Replay applies the recorded
  facts and never reruns the planner. NPC management may continue during
  cleaning.
- **Public information.** **(builder's call:** the planner receives a public
  view that is a pure function of the committed hall state at the planning
  position, never a stored or lagging table: published market prices and
  available market stock, each open stall's menu, prices, and exposure tier,
  and hall-wide demand summaries from completed days, which the hall records at
  each midnight. It excludes rivals' cash, inventory, orders, and costs, and
  any undrawn random state. The planner receives only that view plus its own
  restaurant, enforced by its function signature and a test. Milestone 3 shows
  human owners the same view.)
- Retirement and restoration remain Milestone 4.

#### Locations

Per [location quality and lease pricing](../../GAME_DESIGN.md#location-quality-and-lease-pricing).

- `HallInitialized` records the layout: at most 150 slots, each with an
  exposure tier and its factor from the tuning register (quiet 0.8, standard
  1.0, busy 1.25, prime 1.5). Creating a restaurant takes a vacant slot; no
  more than 150 are ever occupied.
- **Free choice (owner decision, 2026-11-09):** owners and NPCs choose any
  vacant slot. Rent and holding charges arrive with leases in Milestone 3, so
  until then a better tier carries no cost; Milestone 2 balance results must be
  read with that in mind.

#### One cuisine

**(owner decision, 2026-11-09:** every restaurant, human or NPC, stays Mexican;
they compete on price, quality, exposure, and availability. The remaining
cuisines arrive in Milestone 4.)

### Decisions recorded during Project B

These were settled while building Project B (`milestone-2b-shared-simulation`).
Each is a **builder's call pending owner confirmation**: made by the controller
while implementing, within the cited contracts, and not confirmed by the owner.
None changes an owner decision above; each states how to change it. Details
live in the architecture's
[implementation status](../../ARCHITECTURE.md#implementation-status).

- **NPC identity.** An NPC's `profile_id` is its operator ID. An operator with
  no matching `npc_profiles` entry still owns its restaurant, but the authority
  reports `:npc_planner_failed` instead of planning. Reason: the plan creates
  NPCs as `{:npc, profile.id}`; a separate profile field would be a small
  rework.
- **Per-day counters.** The day summary is fed by per-day counters in
  `demand.today` (`arrivals`, `admitted`, `left` by reason, `trays_served`),
  updated from visit events, with simulated arrivals adding to the same
  counters. Reason: the summary has to exist before arrivals do.
- **Catalog values are JSON-shaped.** Segment ranges (`budget`,
  `patience_hall_ms`) are `[lo, hi]` lists, not tuples, and a malformed catalog
  returns `{:error, problems}` with tagged problems rather than raising.
  Reason: the catalog rides in the `hall_initialized` event and the codec
  cannot encode tuples.
- **Target stock at the equivalent floor.** The market's target stock for a
  product is `target_stock_per_equivalent` times the floor of three equivalents
  (`equivalent_floor_millis / 1000`, so 1,200 for most products). Reason: the
  design says "per operating business equivalent (floor three)". Retune only.
- **Queue limit gates mains only.** The stall queue limit refuses new main
  trays; dessert quotes and acceptance are not refused by `:queue_full`. Reason:
  the design makes the limit "part of main eligibility". Gating desserts too is
  a small `Offers` change.
- **Order status is the work stage.** An order's `status` carries its kitchen
  stage (`:queued_prep` through `:ready`, then `:served` or `:cancelled`), with
  no separate `stage` field. Reason: one field cannot disagree with itself.
- **One clearing event per interval.** The market writes one `market_cleared`
  event at every clearing interval (about 360 per game day) even when no request
  is pending, because class 7 fires at every multiple and the batch number
  drives the rotating tie-break. Cost: log growth; skipping empty clearings is a
  contained change in `Advance` if Project C's budgets object.
- **Drink fit.** In diner choice a drink "fits" only if the main-plus-drink
  quote is within the diner's budget and patience; otherwise the candidate is
  the main alone. Reason: a diner should not walk away from an affordable main
  because of an optional drink. Reverting is a two-line change.
- **Patience is hall time.** Segment patience is stored as `patience_hall_ms`
  and used without a service-time conversion. Reason: the world-clock table puts
  patience on hall time, and the shipped 5-40 minute values only make sense
  against the 45-minute hall service window (converted they would be 2-16 hall
  hours and never bind). If the owner wants service-time patience the values
  must be retuned.
- **Exact crossings land one millisecond early.** An arrival whose accumulator
  threshold is crossed exactly on an integer instant is placed in the preceding
  millisecond, so no arrival can land at 03:00 and a 00:00 crossing belongs to
  the new day after `day_closed`. Reason: the daily total stays exact with no
  reopening surge. Change only if the owner wants "scheduled at 03:00 means
  dropped".
- **Unaffordable NPC purchases are refused at clearing.** An NPC that cannot
  afford its restock has its request accepted into the plan and refused at the
  next clearing with `:insufficient_cash`; an unaffordable unlock is rejected
  inside the plan; the slot still advances. Reason: the market decides funding
  at clearing and holds no cash at submission. If the owner wants
  submission-time refusal the market rule itself must change.
- **Overdue NPC slots are not a recovery violation.** Recovery checks only the
  form of an NPC's `next_slot_at`, not its lateness: a slot is legitimately
  overdue after a crash between advance and plan or after the planner gave up,
  and a lateness check would make a healthy hall unrecoverable.
- **Diagnostics emission point.** Simulation diagnostics are emitted by
  `CommandWorkflow.decide_and_append/3` after a successful append, not by
  `HallAuthority`: only the workflow holds the committed event list and every
  committing path goes through it. Records carry no epoch or scope. Move only if
  the owner wants fencing context on them.
- **Idle clearings are not reported.** A clearing with no fills and nothing
  unfilled emits no `market_cleared` diagnostic (about 8,600 empty records a
  day otherwise). "The clearing ran with nothing pending" is visible only in the
  event log.
- **A full queue is not operating (ruling R23).** A stall whose queue is full
  does not count as operating for business equivalents: `Demand.operating`
  uses the same main-gated stall check as diner choice
  (`Offers.open_stall_for_main`), so time spent at the queue limit adds
  nothing to the next day's scale. Reason: an equivalent measures capacity to
  take new diners. Counting a full stall instead is a one-line change to
  `Demand.operating`.
- **NPC planner tuning in code.** The planner keeps three tuning values as
  module attributes (`@unlock_cash_multiple 4`, `@price_limit_permille 1_500`,
  `@fallback_trays_per_day 10`) until a content pass moves them into the
  catalog. Safe for replay: planner output is recorded in `npc_planned` and its
  action events, and replay never reruns the planner.
- **Finished work stays in live state (ruling R22).** Finalized visits and
  their trays and orders stay in the hall state, and the advance scans them.
  Measured: about 48 ms per idle wake-up and about 161 MB of state at 100,000
  finished visits. This is a known scaling limit deferred to the start of
  Project C: its first task removes finalized visits, trays and orders from
  live state (or indexes live orders) and replaces `seq: map_size(state.orders)`
  with a counter.
- **Leave reasons.** A simulated diner who leaves records one reason, the first
  that applies: `:no_open_stall` (no stall open and accepting new mains),
  `:no_compatible_main` (every offered main is dietary-incompatible),
  `:nothing_available` (no main can be quoted: none on a menu, none suppliable
  from stock, or none can finish in time), `:nothing_affordable`,
  `:wait_too_long`, `:chose_to_leave` (plus `:admission_failed` when the
  admission of a chosen tray fails). Reason: stock-outs and closed or full
  stalls were recorded as `:nothing_affordable` or `:no_compatible_main`, which
  are permanent facts in `diner_arrived` and the day summary. The order keeps
  the design's four reasons in their order and places the two supply-side
  reasons where they first apply (`Choice` moduledoc).
- **`DS:` is a reserved command-ID prefix.** A simulated diner's dessert order
  derives from `"DS:" <> visit_id` just as a guest's derives from its command
  ID, so `CommandWorkflow` refuses `DS:` IDs from clients and NPCs, and
  `Admission` refuses any derived visit, tray or order ID that already exists
  (`:visit_id_taken`, `:order_id_taken`). If the guard ever fires in the
  advance, the simulated diner declines dessert instead.
- **Operating lists recorded on change.** `clock_advanced` carries `operating`
  only when the list differs from the last one recorded (kept in
  `demand.operating`, initially empty); an interval without it credits the
  last list. Older logs that restate it on every interval replay to the same
  state. Reason: an idle one-stall hall wrote about 630 copies of the list a
  day. Snapshot evolution is 4.

### Project C: the 150-stall measurement

A script, not a test: it creates its own disposable database, runs a 150-stall
workload through the authority and the PostgreSQL store for a stated number of
game days, and writes a report for the owner to judge (see Goals).

- **Workload (builder's call).** 150 restaurants with one stall each (expansion
  is Milestone 4), all operated by NPC actors cycling the three planner
  profiles, so about 13,500 potential arrivals per game day. The workload
  includes main-only trays, trays with drinks, desserts, meal peaks, cleaning,
  and market contention. No sessions or helpers yet.
- **Report.** Per-append latency percentiles; per-wake-up processing time
  (decide, evolve, append) against the one-second wake-up and the five-second
  gap threshold; sustained throughput; events and bytes per second and per
  day; table and index growth; snapshot size and time; snapshot-tail recovery
  time, compared with the proposed 30-second target; full replay time;
  projection lag; and peak combined BEAM and PostgreSQL memory. The report
  states its machine, PostgreSQL version, and workload limits.
- **Clock (builder's call).** The run uses an accelerated injected clock that
  still steps one available-service second per wake-up, so each batch has the
  same shape as in production while wake-ups run back to back. The report
  labels the run accelerated. The number of game days is a script option; the
  default covers several complete game days, including cleaning and both meal
  peaks. The architecture's 30-real-day (720-game-day) full-replay measurement
  is not attempted locally in this milestone; the report says so and
  extrapolates nothing.

## Non-goals

Phoenix, channels, HTTP, or any UI; staff, wages, helpers, and guest helper
shifts; leases, rent, and holding costs; accounts, invitations, licensing, and
authentication; owner absence and unattended operation; daily purchasing
budgets, configurable ingredient priority, and restock policies; reputation and
awards; announced demand trends and supplier events; expansion beyond one
stall per restaurant; NPC retirement and restoration; cuisines beyond Mexican;
reports beyond the one async projection; outbox delivery workers; production
wiring of authorities; backups, archival, and Render deployment; the full
450-session peak workload; the 30-real-day full-replay measurement.

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
  processes. Tests and scripts use their own databases inside that server
  (`feud_hall_test`, `feud_hall_mutation`, and for Project C
  `feud_hall_bench`). The CI workflow declares its own PostgreSQL service; it
  is kept current but unexercised while nothing is pushed.
- **Stack:** Ecto and Postgrex per [AGENTS.md](../../../AGENTS.md).
  **(builder's call:** a minimal hand-written adapter rather than the
  EventStore library, which the architecture says has not been shown to meet
  the cross-stream and fencing contract.)
- **Local resources:** combined memory of the BEAM, PostgreSQL backends, and
  tooling stays under 2 GiB. On 2026-11-09 the owner gave the advance
  permission [AGENTS.md](../../../AGENTS.md) requires for full local
  `mix test` runs within that limit; run them serially with memory sampled
  throughout and abort above the limit. The mutation cohort runs in an
  isolated scratch copy against `feud_hall_mutation` under the same limit. No
  `tsc`.
- **Git:** Project B and C work on new local branches based on
  `milestone-2a-durable-storage`. Nothing is pushed; CI cannot provide
  evidence, so local runs must.
- **Purity:** domain modules stay free of Ecto, processes, and ambient clocks;
  the architecture test covers new modules.

## Verification

The owner's bar is "thorough and reliable". Concretely:

- **Determinism.** Every test drives time through explicit advances or an
  injected clock and randomness through fixed seeds. No `Process.sleep` or
  wall-clock waits in assertions.
- **Isolation.** Database tests own their data: each test truncates what it
  uses; concurrency and crash tests use real separate connections and
  transactions (not the Ecto SQL sandbox, which would hide commit behaviour).
  The suite runs serially.
- **Store tests.** The shared contract runs the sequential cases (receipts and
  retries, expected positions and versions, multi-stream atomicity, outbox,
  snapshots, projections, ownership) against both adapters. Cases that need
  separate processes sharing one store — two concurrent writers, a writer
  killed mid-transaction, a superseded owner, a stuck lock holder — run on
  PostgreSQL only, because the in-memory store is a value.
- **Simulation examples** for each rule, including exact boundaries:
  - market: allocation under contention, partial fills, cash and storage
    limits, price clamps, replenishment toward target and cap, request
    replacement and cancellation, splitting a request gaining nothing, and
    clearing across cleaning;
  - diners: arrival totals preserved across clock partitioning, no catch-up
    after cleaning or a platform gap, incompatible food never chosen, the
    no-compatible-main departure, duplicate menu rows not multiplying demand,
    exposure applied once, and patience abandonment;
  - kitchen: stage capacity, queue limit, handover order, the 03:00 cutoff for
    queued and in-progress work, and quote/acceptance agreement on wait;
  - NPCs: an identical action from a human and an NPC producing identical
    outcomes, the planner seeing only the public view, a whole-slot plan
    committing atomically, and planning during cleaning.
- **Property traces** extend the trace properties with market, arrival,
  kitchen, and NPC actions. They use macro actions (a full market clearing, a
  meal peak, a dessert completion) and structural progress floors so traces
  are never vacuous, and compare live, genesis, snapshot-tail, and codec
  round-trip state. The PostgreSQL trace property runs the same traces with
  restarts, injected commit failures, and observed-clock catch-ups.
- **Diagnostics** follow the applicable observability qualification items: an
  in-memory sink checks schema, reason codes, and correlation; no
  committed-success record precedes the append; sentinel secrets are redacted;
  and a failing or full exporter leaves events, receipts, and balances identical
  to a run with diagnostics disabled. Project B adds records for market batch
  clears, aggregated arrivals and departures, automatic course lifecycle,
  cleaning boundaries, and NPC planner failures.
- **Oracles** gain market conservation (initial stock + replenishment = filled +
  remaining), arrival accounting (arrivals = admitted + left, per source and
  reason), and projection-versus-fold agreement.
- **Mutation cohort** adds curated faults from the
  [architecture list](../../ARCHITECTURE.md#early-qualification-and-ongoing-tests)
  and the [game design's mutation policy](../../GAME_DESIGN.md#mutation-testing):
  for Project B, market and arrival faults, kitchen faults (handover at 03:00,
  a queue kept across cleaning, capacity bypassed, ingredients consumed twice),
  an NPC planner reading rival state, and removing an event or altering its
  amount or order. Every curated mutant must be killed by a behavioural
  assertion; any survivor is reported and reviewed per
  [Testing](../../TESTING.md#properties-replay-and-mutation) before the project
  is called done.
- **Evidence.** At the end of each project, the full suite runs locally at least
  three times with different seeds under the memory limit, and the results are
  reported exactly, including anything not verified.

## Documentation updates

As each project lands, update the implementation status in
`docs/ARCHITECTURE.md` (including its temporary-seams note once the kitchen and
market are automated), the implemented entry points in `docs/TESTING.md`, and
`AGENTS.md` as commands become real; record the measurement run's results and
limits; and add newly settled decisions to this document.

## Left to the builder

Module and table layout, event names beyond those the architecture names, the
exact scarcity curve, arrival curve, segment weights, patience distribution,
NPC heuristics, station capacities and queue limits, market target stock,
price bounds, and replenishment caps, and snapshot serialization — provided
tuning is authored as validated versioned content and every choice stays within
the cited contracts.
