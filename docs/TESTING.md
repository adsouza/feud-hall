# Feud Hall Testing

The Phoenix server and Svelte client have focused local and hosted checks.
See [Implemented backend entry points](#implemented-backend-entry-points) and
[Management and web checks](#management-and-web-checks) for runnable commands.
The qualification matrix also lists checks required for a release.

The [game design](GAME_DESIGN.md#required-correctness-scenarios) owns gameplay
acceptance scenarios; [architecture](ARCHITECTURE.md#architecture-verification)
owns implementation invariants. This document owns how to select, run, and report
checks. Release execution belongs in [Deployment](DEPLOYMENT.md).

## Offline single-player qualification (planned)

These are requirements, not passing evidence: the current clients remain
networked. Test the shared core through local and multiplayer execution adapters
using the same catalog, seeds, commands, and active-time advances; compare
committed events, receipts, resource accounting, and replay at equivalent heads.
Use isolated local saves and disposable online halls, never a player's live data.

- With all external networking blocked and no separately installed service or
  PostgreSQL, start/load a local hall, manage against NPCs, and save/relaunch.
  Assert that online transport, credential lookup, and version handshakes are not
  invoked in this mode; unreachable-server error handling is not offline play.
- Close or suspend with accepted food, reserved stock, payroll, cleaning, lease
  charges, and other deadlines pending. Change wall time forward/backward and
  resume: both gameplay clocks and all economic quantities stay at the saved
  head until active time advances. No offline catch-up or extra demand/grants.
- Inject failure before/during/after local append, interrupted acknowledgements,
  concurrent opens of the same save, full/evicted storage, corrupt snapshots,
  missing content versions, and failed upgrades/imports. Require atomic batches,
  original-ID receipt resolution, single-writer ownership, compatible recovery,
  and genesis/snapshot-tail equality without replay effects.
- Prove that local identities, balances, proofs, exported saves, and owner
  admission cannot mint online rights/progress, and that multiplayer disconnect
  does not fork or pause the shared economy.
- Qualify offline web/browser runtime and installed macOS/Flatpak/`.deb` delivery,
  English/Japanese fonts/IME, and shutdown of native local workers. Browser-asset
  caching, source review, or a localhost development server is insufficient.
- Curated mutations should charge the closed interval, reset a resumed deadline,
  reissue a grant, skip atomic receipt persistence, or accept offline progress
  into an online scope. Keep property/action budgets and local suite restrictions.

## Frontend toolchain

Use **Bun** for dependency management, TypeScript execution, scripts, and suitable
unit/property tests. Commit `bun.lock`, pin the Bun release, and install CI
packages with `bun install --frozen-lockfile`. Use the locked **Oxlint** dependency
as the JavaScript/TypeScript linter. Do not introduce ESLint or a separate `tsc`
CLI step. Keep Svelte's browser compilation pipeline and invoke its build scripts
through Bun; successful transpilation/build is not evidence of type correctness.

Use **`bun check` locally and in hosted CI** for TypeScript type checking. It is a separate
check from running TypeScript or tests without checking. See the official
[Bun type-checking documentation](https://bun.sh/docs/runtime/check). Avoid a
package script named `check` that shadows the native command; validate the actual
entry point in the pinned version and record its invocation in the workflow.

Qualify Svelte coverage with deliberately invalid component-prop, template
expression, and script fixtures. Oxlint's [compatibility matrix](https://oxc.rs/compatibility)
currently identifies a template-linting gap, so linting scripts alone cannot
establish coverage of `.svelte` files. If the pinned Bun checker does not diagnose
those component/template cases, add a pinned Svelte-aware CI check invoked through
Bun, such as the component diagnostics described in the official
[Svelte TypeScript guide](https://svelte.dev/docs/svelte/typescript). Record which
files and error classes each check covers; do not silently drop uncovered cases
or add ESLint/`tsc` to conceal the gap. The exact Svelte integration is an early
frontend qualification task, not an already demonstrated capability.

Oxlint's [type-aware mode](https://oxc.rs/docs/guide/usage/linter/type-aware) is an
optional additional check after qualification. Inspect configuration and flags so
the scope, child tools, and resource use are known. Local type analysis is not
banned in general; indirect `tsc` calls remain prohibited.

## Code formatting

Use Elixir's built-in [`mix format`](https://hexdocs.pm/mix/Mix.Tasks.Format.html)
for backend code, with a committed `.formatter.exs` defining the application,
configuration, migration, and test inputs. Pin Elixir so developer and CI
formatter output agrees. Run `mix format` locally to apply formatting and
`mix format --check-formatted` in CI to reject unformatted code.

Use **Prettier** for frontend TypeScript/JavaScript, Svelte, CSS, and JSON, with
the Svelte-maintained
[`prettier-plugin-svelte`](https://github.com/sveltejs/prettier-plugin-svelte)
explicitly loaded in the committed Prettier configuration. Lock compatible
Prettier/plugin versions in `bun.lock`. Define frontend-scoped file patterns and
a `.prettierignore` excluding generated, dependency, build, and coverage output;
do not sweep backend code or original artwork into frontend formatting.
Keep Prettier configuration minimal and use the same configuration in editors
and command-line checks. Oxlint handles linting; formatting does not replace
linting, type checking, or Svelte diagnostics.

Provide `bun run format` for Prettier's `--write` mode and
`bun run format:check` for its `--check` mode. CI runs the check commands for
both languages without rewriting source. Add the configurations and scripts
when their application manifests are created; they are not installed yet.

## Local execution policy

- Never run local `tsc`, directly or through scripts, hooks, aliases, or child
  tools, because of its RAM use. Local `bun check` is allowed, including checks
  of the entire configured project; it is not a full test-suite run. Other
  diagnostic tools must avoid invoking `tsc` and obey the same resource budgets.
- A full local suite requires the owner's express advance permission. Focused,
  bounded tests and lint/format checks are allowed after inspecting
  their complete command chain. A default `bun test` or `mix test` may run the
  whole suite; selecting a package alone is not proof of a focused scope.
- Run memory-heavy local work serially and stop above 2 GiB combined RSS. Bound
  worker counts and property/mutation budgets. If a dependency launches Node,
  cap its old space at 1536 MB per process; that flag is not a Bun memory limit.
- Use disposable databases for SQL, replay, and failure-injection checks. Never
  point destructive test setup or projection-rebuild fixtures at a live hall.
- Documentation/artwork changes need relevant link, syntax, or render checks,
  not an application suite. Report unavailable checks without claiming a pass.

## Planned entry points

Establish the actual working directory, versions, and scripts during scaffolding.
Keep format, lint, build, type, and test entry points explicit so their costs are visible.
Local `bun check` is permitted; these examples do not authorize a full local test
suite or any indirect `tsc` execution.

| Check | Planned entry point | Where and scope |
| --- | --- | --- |
| Dependency install | `bun install --frozen-lockfile` | Frontend directory containing `package.json` and `bun.lock`; inspect lifecycle scripts first. |
| Backend formatting | `mix format`; CI: `mix format --check-formatted` | Committed `.formatter.exs` defines backend scope; inspect aliases/plugins before local execution. |
| Frontend formatting | `bun run format`; CI: `bun run format:check` | Locked Prettier plus Svelte plugin; explicit frontend scope, write locally and check in CI. |
| Frontend lint | `bun run lint` resolving to locked Oxlint | Inspect selected modes/configuration and local resource use; applicable project scope in CI. |
| TypeScript types | Native `bun check` | Local and hosted CI; check the whole configured project, not just changed files. |
| Svelte diagnostics | `bun run check:svelte` | After coverage qualification; document the script/tool. Local use must avoid `tsc` and respect memory limits. |
| Frontend unit/property test | `bun test <test-file>` | Focused locally after command inspection; bounded suite in hosted CI. |
| Browser tests | `bun run test:browser --grep '<scenario>'` | Focused Playwright regression against a disposable hall. See [Management and web checks](#management-and-web-checks). |
| Backend unit/property test | `mix test <test-file>` | Focused ExUnit/StreamData or equivalent; inspect Mix aliases and setup first. |
| SQL, replay, mutation, load, package checks | Dedicated scripts/jobs | Implement explicit bounded entry points; run broad/heavy work in hosted CI. |

## Implemented backend entry points

Run from `server/` with Elixir/OTP pinned in `server/.tool-versions` and
dependencies locked in `server/mix.lock` (Ecto, Postgrex, and test-only
StreamData). The only Mix alias is `test`, which runs `ecto.create --quiet` and
`ecto.migrate --quiet` and then `test`; every `mix test` therefore needs the
PostgreSQL server below.

PostgreSQL requirement: use the system PostgreSQL server on `localhost:5432`
(never start another server or a container). Connection settings come from
`PGUSER` (default: the OS user), `PGPASSWORD`, `PGHOST` (default `localhost`),
and `PGPORT` (default `5432`). Databases: `feud_hall_dev`, `feud_hall_test`
(override with `FEUD_HALL_TEST_DB`), and `feud_hall_mutation` (used only by the
mutation cohort). Database test modules are `async: false`, start from
truncated tables, and never share rows; keep destructive setup on these
disposable databases.

| Check | Command | Scope and cost |
| --- | --- | --- |
| Dependencies | `mix deps.get` (CI: `--check-locked`) | Fetches Ecto, Postgrex, StreamData. |
| Formatting | `mix format`; CI: `mix format --check-formatted` | `.formatter.exs` covers `lib`, `test`, `scripts`, and Mix files. |
| Compile | `mix compile --warnings-as-errors`; also `MIX_ENV=test mix compile --warnings-as-errors` | Pure Elixir, no NIFs. |
| Focused tests | `mix test <file> --max-cases 1` | One file at a time. PostgreSQL files (`postgres_*`, `hall_authority`, `daily_activity_projector`, `projection`, `schema`, `snapshot_store`, `recovery`) run against `feud_hall_test` after the alias creates and migrates it. |
| Model-based property (pure) | `mix test test/feud_hall/properties/hall_trace_property_test.exs --max-cases 1` | Pure; 100 runs, at most 70 generated actions plus the closing service; the oracle checks every accepted command. Includes a deterministic example that the bare closing service alone reaches every structural floor (the case shrinking collapses to). About 130 MB peak RSS locally (measured at Milestone 1). |
| Model-based property (PostgreSQL) | `mix test test/feud_hall/properties/postgres_trace_property_test.exs --max-cases 1` | Replays pure traces through `CommandWorkflow` on PostgreSQL with snapshots, restarts, aborted commits, and lost replies, and an observed-clock arm that folds every other advance into its successor's catch-up batch (with lost replies and aborted commits on the catch-up append); structural floors on injections, catch-ups, and served trays; checks projection rebuild and genesis replay at the end. |
| Full suite | `mix test --max-cases 1 [--seed N]` | Locally permitted only because the owner gave advance permission on 2026-11-09, serially, with combined `beam.smp` and `postgres` RSS sampled every second and the run killed above 2 GiB. Otherwise hosted CI. |
| Curated mutation cohort | `elixir scripts/mutation_cohort.exs <empty-dir>`; `elixir scripts/mutation_cohort.exs --check` | 49 patches including NPC refusal serialization, premature handover credit, and device revocation. Copies the project into `<empty-dir>`, never edits the checkout, and runs mutants with `MIX_ENV=test` against `feud_hall_mutation`. One worker runs focused files per mutant with a recorded seed and verifies the baseline before and after. A structured ExUnit formatter separates behavioral assertions from setup and runtime failures. `--check` verifies that every patch matches exactly once. Append `--match '<name fragment>'` to an isolated run to select a bounded subset. Hosted CI runs the cohort. |
| Projection rebuild (maintenance) | `PostgresEventStore.rebuild_projections/1`, `Postgres.DailyActivityProjector.rebuild/1` | Recompute derived tables from the log. Not a Mix task and exercised by tests only; never point it at a live hall without an operations procedure. |
| Project C capacity measurement | `python3 scripts/capacity_bench.py --output /tmp/feud-hall-capacity.json` | Standalone, serial benchmark on local PostgreSQL 18. Creates and drops `feud_hall_bench` and refuses an existing database of that name. Defaults to three complete game days, with `--days` accepting one through seven. Stops above 2 GiB combined RSS. |

Run the capacity benchmark separately from other checks. The completed run
records the original one-cuisine workload, replay comparisons, and resource use.
The benchmark now uses the three-cuisine catalog for new halls.
[Project C capacity report](superpowers/reports/2026-11-10-milestone-2c-capacity.md).

Run `mix test test/feud_hall/domain/slice_catalog_test.exs --max-cases 1` to
check the current catalog, course service, and replay for all three cuisines.
Earlier scenarios with fixed prices, portions, or serialized events use the
original Mexican catalog from the committed initialization fixture.

The pure property's action vocabulary (`test/support/hall_trace.ex`) includes
market actions (`{:request, idx, qty}`, `{:cancel_request, idx}`) and macros
that finish lifecycles random steps rarely complete: `{:market_clear}` (to the
next clearing), `{:meal_peak}` (through 12:00 to 13:00 with a restock and NPC
plans), `{:npc_slot}` (to the next hour, then each due NPC's plan submitted as
`{:npc, op}`), `{:dessert_course, guest}`, `{:cycle, ms, desserts}`, and
`{:regret, ...}`. Every trace ends with `HallTrace.closing/0`, and each run
must reach the structural floors of `HallTrace.floors/1` (a clearing with a
fill, a stream arrival admitted and one that left, a served tray, an NPC plan);
cross-run counters guard the rarer lifecycles. The PostgreSQL property runs the
oracle (`Oracle.violations/2`) on its own final state and stored log as well as
`Invariants.check/1`.

The pure property checks the independent oracle (`test/support/oracle.ex`)
after every accepted command, then genesis replay, snapshot-plus-tail replay,
JSON codec round-trip replay, and clock-partition equivalence, and asserts
cross-run progress floors so an all-rejected trace cannot pass. The mutation
cohort's curated faults each name the test file expected to kill them; a
compile failure is reported as invalid and a timeout as a timeout, never as a
kill. Architecture checks (`test/feud_hall/architecture_test.exs`) guard the
domain and application dependency direction and the storage boundaries, and
that `Npc.Planner` and `PublicView` reference neither `Hall.Decider`,
`Hall.Evolver`, nor `Hall.Admission` (the planner sees only its inputs), each
with a planted-violation sensitivity case.

The Project B mutants (`B1`-`B13`, with variants `b`) cover the market (rotation
tie-break, price clamp, stock decrement, replenishment), arrivals during
cleaning, diner choice (exposure applied once, dietary compatibility), the
kitchen (the 03:00 cutoff against service, dispatch gating, queues across
cleaning, station capacity, consumed-ingredient posting), the planner's inputs,
and NPC slot advancement. Several are realised as the closest real source
mutation rather than the original wording (for example a class-order swap for
"handover allowed at the cutoff"); the report records each exact source string
and the test that killed it.

## Choose checks by change

| Changed behavior | Required evidence |
| --- | --- |
| Pure rules, arithmetic, content | Success/rejection/boundary examples; independent conservation and stateful properties; validate affected definitions. |
| Dietary demand | Hard exclusion before choice scoring, full-bill vegetarian/vegan and carbohydrate facts, substitutions/missing metadata, enabled-profile coverage, unchanged finite arrival totals, and shared main/drink/dessert ceilings across acceptance/service/cancellation/replay. |
| Main/drink trays | Every launch drink recipe, initial-only add-on, combined stock/funding/carbohydrate feasibility, one queue/helper handover, atomic paired acceptance/service/cancellation, component waste, freshness/cleaning cutoff, and all four main/drink/dessert combinations. |
| Commands, permissions, resource lifetime | Wrapped use-case tests, retries/conflicts, current authorization, settled-state resource oracle, deferred settlement. |
| Dining acceptance/cancellation | Confirmed-term mismatches, revised command IDs, one active visit with atomic main admission, pre-preparation cancellation races, exact funding/waste, and no cancellation of served courses. |
| M5 diner and helper interactions | Compare real eligible offers and exact prices across views, preserve drafts and committed service on reconnect or renderer failure, and test private tasting history. Generate readiness, staging, yield, controller changes, expiry, and cleaning in varying orders. Check exclusive work, one-time setup credit, ordinary service and payroll, and no licensing proof for staging. |
| Capacity/admission | Compatible FIFO offers, one active entry/draft, expiry/rejoin, dormant reopening, no direct/NPC bypass, and atomic confirmation under contention. |
| Persistence/events/clocks | Disposable PostgreSQL transactions, failure injection, fencing, uncertain append responses, genesis/snapshot-tail comparison, historical fixtures, projection rebuild. |
| Transport/credentials | Cross-origin/CSRF attempts, cookie/session/refresh revocation, queued private delivery after capability loss, protected native credential storage, and denied native IPC/navigation. |
| Frontend state/forms/network | Focused unit/component/browser checks, validation, keyboard alternatives, live-update continuity, reconnect and uncertain-command handling. |
| Responsive workspace/onboarding | Core role flows at 320/390/768/1280/1920 CSS px and wider reference displays; portrait/landscape, zoom, touch, virtual keyboard/IME, browser Back, inspector/detail continuity, phone suspension/resume, and no duplicated submissions/subscriptions. Readiness/hints use real rules and cannot create assets, unlocks, or a tutorial gate. |
| Cuisine-map selection | Equal-area reference fixtures, all cuisine footprints/IDs, proportional resizing and hit alignment, small/overlapping regions, Eastern Thrace selecting/highlighting Turkish only, synchronized keyboard/screen-reader list, both locales, packaged assets, and failure fallback; preview has no economic effects. |
| English/Japanese text and layout | Catalog keys/typed placeholders, terminology and unit checks, both-locale workflows, viewport/zoom checks, glyphs, IME and character/storage boundaries. |
| Packaging/deployment | Relevant browser/native flows, install/launch/connection checks, font/runtime coverage and recovery/compatibility evidence from the exact built revision. |
| Observability | Boundary coverage, asynchronous correlation, redaction, post-restart search, and bounded telemetry-failure behavior under the [qualification contract](#observability-qualification). |
| Documentation/artwork | Links/anchors, file validity, SVG/PNG dimensions and visual inspection as appropriate. |

Do not add tests that merely duplicate implementation expressions. An independent
oracle should fail when the protected behavior is removed, not reproduce the same
mistake. Add tests proportional to behavioral risk; avoid testing reversible prose
or cosmetic edits through a game suite.

## Properties, replay, and mutation

Use explicit clocks, deterministic seeds/IDs, versioned content, and bounded
case/action/shrink/time budgets. Include meaningful accepted transitions and
completed lifecycle states so an all-rejected trace cannot pass. Preserve failing
seeds, minimized traces, content hashes, and the independent assertion.

Conservation covers declared sources/sinks: grants, wholesale replenishment,
simulated spending, allowances, payroll, spoilage, and salvage. Test resource
release after cancellation, closure, handover, distress, refit, and bankruptcy.
Compare canonical live, genesis, and snapshot-tail state at the same committed
batch. Recovery reconciliation is a new transition; compare again at its new
position instead of expecting old sockets/helper control to survive unchanged.

Run a smaller sampled property set through real PostgreSQL adapters with restarts
and injected failures. Cover original immutable receipts versus later settlement,
source-lotted guest funds, multiple courses in one visit, full-bill substitutions,
identity admission races, the 03:00/05:00 cutoff, and cross-clock deadlines. The
[architecture's early qualification plan](ARCHITECTURE.md#early-qualification-and-ongoing-tests)
defines the capacity/recovery proof and retained-history measurements.

Include midnight budgets versus 03:00 reports, initialization's partial report,
invitation activity becoming eligible/ineligible inside an advance, and earning
thresholds tied with closure. Exercise repeated recovery with a stable recovery
identity and newer fencing epochs, fresh NPC presence after restart, and a
migration requiring the old writer to stop. Curated mutations bypass confirmed
terms, allow post-preparation voluntary cancellation, skip a waiting-list entry,
retroactively accrue invitation time, reuse old presence, or deliver a queued
private payload after revocation; each needs a named failing assertion.

Dietary properties generate resolved ingredient bills, hidden animal-derived
components, substitute/yield conversions, missing metadata, profile intersections,
and carbohydrate quantities just below/at/above each limit. Check deterministic
incompatibility even at extreme price/prestige, one profile per existing arrival,
and exact per-visit served/reserved totals across courses, cancellation, locale,
reconnect, and content changes. Exercise both simulated choice and guest quotes
through the application boundary. Mutations bypass the filter, trust a client
badge, ignore sauce/side ingredients, round carbohydrate downward, reset the
ceiling for dessert, or reclassify an accepted course using new content; require
the independent behavioral assertion to fail.

Mutation cohorts start with one worker in an isolated copy or hosted job. Pass
the unchanged baseline, retain exact patches and selected tests, observe a real
behavioral assertion, then restore and recheck the baseline. Report killed,
survived, untested, invalid/compile failure, timeout, and harness/setup failure
separately. Replay valid survivors against the broader applicable scope before
classifying a selection miss or missing assertion; an unproven equivalent claim
is not a pass. Include semantic faults as well as generated arithmetic/Boolean
mutations. The [game-design mutation policy](GAME_DESIGN.md#mutation-testing)
specifies required evidence and budgets.

Drink/tray traces cover every launch drink recipe and all four optional-item
combinations. Contend for a shared ingredient used by both main and drink;
reject combined over-budget, over-capacity, or over-carbohydrate requests without
partial reservations. Vary component completion order, ready-food expiry,
counter control, cancellation after only one preparation starts, 03:00 cutoffs,
recovery, and dessert eligibility after joint service. Mutations admit a late
drink, reset its slot, accept/serve half a tray, count a second meal/helper task,
skip drink work or a shared-stock check, double a debit, or grant a new dietary
allowance. An independent settled-state/accounting assertion must detect each
protected fault. Include paired-tray attachment and contention in load/replay
measurements rather than assuming a main-only workload covers them.

## Observability qualification

Build focused checks for the
[logging contract](ARCHITECTURE.md#observability-and-diagnostic-logging) with
each boundary, using an in-memory diagnostic sink and controlled exporter faults:

- Exercise human, NPC, timer, unattended and admin paths plus authorized/rejected
  queries. Check structured schema, stable reason codes, attempt versus command
  identity, build/rules/clock context, and accepted versus settled outcomes.
  Follow one main/drink/dessert visit and one helper/payroll or licensing flow
  through command, durable batch, asynchronous work, delivery and reconnect.
- Inject pre-append failure and commit-before-acknowledgement loss. Assert no
  premature committed-success record, explicit uncertainty, and same-command
  receipt resolution after restart. Verify operators can join diagnostics to
  durable history without a running original process or full request-body logs.
- Inject sentinel credentials, contact values, invitation links, player text,
  database parameters and malicious exception/URL content. Assert exclusion or
  redaction before both client transmission and server export. Check spoofed
  client context cannot claim trusted identity, versions, or server outcomes.
- Fail or stall serialization/export, exhaust queues, and flood repeated errors.
  Check bounded buffers/timeouts and visible drop/aggregation counters. Compare
  deterministic domain events, receipts, balances and external-delivery intents
  against the same workload with diagnostics disabled; failure must not change
  outcomes, retry economics, block progress, or perform side effects in pure replay.
- In an isolated release environment, verify searchable persisted records across
  a process restart, both web/native build mappings, support-reference lookup,
  operator-access denial, retention expiry, and collector-loss monitoring. Retain
  redacted evidence under the deployment policy; an in-memory sink alone does
  not prove production collection, retention, or access control.

Include bounded property cases for untrusted-field redaction, context propagation
and telemetry-failure noninterference. Curated mutations remove correlation or
redaction, report success before commit, or retry an economic command on exporter
failure; require a named behavioral assertion to detect each fault. Use the
existing local/hosted resource budgets rather than adding an unrestricted suite.

## Release qualification commands

The `release qualification` workflow builds the assembled server container,
runs its explicit migrations, then probes health, protocol and restart against
disposable PostgreSQL. Its optional capacity job runs both peak distributions
and the launch catalog's archive and restore drill.

Run the following from `server/` with matching PostgreSQL utilities on the
path. Use a local PostgreSQL role that can create and drop disposable databases.
The commands write JSON evidence to new paths.

```sh
python3 scripts/peak_sessions.py --scenario owners --output /tmp/feud-owners.json
python3 scripts/peak_sessions.py --scenario expanded --output /tmp/feud-expanded.json
python3 scripts/capacity_bench.py --mode launch --days 1 --restore --output /tmp/feud-capacity.json
```

The HTTP probe provisions 150 occupied stalls, 150 paid helper shifts and 150
funded dining visits through normal commands. Three bursts each use 450 open
HTTP connections, with 30 owner heartbeat commands in the first burst. The
expanded case uses 50 owners with three stalls each and three sessions per
owner. The probe validates the principal and private scope in each response.
It measures burst latency, with the hall at a fixed game instant. The separate
launch benchmark advances the economy at one service-second intervals,
checks contested wholesale, paired trays and dessert service, and compares
genesis and snapshot-tail recovery. Its archive drill verifies the logical
backup against the restored committed head, hall/control state and rebuilt
projections. A one-game-day run gives short-window evidence.

Run `bun run test:browser --grep 'release boundary'` from `app/` to exercise
the protocol, origin protection and a replayed revoked cookie against a
disposable hall. From `app/src-tauri/`, run `cargo fmt --check` and
`cargo test --locked --bin feud-hall` after `bun run desktop:assets` in
`app/`. Keep Cargo to one local build job. The native workflow builds the
macOS bundle, installs both Linux packages, and attempts their launch.
In each packaged client, check Cmd (macOS) or Ctrl (Linux) with `+`/`=`, `-`,
and `0` for whole-page zoom and reset. Check reflow, focused input/draft
continuity, English/Japanese text, and the hall canvas at enlarged zoom; the
camera controls must remain separate from page zoom. Quit/relaunch after zooming
and after resetting to 100%; the next shortcut must start from the restored
level. `bun run test:browser ui-zoom.spec.ts --workers=1` exercises the actual
native initialization script with a mocked zoom bridge: macOS/Linux shortcuts,
real browser-process restarts with a retained storage profile, rapid/delayed
requests, native refusal, invalid/blocked storage, bounds, IME, and wheel/camera
separation. It does not substitute for installed WKWebView/WebKitGTK checks.
Local macOS verification on November 11, 2026 confirmed that 120% zoom
survives an actual app quit/relaunch and that the next Cmd+- returns to 100%.
The native Linux persistence path has not been exercised locally.
Track real installed-client gameplay, native IME and GPU measurements,
live Render evidence, and a representative 30-real-day archive separately.
See the [local Milestone 6 evidence](superpowers/reports/2026-11-10-milestone-6-local.md).

## Hosted CI and release evidence

Build checks alongside each implementation slice; do not defer event/replay or
localization coverage until a final release phase. Planned gates are:

1. Frozen installs and applicable format/lint, definition/catalog validation,
   dependency-direction and command/query ownership checks.
2. `bun check`, qualified Svelte diagnostics, backend checks, focused regression
   suites, bounded property traces, and relevant PostgreSQL/authorization tests.
3. A bounded risk-based mutation cohort for critical changes, with reviewed valid
   survivors. Broader exploration runs separately with explicit budgets.
4. Browser and native verification of affected owner, visitor, helper, reviewer,
   main/drink/dessert, absence/cleaning, and recovery flows in English and Japanese.
   Include narrow/wide layouts and real supported phone browsers, coarse-pointer
   tasks, virtual keyboard/IME, text zoom, suspension/network changes, and novice
   discovery through ordinary screens. Uncoached playtests assess understanding;
   automated checks enforce the contracts, not a claim that ease of use is proven.
5. Release qualification of the specified 150-stall/mixed-session workload,
   backup/restore, historical compatibility, diagnostic collection/retention/access,
   and Linux/macOS packages. Reuse valid evidence for the exact source/artifact
   rather than rerunning unrelated work.

Store source revision, tool/config/lockfile versions, commands and scope, seeds,
failures/survivors, timings, and artifact identifiers with results. Clearly
separate planned, run, passing, failing, and unverified checks. A linter score,
coverage percentage, successful bundle, or screenshot does not alone prove types,
translation quality, economic correctness, or capacity. No fluent Japanese review
is required; localization qualification uses the documented automated checks.

## Management and web checks

Run `mix test test/feud_hall/application/management_test.exs --max-cases 1`
and `mix test test/feud_hall/domain/identity_property_test.exs --max-cases 1`
from `server/` against a disposable test database. The management regression
crosses stall setup, staff-controlled handover, funded wages, eligibility,
reviewer approval and replay. A bounded management property retries a tray choice
before, at, and after its deadline and checks that cleaning leaves one served
tray, one wage settlement, the expected handover credit, and equivalent replay.
The allowance property generates timed command sequences across three principals
and four credentials. An independent model checks daily limits, shared fund and
wallet conservation, receipt reuse and conflicts, and agreement with replay.
The mutation cohort bypasses the daily claim limit and skips midnight
replenishment to check that the property detects both faults.
The stall-allocation property generates direct reservations, waitlist entries,
releases, expiries, and leases across three owners and two location tiers.
It compares the holds and available slots against an independent allocation
model after each step and checks that committed history replays.
The identity property checks cumulative earning against an independent quota oracle.

For progression, run `mix test test/feud_hall/application/progression_test.exs
test/feud_hall/domain/launch_catalog_test.exs --max-cases 1` from `server/`.
These checks exercise all 25 starter, drink, and dessert combinations with
funded purchases and managed kitchen service. They also check a PostgreSQL
catalog upgrade, scoped equipment and prices, expiry and fresh starts across
clock partitions, receipt paging and authorization, award review eligibility,
and NPC retirement and restoration. The mutation cohort includes the
location limit, distress cost freeze, and guest exclusion from awards.

The Māori additions also exercise both unlockable mains and a version-1 to
version-2 launch expansion with a pending order. Check preserved terms and
pools, forward-only versions, PostgreSQL replay and snapshot-tail replay.
The curated `Māori catalog expansion` mutation must fail the same-version
rejection assertion.

The web workflow runs frozen Bun install, Prettier, Oxlint, native `bun check`,
and a Vite production build. It also runs a one-worker Chromium suite for
changes to the web client, server, or branding assets. The suite exercises
dining, helper handover, invitation and cuisine selection, and NPC startup
recovery through the built client, Phoenix, and disposable PostgreSQL databases.
The launch journey also checks all 24 map choices, an equipment purchase, and
leasing a second location. The dining journey reads a served order from the
committed history and checks that an unauthenticated session is refused.
The test harness advances the server's manual clock over stdin. Playwright
controls browser timers separately and can hold back a view or drop a command
reply to test the client while the server keeps its committed outcome.
Alongside the real-server journeys, the generated dining check exercises the
built client against controlled quotes and views. It varies draft edits, lost
eligibility, and the order of successful and refused replies, checking which
confirmation the player sees and which terms the client submits. Keep browser
models focused on observable contracts and use the real-server journeys to
verify compatibility with Phoenix and PostgreSQL. The generated case is bounded
to 12 runs and varies its seed across CI runs. To replay a shrunk failure, pass
the reported seed and path as `FEUD_HALL_BROWSER_SEED` and
`FEUD_HALL_BROWSER_PATH` to the focused `--grep 'generated dining edits'` run.
A second generated browser check varies which license applications are edited,
then changes the queue and verifies that each draft and decision stays with
its own application. Replay it with `--grep 'generated review edits'`.
Run `--grep 'M5 '` for the live 3D hall, WebGL loss and HTML checkout journey,
and the helper staging and yield journey. The Chromium checks use software
rendering. They do not qualify hardware or 150-stall frame rates. The focused
`visitor_play_test.exs` file checks replay, payroll, tasting privacy, and
staging across different readiness boundaries. The curated mutation
`M5 staged setup credit can be reused` checks the one-use invariant.
CI retains failure traces and hall logs. A separate Svelte template type-check
and broader cross-browser coverage remain release qualification work.

`hall-interactions.spec.ts` checks in-hall ordering and committed meal receipts,
helper acceptance/staging/selection, owner stock/menu/opening controls, keyboard
E/Escape and focus return, camera-node continuity, shared drafts, Japanese at
320px, and preserving the actual input node/focus through WebGL fallback.
Run this focused file with one browser worker alongside `visitor-play.spec.ts`,
`phone-layout.spec.ts`, `owner-view.spec.ts`, and `participation.spec.ts` when
changing the shared controls. These use the disposable browser hall, not the
running local game, and do not qualify physical touch/GPU performance.

`participation.spec.ts` exercises a visitor receiving a license during a shift,
owner navigation/history, own-stall purchase exclusion, and competitor dining.
The focused `visitor_play_test.exs`, `management_test.exs`, and
`progression_test.exs` files cover all admission routes, staging/selection
release, exact earned payroll, unchanged state on rejection, expansion stalls,
main and dessert guards, receipt retries, and PostgreSQL/genesis/snapshot-tail
replay. The four curated `participation` mutants remove purchase, helper-role,
promotion-termination, and dessert guards; run just that cohort with
`elixir scripts/mutation_cohort.exs <empty-work-dir> --match participation`.

For a focused local browser run, fetch the locked Mix dependencies from
`server/`. From `app/`, run `bun install --frozen-lockfile`, `bun run playwright
install chromium`, `bun run --bun build`, and `bun run test:browser --grep
'<scenario>'`. Use local PostgreSQL with a role that can create and drop test
databases. Each scenario uses its own loopback port and creates and drops a
`feud_hall_browser_*` database. The runner supplies its own signing key and
starts the test endpoint without the live hall environment file. Respect the
local worker and memory limits above.

`bun run test:browser phone-layout.spec.ts --workers=1` checks the compact
phone layout at 320/390/399 CSS px and the return to the wider layout at 400px.
It covers English/Japanese, bottom navigation, business-section drafts,
composition/focus continuity during reflow, and stall-detail Back/Forward.
The browser dispatches composition events; real mobile keyboards/IME, safe-area
insets and touch/GPU performance still need device qualification.

To regenerate the launch cuisine map after changing its
source footprints, run `bun scripts/build-map.js` from `app/`. The equal-area
view uses D3's Equal Earth projection and [Natural Earth public-domain land
geometry](https://www.naturalearthdata.com/about/terms-of-use/) distributed by
[World Atlas](https://github.com/topojson/world-atlas). The highlighted areas are
approximate cultural locator footprints for the launch catalog.

The focused `app/test/browser/hall-interactions.spec.ts` coverage includes real
ray/UV clicks on the physical menu tablet (allowance, diet, main, compact bill
and confirmation), a lost accepted response retried with the same command ID,
committed service/receipt without changing the scene's document position or height, keyboard stepping back, Japanese portrait rendering
and WebGL fallback. It also checks helper and owner workbenches. Run this file
with one worker against the disposable browser-hall fixture; inspect its tablet
screenshots as well as the assertions. The accessible text mirror is inspected
for action metadata, but purchase actions in the tablet journey use canvas clicks.

`app/test/browser/tablet-text.spec.ts` checks all shipped English/Japanese dish
labels with real canvas font metrics and several prices. It requires complete
prices, English word boundaries, no clipped text, and at most two readable lines
per tablet row, including a regression where only part of a price used to fit.
It also checks English/Japanese error messages after splitting them into rows.
The focused `confirmation errors` hall-interaction test refuses confirmation
and checks immediate whole-word red explanations, Japanese rendering and
repeated identical failures. Refusals and uncertain outcomes must not add a
page-top banner or move the 3D scene while their tablet is visible; ordinary
refusal notifications remain dismissible on the conventional screens. The dining journey checks that the compact review
contains ordered items and prices without ingredient rows, while the original
bound quote is still confirmed. Completed visits immediately restore a clean
menu and allow another quote without advancing time, while the receipt remains
in dining history. `tablet-pages.spec.ts` exercises the renderer
directly with a long view: new errors open their page, routine updates allow
browsing elsewhere, and repeated errors become visible again.

`app/test/browser/hall-layout.spec.ts` checks corner-first/largest-gap placement,
the sixteen-stall island threshold, eight-stall cap, balanced splitting, stable logical identities, inward/outward
headings, room bounds, and independent world-space booth separation at every
size through 150. A bounded seeded property checks vacancies and coordinate
transforms. Browser artifacts cover a populated outer ring, multiple compact islands, a tablet that stays pickable when its stall changes island and heading, and 150-stall rendering; these are presentation checks, not a simulation
capacity benchmark. Run with one worker alongside focused hall-interaction and
owner-view tests when changing stall orientation or placement.

`app/test/browser/hall-navigation.spec.ts` checks clear walking entrances and
open-stall preference through 150 stalls, including closed/empty fallback. Its
browser probe inspects the actual WebGL view matrix for arrow/Shift entry,
eye height, level heading, continued movement and restoration after navigation.

`tray-pickup.spec.ts` checks private served-course eligibility and deduplication,
real ray clicks on a served tray, reaching/taking animation, reduced-motion F-key
collection, and absence after scene remount. It verifies that collection changes
neither the committed position nor dining balance and sends no gameplay command.
It also checks real canvas clicks on counter surfaces, signage and another diner's
public tray in the immersive layout: these select the stall without opening the
tablet, while a click on its actual screen opens it.
Run this focused file with one worker against the disposable browser hall and
inspect its pickup screenshot.
