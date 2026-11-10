# Feud Hall Testing

Status: verification plan with the first backend slice implemented. The Elixir
economic core in `server/` has a Mix manifest, lockfile, pinned toolchain, and a
hosted CI workflow (`.github/workflows/server.yml`); its verified entry points
are listed under [Implemented backend entry points](#implemented-backend-entry-points).
Frontend commands below remain planned interfaces, not claims of installed
tooling or passing checks.

The [game design](GAME_DESIGN.md#required-correctness-scenarios) owns gameplay
acceptance scenarios; [architecture](ARCHITECTURE.md#architecture-verification)
owns implementation invariants. This document owns how to select, run, and report
checks. Release execution belongs in [Deployment](DEPLOYMENT.md).

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
| Browser/component tests | Bun-invoked scripts | Pin the browser/component harness when added; use actual browser/webview checks for interaction, IME, and rendering. |
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
| Curated mutation cohort | `elixir scripts/mutation_cohort.exs <empty-dir>`; `elixir scripts/mutation_cohort.exs --check` | 43 patches (27 for the economic core and storage, 16 `B*` for the shared simulation). Copies the project into `<empty-dir>`, never edits the checkout, and runs mutants with `MIX_ENV=test` against `feud_hall_mutation`; one worker, focused files per mutant, baseline verified before and after, each patched file restored even on an exception. `--check` only verifies every source string still matches exactly once and runs nothing; run it after changing source a patch touches. Hosted CI job; about 2 minutes locally at roughly 0.5 GB peak combined RSS. |
| Projection rebuild (maintenance) | `PostgresEventStore.rebuild_projections/1`, `Postgres.DailyActivityProjector.rebuild/1` | Recompute derived tables from the log. Not a Mix task and exercised by tests only; never point it at a live hall without an operations procedure. |

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
| Main/drink trays | All twenty drink recipes, initial-only add-on, combined stock/funding/carbohydrate feasibility, one queue/helper handover, atomic paired acceptance/service/cancellation, component waste, freshness/cleaning cutoff, and all four main/drink/dessert combinations. |
| Commands, permissions, resource lifetime | Wrapped use-case tests, retries/conflicts, current authorization, settled-state resource oracle, deferred settlement. |
| Dining acceptance/cancellation | Confirmed-term mismatches, revised command IDs, one active visit with atomic main admission, pre-preparation cancellation races, exact funding/waste, and no cancellation of served courses. |
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

Drink/tray traces cover all twenty recipes and all four optional-item
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
