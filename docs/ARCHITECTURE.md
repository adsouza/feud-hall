# Feud Hall Architecture

Status: implementation design with a first pure-core slice ([implementation status](#implementation-status)); no runtime, recovery, or capacity qualification is claimed.

This document owns the implementation contracts for the game defined in the
[game design](GAME_DESIGN.md). The [event-sourcing ADR](decisions/0001-event-sourcing.md)
records why that persistence approach was selected and its tradeoffs. Gameplay
rules and confirmed owner choices remain in the game design; architectural
changes must preserve those contracts. Storage/recovery contracts live here so the ADR stays focused.
[Testing](TESTING.md) owns verification procedures and evidence;
[Deployment](DEPLOYMENT.md) owns release and operational sequencing.

Navigation: [system shape](#system-shape), [DDD](#domain-driven-design),
[Clean Architecture](#clean-architecture-and-aggregate-ownership),
[CQRS](#cqrs), [AOP techniques](#aop-techniques-and-cross-cutting-wrappers),
[observability](#observability-and-diagnostic-logging),
[pure core](#functional-core-and-imperative-shell), [scheduling](#simulation-scheduling),
[commands and authorization](#commands-state-synchronization-and-authorization),
[event persistence](#event-persistence), [deployment](#deployment-and-clients), [localization](#localization-and-presentation-boundaries),
[verification](#architecture-verification).

## System shape

Use a modular monolith with one authoritative online simulation and PostgreSQL.
Start with one public hall containing at most 150 physical stalls. Keep identity
service-wide and economies hall-scoped so future private halls do not require
separate human accounts. Smaller domain boundaries do not require microservices,
a broker, or independently committed aggregate processes.

Use an Elixir/Phoenix backend, PostgreSQL persistence through Ecto, and Phoenix Channels/PubSub for live delivery. Use Svelte with TypeScript for management UI and Three.js for WebGL presentation. Tauri wraps the shared frontend for Linux and macOS; its Rust code handles native integration rather than owning a second economy.

All clients connect to the authoritative Render service. Solo means one human in that online hall with NPC competitors. It does not mean an offline local simulation. The earlier local Elixir sidecar discussion was superseded by the explicit centralized-server decision.

Phoenix Channels provide topic-based communication to browser and native clients; the game still needs its own authorization, persistence, and recovery protocol. See the official [Phoenix Channels guide](https://hexdocs.pm/phoenix/channels.html).

### Frontend toolchain

Use Bun for dependency management, scripts, TypeScript execution, and suitable
unit/property tests, with pinned versions and a committed `bun.lock`. Use Oxlint
as the frontend linter and native `bun check` for local and hosted TypeScript verification;
do not add ESLint or a separate `tsc` CLI step. Keep Svelte browser compilation
explicit and invoked through Bun. Svelte template coverage must be proven by the
checks selected for the pinned toolchain, independently of script linting or a
successful bundle. [Testing](TESTING.md#frontend-toolchain) records the baseline,
coverage qualification, and local restrictions; changing tools does not remove
static or runtime validation requirements.

Use `mix format` for Elixir and Prettier with `prettier-plugin-svelte` for
frontend formatting. Shared committed configurations define their respective
scopes; pinned versions keep local and CI output consistent. CI rejects
formatting differences without rewriting source. See
[Code formatting](TESTING.md#code-formatting) for the planned entry points.

## Domain-driven design

Use the game's own vocabulary: principal, owner license, hall, restaurant,
stall, position, shift, order, ingredient batch, and lease. A restaurant is the
shared venture; a stall is one location. A staff position is distinct from its
visitor controller. Preserve these distinctions in commands, events, value
objects, and projections rather than using an ambiguous generic player/entity.

The following is the starting responsibility map for bounded contexts/modules
inside the monolith. It assigns authoritative facts without fixing every future
module or process boundary. Contexts expose explicit application/domain contracts;
they do not share mutable tables as a hidden API.

| Domain | Owns |
| --- | --- |
| Identity and history | Canonical principals with guest/owner roles and restaurant licenses, inviter/sponsor tree, quota, licensing eligibility and application decisions, reviewer capabilities, credentials and recovery, venture membership, stable employer identities, immutable outcomes. |
| Service clock | Shared available-service time and availability epochs at launch; referenced by identity and hall deadlines. |
| Hall and leases | Capacity, slot ownership, location profiles and quoted lease terms, draft reservations, admission, hall clock, mandatory cleaning/access gate, operating configuration. |
| Supply market | Wholesale stock, scarcity pricing, purchase batches, fill receipts. |
| Restaurant operations | Business cash, inventory/reservations, main/drink/dessert menus and substitution policies, resolved accepted-course bills, stations, cost ledger. |
| Workforce | Staff skills, shifts, fatigue, assignments, visitor control/handover, and wage obligations. |
| Visitor participation | Hall dining wallets, allowance grants, payroll credits, reservations, and visitor earnings history. |
| Customer demand | Simulated and visitor arrivals, dietary profiles/compatibility policy, dining admission, visit/course eligibility and carbohydrate commitments, finalization, choices, patience, and satisfaction. |
| Development and recognition | Recipe/equipment unlocks, reputation, awards, and milestones. |

Hall-scoped entities carry `hall_id` and stable IDs. Accounts, verified identities, licenses/applications, and the invitation/sponsor tree are service-level identity; hall memberships refer to them. A restaurant's money and inventory are restaurant-owned; a stall cannot mutate an independent copy of that wallet or warehouse.

### Aggregate roots, policies, and coordination

Proposed aggregate roots follow the invariant being protected. An identity
principal owns roles, license and immutable ancestry; an invitation owns its
single-use lifecycle; a license application owns its terminal review state. The
hall lease registry protects unique slots/capacity. A restaurant owns its shared
cash, inventory, menus and accepted-order commitments; its workforce roster owns
worker assignments, coverage and helper control. A dining wallet owns its funded
credits and spending reservations, and the market owns wholesale stock/clearing.
A customer visit owns the source/principal, original restaurant/stall, course slots,
offer deadline, and terminal finalization identity; recognition owns its finalized
score and review inclusion. Development/recognition owns its unlock/award facts.
Splitting a large root later
requires preserving its invariants explicitly, rather than adding competing
writers to the same facts.

Use immutable, validated value objects for money, quantities, IDs, time contexts,
content versions, and reservations. Economic arithmetic is exact and bounded;
serialization belongs at adapters. Pure domain policies handle rules spanning
entities, such as substitute feasibility, customer choice, and invitation
eligibility. Entities enforce local transitions; application coordinators obtain
root decisions and compose the atomic batch. Domain policies do not perform
repository calls or send commands to another root.

| Workflow | Coordinated owners | Atomic invariant |
| --- | --- | --- |
| Wholesale fill | Market, restaurant inventory/cash, capacity commitments | Filled stock, actual debit, inventory and released commitments agree. |
| Main/drink tray | Visit, restaurant inventory/cash/jobs, workforce, dining wallet | Combined acceptance and joint handover settle both components together; one queue/control claim, exact budget/diet commitments, and no partial service. |
| Helper payroll | Workforce, restaurant finance, visitor wallet/transfer limits | One covered interval debits the employer and credits the visitor once; unused reservations release. |
| License eligibility/admission | Workforce proof and identity/application/invitation roots | Qualifying work, one license, one parent, and invitation quota stay consistent under races. |
| Hall cleaning | Hall gate, affected restaurants/workforce/wallets, clock/report facts | Customer access closes before cutoff service, affected work settles once, and saved reopening holds survive. |
| Vacancy offer/confirmation | Hall lease registry, identity, restaurant finance | Compatible FIFO allocation reserves one slot; confirmation creates at most one paid lease and the permitted starter grant, while expiry only releases an unpaid offer. |

These workflows use the shared PostgreSQL transaction and version/read-set checks
described below. Domain-event ownership remains with each root even when several
roots' events share one batch. NPC planners and unattended policies propose
ordinary commands; they do not own another root's facts or bypass its policies.

## Clean Architecture and aggregate ownership

Use a modular monolith with dependency direction toward the domain:

```text
Svelte / Tauri clients
  -> Phoenix HTTP and Channel presentation adapters
  -> Application command and query use cases
  -> Pure domain models, aggregate roots, and domain services

Application use cases -> application-owned runtime, persistence, and delivery ports
Infrastructure adapters -> implement those ports using OTP, Ecto/PostgreSQL,
                           credential services, clocks, telemetry, and mail
Composition root -> wires concrete adapters to application ports
```

Presentation adapters call use cases; they do not reach into domain tables or directly call database adapters. Application workflows depend on narrow behavior contracts, not Phoenix/Ecto or a generic infrastructure service locator. Infrastructure can be replaced in focused tests without recreating the network stack. The pure domain depends on no outer framework. Avoid additional layers or one-function interfaces unless they express a real rule or side-effect boundary.

Assign every authoritative domain fact and aggregate state one owning aggregate root and document its invariants. Typed entities and value objects express money, quantity, inventory reservations, shift assignments, and work commitments. Roots decide named transitions and emit events such as ingredients reserved, fill settled, or stall closed; they do not expose generic writes to arbitrary callers. Projection tables have explicit projector ownership. Multi-aggregate workflows sequence roots through explicit coordinators, with no root-to-coordinator dependency cycle.

The hall is initially the shared atomic commit boundary; smaller aggregate responsibility boundaries do not imply separate servers or independent transactions. A coordinator can atomically combine restaurant finance, market stock, and inventory changes without letting one root edit another root's rows. Root transitions revalidate deciding facts instead of trusting a UI estimate or an NPC's proposed result.

Each transition releases the resources it invalidates through the same atomic event batch. Canceling an order releases unconsumed ingredients and station/worker claims; closing a stall cancels future replenishment; bankruptcy cancels all remaining jobs, leases, and purchase requests. Applying that batch must produce a settled candidate state. Do not rely on a later global cleanup sweep to repair a successful command. Timer-driven expiry remains the scheduler's responsibility.

Enforce dependency direction and owning-root writes with compilation/static checks and architecture tests. Document any necessary exception and its reason. Module naming alone is not evidence of Clean Architecture or DDD compliance.

## CQRS

Use lightweight CQRS: command use cases own transitions and minimal receipts; query use cases own authorized read models, planning offers, and reports. A query performs no gameplay write, including invitation accrual or policy repair. Public projections contain committed public state only; private projections are built only after authorization. Projections carry a source revision, are rebuildable, and never become an independent economic authority.

Share pure rule calculations between command validation and read-side offers instead of duplicating price, capacity, eligibility, or timing formulas in Svelte. Querying a maximum and executing that maximum against unchanged controlled state must agree. Deferred actions additionally need an outcome test through settlement and production; acceptance alone is insufficient. Combine CQRS with full gameplay event sourcing while retaining one PostgreSQL database and a modular monolith. Authoritative decisions never depend on a lagging read projection.

Separate command handlers from query handlers in the application layer, while
sharing pure rule calculations. CQRS here uses one database and explicit
projection ownership. It does not imply asynchronous economic acceptance or a
second independently writable store. Minimal command receipts describe the
invocation; linked entity queries describe its subsequent lifecycle.

| Read surface | Freshness and authority |
| --- | --- |
| Decisions, authorization, budgets, stock and control leases | Fully caught-up authoritative fold plus transaction-time version/read-set checks. |
| Current management views and action offers | Committed revision; allow a caller to require at least the position returned by their command. Revalidate an offer on submission. |
| Public hall, guest tasks and reviewer queue | Authorized projections with revision and current permission checks on each private read/payload. |
| Historical reports and analytics | May lag with a visible checkpoint; never decide affordability, permission, or capacity. |

A query cannot accrue invitation progress, repair a policy, change presence, or
advance a business clock as a hidden side effect. Explicit bootstrap, presence,
clock, and command use cases own those transitions. Account recovery and helper
work receive only their authorized read surfaces, not a raw event subscription.

## AOP techniques and cross-cutting wrappers

Borrow AOP's handling of cross-cutting concerns through explicit, testable operation wrappers or middleware: authentication, authorization, request validation, rate limits, correlation IDs, telemetry, audit context, and failure classification. Human actions, NPC actions, and unattended policies share the relevant application boundary; a trusted internal caller cannot bypass economic rules. Timer and administrative operations use explicit system capabilities and audit identities.

Keep business-specific eligibility in domain policies. Put the atomic transaction and receipt flow in an explicit application commit workflow rather than hidden interception that changes domain behavior or wraps a transition twice. Ordinary domain rejection returns a typed result and leaves protected state unchanged. Malformed requests and failed report reads are isolated; authoritative storage or integrity failure stops economic advancement. An NPC planner exception disables/retries that planner without inventing a successful command or mutating the hall.

Use explicit reusable Elixir functions/behaviours, Phoenix plugs where suitable,
and application-operation wrappers. Keep their order visible in the composition
root and exercise the wrapped path in tests. Framework-free use cases remain
callable with fake ports. No runtime weaving or opaque macro interception is
required for launch.

| Concern | Boundary and responsibility |
| --- | --- |
| Authentication | Presentation/application entry resolves a principal or explicit system capability; never trusts a supplied actor ID. |
| Structural validation and rate limits | Bound payloads and resource use before expensive execution. Malformed/unauthenticated requests cannot advance the economy. |
| Authorization | Application use cases enforce scope; append revalidates deciding identity facts, and queries/live delivery check current capabilities. |
| Correlation, telemetry and audit context | Carry request, actor, hall, causation and batch references through operations without leaking secrets or private ledgers. |
| Failure classification | Distinguish domain rejection, optimistic conflict, storage uncertainty, and optional-feature failure; never report uncertain append as rollback. |

After those entry guards, an explicit command workflow handles original receipt
lookup, independently due clock advancement, domain decisions, expected-version
checks, and atomic append. Verify credentials/authority before replaying a receipt.
Only bounded optimistic conflicts replan; an uncertain commit resolves the same
command ID through recovery. Telemetry or generic retry middleware must not
execute the economic workflow twice or retry a changed payload under a new ID.

Keep the transaction/receipt workflow visible rather than burying it in an
"after" hook. Business-specific rules such as seven-day invitation accrual,
03:00 cleaning, substitution penalties, shift qualification, and license review
eligibility remain domain policies/transitions, even if authentication and audit
wrappers apply uniformly. Query handlers share applicable read guards and
telemetry but never inherit an economic-write transaction interceptor.

## Observability and diagnostic logging

Pervasive structured diagnostic logging and linked traces are first-release
requirements, implemented alongside each application slice. Committed gameplay
events and immutable command receipts remain the durable evidence of economic
outcomes. Diagnostic records explain attempts, rejections, timing, failures, and
delivery; they are separately retained operational data and cannot replace the
event store, authorize an action, or establish that an uncertain append rolled
back. Investigation must work after the original process or client has gone.

### Coverage and correlation

Instrument the browser/Svelte and Three.js boundaries, Tauri native integration,
Phoenix HTTP/Channel entry points, application command/query wrappers, NPC and
unattended planners, scheduler/authority lifecycle, persistence, projections,
outbox workers, and external delivery adapters. Required coverage includes:

- Operation attempts and terminal outcomes: accepted/committed, domain-rejected,
  unauthorized, rate-limited, conflicted/retried, failed, or commit-unknown.
  Record stable reason codes, retry attempts, and receipt replay versus new work.
  Never emit committed success before the append succeeds; later settlement is
  a linked operation rather than a rewrite of the acceptance result.
- Meal/course preparation, handover and settlement; market fills; helper control
  and payroll; licensing and admission; and their cancellations/timeouts. Link
  lifecycle records to their originating command and committed batch references
  without copying full domain events, private ledgers, or request bodies.
- Scheduler lateness and slow advances, cleaning boundaries, authority/fencing
  changes, NPC planner failures, storage failures, invariant violations, startup,
  replay/recovery, projection/delivery backlog, and external-delivery failures.
- Client exceptions/unhandled rejections, rendering or WebGL fallback failures,
  slow operations, connection loss/resume, rejected protocol versions, and
  uncertain-command resynchronization. An accepted order remains traceable after
  a browser disconnect or a server restart.

Use a versioned structured schema with stable event/operation names, severity,
UTC timestamp, monotonic elapsed duration, component/environment, server/client
build and protocol versions, and applicable rules/content versions. Include
request/attempt ID, trace/span and correlation/causation IDs, canonical command
ID, authorized internal actor/system reference, hall/entity/job IDs, batch and
stream positions, authority epoch, and relevant gameplay-clock context where
available. Missing pre-authentication or pre-commit fields stay absent; logs must
not invent a principal, receipt, or committed version. Keep exact economic values
in their canonical representation when an allowlisted diagnostic field needs one.

Propagate context through asynchronous work and link delayed settlement/delivery
to its cause even after a request span ends. Retries retain the command identity
and get distinct attempt references. Validate/bound incoming context; a client
trace ID or client-reported error is untrusted diagnostic evidence, never proof
of identity or outcome. Provide an opaque support reference for user-visible
failures that operators can resolve without exposing internal logs to players.

### Privacy, volume, and failure isolation

Use allowlisted fields and redaction at emission, before client upload or server
export. Do not collect passwords, session/device/invitation/email-link tokens,
authorization headers, contact addresses, player-entered text, raw request or
response bodies, database parameters, or full private projections. Sanitize
exception messages/stacks and URL fields; URLs must not leak query credentials.
Keep build-matched source maps/debug symbols in restricted operational storage
for interpreting sanitized stacks. Operator log access is separate from public
hall access and seed/admin gameplay capabilities.

Record meaningful operations and transitions, not animation frames, camera moves,
crowd interpolation, every heartbeat, or a line per unchanged simulation tick.
Keep minimum command/lifecycle outcome records unsampled during normal operation;
sample verbose successful spans/reads under an explicit policy. Retain error,
invariant, and slow-operation diagnostics under bounded burst limits. Aggregate
repeated malformed/unauthenticated traffic with counts and safe examples rather
than allowing an attacker to fill storage. Any sampling, aggregation, or loss
must be measurable; absence of a diagnostic record is not proof of no action.

Telemetry uses bounded asynchronous queues, payload limits, rate limits, and
export timeouts. Collector outages, serialization errors, full queues, and log
rotation cannot block the hall authority, change a domain result, trigger an
economic retry, or grow memory/disk without bound. Expose dropped-record/export
failure counters and collector health outside the failing export path. Durable
events, receipts, and required operational commits retain their existing
fail-closed persistence guarantees; optional diagnostic failure does not weaken
them. Pure decision/evolution functions have no logging side effects; wrappers
observe their results. Replay diagnostics identify the replay run and historical
positions and cannot masquerade as new live sales or trigger external delivery.

Centralized search, retention/access policy, and operational investigation are
required by [Deployment](DEPLOYMENT.md#diagnostic-operations-and-retention).
Coverage, redaction, correlation, and failure-isolation evidence are defined in
[Testing](TESTING.md#observability-qualification).

## Functional core and imperative shell

The functional core separates `decide(state, command, context)` from `evolve(state, event)`. Decision functions receive explicit clocks, rules/content version, identifiers, and deterministic random state, and return proposed domain events plus a result or rejection. Applying those events through pure evolution functions is the only way to obtain the next authoritative state. Live execution and historical replay use the same evolution path; there is no parallel state-mutation path that can diverge from the recorded events. Neither function queries a database, reads an ambient clock, calls PubSub, or inspects process state.

The shell authenticates and authorizes, reads external time, schedules work, loads definitions, persists accepted transitions, and publishes authorized projections. Configuration is passed into the core; the core does not read global ETS configuration implicitly.

Domain boundaries do not require a GenServer per staff member, diner, or station. Those entities can be plain data. Initial implementation should favor one authoritative hall coordinator applying pure domain transitions, with independently scheduled NPC decision work and read projections. Partition hot operations into additional authorities only after measurement and with an explicit atomic transaction protocol.

The 150-stall target is an acceptance workload, not evidence that this process structure already meets capacity. Avoid synchronous cycles of restaurant, inventory, and market calls that can deadlock or leave half-completed purchases.

## Simulation scheduling

Use the [three-clock gameplay contract](GAME_DESIGN.md#world-clock): hall time
advances at 24× real time while ready, available-service time at 1× while ready,
and wall/monotonic time governs security/liveness independently of downtime.
Scheduled cleaning advances both gameplay clocks; platform unavailability pauses
them. Carry explicit clock types/contexts into decisions so a duration cannot
silently cross from game hours to service hours. The game design owns the
durations and player-visible schedule.

Proposed baseline is one real-second scheduling wake-up, not one second of assumed work per message. The shell supplies monotonic elapsed available time; the domain advances the recorded service clock and hall clock through due boundaries, preserving fractional work and currency accrual. Commands are timestamped by the server. Before deciding a new economic command, process due clock-driven work to its captured time in its own committed advance batch, then decide the command against that head. Malformed/unauthenticated inputs do not trigger this path. A business rejection has no command-specific effects, although an independently committed advance may already have changed the world; rejection-immutability tests freeze clocks or compare against that advanced baseline.

Persist random continuation and scheduled arrival times so partitioning an advance into several wake-ups does not resample demand or round wages repeatedly. A physical timer callback identifies a scheduled logical event/generation; duplicate or obsolete callbacks cannot settle it again. An append conflict replans from the current head and never moves either clock backwards.

Process the earliest due boundary across both domain clocks. At a shared timestamp: (1) advance existing work and accrue covered wages/costs and qualifying invitation progress once for the completed interval; (2) expire unconsumed stock and ready meals; (3) apply a due 03:00 hall cleaning cutoff, settling/canceling affected work and clearing customer/helper access before any service at that timestamp, then settle other permitted stage completions and valid service with matched wage/funding entries; (4) resolve remaining diner deadlines, worker/helper shift ends and breaks, and controller handovers; (5) settle due bills and terminal lifecycle deadlines, applying required stops/closures before more spending; (6) apply a due 05:00 hall access reopening, then opening/policy/refit boundaries only where the hall gate, attendance, business state, and safety permit; (7) publish due 03:00 reports after cutoff settlement, then settle invitation expiry, earned thresholds and review boundaries, with expiry before any new redemption; (8) replenish/clear due market batches, allocate arrivals, and start eligible work. Reset day-indexed budgets once at their boundary before new requests, without releasing still-funded reservations for another window.

Integrate invitation progress using the predicate that held over each elapsed
interval, never the eligibility observed only at its end. Schedule last-meal
activity expiry and earning thresholds as due boundaries alongside work/stock
changes. Boundary events establish eligibility for the next interval; a first
sale cannot qualify prior time. A threshold reached through eligible prior time
remains earned even if the stall closes at that timestamp, subject to the quota
cap. Persist interval/progress and entitlement facts so replay does not infer
eligibility from today's projection. Calendar day/budget and award boundaries
use the game design's midnight origin; operating reports retain their distinct
03:00 cut and label initialization's partial period.

Service wins an exact tie with patience only if its meal is still fresh, the position remained staffed through completion, and the timestamp is outside the hard cleaning window. Meal/raw-stock expiry wins an exact freshness tie. Work due at a worker's shift end can complete before the break; no new work starts using that worker after the boundary. A helper's payroll accrual ends at the precise controller/shift boundary, and split intervals sum to the same amount as a continuous one. Commands at the same timestamp follow scheduled events and then the authority's durable sequence order. Historical replay applies those recorded facts rather than running these decisions again.

Arrival generation uses a cumulative rate so fractional expected arrivals carry forward. Customer choice uses seeded sampling or an allocation method that preserves exact population counts. Never independently round every stall's share.

### Recorded decisions and clock continuity

Events carry resolved prices, amounts, allocation results, IDs, applicable
timestamps, and necessary work/policy facts. Random customer and NPC outcomes
are recorded, along with the deterministic continuation state needed for future
decisions. Replay does not resample diners, rerun an NPC planner, or recompute an
old meal's price using current balance rules. Testing a different economic
policy is a separate simulation, not a rewrite of production history.

Clock progress is explicit. Preserve hall time, unaccelerated available-service
time, fractional arrival accumulators, due-event ordering, and work/fatigue
anchors. Progress between anchors can be derived deterministically when its
rate and effective boundaries are recorded. Do not append one event per rendered
frame or per station percentage change. A one-second economic scheduling step
can create a bounded batch of actual outcomes and clock progress.

Daily hall cleaning is durable scheduled gameplay, not service unavailability.
Record `HallCleaningStarted` at 03:00 and `HallCleaningEnded` at 05:00 game time,
with stable day/boundary identities. The start batch closes customer access before
same-timestamp service, cancels unfinished meals, releases funding/unused stock,
records consumed-food waste, settles helpers, masks production coverage, and
switches eligible lease accrual to holding rates. Publish the 03:00 operating
report after settlement, with its explicit preceding-24-hour period. Preserve
saved stall schedules and absence/safety/business holds; reopening grants access
only to eligible stalls. Clocks, aging, and normal service deadlines advance
through cleaning, while NPC population observation windows pause and no deferred
diner arrivals accumulate. Replay/recovery restores the cleaning gate, remaining
interval, paused observation progress, and cutoff/report identities without
duplicate settlements or bypassing the five-available-real-minute closure.
Qualification exercises both exact boundaries, accepted shifts truncated at
03:00, absence during cleaning, and restart midway through the interval.

The service-level identity/control stream owns the launch available-service
clock; hall clock-advance facts reference that committed service-time boundary.
One coordinator advances them consistently, using monotonic elapsed time only
while ready. Credential validity still uses wall time. Before a newly admitted
economic command, commit the independently due advance, then decide against that
head. A rejected business command has no own economic effects, even if that
preceding advance paid bills or expired stock. Original command retries do not
redecide their historical outcome or rerun old advances.

If storage/readiness is lost, freeze at the last committed boundary. A proposed
maximum unobserved wake-up gap of five real seconds distinguishes ordinary short
scheduler lag from a suspension/discontinuity: beyond it, enter recovery rather
than charge the unobserved interval as economic catch-up. Record a new availability
epoch and resume from committed clock values after reconciliation. Tune the gap
with load/GC measurements, and test both sides explicitly. This rule is shared by
timer, command, and restart paths; a wall timestamp in an event envelope does not
advance game time by itself.

## Commands, state synchronization, and authorization

### Core command families

| Command family | Examples | Required checks |
| --- | --- | --- |
| Account admission | Redeem invitation; submit/withdraw license application; approve/reject application | Device/principal authority, code/quota or server-owned shift eligibility, unique pending application/license/parent, current reviewer capability, no self-approval, terminal-state/version checks. |
| Business lifecycle | Create restaurant, open/close, enable unattended trading | Owner license, identity, membership, business state, valid policy, hall cleaning gate; approval alone creates no venture or grant. |
| Visitor dining | Join as customer, order main with optional drink, accept/decline dessert, inspect own tray/course/visit, cancel eligible unserved tray/course | Hall access for new service, canonical guest authority, served parent main at the same restaurant/stall, initial drink-slot decision, unused dessert slot and valid offer deadline, allowance/earned-credit slices, admission/capacity, unchanged confirmed terms, pre-preparation voluntary cancellation, stable visit/order/command IDs. |
| Visitor staff | Offer/withdraw help, accept/end shift, claim/complete assigned task, settle wages | Owner opt-in, guest capability, hall access and accepted shift end capped at 03:00, unique shift/position/task control, controller generation, funded payroll, actual work and normal service constraints. |
| Market and inventory | Submit/cancel purchase, configure restock, discard stock | Quantity, cash/budget, price limit, storage, reservation integrity. |
| Menu and development | Set price/substitution policy, enable recipe, buy equipment, learn recipe | Ownership, unlocks, recipe-approved alternatives, cost/quality preview, station compatibility, safe effective time; accepted bills stay pinned. |
| Staff | Hire, schedule, break, assign, dismiss | Ownership, unique assignment, commitments, wage/cost validity. |
| Leases | Join/pause waiting list, offer/expire vacancy, confirm starting location, acquire expansion, surrender stall | Compatible FIFO priority, one entry/draft per applicant, capacity, vacancy reserve, accepted location/price version, funds, disclosed rent/holding terms, existing work settlement. |
| Recovery | Liquidate, settle arrears, accept bankruptcy, reopen dormant venture, restart | Lifecycle state, server salvage values, one non-terminated venture, unique grant, immutable archive. |

After the dedicated device-bound bootstrap, each economic command includes a globally unique `command_id`, authenticated principal, target hall/entity, payload, and relevant expected version or policy revision. System/maintenance commands use explicit server capabilities instead of a forged human actor. Bind the original-payload fingerprint, command kind, actor, and target scope to its durable receipt. The same ID and request replay the recorded result; changed content under that ID is a conflict. Authenticate and validate before receipt lookup, so replay cannot bypass revoked credentials. The server determines costs, resources, outcomes, and membership; client IDs and payloads are untrusted.

Reject unknown or misplaced fields, invalid identifiers, oversized payloads, non-finite/fractional quantities, unsupported text/control characters, and integer overflow before they reach storage. Text and numeric bounds match the actual persistent representation, including limits on multibyte names. Bad player input must not become a database exception that pauses every restaurant. Limits apply equally to NPC and automatic command proposals.

Wire money amounts and potentially large event positions use canonical integer decimal strings, parsed by adapters into bounded integer value objects. TypeScript calculations use exact integer arithmetic for those fields; converting them through a floating-point number must not change cents or replay positions. Ordinary counts may use JSON numbers within their declared safe bounds. Protocol serialization/deserialization is part of the tested boundary, not a display formatter that can silently round a quote.

The original command receipt is immutable: it records that invocation's accepted/rejected result, initial pending status if any, and event range/versions. A retried command returns that established result, not a newly evaluated command. Query the linked order/shift/fill entity for its evolving settlement status. A market submission can therefore replay as accepted-and-pending even after a separate fill completed; the client combines its receipt with current entity status rather than interpreting replay as another purchase. Transient pre-commit storage/availability failures have no successful receipt and are resolved by retrying/querying the same ID.

Dining queries return server-verifiable offered terms and their revision/validity,
including price, resolved variant, recipe version, and absolute service deadline.
The confirmation references those exact terms; acceptance revalidates them and
funding/capacity atomically rather than silently substituting a current quote.
Client-supplied terms cannot authorize a lower price or longer deadline. A stale
confirmation rejects without reservations, and a revised confirmation is a new
invocation. Voluntary cancellation checks that preparation has not begun; only
the server's defined failure/deadline transitions can cancel after consumption.
The existing per-course waste, payment, and visit-finalization rules still apply.
Admission atomically checks one active dining visit per principal/hall across
devices, and commits that human visit with its accepted main, optional drink, and all
tray reservations.
Browsing or a failed confirmation cannot strand an active-visit claim.
Cancellation-related limits constrain later admissions, never an
otherwise eligible cancellation of existing work. Clearing/finalizing that
principal's active-visit claim belongs to the same terminal event batch.

Dietary matching uses a shared pure policy over the resolved ingredient bill,
versioned product/recipe facts, and canonical visit requirements. Apply it to
read-side badges/offers, simulated choice, and main/drink/dessert acceptance before
preference scoring or reservations. An owner/client cannot assert a compatibility
badge, invent a nutrient value, or override a requirement. Guest requests select
an enabled profile; the server resolves its rules and limits. Unknown required
metadata is incompatible, and the typed rejection explains why without writing
an order. NPCs use the same policies and public demand summaries.

The visit owns its pinned requirement bundle and carbohydrate ceiling, served
total, and accepted-course commitments. Use bounded integer milligrams for
declared carbohydrate amounts and ceilings. Derive each whole portion with exact
quantity/yield arithmetic, rounding upward to that unit once after the full bill,
then compare the summed served/reserved amounts with the ceiling. Display grams
without changing the committed values. Acceptance reserves, service consumes,
and cancellation releases that course's amount atomically with its ordinary
stock/funding and course-slot effects. No timer, reconnect, locale change, or
drink or dessert request grants a new allowance. Diet settings are eating requirements,
not medical diagnoses; the launch API has no diagnosis field.

### Public and private projections

Hall subscribers receive public stall state, menus and prices, visible demand/service indicators, NPC status, and announcements. An owner receives detailed projections for their own business, inventory, ledger, staff, and policies. A selected owned stall can subscribe to detailed production updates. Private business state is never placed on a public broadcast topic.

A visitor helper receives only public offer terms and the task/order details needed for their current position, plus their own shift, wages, and dining wallet. Shift acceptance grants a revocable position-scoped capability, not owner authorization. Ending/reassigning a shift invalidates position/task control generations in the same event batch. Other helpers' wallets, unrelated orders, and private restaurant management state remain outside this projection. Identity promotion does not make a guest-authorized channel an owner channel; refresh authorization and obtain the appropriate projection after any role change.

Applicants can query only their own eligibility and applications. The reviewer queue and each decision require the current explicit review capability; seed ancestry alone is insufficient. Revoking it stops private queue payloads as well as decisions. Approval while an applicant is offline records their role but creates no device session and cannot reactivate a revoked credential. Their next valid sign-in obtains a newly authorized owner projection.

Channel joins and every mutating command check authorization. Topics include hall identity from the start, for example `hall:{id}`, `hall:{id}:market`, and `restaurant:{id}:owner`. Being connected to the correct socket or knowing an entity ID is insufficient permission.

Queries and every private live payload also use current authorization, not the role cached at channel join. Ending a shift or revoking a credential removes its live task access and invalidates cached capabilities; an old subscription cannot receive the next helper's tasks. Recheck authorization when draining queued private publications, not only when enqueuing them. The former helper can still query their own terminal receipt/history with a valid principal session. Promotion to owner requires a newly authorized owner projection. Cooperative clients clear privileged views/caches on logout or a revocation notice and do not persist private projections in a shared public/offline cache. Authorization prevents future disclosure; it cannot erase information already delivered to a client.

### Transport and credential boundaries

Serve production traffic over HTTPS/WSS. For the web client, use protected
Secure/HttpOnly session cookies with an explicit SameSite policy, CSRF protection
on cookie-authenticated mutations, and checked WebSocket origins. Allow only
configured web/native origins; a permissive CORS setting is not authentication.
Keep long-lived recovery/device secrets out of JavaScript-readable web storage,
URLs, analytics, and logs. Native credential persistence uses a qualified
protected credential-store adapter; a copied public principal ID is never a
credential. Credential rotation/revocation invalidates refresh as well as current
private access, under the common server authorization rules.

Escape user text, configure a Content Security Policy, and restrict Tauri IPC,
navigation, plugins, and remote content to the operations the client needs.
Untrusted web content receives no native filesystem/shell/credential capability.
Verify the browser and installed-client paths independently, including cross-site
and stale-session cases. Use the official
[Phoenix security guide](https://hexdocs.pm/phoenix/security.html) and
[Tauri trust boundaries](https://v2.tauri.app/security/) when implementing these
adapters; framework defaults alone do not establish the application's contract.

### Reconnection and optimistic UI

Clients track connection state and the last projection version. After a gap they request an authoritative snapshot, or a contiguous delta range if still available. Missing or out-of-order versions trigger resynchronization. Business connection presence is advisory; persisted ownership and operating policy determine economic authority.

The UI may show pending edits and local visual feedback immediately. It must not present unconfirmed purchases, stock, cash, awards, or completed sales as committed facts. A rejected command removes its pending overlay and preserves unrelated server changes.

When disconnected, show current cached information as stale and disable new economic submissions. Draft policy/menu edits may be retained locally, but they require revalidation after reconnect. Do not blindly replay stale purchases at changed market prices. An uncertain in-flight command is resolved by querying or retrying the same command ID, never by issuing a fresh purchase ID.

Short-lived access credentials require an authenticated refresh and revocation design. Web and desktop adapters may store credentials differently, but share authorization semantics. Credentials, private ledgers, and complete token payloads do not appear in logs.

## Event persistence

The [ADR](decisions/0001-event-sourcing.md) selects full gameplay event sourcing.
The following contracts define its implementation within the architecture above.
Background reference: [Microsoft's event-sourcing pattern guidance](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing).
The append protocol, batch boundaries, and targets below are Feud Hall design
contracts requiring qualification.

### What must be reconstructible

Events cover all rule-relevant durable changes: account creation and inviter
links; invitation issuance, quota, redemption, expiry, and revocation; restaurant
licenses, successful-shift eligibility, applications and decisions, admission
routes/sponsors, and explicit reviewer-capability grants/revocations; business
creation and failure; leases; funds and obligations; stock and reservations;
first-location waiting-list entries, compatible vacancy offers and draft expiry;
menus and policies; staff, shifts, fatigue, and work; diner decisions and orders;
guest profiles/allowances, helper offers and shifts, task-controller generations,
on-duty coverage and payroll-funded dining-wallet settlements, funding lineage,
and employer/hall transfer-limit reservations; market fills and replenishment;
reputation, awards, milestones;
NPC lifecycle decisions; clocks; and content-version activation.

`HallInitialized` records the initial layout and location exposure profiles,
stock, clock anchors, random seed, and immutable content references. Lease events
record the accepted location/profile version, rent, and closed holding terms;
replay cannot reprice old leases from today's catalog. Starter grants and later
additions are explicit events too; recovery cannot depend on rerunning an
unrecorded database seed.

Record semantic facts such as `InvitationRedeemed`, `IngredientsReserved`,
`MarketBatchCleared`, `MainTrayServed`, and `RestaurantBankrupted`. A batch event may
contain bounded itemized fills or arrivals with stable individual IDs. A log of
commands, generic row diffs, or financial transactions alone cannot reconstruct
the entire game and does not satisfy this decision.

A diner arrival creates one stable visit; main, optional drink, and optional
later dessert have distinct component order IDs linked to it. Persist the
source/principal, original restaurant/stall, simulated budget, requirements,
pinned scoring policy, seeded drink/dessert choices and random continuation,
initial drink-slot decision, dessert offer deadline, and consumed dessert slot.
Main-only acceptance closes drink selection; no later add-on or replacement can
reopen it. Queries create no offers, reservations, or new allowance.

Initial checkout creates one stable tray ID with the main and selected drink.
Acceptance checks the complete combined bill and records all component
reservations, prices/funding slices, carbohydrate commitments, production jobs,
one queue claim, and shared maximum service deadline atomically. A partial pair
cannot commit. Each component's production/ready lifetime is explicit, while the
counter candidate is the tray, eligible only when all its components are ready
and fresh. Ready-time FIFO uses the final required component's ready time. One
counter selection/handover generation covers the tray; helpers cannot deliver a
drink alone or earn another task/wage interval for its line item.

Facts such as `MainTrayAccepted`, component preparation/ready transitions,
`MainTrayServed`, and `MainTrayCancelled` preserve the joint outcome. Service
atomically consumes both components' funded and carbohydrate commitments,
records their actual served costs/revenue, and counts the main once. Failure or
cancellation settles the complete unserved tray, releasing unused commitments
and classifying already consumed components as waste once. The drink slot never
reopens. Enforce the pre-preparation voluntary-cancellation cutoff across both
components, exact freshness/deadline ordering, and the hard cleaning cutoff.

Successful tray service unlocks the ordinary same-stall dessert decision using
remaining visit budget and carbohydrate allowance. Facts such as
`DessertOffered`, `DessertOrderAccepted`, and `VisitFinalized` retain the later
course's outcome. Acceptance consumes its slot with its reservations;
cancellation never resets it. Closing/expiry withdraws an unaccepted offer and
finalizes the served main/optional-drink visit, while an accepted dessert settles
before finalization. A dessert timeout cannot cancel an accepted course or refund
the served tray. A failed tray grants no dessert eligibility.

Finalization records one normalized recognition outcome and its components,
main:drink:dessert weights 4:1:2 over accepted items, cleaning exemptions, and
review-cut facts. Omitted optional items add no penalty, and main:dessert remains
2:1 without a drink. Replay and snapshots retain tray membership, per-component
costs/funding, deadlines, source recognition, and course slots without resampling
choices or emitting effects. Compare all four main/optional-drink/optional-dessert
combinations through genesis/snapshot replay, recovery, reconnect, content
changes, exact cutoffs, and projection rebuild. No component is another arrival,
completed main, allowance grant, or award-qualifying visit.

Ingredient-substitution policies are durable restaurant facts. Order acceptance
records the resolved ingredient IDs/quantities, conversion and penalty definitions,
and pinned recipe/content version together with reservations. Preparation records
the actual consumed batches and acquisition costs; service records the resulting
quality, including the substitution penalty once. Cancellation/spoilage classify
those same costs as waste when appropriate. Replay never resolves an old order
against current stock, policies, prices, or substitute mappings. Qualification
traces include non-unit yields, shared-stock contention between recipe lines,
policy changes, expiry, cancellation, and content upgrades around acceptance.

An accepted bill also binds composition-relevant ingredient definition versions.
Replacing expired reservations requires matching those definitions as well as
product IDs; fresh stock with changed dietary/composition facts cannot silently
replace the pinned bill. Ordinary acquisition-price differences remain accounted
for through actual batch costs.

Persist each arrival's dietary-profile selection and continuation, the visit's
resolved requirements/policy version and carbohydrate ceiling, and each accepted
course's ingredient-derived compatibility evidence and carbohydrate amount.
Course service/cancellation records the corresponding commitment change; the
same batch preserves money, stock, served totals, and visit state. Declared food
composition and classification definitions remain available by content hash.
Historical replay never resamples a profile, infers a diagnosis, recomputes
eligibility using current nutrition data, or resets a main/drink/dessert limit.

Visitor work adds facts such as `HelperShiftAccepted`, `TaskControlTransferred`,
and `HelperWagesSettled`. Persist validated on-duty/standby coverage, counter
selection, and position/task controller handovers, not every pointer movement.
Payroll debit, wallet credit, transfer-limit consumption, commitment release,
and settlement identity form one atomic batch. Replay reconstructs funding
lineage, raw/work-in-progress/served/waste costs, assignments, generations, and
partial wages without paying again or reopening an ended shift.

Successful shift completion and its server-owned task/end-time evidence grant
service-level licensing eligibility in the same cross-stream batch as the hall's
shift completion and final payroll settlement. Record semantic facts such as
`LicenseEligibilityGranted`, `LicenseApplicationSubmitted`,
`LicenseApplicationDecided`, and `RestaurantLicenseGranted`, with stable principal,
shift/application, reviewer, sponsor, and admission-route references. Workforce
owns the proof; identity owns eligibility, applications, and licenses. Application
approval and invitation redemption use the same single-license/immutable-parent
invariants and revalidate the identity stream version. Invitation admission
supersedes a pending application atomically; approval-first leaves a subsequently
attempted invitation unused. Reviewer authority is checked against current facts,
never a cached queue projection. Application decisions, role/license/parent,
durable notice, and command receipt commit together; approval alone writes no
business grant or lease. Replay reconstructs the queue, eligibility, authority,
and outcomes without repeating approval, sending old notices, or creating access
sessions. Protected evidence remains server-private through authorized projections.

Raw passwords/tokens, email-link credentials, and contact addresses are not
copied into an immutable game log. Record stable credential/contact references
and lifecycle facts, with secrets and contact values in protected dedicated
storage. Restoring old events must not reactivate expired or revoked credentials.
Request receipts, delivery attempts, server-authority ownership leases/fencing
counters, and projector checkpoints also need durable operational storage;
physical stall leases remain fully event-sourced domain state. Full event
sourcing concerns domain state, not a requirement to event-source every database
implementation detail.

Backups cover the event log, immutable content, protected credential/contact
records, receipts, and delivery/outbox tracking at a consistent cut. Only domain
projections, indexes, reports, and snapshots may be discarded for a rebuild test.
Events cannot recreate a missing authentication secret or prove that an external
email was already sent. Missing protected data denies the affected access or
requires recovery; it never manufactures a replacement session from a public ID.

Camera movement, animation frames, ambient sound, interpolated crowd positions,
and raw connection heartbeats remain transient. Record a rule-relevant outcome,
such as an absence-triggered closure or a satisfied NPC-retirement condition,
rather than every heartbeat that helped determine it.

### Streams and atomic append

For launch use an ordered `hall:{id}` gameplay stream and an ordered service-level
identity/control stream. Hall events identify the owning aggregate/entity; a hall stream
does not erase restaurant, market, workforce, or lease ownership boundaries.
Keep identity separate so future private halls can reuse the account/inviter
tree. The initial coordinator may own both streams; this is not a requirement
for distributed actors per aggregate.

An application-owned event-store port must support:

- Reading complete committed batches and stream prefixes.
- Appending to affected streams with expected versions and read-set checks.
- Atomic multi-stream append for workflows such as a restaurant action earning
  an account invitation, or business formation attaching an owner to a lease.
- A receipt bound to the authenticated actor, original request fingerprint,
  outcome, and appended event range.
- Ownership-fencing checks, durable delivery intents, and required synchronous
  projections in that same database transaction.

A minimal PostgreSQL adapter is the baseline. Evaluate a maintained library
against these contracts before selecting it. Elixir
[EventStore](https://hexdocs.pm/eventstore/EventStore.html) demonstrates that
PostgreSQL-backed append/read/subscribe infrastructure exists; its use is not
assumed to provide this application's cross-stream/Ecto transaction and fencing
contract without proof. Commanded is optional, not a reason to replace the hall
transaction model with independently committed actor workflows.

The append transaction locks the global append head first, then stream/read-set
heads in a consistent order, verifies authority, expected versions, and current authorization facts,
appends all events, advances heads, and writes the receipt/outbox atomically.
Verify identity facts needed for authorization even when a hall-only operation
does not append an identity event. A conflict replans from fresh state with
bounded retries; it never appends half a purchase or applies a stale candidate.

Event envelopes include event ID, type and schema version, stream/version,
batch ID and within-batch order, affected IDs/hall, actor/system principal,
causation and correlation IDs, rule/content hash, and applicable clock context.
Use explicit portable serialized types and integer economic units.

Client-facing projections/commands encode money and potentially large positions
as canonical decimal integer strings, with exact parsing and domain bounds.
Stored event schema codecs likewise preserve exact values; raw JSON number
conversion through a floating-point client must not become part of the replay
or receipt-fingerprint path.

For launch, allocate a global committed-batch position under a shared append-head
row lock held until transaction completion. This gives the two streams one
consistent replay/checkpoint order and matches the initial serialized workload.
An ordinary independently allocated SQL sequence is not proof of commit order:
another transaction could commit first. Unique stream-version and event-ID
constraints plus expected-version checks reject competing appends. PostgreSQL's
[transactional locking](https://www.postgresql.org/docs/current/explicit-locking.html)
provides the primitive; this cursor protocol is our design to implement and test.

After commit, accept the candidate state and expose the committed positions.
A crash after commit but before acknowledgement recovers through the receipt
and replay. A crash before commit leaves no events, payment, lease, or delivery
intent. Rejections may have durable request outcomes but do not invent successful
domain events.

A lost database response is an uncertain commit, not proof of rollback. Stop new
economic acceptance, recover/inspect the original receipt and event range, and
resolve the same request ID. If acceptance or publication fails after a successful
append, restore that committed head rather than running from the previous
in-memory candidate. Receipts keep the original invocation result; linked
order/shift queries supply later settlement status. Stream ownership and receipt
retention prevent ambiguity from becoming another grant or purchase.

### Projections, delivery, and consistency

Raw event streams remain server-private; clients receive only authorized
projections rather than historical rival finances, private orders, or identities.
Command decisions read the fully caught-up authoritative fold. Serve current
management views from committed state; a successful reply includes the relevant
stream/batch position so a subsequent query can require at least that position.
Historical reports and other noncritical views may project asynchronously,
showing their applied position and lag. A lagging report never authorizes money,
stock, identity, or lease changes.

A projector updates a complete batch and its checkpoint in one transaction.
Duplicate delivery must not double-post a ledger entry, meal, milestone, or quota
grant. Rebuild new projector versions into shadow tables, compare at an agreed
committed boundary, and switch readers only when the new projection is ready.
Events and a required synchronous projection cannot commit independently.

Keep external side effects outside pure replay. The initial live commit records
stable outbox intentions. Only the delivery worker sends email or publications,
using deduplication identities and preserved delivery state. Rebuilding an inbox
does not send historical email again or issue another invitation. Provider
uncertainty remains explicit; local idempotency does not promise exactly-once
execution by an external provider. See
[Commanded's event-handler documentation](https://hexdocs.pm/commanded/events.html)
for its explicit at-least-once delivery semantics; Feud Hall must enforce its own
projection and side-effect contracts regardless of library choice.

### Snapshots, replay, and historical compatibility

Snapshots identify a complete global batch boundary, covered streams/versions,
schema and evolution versions, rule/content hashes, and an integrity checksum.
Capture a consistent immutable state at that boundary; never combine a hall at
one revision with identity state from another. A snapshot cannot be newer than
the durable event head.

Proposed initial cadence is every 10,000 events or five available-service minutes, whichever
comes first, tuned after measuring size and recovery. Snapshot generation must
not hold the append lock while serializing a large world. Keep at least one
previous validated snapshot and verify a new one before making it the recovery
default. A missing, incompatible, or corrupt snapshot falls back to an earlier
one or full replay; a missing/corrupt authoritative event does not.

Live recovery first obtains fenced recovery ownership so an old authority cannot
append past the chosen committed head. It loads a compatible snapshot and applies
subsequent complete batches without issuing commands or external side effects. At that head,
validate balances, claims, jobs, ancestry, clocks, and versions; rebuild indexes;
then perform a distinct live reconciliation before readiness. The launch recovery
ownership covers both hall and identity/control streams; no other coordinator
may append either during this recovery.

Persist one recovery identity for the interrupted availability interval and
retain it across recovery retries, even when a replacement process acquires a
newer fencing epoch. Reconciliation is an idempotent new batch keyed to that
recovery identity; fencing still uses the current authority epoch. Resolve an
uncertain reconciliation append by that same identity before issuing another.
End restored helper shifts at the recovered clocks, settle only funded
earned coverage, invalidate task/position generations, release unused cash and
transfer authorization, and restore eligible automatic staffing. Do not assume
old sockets or helpers are present. Clear incomplete connection-based NPC
eligibility windows and the retirement-eligibility latch: new retirements require
a fresh post-recovery 13-owner/five-service-minute observation. This is an explicit
recovery exception to normal population hysteresis, since restored sockets are
not proof of simultaneous play. Already committed closing work still settles
normally. Preserve remaining recorded absence grace or declare newly observed
absence at the recovered service time. Safety and attendance holds remain latched.

Verify ownership is still held, establish a fresh monotonic anchor, and only then
resume clocks/scheduling and admit commands. A reconciliation crash cannot pay
again or create another handover on retry. No economic, invitation, helper pay,
or player-rights deadline advances for platform downtime. Security credential
validity is checked against current wall time after replay. An offline history
or shadow-projection rebuild uses a fixed committed cut without claiming the
live authority, running reconciliation, or pausing play.

Version every event schema. Retain deterministic decoders/upcasters and the
evolution semantics required by old facts. Upcasters adapt historical structure,
not old outcomes to a newly preferred balance policy. Versioned content packages
needed by active state and historical interpretation remain available by hash.
An unknown event type/version blocks affected recovery/projecting with an
actionable error; silently dropping it is forbidden.

Corrections append explicit linked compensating events, preserving the original
facts and their accounting consequences. Snapshots and projection compaction do
not permit deletion of the event prefix. Cold archival is acceptable only with
verified complete restoration and retained decoding/content support. Projection
bugs are repaired by rebuilding; incorrect historical business facts require an
explicit domain correction.

### Accounting, derived writes, and durability

An acknowledged committed economic change survives process or application
restart. A purchase cannot debit cash without delivering stock, and restart
cannot duplicate a sale, wage payment, lease, license, or award. PubSub is a
notification mechanism; successful commitment requires the durable batch first.

Apply events and update projections through explicit declared changes: derived puts/deletes come from the event batch, not a world scan or an independent mutation that bypasses events. Evicting a cache does not delete history. Batches contain balanced integer-unit facts for cash/commitments, raw inventory, work-in-progress/ready food, cost of sales, waste, liabilities, payroll credits, and revenue. Ledger and current-balance views rebuild and reconcile from them. Durable notices are reconstructible while delivery tracking prevents replayed notifications. Reconcile affected restaurants on acceptance and all recovered current state; keep full historical audits outside routine tick latency.

Debounced snapshots alone can lose recent actions; shutdown callbacks alone cannot establish durability because Elixir does not guarantee that `terminate/2` runs on every exit. This is why committed transitions require durable records before success is exposed. See the official [GenServer lifecycle documentation](https://hexdocs.pm/elixir/GenServer.html#c:terminate/2).

## Deployment and clients

### One authority per hall

Start with one active simulation authority per hall and a single application service configuration. At launch one coordinator holds fenced authority for both the hall and the shared identity/service-control stream; its recovery head includes both. A database-backed ownership lease with a monotonically increasing fencing epoch must be checked in every economic commit. An old authority that loses ownership cannot continue writing or announcing new committed state. A stream-version match alone is not permission to impersonate the current authority.

Horizontal scaling later must route commands to the correct hall authority. Distributed registration alone is not proof that two nodes cannot mutate the same economy. The multi-hall model should remain independent of whether halls share a machine.

### Render deployment

[Deployment](DEPLOYMENT.md#web-and-server-release-sequence) owns the planned
release/handover procedure and evidence; this section defines its constraints.

Host the canonical Phoenix service and web client on Render, with durable PostgreSQL storage. Desktop builds contain the frontend and native wrapper; they do not bundle a second canonical Elixir server. An always-running service configuration is required for a persistent hall even with no connected owners; select actual capacity from measurements rather than assuming a free plan will satisfy it.

Use an explicit migration phase, application readiness checks, and controlled authority handover. A failed migration or unavailable persistence layer leaves the economy unavailable rather than admitting mutations against incomplete state. Keep connection pools bounded across instances and background workers.

Clients must expect deploy and maintenance disconnects. Render documents that connections can be interrupted and reconnects may reach another instance; include exponential-backoff reconnection and state recovery. See [WebSockets on Render](https://render.com/docs/websocket).

### Content and client versions

Store recipes, ingredients, equipment, NPC profiles, milestones, and balance data as validated versioned definitions. Validate IDs, references, positive durations, ingredient quantities, prerequisites, limits, and absence of unlock cycles before enabling a version. Substitute mappings must reference distinct valid products, preserve recipe claims, use positive bounded conversions and small quality penalties, and satisfy launch coverage; reject fallback chains/cycles. Validate full resolved bills against shared ingredient requirements. Declare recipe `course_kind` as main, drink, or dessert, and each cuisine's three savory recipes, one dessert, and one drink (100 recipes in total). Validate chilling/setting and assembly capabilities, timed work and resource-claim policies, as well as thermal cooking; dessert finishing must not bypass finite station/storage capacity or ready-food expiry.

Dietary content includes complete ingredient-origin and carbohydrate facts for
all portion components, derived compatibility for approved resolved bills,
profile requirements/weights, and explicit carbohydrate ceilings. Validate known
metadata, nonnegative bounded composition, coherent vegetarian/vegan rules,
nonnegative weights summing to one, supported constraint intersections, and a
stricter keto-style ceiling than the carbohydrate-conscious ceiling. Demonstrate
at least one viable main per enabled profile/combination within the launch
catalog; each cuisine need not cover every diet. All compatible substitute bills
must preserve invariant recipe claims and recompute portion facts before a new
offer. Missing profile/composition values cannot silently default to unrestricted
or zero carbohydrate. Profile changes activate with content; visits and accepted
courses keep their original versions.

A hall uses a pinned rules/content version. Apply balance updates at an announced safe boundary; jobs and transactions already accepted retain the agreed recipe, cost, and work definitions. Do not replace configuration underneath active economic work through an unversioned hot reload.

Maintain a supported client protocol range. An incompatible desktop build receives a clear update requirement. A backend deployment does not update frontend assets already bundled in an installed Tauri application.

### Native distribution

See [native release procedures](DEPLOYMENT.md#native-release-artifacts) for
packaging inputs, artifact qualification, and publication requirements.

Target Linux and macOS build artifacts through hosted CI, after the common web game works. Test the actual supported browser/webview combinations rather than assuming all GPU and audio behavior matches.

The Linux release pipeline must produce both a Flatpak package and a Debian
`.deb` package from the same versioned Tauri client source and retain both as
downloadable release artifacts. Define the supported CPU architectures,
distribution versions, Flatpak runtime, and runtime dependencies before enabling
the packaging jobs. Pin build inputs and package metadata, including application
identity and version. Qualify each format through installation, launch, and
connection to the authoritative server in its supported target environments;
the Flatpak flow must also verify that its declared permissions permit the
required network, rendering, and native-client behavior. These are required CI
deliverables; the packaging jobs remain implementation work.

The lack of a paid Apple Developer account is a distribution constraint. Initial macOS builds may require ad-hoc signing and explicit user approval in system security settings; seamless notarized distribution is not promised. Verify the actual install flow before publishing. See [Tauri macOS code signing](https://v2.tauri.app/distribute/sign/macos/). Tauri updater artifact signatures are a separate concern from Apple signing/notarization; automatic updates are a later release task.

## Localization and presentation boundaries

English and Japanese are launch locales under the [game-design contract](GAME_DESIGN.md#ui-languages-and-localization). Implement shared internationalization in the Svelte client used by web and Tauri, with application/presentation adapters for server-rendered player messages. Keep locale out of economic decisions, identifiers, random state, prices, clock rules, and authorization. Per-installation/browser language preference is presentation state; changing it performs no economic command or clock advance.

### Responsive workspace and contextual guidance

The [interaction model](GAME_DESIGN.md#gameplay-interaction-model),
[in-context onboarding](GAME_DESIGN.md#learning-through-ordinary-play), and
[responsive layout](GAME_DESIGN.md#responsive-layout-and-input) own the user
experience. Use one Svelte application/use-case boundary across phone browsers,
desktop browsers, and Tauri. Small screens must not fork the economic rules or
drop a core role workflow. Native phone packaging remains outside launch scope.

Keep route, business/stall scope, selected entity, editor draft, pending command
ID, and projection revision in one coherent presentation state. Desktop
inspectors and phone detail routes use the same editor/action model; do not
create two independently submitting forms or duplicate socket subscriptions
because both layouts exist. Reflow, orientation, browser Back, and virtual
keyboard changes preserve composition/drafts and cannot submit a command.
Revalidate any restored quote against current authority and content.

Use content-driven CSS layout and available container/viewport width, with input
capability and text zoom considered independently of device names or physical
pixel resolution. Keep active actions above keyboards/safe areas and essential
information available without hover/drag. Bound public/private subscriptions and
rendering detail; a contextual hall view and full hall share one renderer/model
where possible rather than mounting duplicate worlds. Hall navigation replaces
the contextual preview with the full workspace, and returning to Business
restores it; never display both hall views together. Low-detail/list fallback
preserves management, dining, helper, and review use cases. Qualify actual mobile
browser suspension and reconnect behavior; cosmetic render suspension never
pauses gameplay or changes the server attendance policy.

Readiness, explanations, and suggested actions are authorized read models built
from existing domain predicates and quotes, with explicit blockers and estimates.
They do not repair state, accrue clocks, unlock features, or auto-execute policy.
Hint visibility is presentation preference, not a tutorial-completion domain
gate. Retain mandatory costs/risk/authorization information when optional help
is dismissed. Show real eligibility, licensing waits, funding limits, and
cleaning state; never create tutorial customers, grants, or an independent economy.
Domain events remain the source of real outcome explanations and durable notices.

### Message and content contracts

Use stable message codes with typed, named parameters, and catalog lookups for all player-facing text. Translate whole sentences, including count/select variants, rather than concatenating English fragments. A maintained formatter must support parameter reordering and locale-specific grammar; select/pin it during implementation instead of creating a second ad hoc formatting language. Catalog validation checks matching keys, parameter names/types, and required variants across English/Japanese. Translation catalogs have their own presentation versions mapped to stable content IDs; editing a translation does not activate new economic rules or alter accepted historical terms. Fallback remains a runtime resilience path; complete Japanese coverage is a release requirement.

Domain rejections expose stable error codes and structured facts. Events, receipts, and durable notices retain codes/semantic facts and canonical amounts, not localized prose as their authority. Resolve content names/descriptions through immutable cuisine/recipe/ingredient IDs and the supported catalog version. Retain mappings for historical notices and supported clients so changing locale or rebuilding a projection does not erase meaning or resend notifications. Commands contain canonical IDs/values, never translated display names or formatted labels; locale is excluded from economic request fingerprints. Translate optional email/player notifications through the delivery adapter, preserving outbox identity and delivery tracking.

User-entered names, motivations, and decision reasons stay user text; they are neither auto-translated nor interpreted as catalog templates/markup. Escape them at presentation boundaries. Scope shared caches/projections to the appropriate locale when they contain localized text, while preserving current principal authorization. Pure domain state and replay remain identical for either UI language.

### Formatting, text, and input

Adapters format exact canonical integer money/positions and bounded quantities for display. Do not route large amounts through floating-point numbers. Price/quantity parsers validate the numeric field's declared syntax, including explicitly supported full-width digits, and return the same canonical values in either locale; reject ambiguous separators or unsupported input with a localized actionable error. Do not apply numeric-input transformations to names, credentials, invitation codes, or identifiers. Virtual dollars retain their unit and fractional precision in Japanese. Keep locale, wall-time display zone, and shared hall time independent and label the game's clocks explicitly.

Set document/control language metadata and use Japanese-capable fonts with appropriate fallback. Choose a licensed bundled/system-font strategy whose glyph coverage, download/install size, offline availability, and rendering are verified in each supported package. Include generated 3D text/atlases and their accessible HTML alternatives in that check; a Latin-only atlas cannot silently discard Japanese. Layout uses flexible wrapping/sizing and appropriate Japanese line-breaking/punctuation, informed by [W3C Japanese layout guidance](https://www.w3.org/TR/jlreq/).

Treat text as Unicode. Define consistent user-visible character limits plus safe UTF-8 storage bounds, preserve grapheme boundaries, and share boundary fixtures between frontend/server validation. IME composition/conversion must not submit forms, activate shortcuts, or be overwritten by reactive ticks. Locale changes can be deferred until composition commits; preserve that composition instead of remounting its input. Verify actual input on supported webviews, using the [UI Events composition model](https://www.w3.org/TR/uievents/#events-compositionevents) as reference; this work-in-progress specification is not proof that every webview behaves identically.

### Localization qualification

Run catalog/placeholder checks and critical owner/guest/helper/reviewer workflows in both locales from the first UI slice. Add pseudo-localization, narrow/wide viewport and zoom checks, real Japanese text-entry checks, error/reconnect coverage, and installed-package font/input checks. Compare economic command/outcome traces across locales: only presentation differs, and retries remain the same invocation. Exercise canonical numeric round trips, Japanese names at character/byte boundaries, translation parameter permutations, and current-authorization checks on localized projections. Curated mutations remove keys or parameters, change units/precision, bypass IME guards, or omit locale from a localized cache key. Use a shared English/Japanese terminology glossary and automated checks for missing or inconsistent labels, parameters, and units.

### Cuisine-map presentation data

Implement the [cuisine picker](GAME_DESIGN.md#cuisine-selection-map) as a
responsive 2D SVG/vector view in Svelte, independent of Three.js. Use the proposed
Equal Earth projection consistently for basemap, cuisine polygons, labels, and
hit testing; preserve aspect ratio and define the projected coordinate system.
Ship the geometry with web/native assets rather than requiring a live map API.
Version geographic sources, licenses/attributions, simplification/export inputs,
projection parameters, and footprint-to-cuisine-ID mappings as presentation
assets. Geographic tooling is a build/presentation concern, not a domain
dependency or a new authoritative simulation.

Validate complete coverage of the available cuisine catalog, finite valid
geometry, multipart/overlap handling, and stable IDs. Region mappings need not
partition the world or follow country borders. A shared selection model drives
the SVG and searchable accessible list; neither localized names nor polygon IDs
become economic identifiers. Keep labels in the English/Japanese catalogs and
retain selection/viewport through updates. Map hits and list actions produce
only a draft cuisine ID; existing setup/refit use cases validate and commit it.
No projected area or map interaction changes economic weights or eligibility.

Enforce the game's explicit footprint assignments in geometry validation and
interaction fixtures: Eastern Thrace is included only in the Turkish cuisine
region and excluded from European highlighting and hit/overlap candidates.

Test known relative-area projection fixtures independently of the renderer,
geometry-to-hit alignment at different sizes/zooms, small and overlapping
regions, all cuisine IDs, input methods, localization, and map-loading failure.
Installed clients must include the map assets; missing WebGL must not disable
the picker or its list alternative.

## Implementation status

Milestone 1 (economic core) built an internal one-cuisine slice in `server/`;
Milestone 2A adds durable PostgreSQL storage for it. Together they qualify the
event-store, recovery, fencing, and projection contracts above for that slice.
They do not qualify capacity, the full market, or any online surface.

| Layer | Modules |
| --- | --- |
| Domain (pure) | `FeudHall.Domain.Money`, `Clock`, `Content` (+ `SliceCatalog`), `Dietary`, `Substitution`, `Inventory`, `Offers`; the hall boundary `Hall` with `Decider`, `Evolver`, `Advance`, `Settlement`, `Invariants`; and `Control` (the availability/recovery control stream) |
| Application | `CommandWorkflow` (validation, fingerprinted receipts, separate clock-advance batch, decide, append, `resolve/2` for uncertain appends), the `EventStore` port, `Recovery` (snapshot-then-tail rebuild plus the idempotent reconciliation batch), `Diagnostics`, `MonotonicClock`, and the projections `Projections.Balances` and `Projections.DailyActivity` |
| Infrastructure | `Repo`, `PostgresEventStore` (migrations in `server/priv/repo/migrations`), `Postgres.DailyActivityProjector`, `InMemoryEventStore` (failure injection; the second adapter for the shared port contract), `EventCodec` (allowlisted JSON), `Snapshot` (versioned, checksummed), `HallAuthority`, `Diagnostics.MemorySink` and `Diagnostics.Exporter`, `SystemClock`, `ManualClock` |

Implementation decisions within the contracts above:

- **One master tick.** Hall and available-service time both advance only while
  the service is ready and both pause during downtime, so they stay exactly
  proportional (24:1). The domain stores hall milliseconds and converts
  service-time quantities explicitly through `Clock.service_duration/1`. If a
  future rule makes the clocks diverge, replace this with two stored clocks.
- **Deterministic identities.** Entity IDs (visit, tray, order, batch, wallet
  slice) derive from the command ID, so a decision is a pure function of state,
  command, and context, and a retry cannot mint a second entity.
- **Temporary seams.** Kitchen progress is decided from explicit
  `{:system, :kitchen}` commands until the workforce milestone schedules it from
  staff coverage, and purchases fill directly at the catalog base price until
  the batched scarcity-priced market lands. Both already emit the same facts
  the later mechanisms will produce.
- **One hall per database.** Milestone 2 stores exactly one hall's global log
  per PostgreSQL database; `read_from/2` returns the whole log. Multi-hall
  hosting needs a hall key on every table and is a later decision.
- **Append order.** A PostgreSQL append locks the append head, checks the
  authority epoch, then checks the expected position, so a fenced owner gets
  `:fenced` rather than a position conflict. A `lock_timeout` turns a stuck
  writer into `{:error, :unavailable}`. Each batch records its `event_count`;
  reads verify it and report `{:event_count_mismatch, recorded, found}` instead
  of replaying a torn batch.
- **Authority acquisition.** `acquire_authority/4` may carry an expected epoch;
  the bump happens only if the stored epoch equals it. It also succeeds when the
  row already shows the same owner at exactly the expected epoch plus one, which
  recognises that owner's own acquisition whose reply was lost. That makes owner
  names identify one authority incarnation: production owner names must be
  unique per incarnation (32 bytes at most).
- **Control stream and recovery identity.** Availability transitions live in a
  separate control stream. Starting an epoch is recorded only by
  `start_availability`; reconciliation is keyed by an epoch-independent
  `recovery_id`, so every owner retrying the same interrupted recovery sends an
  identical fingerprint and gets the original receipt. `Control` rejects any
  other recovery ID as not pending.
- **Projector checkpoint.** The asynchronous daily-activity projector advances
  its checkpoint only from the exact predecessor position (contiguous batch
  positions) in the same transaction as its deltas, so concurrent or repeated
  runs cannot double-count. `PostgresEventStore.rebuild_projections/1` and
  `Postgres.DailyActivityProjector.rebuild/1` recompute derived tables from the
  log.
- **Snapshots, evolution 2.** A snapshot encodes the hall and control states at
  a position and is accepted only for the current evolution version; version 1
  (hall only) is rejected as incompatible. Recovery uses only verified
  snapshots, skips one beyond the store head, and falls back to older ones or
  genesis. Snapshots never justify skipping history that fails to replay.
- **Unavailable storage.** On PostgreSQL, connection errors (and lock timeouts,
  cancellations, and shutdowns) surface as `{:error, :unavailable}` from
  `head/1`, `stream_versions/2`, `read_from/2`, `receipt/2`, `append/2`,
  `acquire_authority`, `save_snapshot/3`, `snapshots/1`, `prune_snapshots/2`,
  and `rebuild_projections/1`. `projection/2`, `outbox/1`, and
  `mark_snapshot_verified/2` raise instead; the authority's shield turns a
  raised connection or transaction error, or a `Postgrex.Error` with one of
  those unavailable codes, into `:unavailable`, and lets any other raised
  error stop the process. The authority freezes its clocks at the last
  committed boundary and, after more than five unobserved seconds, recovers
  instead of charging the gap.
- **Clock catch-up identity.** A command executed with an observed service
  instant past the hall's clock first commits a catch-up advance whose command
  ID is `"adv:<target_service_ms>"`, a pure function of its target. A retry of
  the caller's command observed later catches up to its own target, a catch-up
  already recorded is not appended again, and a lost catch-up reply is
  resolved inside the workflow: the caller only ever sees its own command ID.
- **Stored terms.** Receipts, outbox payloads, content, and snapshots are
  external terms decoded with `[:safe]`, which never creates atoms. The
  application loads all of its modules at start-up so atoms this build defines
  exist in a fresh VM; a stored term that still cannot be decoded is an error
  value (`{:undecodable_receipt, id}`, `{:undecodable_outbox, key}`,
  `{:undecodable_content, ref}`, or an incompatible snapshot), never a raise.
- **Authority status.** `HallAuthority` formats its status and crash reports
  with scalar fields only (scope, owner, epoch, mode, position, service time):
  never the hall, its store, or player-entered text.

Not yet implemented, and therefore not qualified:

- Project B: the batched market, simulated diners and choice, kitchen jobs and
  staffing, helpers and wages, rent and leases, reports, and NPCs.
- Project C: the 150-stall capacity and latency measurements; no performance
  claim exists yet.
- The outbox delivery worker (intents are committed atomically but nothing
  delivers them) and production wiring of authorities: the application
  supervises the `Repo` and an empty authority `DynamicSupervisor`, but nothing
  starts a `HallAuthority` outside tests, and owner-name allocation is
  unspecified.
- Identity, invitations, licensing, Phoenix, Channels, deployment on Render,
  and every client.

## Architecture verification

[Testing](TESTING.md) owns check selection, planned entry points, execution
budgets, and evidence reporting. The contracts below remain required invariants.

Architecture checks exercise actual boundaries, not just module names:

- Enforce inward imports: domain code has no Phoenix, Ecto, database, network,
  global configuration or ambient-clock dependency; outer adapters implement
  application-owned ports.
- Inventory command/query handlers and aggregate/projector ownership. Reject
  direct table writes or read-side gameplay mutations that bypass these owners.
- Contract-test persistence, clock, delivery, and credential adapters against the
  same use cases as pure fakes, including current authorization and failure modes.
- Test the wrapped application entry as well as pure decisions: human, NPC,
  timer, unattended, and admin callers cannot bypass required guards.
- Use property-based stateful traces, shrinking, independent accounting/resource
  oracles, and curated/generated mutation cohorts as required by the
  [game design's verification policy](GAME_DESIGN.md#property-based-testing).
  Include changing permissions between decision and commit, read-offer/command
  agreement, clock boundaries, and prohibition of side effects during replay.

The [correctness scenarios](GAME_DESIGN.md#required-correctness-scenarios) and
[target workload](GAME_DESIGN.md#technical-target-workload) remain acceptance
criteria for this architecture. Critical architecture guards need mutation
sensitivity evidence; line coverage alone does not establish the invariants.
Local full-suite runs require advance permission. Local `tsc` is prohibited
because of its RAM usage, including indirect invocations; local `bun check` is
allowed. Bound local diagnostic resources and use hosted CI for broad suites and
heavy mutation work under the [verification budgets](GAME_DESIGN.md#mutation-testing).

### Early qualification and ongoing tests

Build this proof with the economic core and persistence slice, before the
gameplay depends on a large event catalog:

1. Run representative main/drink/dessert orders across all four optional-item
   combinations, atomic tray acceptance/service/cancellation, choice expiry, course settlement and
   visit finalization, market contention, hiring, absence, guest dining,
   helper control/handover and wage settlement, successful-shift eligibility and
   license application/review races, invitation earning/redemption,
   expansion, and failure through decision/evolution.
   Rebuild from genesis and from each supported snapshot cut; compare canonical
   domain state, balances, random continuation, clocks, and durable notices at
   the same committed batch position. Exclude process-local caches/handles.
   Recovery reconciliation then appends new facts; compare again at that new
   position instead of expecting pre-crash control leases to survive unchanged.
2. Delete only derived tables in a disposable database and rebuild them from the
   event log, retaining protected credentials, receipts, outbox/delivery state,
   content, and coordination records. Verify authorizations, private projections,
   ledger totals, quota, and outcome history without entity rows as a fallback.
3. Inject failure before append, during multi-stream append, after commit before
   reply, and during projection/checkpoint updates. Exercise duplicate delivery,
   conflicting versions, revoked credentials, and superseded fencing epochs.
   Assert atomic outcomes and no repeated external delivery intent.
4. Retain historical serialized fixtures across supported event versions and
   content changes. Test snapshot incompatibility, missing required events,
   compensating corrections, and replay with side-effect adapters set to fail if
   called.
   Exercise the separate recovery-reconciliation batch with an interrupted
   helper shift, pending wages, revoked credentials, lost owner presence,
   incomplete NPC windows, an uncertain append response, and a large scheduler
   gap. Replay alone must produce no live effects; reconciliation must be safe
   to retry and accrue no outage pay.
5. Load-test 150 occupied stalls and the GDD's 450-session peak mix of owners,
   diners, and helpers, meal peaks, paired main/drink trays and later desserts,
   and absent automation. Measure append latency,
   events/bytes per second and per day,
   indexes/storage growth, projection lag, snapshot cost, and tail/full replay
   time. One clock event per real second alone is 86,400 events per real day;
   size the retained history rather than assuming it is negligible.

A proposed tail-recovery target is at most 30 real seconds from a validated
snapshot on the selected server, under the target 150-stall workload. Also test
full replay of a representative 30-real-day history and record its cost; it need
not share the interactive recovery budget. Validate backup plus archived-history
restore and projection rebuild before release. Existing command-latency and
freshness targets still apply.

Property tests compare live evolution with genesis and snapshot-tail replay,
including helper controller generations, partial payroll/wallet settlement,
serialization round trips, and duplicate projector deliveries. Curated
mutations remove an event, alter its amount/order, skip a stream-version/fencing
check, accept half a batch, advance a checkpoint before its writes, or trigger
side effects during replay. The expected independent assertion must fail.

If the qualification fails, first investigate event granularity, batching,
indexes, snapshot cadence, and projector placement. Record measured limits and
the resulting design adjustment. Do not silently fall back to mutable entity
tables as a second source of truth or weaken the atomic economic contract.
