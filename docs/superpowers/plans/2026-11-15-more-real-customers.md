# More Real Customers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the hall more real customers, with supply to serve them, by measuring the simulation and tuning arrivals, wholesale stock and computer-run restocking together until an agreed feel is reached; then record the chosen values as a rule change that an operator applies deliberately.

**Architecture:** The values that may be tuned become data: the computer-run planner's literals move into `catalog.rules.npc` with today's values as the default. A new recorded event, `hall_rules_retuned`, replaces only those tunable values in a managed hall's catalog and takes effect at the next midnight, where the day's arrival quotas and market replenishment are already recorded per day. A bounded driver script runs a real hall authority on an in-memory store with a manual clock and prints the acceptance measurements; the tuning task uses it to choose the values. Nothing applies the change at boot: an operator endpoint does it on request.

**Tech Stack:** Elixir / Phoenix, event-sourced domain under `server/lib/feud_hall/domain`, StreamData property tests, ExUnit. No client change.

**Spec:** [docs/superpowers/specs/2026-11-13-livelier-hall-design.md](../specs/2026-11-13-livelier-hall-design.md), section "Project 4: More real customers", plus its Goals, Non-goals, Anti-goals and "Existing contracts" sections. Read those and [AGENTS.md](../../../AGENTS.md) before starting any task.

## Global Constraints

- **Success is served meals.** More arrivals that mostly walk away is the failure the spec names. Where the queue targets and the served share pull against each other, served share wins.
- **Allowed knobs, and no others:** `rules.demand.arrivals_per_equivalent`; the shape of `rules.demand.hourly_weights`; `rules.market.target_stock_per_equivalent` and `rules.market.replenish_cap`; the computer-run planner's fallback and expected-use heuristic; computer-run starter shifts.
- **Not to be changed:** kitchen stations, the queue limit, handover and recipe times; segment budgets and patience; prices, rents, wages and exposure factors; `storage_capacity` (300,000); `equivalent_floor_millis`; anything in the spec's non-goals. If a target cannot be met with the allowed knobs, report the closest result and the binding constraint.
- `hourly_weights` keeps 24 non-negative integers with hours 3 and 4 (03:00–05:00 cleaning) at 0.
- The finite-pool rule is unchanged: the arrival pool does not grow because stalls, menu rows or devices are added, and every arrival is accounted for exactly once.
- An existing hall's rules change only through a recorded event. Events before the change replay under the old values. Live, genesis-replay and snapshot-tail state agree at the same committed position across the change.
- Accepted orders, leases, drafts and other pinned terms keep the terms they were accepted under.
- The recorded change is built and tested but is **not** applied automatically: not at boot, not on recovery, not by a migration. `LaunchCatalog.catalog/0` keeps today's values, so a new hall also starts on them.
- The domain stays pure: `decide` and `evolve` take no clock, no I/O and no global configuration. The planner draws no randomness and uses integer arithmetic only.
- Anything that rides in an event must pass the event codec: new atoms are allowlisted in `FeudHall.Infrastructure.EventCodec`, and no tuples are stored (use lists or maps).
- The driver never injects stock, cash, orders or state. It acts only through the commands a human owner or the operator has.
- Never run `mix test` without a file name; run test files one at a time. Server commands run from `server/`. Keep the driver and tests under 2 GiB RSS and run nothing heavy in parallel. Check `df -m /System/Volumes/Data | tail -1` before a long run and stop under 1000 MB free.
- Never start a server against the databases `feud_hall_management` or `feud_hall_trial_rooms`. Do not push.
- Format with `mix format`. Commit messages end, after a blank line, with the Co-Authored-By line for the model that wrote the commit.

## Review Focus

Each line names a condition the spec implies and the behaviour a person would expect. The test that pins it is in the task named.

1. **The change lands in the middle of a game day.** Today's arrivals follow the quotas already recorded for today; the new values start at the next midnight; no arrival is lost or counted twice at that boundary and the fractional remainder carries. (Task 2)
2. **The change is applied twice, or an older version arrives after a newer one, or the same command ID is retried with a different payload.** The hall keeps the newer rules; the retry returns the original receipt; nothing is recorded twice. (Tasks 2 and 5)
3. **A hall that cannot take it** (a slice hall, a hall recorded before demand rules, a hall not yet initialised). The command is refused with a named reason and nothing is recorded. (Task 2)
4. **A malformed tuning** (23 hourly weights, a weight in a cleaning hour, a negative number, an unknown product, a key outside the allowed knobs). Refused as invalid content, nothing recorded. (Task 2)
5. **Market stock above a lowered target, and a computer-run restaurant created before the change.** Stock is never destroyed (replenishment adds zero); the restaurant keeps trading and its planner reaches the new shifts through ordinary commands, not a state rewrite. (Tasks 2 and 4)

---

## File Structure

New:
- `server/lib/feud_hall/domain/hall/retune.ex` — decides and evolves the recorded rule change.
- `server/lib/feud_hall/domain/content/tuning.ex` — the tunable values as data: read from a catalog, written onto a catalog, and (from Task 4) the chosen values.
- `server/scripts/customer_sim.exs` — the bounded simulation driver.
- `server/test/feud_hall/domain/retune_test.exs`, `server/test/feud_hall/domain/tuning_test.exs`, `server/test/feud_hall/application/retune_test.exs`, `server/test/feud_hall/scripts/customer_sim_test.exs`.
- `docs/superpowers/reports/2026-11-15-more-real-customers.md`.

Modified: `server/lib/feud_hall/domain/npc/planner.ex`, `domain/content.ex`, `domain/hall/decider.ex`, `domain/hall/evolver.ex`, `application/command_workflow.ex`, `infrastructure/event_codec.ex`, `infrastructure/postgres_event_store.ex` (only if it lists event types that carry a catalog), `web/router.ex`, the tests named in each task, `docs/GAME_DESIGN.md`, `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, `docs/TESTING.md`.

A **tuning** is this map, and nothing else:

```elixir
%{
  version: pos_integer,                      # 1 is today's values; the chosen values are 2
  demand: %{arrivals_per_equivalent: non_neg_integer, hourly_weights: [non_neg_integer]},  # 24 entries
  market: %{target_stock_per_equivalent: %{product_id => non_neg_integer},
            replenish_cap: %{product_id => non_neg_integer}},
  npc: %{fallback_trays_per_day: pos_integer,
         expected_use: String.t(),           # a heuristic name the planner knows; "even_share" is today's
         starter_shifts: %{profile_id => [start_hour, end_hour]}}
}
```

---

### Task 1: The planner's tunable values come from the catalog

**Files:**
- Create: `server/lib/feud_hall/domain/content/tuning.ex`, `server/test/feud_hall/domain/tuning_test.exs`
- Modify: `server/lib/feud_hall/domain/npc/planner.ex`, `server/lib/feud_hall/domain/content.ex`
- Test: `server/test/feud_hall/domain/npc_planner_test.exs`, `server/test/feud_hall/domain/launch_catalog_test.exs`

**Interfaces:**
- Produces `FeudHall.Domain.Content.Tuning`:
  - `npc_defaults() :: %{fallback_trays_per_day: 10, expected_use: "even_share", starter_shifts: %{"budget" => [5, 17], "mainstream" => [12, 0], "premium" => [19, 7]}}`
  - `npc(catalog) :: map` — `catalog.rules.npc` when present, otherwise `npc_defaults()`.
  - `of(catalog) :: tuning` — the tuning a catalog currently has: `version` from `catalog.rules[:tuning][:version]` or 1; `demand` and `market` values copied from the catalog's rules; `npc` from `npc/1`.
  - `put(catalog, tuning) :: catalog` — the catalog with the tuning's demand, market and npc values written into `rules` and `rules.tuning` set to `%{version: tuning.version}`. Every other key of `rules.demand` and `rules.market` is kept.
  - `validate(catalog, tuning) :: :ok | {:error, [problem]}` — the map has exactly the keys shown under File Structure; 24 hourly weights, all non-negative integers, hours 3 and 4 zero, at least one positive; `arrivals_per_equivalent` a non-negative integer; the market maps have exactly the catalog's product IDs as keys with non-negative integer values; `fallback_trays_per_day` a positive integer; `expected_use` one of `Planner.expected_use_heuristics/0`; `starter_shifts` has exactly the catalog's `npc_profiles` IDs, each `[start, end]` with both in 0..23.
- Produces `Planner.expected_use_heuristics() :: ["even_share"]`.
- `Planner.plan/5` reads `Tuning.npc(catalog)` instead of `@fallback_trays_per_day` and `@starter_shifts`. Behaviour with a catalog that has no `rules.npc` is exactly today's.
- `Content.validate/1` accepts a catalog with or without `rules.npc` and `rules.tuning`; when `rules.npc` is present it must satisfy the npc part of `Tuning.validate/2`.

- [ ] **Step 1: Write the failing tests.**

```elixir
# tuning_test.exs
test "a launch catalog's tuning is version 1 with today's values" do
  catalog = LaunchCatalog.catalog()
  tuning = Tuning.of(catalog)
  assert tuning.version == 1
  assert tuning.demand == Map.take(catalog.rules.demand, [:arrivals_per_equivalent, :hourly_weights])
  assert tuning.market == Map.take(catalog.rules.market, [:target_stock_per_equivalent, :replenish_cap])
  assert tuning.npc == Tuning.npc_defaults()
  assert Tuning.validate(catalog, tuning) == :ok
end

test "put then of returns the tuning, and put changes nothing else" do
  catalog = LaunchCatalog.catalog()
  tuning = Tuning.of(catalog) |> Map.put(:version, 2) |> put_in([:demand, :arrivals_per_equivalent], 180)
  changed = Tuning.put(catalog, tuning)
  assert Tuning.of(changed) == tuning
  assert Map.delete(changed, :rules) == Map.delete(catalog, :rules)
  assert Map.drop(changed.rules, [:demand, :market, :npc, :tuning]) == Map.drop(catalog.rules, [:demand, :market, :npc, :tuning])
  assert Map.drop(changed.rules.demand, [:arrivals_per_equivalent, :hourly_weights]) ==
           Map.drop(catalog.rules.demand, [:arrivals_per_equivalent, :hourly_weights])
  assert Content.validate(changed) == :ok
end
```

One `validate/2` test per refusal, each asserting `{:error, _}`: 23 weights; hour 3 non-zero; a negative weight; all weights zero; a negative `arrivals_per_equivalent`; a product missing from `target_stock_per_equivalent`; an unknown product in `replenish_cap`; `fallback_trays_per_day: 0`; `expected_use: "nonsense"`; a starter shift for an unknown profile; a shift hour of 24; an extra top-level key; a tuple shift `{5, 17}`.

In `npc_planner_test.exs`: an existing plan scenario run with `Tuning.put(catalog, Tuning.of(catalog))` gives exactly the same actions as with the untouched catalog; with `fallback_trays_per_day: 30` and no day summary, each purchase quantity is what the planner's formula gives for 30 trays (compute the expectation in the test from the recipe lines, not by calling the planner); with `starter_shifts` `"budget" => [6, 18]`, the budget profile's plan contains `{:set_staff_schedule, %{start_hour: 6, end_hour: 18, ...}}`.

- [ ] **Step 2: Run** `mix test test/feud_hall/domain/tuning_test.exs` then `mix test test/feud_hall/domain/npc_planner_test.exs` — Expected: FAIL (module and options missing).
- [ ] **Step 3: Implement.** Remove the two module attributes from the planner. Do not add `rules.npc` to `LaunchCatalog.catalog/0` or `SliceCatalog`: absent means defaults, so no existing catalog hash changes (assert in `launch_catalog_test.exs` that `Content.hash(LaunchCatalog.catalog())` is unchanged by this task: record the value before your change and pin it).
- [ ] **Step 4: Run**, one at a time: the two files above, `test/feud_hall/domain/launch_catalog_test.exs`, `test/feud_hall/domain/slice_catalog_test.exs`, `test/feud_hall/domain/npc_plan_test.exs`, `test/feud_hall/domain/npc_actor_test.exs`; then `mix format --check-formatted`. Expected: PASS.
- [ ] **Step 5: Commit** — `Read the computer-run planner's tuning from the catalog`

---

### Task 2: The recorded rule change

**Files:**
- Create: `server/lib/feud_hall/domain/hall/retune.ex`, `server/test/feud_hall/domain/retune_test.exs`, `server/test/feud_hall/application/retune_test.exs`
- Modify: `server/lib/feud_hall/domain/hall/decider.ex`, `domain/hall/evolver.ex`, `application/command_workflow.ex`, `infrastructure/event_codec.ex`, and `infrastructure/postgres_event_store.ex` if its list of catalog-carrying event types needs the new type

**Interfaces:**
- Consumes: Task 1's `Tuning.of/1`, `Tuning.put/2`, `Tuning.validate/2`.
- Produces: command `{:retune_rules, %{tuning: tuning}}`, accepted only from actor `{:system, :admin}`, in the same place and style as `{:expand_catalog, _}`.
- Produces: event `%{type: :hall_rules_retuned, tuning: tuning, content_hash: hash}` where `hash` is `Content.hash/1` of the catalog after the change.
- Produces: `Retune.decide(state, tuning) :: {:ok, [event]} | {:error, reason}` and `Retune.evolve(state, event) :: state`.
- Refusals: `:retune_unavailable` when the hall's catalog is not `id: "launch"`, or has no demand rules, or `tuning.version <= Tuning.of(state.catalog).version`; `{:invalid_content, problems}` when `Tuning.validate/2` or `Content.validate/1` of the resulting catalog fails.
- `evolve` sets `state.catalog` to `Tuning.put(state.catalog, event.tuning)` and `state.content_hash` to the event's hash, and changes nothing else: not `demand.hour_quotas_millis`, not `demand.supply_scale_millis`, not `market.stock`, not any restaurant, lease, order or NPC record.

- [ ] **Step 1: Write the failing tests.**

`domain/retune_test.exs` (build hall states the way `server/test/feud_hall/domain/rooms_test.exs` and `demand_forecast_test.exs` do):

```elixir
test "a retune replaces the tunable values and nothing else" do
  state = launch_hall()
  tuning = doubled(state.catalog)                 # version 2, arrivals_per_equivalent 180, every market target and cap doubled
  assert {:ok, [event]} = Retune.decide(state, tuning)
  assert event.type == :hall_rules_retuned and event.tuning == tuning
  after_state = Retune.evolve(state, event)
  assert Tuning.of(after_state.catalog) == tuning
  assert after_state.content_hash == Content.hash(after_state.catalog) and after_state.content_hash != state.content_hash
  assert Map.drop(after_state, [:catalog, :content_hash]) == Map.drop(state, [:catalog, :content_hash])
end

test "today keeps its recorded quotas; the next midnight uses the new values" do
  # Advance a launch hall to 14:00 on day 0, retune, advance to 00:00.
  # Arrivals counted for day 0 equal the sum of day 0's recorded hour quotas (within the carried remainder, exactly as without the retune).
  # The day_closed event at that midnight has hour_quotas_millis == Demand.hour_quotas(new_rules, scale).
  # Its replenishment for a product whose stock is below the new target is positive and equals min(new target, new cap) - stock.
end

test "stock above a lowered target is kept" do
  # Retune a product's target and cap to 0 with stock 500: the next day_closed replenishment for it is 0 and market.stock stays 500.
end
```

Refusals, each asserting the exact reason and that `decide` returns no events: a slice hall; a hall whose catalog has no demand rules; `version: 1`; a second retune with the same version after the first is applied; a newer version (3) applied and then version 2; each malformed tuning from Review Focus 4.

`application/retune_test.exs` (follow `server/test/feud_hall/application/rooms_test.exs` and `recovery_test.exs` for the store, the workflow and the replay helpers):

```elixir
test "live, genesis replay and snapshot-tail replay agree across a retune" do
  # Initialise a managed launch hall, run half a day, execute retune_rules as {:system, :admin} with command ID "retune:2",
  # run past two midnights with arrivals and at least one computer-run plan.
  # Compare state from: the live runtime; a replay from genesis; a snapshot taken before the retune plus tail;
  # a snapshot taken at the head (empty tail). All four are equal.
end

test "a retried command returns the original receipt; a different payload under the same ID is refused" do
  # Same ID, same tuning: accepted once, the retry returns the same receipt and the event count does not change.
  # Same ID, a different tuning: the workflow's existing fingerprint refusal, and the hall's tuning is unchanged.
end

test "only the system admin may retune" do
  # A principal, an owner and an NPC actor are each refused; nothing is recorded.
end

test "the event survives the codec" do
  # EventCodec round-trip of a hall_rules_retuned event with the full launch product map; decode in the shape the store returns.
end

test "an accepted order placed before the retune settles on its accepted terms" do
  # Accept a main before the retune, retune, serve it: bill, recipe version and funding slices equal those recorded at acceptance.
end
```

- [ ] **Step 2: Run** each new file — Expected: FAIL (unknown command).
- [ ] **Step 3: Implement.** Mirror how `expand_catalog` and `hall_catalog_expanded` are wired through the decider, the evolver, the workflow's command list and the codec's allowlists. The event carries the tuning, not a whole catalog. Document in the `Retune` moduledoc when the values take effect (the next `day_closed`) and why (quotas and replenishment are recorded per day).
- [ ] **Step 4: Run**, one at a time: the two new files, `test/feud_hall/application/recovery_test.exs`, `test/feud_hall/application/command_workflow_test.exs`, `test/feud_hall/infrastructure/event_fixtures_test.exs`, `test/feud_hall/domain/arrivals_test.exs`, `test/feud_hall/domain/demand_forecast_test.exs`, `test/feud_hall/domain/invariants_test.exs`; then `mix format --check-formatted`. Expected: PASS. Then show sensitivity: make `evolve` also overwrite `demand.hour_quotas_millis` with the new values, confirm "today keeps its recorded quotas" fails, and restore. Report the result.
- [ ] **Step 5: Commit** — `Record a rule change that retunes arrivals, market stock and planner values`

---

### Task 3: The simulation driver

**Files:**
- Create: `server/scripts/customer_sim.exs`, `server/test/feud_hall/scripts/customer_sim_test.exs`
- Modify: `docs/TESTING.md` (how to run it)

**Interfaces:**
- Consumes: Task 1's `Tuning`; Task 2's `retune_rules` command.
- Produces the command line, run from `server/`:
  `mix run --no-start scripts/customer_sim.exs -- --run a|b --tuning current|chosen|PATH --days N --seed S [--via init|retune] [--set KEY=VALUE ...] [--json PATH]`
  - `--run a`: the three computer-run restaurants plus the reference stall. `--run b`: the three computer-run restaurants alone.
  - `--tuning current`: `Tuning.of(LaunchCatalog.catalog())`. `--tuning chosen`: `Tuning.chosen/0` (added in Task 4; until then the script says it is not defined and exits non-zero). `PATH`: an Elixir term file holding a tuning.
  - `--days N`: N measured game days after one warm-up day. Default 3, maximum 14.
  - `--via init` (default): the hall is initialised with `Tuning.put(LaunchCatalog.catalog(), tuning)`. `--via retune`: the hall is initialised with the launch catalog and the tuning is applied with `retune_rules` during the warm-up day, so it is in force from the first measured midnight.
  - `--set KEY=VALUE`: overrides one value of the tuning for sensitivity runs, for example `--set demand.arrivals_per_equivalent=90`.
- Produces modules defined in the script file: `FeudHall.CustomerSim.Stats` (pure accumulation and the acceptance verdict), `FeudHall.CustomerSim.Hall` (starts the authority and plays the reference owner), `FeudHall.CustomerSim.CLI`. The script runs `CLI.main(System.argv())` only when `CUSTOMER_SIM_NO_MAIN` is unset, so the test can `Code.require_file/2` it.
- Produces `Stats.verdict(run, stats) :: [%{check: String.t(), value: number, low: number | nil, high: number | nil, pass: boolean}]` with these checks, using the spec's numbers:
  - Run A, reference stall, hours 12 and 19: time-averaged orders waiting in 2.5..4.5; counter busy share >= 0.85.
  - Run A, reference stall, hours 9–10 and 14–16: time-averaged orders waiting in 0.5..2.
  - Run A, whole hall, hours 0–2: time-averaged orders waiting per stall <= 0.3.
  - Run A: the reference stall never had an ingredient its menu needs at zero while open (count of sampled instants, must be 0).
  - Run B: of diners who left without ordering, the share that left for `nothing_available` <= 0.25.
  - Run B: mains served on day 0 > 0.
  - Both: served share = mains served / arrivals over the measured days (reported; the comparison with the baseline is made in Task 4).

**How it runs:**
- A `FeudHall.Infrastructure.HallAuthority` on `InMemoryEventStore` with a manual clock and `tick_ms: :manual`, initialised as a managed launch hall with the given seed, ticked once per 1,000 service milliseconds (the live cadence), as `scripts/peak_sessions.exs` drives its hall.
- The reference owner (run A) is a real principal who becomes an owner the way a seeded owner does, then uses ordinary owner commands only: lease a **standard** spot in room 1, create a default restaurant with its cuisine's starter main at the suggested price, keep the three starter staff, set the staff schedule to 09:00–21:00, open, and set a restock policy generous enough that the stall would not run out if the market can supply it. Whatever keeps an owner's stall trading while they are away (presence reports or the unattended policy) is used as a player would. No stock, cash or order is injected.
- **Orders waiting** is the value the hall view reports as `activity.waiting` for the stall. **Counter busy** is `activity.cooking > 0 or activity.handover` in the same view. Both are sampled once per tick through the same function the view uses; if that function is private, expose the smallest pure function from `FeudHall.Application.Management` rather than re-deriving the count in the script, and test that the view and the function agree.
- Per hall hour of each measured day it prints: arrivals, admitted, mains served, departures by reason, average orders waiting and counter-busy share per stall; and per game day: profit for the reference stall and each computer-run restaurant (cash at the end of the day minus cash at its start, with rent, wages and purchases as they were charged), and market stock-outs (products at zero). Then the verdict table.
- With `--json PATH` the same numbers are written as JSON, with the tuning, the seed, the run and the git commit.
- Deterministic: the same arguments give byte-identical JSON.
- Bounded: it refuses `--days` above 14, prints progress once per game day, and exits non-zero on any refused command it issued, any `:npc_planner_failed` diagnostic, or a hall that never served a meal.

- [ ] **Step 1: Write the failing tests** in `customer_sim_test.exs` (tag the two that run a hall `@tag timeout: 180_000`):

```elixir
test "Stats averages waiting over time and counts busy share" do
  # 4 samples in hour 12 with waiting [2, 4, 4, 2] and busy [true, true, false, true]: average 3.0, busy share 0.75.
end

test "the verdict applies the spec's bounds" do
  # A stats fixture with reference-stall hour-12 average 2.4 fails that check and reports low 2.5, high 4.5;
  # 2.5 passes; 4.5 passes; 4.6 fails. Counter busy 0.85 passes, 0.849 fails. nothing_available share 0.25 passes, 0.26 fails.
end

test "a run is deterministic and acts only through commands" do
  # Run B for 0 measured days (warm-up only) twice with one seed: identical JSON.
  # Every event in the store has a command receipt (no state was injected): event count equals the sum of the receipts' batch sizes.
end

test "run A's reference stall is a standard spot in room 1, open 09:00 to 21:00, with three staff" do
  # After the warm-up day: the lease's tier, room, schedule and staff count; its menu is one starter main at the suggested price.
end

test "the view's waiting and the sampled waiting agree" do
  # At 20 instants of a short run, Management.view's activity.waiting for each stall equals the sampled value.
end

test "--via retune reaches the same rules as --via init by the first measured midnight" do
  # The two halls' Tuning.of(state.catalog) are equal, and the first measured day's hour quotas are equal.
end
```

- [ ] **Step 2: Run** `mix test test/feud_hall/scripts/customer_sim_test.exs` — Expected: FAIL (file missing).
- [ ] **Step 3: Implement.** Read `scripts/peak_sessions.exs` and `test/support` for how a hall is started, an owner admitted and commands issued.
- [ ] **Step 4: Run** the test file; then `mix run --no-start scripts/customer_sim.exs -- --run b --tuning current --days 1 --seed 20261109` and paste the output into your report, with its wall-clock time and peak RSS (`/usr/bin/time -l`). Then `mix format --check-formatted`. Expected: PASS, a completed run, RSS under 2 GiB.
- [ ] **Step 5: Commit** — `Add a bounded driver that measures customers at sparse-hall settings`

---

### Task 4: Choose the values

**Files:**
- Modify: `server/lib/feud_hall/domain/content/tuning.ex` (add `chosen/0`), `server/lib/feud_hall/domain/npc/planner.ex` (only if a new expected-use heuristic is needed), `server/test/feud_hall/domain/tuning_test.exs`, `server/test/feud_hall/domain/npc_planner_test.exs`
- Create: `server/test/feud_hall/scripts/customer_acceptance_test.exs`, `docs/superpowers/reports/2026-11-15-more-real-customers.md` (measurements and tuning log; Task 6 completes it)

**Interfaces:**
- Consumes: Task 3's driver and `Stats.verdict/2`; Task 1's planner options.
- Produces: `Tuning.chosen() :: tuning` with `version: 2`, valid for `LaunchCatalog.catalog()`.
- May produce: one more name in `Planner.expected_use_heuristics/0`, with its formula documented in the planner's moduledoc and unit-tested with an expectation computed independently in the test.

**Method:**
1. Baseline: runs A and B with `--tuning current --days 3 --seed 20261109`. Record every table.
2. Tune in this order, because the spec says supply binds first: (a) wholesale targets and caps until run B's `nothing_available` share and the reference stall's stock-outs are not the limit; (b) the planner's fallback, expected-use heuristic and starter shifts until the computer-run restaurants serve on day 0 and do not starve their own queues; (c) `arrivals_per_equivalent` and the shape of `hourly_weights` until the queue targets are met. Re-check (a) and (b) after (c).
3. Budget: at most 30 driver runs in total. Log every run in the report: the tuning (as a diff from the previous run), the reason for the change, and the verdict rows. Never run two at once.
4. Final: runs A and B with `--tuning chosen --days 3` on seeds 20261109 and 7, by `--via init`, and run A once by `--via retune`.
5. Sensitivity: with the chosen tuning, revert `demand.arrivals_per_equivalent` to 90 (`--set`) and show the reference stall's rush-hour waiting moves out of its range; revert the market targets to today's and show run B's `nothing_available` share moves.
6. Served share: for each run, chosen versus current, same seed. It must be higher under the chosen values.

If the checks cannot all be met within the allowed knobs and the run budget, stop tuning, keep the closest values as `chosen/0`, and state in the report which check fails, by how much, and what binds. Do not touch a value outside the allowed knobs.

- [ ] **Step 1:** Run the baseline and write the report's "Before" section.
- [ ] **Step 2:** Tune as described, logging each run.
- [ ] **Step 3: Write the tests.** In `tuning_test.exs`: `Tuning.chosen()` has version 2 and `Tuning.validate(LaunchCatalog.catalog(), Tuning.chosen()) == :ok`; hours 3 and 4 are 0; every market cap is at least its target; `Content.validate(Tuning.put(LaunchCatalog.catalog(), Tuning.chosen())) == :ok`. In `customer_acceptance_test.exs`, tagged `@moduletag :acceptance` and excluded from default runs (add the exclusion to `test/test_helper.exs` in the way other excluded tags are handled, or with `ExUnit.configure(exclude: [:acceptance])` if there are none), with a 20-minute timeout: runs A and B at the chosen tuning for 3 days on seed 20261109 and asserts every verdict row the report says passes, and that served share is above the baseline numbers recorded in the test as constants.
- [ ] **Step 4: Run**, one at a time: `mix test test/feud_hall/domain/tuning_test.exs`; `mix test test/feud_hall/domain/npc_planner_test.exs`; `mix test --only acceptance test/feud_hall/scripts/customer_acceptance_test.exs`; the demand properties `test/feud_hall/domain/arrivals_test.exs`, `demand_forecast_test.exs`, `invariants_test.exs`; then `mix format --check-formatted`. Expected: PASS.
- [ ] **Step 5: Commit** — `Choose arrival, market and planner values from measured runs`

---

### Task 5: Applying the change on request

**Files:**
- Modify: `server/lib/feud_hall/web/router.ex`, `server/test/feud_hall/web/endpoint_test.exs`, `docs/DEPLOYMENT.md`
- Test also: the test that covers `FeudHall.Web.Bootstrap` (find it with `grep -rn "Bootstrap" test`)

**Interfaces:**
- Consumes: `Tuning.chosen/0`, the `retune_rules` command.
- Produces: `POST /api/operator/retune`, authorised exactly as `POST /api/operator/seed` is (the operator bearer secret). Body: `{"command_id": string, "version": integer}`. It executes `{:retune_rules, %{tuning: Tuning.chosen()}}` as `{:system, :admin}` when `version` equals `Tuning.chosen().version`. Responses follow the seed endpoint's shapes: `{"accepted": true, ...}` on success or a replayed receipt; a refusal carries the domain's reason code (`retune_unavailable`, `invalid_content`); a `version` that is not the chosen version is refused with `unknown_tuning_version` without executing anything; a missing or wrong secret is refused as the seed endpoint refuses it.

- [ ] **Step 1: Write the failing tests** in `endpoint_test.exs`, beside the seed endpoint's tests:

```elixir
test "an operator applies the chosen tuning once" do
  # POST with the secret, command_id "operator-retune:2", version 2: accepted; the hall's Tuning.of(catalog).version is 2.
  # The same POST again: accepted (replayed receipt), one hall_rules_retuned event in the store.
  # A POST with a new command_id and version 2: refused, retune_unavailable; still one event.
end

test "retune needs the operator secret and the chosen version" do
  # No header and a wrong secret: refused as the seed endpoint refuses; nothing recorded.
  # version 3: unknown_tuning_version; nothing recorded.
end
```

In the Bootstrap test: after boot of a fresh managed hall and of an existing hall, `Tuning.of(state.catalog).version == 1` and the store holds no `hall_rules_retuned` event.

- [ ] **Step 2: Run** `mix test test/feud_hall/web/endpoint_test.exs` — Expected: FAIL (route missing).
- [ ] **Step 3: Implement** the route. In `docs/DEPLOYMENT.md`, add "Applying the customer tuning": it is deliberate and not reversible; take a database backup first; the exact request; what changes and when (from the next game midnight); how to confirm it (the hall's event and the next day's arrival count).
- [ ] **Step 4: Run** the endpoint test and the Bootstrap test, then `mix format --check-formatted`. Expected: PASS.
- [ ] **Step 5: Commit** — `Let an operator apply the customer tuning on request`

---

### Task 6: Documentation and report

**Files:**
- Modify: `docs/GAME_DESIGN.md` (§7 arrival scale, §8 market stock, §14 computer-run planning, the §21 tuning register), `docs/ARCHITECTURE.md` (the recorded rule change beside the catalog expansion; the tuning as data), `docs/TESTING.md` (the acceptance tag), `AGENTS.md` (one sentence in "Start here": the tuning exists, is recorded, and is applied by an operator, with links)
- Modify: `docs/superpowers/reports/2026-11-15-more-real-customers.md`

- [ ] **Step 1:** Update the game design: state both the current values and the chosen values, marked as proposed tuning, and that a hall is on the current values until an operator applies the change.
- [ ] **Step 2:** Complete the report: before and after tables for runs A and B; the chosen values as a diff from today's; the tuning log; the sensitivity results; **the profit comparison for the owner's cost decision** (daily profit of the reference stall and each computer-run restaurant, current versus chosen, per measured day and on average, with rent, wages and purchases shown); which acceptance checks pass and which do not, with the binding constraint for any that do not; each builder's call with what it costs if wrong; what is not verified.
- [ ] **Step 3:** Run `bun run format:check` from `app/` (it covers the docs) and check each relative link you added with `ls`.
- [ ] **Step 4: Commit** — `Document the customer tuning and report the measurements`
