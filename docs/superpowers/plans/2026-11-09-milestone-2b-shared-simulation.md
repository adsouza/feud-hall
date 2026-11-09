# Milestone 2B: Shared Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the durable hall a living economy: a batched wholesale market, a seeded stream of simulated diners who choose stalls, an automatic kitchen, and basic NPC owners that compete through the same rules as a human — all deterministic, replayable, and proven by reliable tests.

**Architecture:** All clock-driven simulation (market clearing, replenishment, midnight forecast, arrivals and choice, kitchen stages, handover, patience) is decided inside `FeudHall.Domain.Hall.Advance` as recorded advance events; only human owners and NPC planners issue commands. New pure domain modules (`Random`, `Kitchen`, `Market`, `Demand`, `Choice`, `PublicView`, `Npc.Planner`) hold the rules; the `HallAuthority` only wires NPC planning slots to the workflow. Admission and reservation move into one shared `Hall.Admission` module used by guests, simulated arrivals, and desserts.

**Tech Stack:** Elixir 1.20.4 / OTP 29, Ecto SQL 3.14, Postgrex 0.22, PostgreSQL 18 (system server, localhost:5432), StreamData 1.4 (test only).

**Spec:** `docs/superpowers/specs/2026-11-09-milestone-2-design.md` — Project B, plus "Decisions recorded during Project A" and the Verification section. Rules cited there (GAME_DESIGN §7, §8, §9 production rules, §14, location tiers; ARCHITECTURE "Simulation scheduling") are authoritative.

## Global Constraints

- Work on a new local branch `milestone-2b-shared-simulation` created from `milestone-2a-durable-storage`. Never push. No git hooks exist; re-check `.git/hooks` before the first commit.
- Use the PostgreSQL 18 server already running on localhost:5432. Never start Docker, other database servers, or other external processes.
- Combined RSS of BEAM + PostgreSQL + tooling stays under 2 GiB. Full local `mix test` is permitted (owner, 2026-11-09) only with `--max-cases 1` and memory sampled throughout; otherwise run focused files. Never run `tsc`.
- Domain modules stay pure: no Ecto, processes, Logger, ambient clocks, or `:rand`. Application modules never reference `FeudHall.Infrastructure`. Randomness only through `FeudHall.Domain.Random` with persisted state.
- No test may sleep, wait on wall-clock time, depend on test order, or share database rows with another test.
- Tuning values live in validated, versioned content (`SliceCatalog`), never as literals in domain logic. Integer arithmetic only for economics and weights; no floats in decisions.
- Replay never draws randomness, reruns the planner, or emits side effects; every draw's result and the new PRNG state are recorded in events.
- Command-ID prefixes `adv:`, `tick:`, `recovery:`, `start:`, `npc:` are reserved for system and NPC actors.
- Keep every existing invariant: trial balance, cost classified once, one finalized outcome per visit, 03:00 cutoff and 05:00 reopening, expiry winning freshness ties, service winning deadline ties.
- Format with `mix format`; compile with `--warnings-as-errors` in dev and test. Commit messages end with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A buyer with no cash or no storage room** submitting purchase requests must receive zero fills with a stated reason (`:insufficient_cash`, `:insufficient_storage`), never negative cash or storage above capacity, while other buyers in the same batch fill normally. Test added to Task 8.
2. **An arrival due exactly at 03:00, 05:00, or 00:00** must follow the scheduling order: no arrival at or during cleaning, the midnight forecast applied before a 00:00 arrival, and nothing deferred into a reopening surge. Test added to Task 12.
3. **A long catch-up advance** (two complete game days in one `advance_clock`) must produce exactly the same events as the same span split into many small advances, and complete within the bounded per-test budget. Test added to Task 12.
4. **An NPC that cannot afford anything** (zero cash, empty storage) must still commit a plan whose rejected actions carry reasons, advance its planning slot, and never crash the authority. Test added to Task 15.
5. **An owner editing the menu or closing the stall while trays are queued** must not change queued or in-progress work: accepted trays keep their bound terms and are still prepared and served; only new orders stop. Test added to Task 7.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `lib/feud_hall/domain/random.ex` | Pure splitmix64 PRNG with integer state; uniform, range, weighted pick |
| `lib/feud_hall/domain/content/slice_catalog.ex` | Adds `rules.kitchen`, `rules.market`, `rules.demand`, `layout`, `npc_profiles` |
| `lib/feud_hall/domain/content.ex` | Validates the new content sections |
| `lib/feud_hall/domain/hall/admission.ex` | Shared quote → fund → reserve for trays and desserts (guest and simulated) |
| `lib/feud_hall/domain/kitchen.ex` | Stage-queue model: dispatch decisions and the queue-aware completion estimate |
| `lib/feud_hall/domain/market.ex` | Published price, request validation, batch clearing allocation, replenishment |
| `lib/feud_hall/domain/demand.ex` | Operating observation, midnight forecast, arrival schedule and draws |
| `lib/feud_hall/domain/choice.ex` | Bounded integer-weighted stall/dish choice and leaving reasons |
| `lib/feud_hall/domain/public_view.ex` | The public projection NPC planners (and later humans) see |
| `lib/feud_hall/domain/npc/planner.ex` | Pure profile-driven planner returning ordinary actions |
| `lib/feud_hall/domain/hall/{decider,evolver,advance,settlement,invariants}.ex` | Modified to host the above |
| `lib/feud_hall/application/command_workflow.ex` | Reserved prefixes, `{:npc, id}` actor, new command kinds |
| `lib/feud_hall/infrastructure/hall_authority.ex` | NPC bootstrap and planning-slot execution; simulation diagnostics |
| `lib/feud_hall/infrastructure/event_codec.ex` | Allowlist additions |
| `lib/feud_hall/infrastructure/snapshot.ex` | Evolution version 3 |
| `test/support/{fixtures,hall_trace,oracle}.ex` | Migrated off kitchen commands and instant purchases; new actions and oracles |
| `test/fixtures/events/*.json` | Golden serialized fixtures for each new event type |

---

### Task 1: Reserved command-ID prefixes and the NPC actor kind

**Files:**
- Modify: `lib/feud_hall/application/command_workflow.ex`, `lib/feud_hall/domain/hall/decider.ex`, `lib/feud_hall/domain/hall/evolver.ex`, `lib/feud_hall/infrastructure/event_codec.ex`
- Test: `test/feud_hall/application/command_workflow_test.exs`, `test/feud_hall/domain/npc_actor_test.exs`

**Interfaces:**
- Produces: actor `{:npc, operator_id}` (operator_id: printable 1..32 bytes) accepted by `CommandWorkflow` validation. `restaurant_created` events gain `owner_kind: :principal | :npc`; the evolver treats a missing `owner_kind` as `:principal`. Restaurants gain `owner_kind`; `state.owners` is keyed by `{owner_kind, owner}`. `Decider` ownership guards accept `{:principal, id}` and `{:npc, id}` for restaurants whose `{owner_kind, owner}` matches. `CommandWorkflow.reserved_prefix?(command_id) :: boolean`.

- [ ] **Step 1: Write failing tests.**

```elixir
test "reserved command-ID prefixes are refused for principals" do
  for id <- ~w(adv:500 tick:1:2 recovery:x start:x npc:a:1) do
    assert {:error, :reserved_command_id, _} =
             Workflow.execute(rt, env(id, {:principal, "alice"}, purchase_request(10)))
  end
end

test "system actors may use reserved prefixes" # an :advance_clock with id "tick:1:24" from {:system, :scheduler} is accepted

test "an NPC owns and operates its restaurant like a principal" do
  # create_restaurant as {:npc, "budget"}; open_stall as {:npc, "budget"} accepted;
  # open_stall as {:principal, "budget"} -> {:error, :forbidden}; a principal and an NPC with the same id string own separate ventures
end
```
- [ ] **Step 2: Run** `mix test test/feud_hall/domain/npc_actor_test.exs test/feud_hall/application/command_workflow_test.exs --max-cases 1` — FAIL.
- [ ] **Step 3: Implement.** Prefix check in `validate/1` after the ID shape check: reserved prefixes are allowed only for `{:system, _}` and, for `npc:`, `{:npc, _}`. Ownership by `{kind, id}`; update `owned_restaurant/3`, `create_restaurant` (any owner kind may create one venture). Codec allowlist: `npc`, `owner_kind`, `reserved_command_id` as needed.
- [ ] **Step 4: Run** the two files plus every existing domain test file individually — PASS.
- [ ] **Step 5: Commit** — `git commit -m "Reserve internal command-ID prefixes and add the NPC actor"`

### Task 2: Deterministic PRNG

**Files:**
- Create: `lib/feud_hall/domain/random.ex`
- Test: `test/feud_hall/domain/random_test.exs`

**Interfaces:**
- Produces: `Random.new(seed :: non_neg_integer) :: state` (state is a non-negative integer < 2^64); `Random.next(state) :: {u64, state}`; `Random.uniform(state, n :: pos_integer) :: {0..n-1, state}` (unbiased, rejection sampling on 64-bit draws); `Random.range(state, lo, hi) :: {lo..hi, state}`; `Random.weighted(state, [{key, weight :: non_neg_integer}]) :: {key, state}` (sum of weights > 0; key order as given); `Random.derive(seed, label :: binary) :: seed` (stable sub-seed from SHA-256 of `<<seed::64, label::binary>>`).

- [ ] **Step 1: Failing tests:** splitmix64 golden values — `Random.new(0) |> Random.next()` returns first output `16_294_208_416_658_607_535` (the reference splitmix64 sequence for seed 0); `uniform` never returns `n` and is uniform over 30_000 draws within ±5% per bucket for `n = 7`; `weighted` never returns a zero-weight key and hits `[a: 1, b: 3]` in ratio within ±5% over 20_000 draws; identical seeds give identical sequences; `derive(1, "demand") != derive(1, "npc:budget")`.
- [ ] **Step 2: Run** — FAIL; **implement** (splitmix64: `state + 0x9E3779B97F4A7C15`, xor-shift-multiply mix, all masked to 64 bits); **run** — PASS. Extend the architecture test's planted case only if needed (the domain already forbids `:rand`).
- [ ] **Step 3: Commit** — `git commit -m "Add a pure persisted-state PRNG"`

### Task 3: Project B content and validation

**Files:**
- Modify: `lib/feud_hall/domain/content/slice_catalog.ex`, `lib/feud_hall/domain/content.ex`
- Test: `test/feud_hall/domain/dietary_and_content_test.exs` (add a `describe "simulation content"`)

**Interfaces:**
- Produces these catalog keys (values are proposed tuning; tests assert validation, not the numbers):
  - `rules.kitchen`: `%{prep_stations: 2, finish_stations: 1, queue_limit: 6}` (per stall).
  - `rules.market`: `%{clear_every_hall_ms: 240_000, price_floor_permille: 500, price_ceiling_permille: 3_000, target_stock_per_equivalent: %{product_id => qty}, replenish_cap: %{product_id => qty}}` — every product present in both maps, cap ≥ target × 3.
  - `rules.demand`: `%{arrivals_per_equivalent: 90, equivalent_floor_millis: 3_000, operating_hours_ms: 22 * hour, hourly_weights: [24 integers, index = hall hour, indices 3 and 4 are 0], segments: [%{id, weight, budget: {lo, hi}, patience_service_ms: {lo, hi}, drink_attach_permille, dessert_appetite_permille, price_weight, quality_weight, wait_weight, leave_weight, main_preference: %{recipe_id => weight}}], profile_mix: %{profile_id => weight}, variety_weight, variety_cap}` with four segments `value`, `time_sensitive`, `enthusiast`, `quality`, and profile mix 60/20/10/7/3 (keto weight applies only when enabled; disabled profiles are dropped and the mix renormalised at draw time).
  - `layout`: 150 slots `%{slot_id: "s001".."s150", tier: :quiet | :standard | :busy | :prime}` with tier factors in `rules.exposure_permille: %{quiet: 800, standard: 1_000, busy: 1_250, prime: 1_500}`.
  - `npc_profiles`: three entries `%{id: "budget" | "mainstream" | "premium", price_permille, policy: :prefer_substitute | :prefer_primary | :primary_only, restock_days, preferred_tier}`.
  - `rules.seed`: default hall seed (integer).
- `Content.validate/1` adds problems: `{:kitchen, :bad_capacity}`, `{:market, product, :missing_target}`, `{:market, :bad_price_bounds}`, `{:demand, :bad_hourly_weights}` (length ≠ 24, negative, or nonzero at hours 3–4), `{:demand, segment_id, :bad_range}`, `{:layout, :too_many_slots}` (> 150), `{:layout, slot_id, :duplicate}`, `{:npc, id, :bad_profile}`.

- [ ] **Step 1: Failing tests:** the slice catalog validates; each listed problem is reported for a minimally broken catalog (one case per problem); `Content.hash/1` still deterministic.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** this file and `content`-touching files — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Author and validate simulation content"`

### Task 4: Hall layout and free location choice

**Files:**
- Modify: `decider.ex`, `evolver.ex`, `event_codec.ex`, `test/support/fixtures.ex`, `test/support/hall_trace.ex`
- Test: `test/feud_hall/domain/layout_test.exs`

**Interfaces:**
- `{:initialize_hall, %{hall_id:, catalog:, seed: optional integer}}` → `hall_initialized` gains `layout` (from content), `seed` (payload or `rules.seed`), `market: %{stock: %{product => qty}}` (target stock at the floor of three equivalents), `demand` initial state (Task 10/12 fill it; this task stores `%{rng: Random.new(Random.derive(seed, "demand"))}`).
- Hall state gains `layout: %{slot_id => tier}` and `market`, `demand`, `npcs: %{}`.
- `create_restaurant` payload keeps `stall_id`, which must be a vacant layout slot: errors `:unknown_slot`, `:stall_taken`. Stalls gain `tier`.
- Fixtures and `HallTrace` use slot `"s001"` instead of `"s1"` (one constant `@stall` in each support module).

- [ ] **Step 1: Failing tests:** initialize records 150 slots and the seed; create in a vacant slot succeeds and the stall has the slot's tier; unknown slot and occupied slot rejected; after 150 restaurants the 151st is `:stall_taken` or `:unknown_slot` (no slot left) — use a generated loop of 150 principals.
- [ ] **Step 2: Run** — FAIL; **implement**; migrate fixtures to `"s001"`; run every existing test file individually — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Record the hall layout and let owners choose vacant slots"`

### Task 5: Shared admission

Pure refactor; no behaviour change.

**Files:**
- Create: `lib/feud_hall/domain/hall/admission.ex`
- Modify: `decider.ex`
- Test: existing `tray_lifecycle_test.exs`, `dietary_and_content_test.exs`, `cleaning_and_stock_test.exs`, the M1 property (unchanged assertions)

**Interfaces:**
- `Admission.admit(state, %{source:, principal:, budget:, stall_id:, main:, drink:, profile_id:, confirmed:, deadline_cap: hall_ms | nil}, entity_id :: String.t()) :: {:ok, [visit_admitted, tray_accepted]} | {:error, reason}` — `entity_id` replaces `ctx.command_id` in derived IDs (`"V:" <> id`, `"T:" <> id`, `"O:#{id}:#{kind}"`). `deadline_cap` (used by simulated patience in Task 12) lowers the bound deadline when non-nil.
- `Admission.accept_dessert(state, visit, confirmed, entity_id) :: {:ok, [dessert_accepted]} | {:error, reason}`.
- `Decider` `admit_visit`/`accept_dessert` become thin wrappers passing `ctx.command_id`.

- [ ] **Step 1:** Move `admit_visit`, `fund`, `take`, `reserve_components`, `reserve_lines`, `accept_dessert`, `fund_dessert`, `bind_deadline` into `Admission` unchanged except the `entity_id` parameter.
- [ ] **Step 2: Run** the listed test files and the M1 property individually — PASS with no test edits.
- [ ] **Step 3: Commit** — `git commit -m "Extract shared tray and dessert admission"`

### Task 6: Kitchen queue model and queue-aware quotes

**Files:**
- Create: `lib/feud_hall/domain/kitchen.ex`
- Modify: `lib/feud_hall/domain/offers.ex`
- Test: `test/feud_hall/domain/kitchen_test.exs`

**Interfaces:**
- Order work state (added by Task 7's evolver; this task defines the shape and reads it): each live order has `stage: :queued_prep | :prep | :queued_finish | :finish | :ready` with `stage_done_at` (for `:prep`/`:finish`), `queued_at`, and `prep_ms`, `finish_ms` copied from the quote at acceptance. Each stall has `counter: nil | %{item: {:tray, id} | {:dessert, order_id}, done_at}`.
- `Kitchen.estimate(state, stall_id, new_components :: [%{prep_ms, finish_ms}], now) :: %{earliest_completion: hall_ms}` — deterministic list-scheduling simulation:
  1. Prep stations: `prep_stations` free times = `stage_done_at` of orders in `:prep` at this stall, padded with `now`. Assign each `:queued_prep` order (FIFO by `{queued_at, order_id}`), then each new component, to the earliest-free station; record its prep end.
  2. Finish stations: same with release time = the component's prep end (or `now` for orders already `:queued_finish`), FIFO by release time then ID; existing `:finish` orders occupy stations until `stage_done_at`.
  3. Counter: trays become ready at the max finish end of their components; process items FIFO by ready time; each takes `handover_ms`; the counter is free from its current `done_at`.
  4. Return the new tray's handover end.
- `Kitchen.accepting?(state, stall_id) :: boolean` — false when accepted-but-unserved trays plus desserts at the stall ≥ `queue_limit`.
- `Offers.timing/2` uses `Kitchen.estimate/4` for `earliest`; `Offers.open_stall/2` adds `{:error, :queue_full}` when not accepting. Quotes, acceptance, and (Task 11) choice all call these same functions.

- [ ] **Step 1: Failing tests:** empty stall estimate = now + max(prep) … exactly `now + prep + finish + handover` for one main; two prep stations run two mains in parallel, the third waits; one finish station serialises finishes; a busy counter delays handover; a full queue makes `open_stall` return `:queue_full`; a quote's `earliest_completion` equals `Kitchen.estimate/4` for the same inputs; the 03:00 check uses the queue-aware estimate (a tray that would finish by 03:00 on an empty stall is refused when the queue pushes it past 03:00).
- [ ] **Step 2: Run** — FAIL; **implement**; **run** kitchen tests and all `Offers` callers' test files — PASS (Milestone 1 tests still pass because an empty kitchen gives the old estimate).
- [ ] **Step 3: Commit** — `git commit -m "Model kitchen stages and quote queue-aware waits"`

### Task 7: The automatic kitchen

**Files:**
- Modify: `advance.ex`, `evolver.ex`, `settlement.ex`, `decider.ex`, `invariants.ex`, `command_workflow.ex`, `event_codec.ex`, `test/support/{fixtures,hall_trace,oracle}.ex`, every test that used kitchen commands
- Test: `test/feud_hall/domain/automatic_kitchen_test.exs`

**Interfaces:**
- Advance boundary classes at one timestamp (lower first; ties by entity ID), replacing the Milestone 1 list in `Advance`'s moduledoc:
  1 raw/ready expiry · 2 03:00 cleaning start · 3 stage completions and counter handover completions (service) · 4 tray/dessert deadlines and offer timeouts · 5 05:00 reopening · 6 day boundary (Task 10) · 7 market clearing (Task 9) · 8 arrivals (Task 12) · 9 dispatch (start queued stages and counter selection).
- New events: `stage_started %{order_id, stage: :prep | :finish, done_at, consumed: [...] (prep only)}`, `stage_completed %{order_id, stage, expires_at (finish only)}`, `handover_started %{stall_id, item, done_at}`. Service at handover completion emits the existing `tray_served`/`dessert_served` via `Settlement` (freshness, deadline, and access rules unchanged). Old `preparation_started`/`preparation_completed` evolver clauses stay for historical replay.
- Dispatch (class 9) runs only while `access == :open`; it starts at most what capacity allows, FIFO as in Task 6, and selects the counter's next ready item FIFO by its final ready time. Closed stalls keep working off accepted work; closing stops only new orders.
- Remove `start_preparation`, `complete_preparation`, `serve_tray`, `serve_dessert` from the decider and from `CommandWorkflow`'s command list; `{:system, :kitchen}` stops being a valid actor.
- `tray_accepted` events gain `estimated_completion` (the quote's `earliest_completion`, from `Kitchen.estimate/4` at acceptance) and the evolver stores it on the tray; `dessert_accepted` likewise on the dessert order. Old events without it store `nil`.
- Fixture `prepare_tray/2` becomes `serve_tray(world, tray_id)`: advance hall time to the tray's `estimated_completion`. `HallTrace` drops `:kitchen`, `:kitchen_all`, and the kitchen steps of `:cycle` in favour of `{:wait, ms}`; its progress floors stay.

- [ ] **Step 1: Failing tests:**
  - one tray is served exactly at `estimated_completion` with no commands after acceptance;
  - the decider rejects every removed kitchen command (`{:error, :unknown_command, _}` through the workflow);
  - two stations / one finisher / one counter ordering matches `Kitchen.estimate` for a queue of four trays;
  - a component ready at the same instant it expires is not served (expiry class 1 before service class 3);
  - service exactly at the tray deadline is served (class 3 before 4);
  - work in progress at 03:00 is cancelled with its consumed cost as waste and no dispatch occurs until 05:00;
  - **(Review Focus 5)** after acceptance, `remove_menu_item`, `set_menu_price`, and `close_stall` do not change the queued tray's price, components, or service; a new order after `close_stall` is refused;
  - drinks and mains share stage queues; a dessert uses the counter after the main tray.
- [ ] **Step 2: Run** — FAIL; **implement**; migrate fixtures, `HallTrace`, `tray_lifecycle_test.exs`, `cleaning_and_stock_test.exs`, `dietary_and_content_test.exs`, `command_workflow_test.exs`, and the oracle (order statuses `:queued_prep..:ready`, `wip` equals consumed cost of orders past `:queued_prep`).
- [ ] **Step 3: Run** every test file individually, including both trace properties — PASS with unchanged floors.
- [ ] **Step 4: Commit** — `git commit -m "Run the kitchen automatically inside the clock advance"`

### Task 8: Market clearing algorithm

**Files:**
- Create: `lib/feud_hall/domain/market.ex`
- Test: `test/feud_hall/domain/market_test.exs`

**Interfaces:**
- Market state: `%{stock: %{product => qty}, requests: %{request_id => %{restaurant_id, product, qty, max_price_per_kunit, submitted_at}}, by_key: %{{restaurant_id, product} => request_id}, batch: non_neg_integer, next_clear_at: hall_ms}`.
- `Market.price(catalog, market, product) :: pos_integer` — `clamp(div(base * target_at_floor, max(stock, 1)), div(base * floor_permille, 1000), div(base * ceiling_permille, 1000))`, where `target_at_floor = target_stock_per_equivalent * 3`.
- `Market.clear(state) :: %{type: :market_cleared, batch, prices: %{product => price}, fills: [%{request_id, restaurant_id, product, product_version, qty, cost, batch_id, expires_at}], unfilled: [%{request_id, qty, reason}]}`:
  1. Prices from current stock (before allocation).
  2. Per restaurant (sorted by ID), its requests in product-ID order: `:price_above_limit` if price > limit; else funded qty = min(requested, cash affordable at price (cumulative over this restaurant's earlier requests in the batch), storage room (cumulative)); shortfall reasons `:insufficient_cash` / `:insufficient_storage`.
  3. Per product: if total funded ≤ stock, fill all; else `base_i = div(stock * q_i, total)`, leftover units go to the largest remainders `rem(stock * q_i, total)`, ties broken by restaurant order rotated by `batch` (start at index `rem(batch, n)` of the sorted requesting restaurants). Unfilled remainder reason `:stock_exhausted`.
  4. `cost = ceil(qty * price / 1000)`; `batch_id = "MB:#{batch}:#{request_id}"`; `expires_at = now + shelf_life_ms`.
- `Market.replenish(catalog, market, scale_millis) :: %{product => qty}` — `target = div(target_stock_per_equivalent * scale_millis, 1000)`; `qty = max(0, min(target, cap) - stock)`.

- [ ] **Step 1: Failing tests (pure, on hand-built states):**
  - uncontended requests fill fully at the published price; cost rounding is ceiling;
  - contention: stock 10, requests 7/7/7 → fills 4/3/3 with the rotation deciding the 4; next batch the rotation moves the extra unit;
  - splitting is impossible (one request per key) and a restaurant gains nothing by submitting the same total twice in successive replacements;
  - price clamps at floor and ceiling;
  - **(Review Focus 1)** a zero-cash buyer and a full-storage buyer get zero fills with `:insufficient_cash` / `:insufficient_storage` while a funded buyer in the same batch fills; no fill exceeds cash or storage; cumulative per-restaurant budgets across products are respected;
  - conservation: `stock_before = sum(fills) + stock_after` per product;
  - replenishment tops up toward target, never above cap, never negative.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Add batched market clearing and replenishment rules"`

### Task 9: Purchase requests, scheduled clearing, and replenishment

**Files:**
- Modify: `decider.ex`, `evolver.ex`, `advance.ex`, `command_workflow.ex`, `event_codec.ex`, `invariants.ex`, `test/support/{fixtures,hall_trace,oracle}.ex`, tests that used `purchase_stock`
- Test: `test/feud_hall/domain/market_flow_test.exs`

**Interfaces:**
- Commands: `{:submit_purchase_request, %{restaurant_id, product, qty, max_price_per_kunit}}` → `purchase_requested %{request_id: "PR:" <> command_id, restaurant_id, product, qty, max_price_per_kunit, replaces: request_id | nil}`; `{:cancel_purchase_request, %{restaurant_id, product}}` → `purchase_request_cancelled %{request_id}` (`:no_pending_request` otherwise). Validation: owned restaurant, known product, `qty` 1..1_000_000, positive integer limit. No cash is held.
- `purchase_stock` is removed from the decider and workflow command list; its evolver clause stays for history.
- Advance class 7 at `market.next_clear_at` (multiples of `clear_every_hall_ms`, including during cleaning) emits `Market.clear/1`'s event; the evolver creates batches, posts `cash`/`raw`, reduces market stock, settles every pending request, increments `batch`, and sets `next_clear_at`.
- Replenishment is emitted by the day boundary in Task 10; until then `market.stock` changes only by fills.
- Fixtures: `buy/4` and `stock/2` submit requests then advance to the next clearing; `stocked_world/1` sets up stock this way. `HallTrace` `{:purchase, ...}` submits a request; add `{:cancel_request, idx}`.

- [ ] **Step 1: Failing tests:** a request filled at the next clearing produces a batch and the right ledger posts; a replacing request supersedes the pending one; cancellation before clearing leaves no fill; clearing at 03:30 (during cleaning) fills; a fill's `expires_at` starts at the fill time; the oracle's market conservation holds; `purchase_stock` through the workflow is `:unknown_command`.
- [ ] **Step 2: Run** — FAIL; **implement**; migrate fixtures/tests/`HallTrace`; run every test file individually — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Replace instant purchases with batched purchase requests"`

### Task 10: Business-equivalent observation and the midnight forecast

**Files:**
- Create: `lib/feud_hall/domain/demand.ex`
- Modify: `advance.ex`, `evolver.ex`, `event_codec.ex`
- Test: `test/feud_hall/domain/demand_forecast_test.exs`

**Interfaces:**
- `Demand.operating(state) :: [restaurant_id]` — restaurants with an open stall, `access == :open`, accepting (Task 6), and at least one main for which `Offers.quote_course/7` succeeds for the unrestricted requirement against current availability. An open stall counts as staffed until staff exist.
- Every `clock_advanced` event emitted by `Advance` gains `operating: [restaurant_id]` computed at the interval's start; the evolver adds `to - now` to `demand.observed_ms[rid]` for each listed restaurant (the day boundary is a due boundary, so intervals never cross midnight). Old `clock_advanced` events without the key observe nothing.
- Advance class 6 at each 00:00 emits `day_closed %{day, equivalents_millis, scale_millis, replenishment: %{product => qty}, summary}`:
  - `equivalents_millis = sum over restaurants of min(observed_ms * 1000 / operating_hours_ms, 1000)`;
  - `scale_millis = max(equivalents_millis, equivalent_floor_millis)` — the scale for the day now starting;
  - replenishment uses the scale fixed at the previous midnight (`demand.supply_scale_millis`, initialised to the floor) and then stores this midnight's scale as the next supply scale (one-day delay); `replenishment` quantities come from `Market.replenish/3` and the evolver adds them to `market.stock`, resets `observed_ms`, and stores the new scale;
  - `summary` (public, Task 14): `%{day, arrivals, admitted, left: %{reason => count}, trays_served, menu_prices_median: %{recipe_id => price}}` for the completed day; the hall keeps the last 7 summaries.
- On a new hall, day 0 uses the floor scale.

- [ ] **Step 1: Failing tests:** a stall open for 11 of 22 accessible hours yields 500 equivalent-millis; two stalls of one owner (not possible yet — one stall per restaurant) are not double-counted (assert per-restaurant cap 1000); cleaning hours never count; a stock-out of every main stops observation until restock; the scale floors at 3000; replenishment at midnight D uses the scale fixed at midnight D-1; the summary counts match the day's events; partitioning a day's advance into 1-, 7-, and 60-minute steps yields identical `day_closed` events.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS, plus every advance-touching test file.
- [ ] **Step 3: Commit** — `git commit -m "Observe operating businesses and fix the daily forecast at midnight"`

### Task 11: Diner choice

**Files:**
- Create: `lib/feud_hall/domain/choice.ex`
- Test: `test/feud_hall/domain/choice_test.exs`

**Interfaces:**
- `Choice.choose(state, diner :: %{segment, budget, requirement, patience_hall_ms, drink?: boolean}, rng) :: {{:stall, stall_id, main_id, drink_id | nil} | {:leave, reason}, rng}`.
- Candidates: every stall where `Offers.open_stall/2` succeeds; per stall every main on its menu; a candidate needs a successful `Offers.quote_tray/5` (with the stall's drink when `drink?` and the drink quote also fits, else main only), `quote.total <= budget`, and `quote.earliest_completion <= now + patience_hall_ms`.
- Integer score per candidate: `price_weight * value + quality_weight * quality + wait_weight * slack + preference`, where `value = div((budget - total) * 1000, budget)`, `slack = div((deadline - earliest) * 1000, patience)`, all segment weights from content; stall weight = `div((best_score + variety_bonus) * exposure_permille, 1000)` with `variety_bonus = variety_weight * min(eligible_mains - 1, variety_cap)`; a stall with weight 0 is excluded. Duplicate menu rows cannot add weight (best-dish only).
- Pick with `Random.weighted/2` over stalls plus `{:leave, segment.leave_weight}`.
- Leave reasons in priority: `:no_compatible_main` (no stall had a dietary-compatible main), `:nothing_affordable`, `:wait_too_long`, `:chose_to_leave`.

- [ ] **Step 1: Failing tests:** incompatible food has zero probability even when it is the only stall and costs 1; exposure applies once (identical stalls differing only in tier: prime chosen ≈ 1.5/2.5 of non-leave picks within ±5% over 4,000 seeded draws); adding a duplicate menu row does not change the stall's weight; each leave reason arises in its constructed scenario; same state and rng give the same result; the returned main/drink quote is accepted by `Admission.admit/3` unchanged.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Add bounded weighted diner choice"`

### Task 12: Arrivals inside the advance

**Files:**
- Modify: `lib/feud_hall/domain/demand.ex`, `advance.ex`, `evolver.ex`, `event_codec.ex`, `invariants.ex`, `test/support/oracle.ex`
- Test: `test/feud_hall/domain/arrivals_test.exs`

**Interfaces:**
- Demand state adds `hour_quota_millis` (the current hall hour's milli-arrivals), `acc_millis` and `acc_at` (accumulator anchor), `arrival_seq`, and `next_arrival_at`.
- Daily quotas: at each midnight `day_closed` also records `hour_quotas_millis: [24 integers]` = largest-remainder split of `arrivals_per_equivalent * scale_millis` (milli-arrivals for the day) by `hourly_weights`, so the day's quotas sum exactly; ties by hour index. Day 0 quotas are computed at initialization.
- Schedule: within hour `h`, the accumulator grows linearly by `hour_quotas_millis[h]` over the hour; an arrival occurs each time it crosses a multiple of 1000. `Demand.next_arrival_at(demand, now) :: hall_ms | nil` returns the next crossing, carrying the fractional remainder across hours and days; hours with quota 0 (cleaning) produce none and accumulate nothing.
- Advance class 8 at `next_arrival_at`:
  1. draw with the demand rng: segment (`weighted` by segment weight), budget (`range`), patience in service ms (`range`, converted with `Clock.service_duration/1`), profile (`weighted` over enabled `profile_mix`), drink attach and dessert appetite (`uniform(1000) < permille`);
  2. `Choice.choose/3`;
  3. on a stall: `Admission.admit/3` with `source: :simulated`, `principal: "diner:D#{day}-#{seq}"`, `deadline_cap: min(now + patience_hall_ms, Clock.service_cutoff(now))`, entity ID `"A#{day}-#{seq}"`;
  4. emit `diner_arrived %{arrival_id, segment, budget, patience_hall_ms, profile_id, drink?, dessert_appetite?, outcome: :admitted | {:left, reason}, rng}` followed by the admission events (if any). The visit stores `dessert_appetite?` for Task 13.
- Hall `stats` gain `arrivals_simulated`, `admitted_simulated`, `left_simulated: %{reason => n}`; oracle: `arrivals_simulated == admitted_simulated + sum(left_simulated)`; arrival accounting per source.
- `{:system, :demand}` `admit_visit` stays only as a test fixture path and calls `Admission.admit/3`; the authority never issues it.

- [ ] **Step 1: Failing tests:**
  - a day at scale 3000 produces exactly `90 * 3 = 270` arrivals, none in hours 3–4;
  - partitioning the same day into 1-minute, 17-minute, and single advances gives identical events (Review Focus 3 includes **two complete game days in one advance** equal to many small advances, and the test runs within the default ExUnit timeout);
  - **(Review Focus 2)** an arrival scheduled exactly at 03:00 does not occur (quota 0 from 03:00), none occur before 05:00, the first after 05:00 follows the normal schedule with no surge, and at 00:00 the new day's quotas apply to an arrival due exactly then;
  - the patience cap is bound into the tray deadline and a slow queue causes abandonment with reason `:deadline_missed` scored 0;
  - an admitted arrival's quote equals what `Choice` saw;
  - arrival accounting holds; replaying the events (no advance) reproduces the state without drawing.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS, plus every advance-touching test file.
- [ ] **Step 3: Commit** — `git commit -m "Generate seeded arrivals and simulated choice in the advance"`

### Task 13: Simulated dessert at service

**Files:**
- Modify: `settlement.ex`, `advance.ex`, `admission.ex`
- Test: `test/feud_hall/domain/tray_lifecycle_test.exs` (new `describe "simulated dessert"`)

**Interfaces:**
- `Settlement.serve_tray/2` for a simulated visit: if dessert is eligible and affordable and `visit.dessert_appetite?`, emit `dessert_accepted` via `Admission.accept_dessert/4` (entity ID `"DS:" <> visit_id`) in the same batch; otherwise `dessert_declined` + `visit_finalized`. Guests keep the `dessert_offered` window; offer timeouts apply only to guest visits.

- [ ] **Step 1: Failing tests:** appetite true and eligible → dessert accepted in the service batch and later served by the kitchen; appetite false → declined and finalized in the service batch; ineligible (carbohydrate ceiling) → finalized without penalty; guest flow unchanged (offer window still 30 service s).
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Decide simulated desserts at main service"`

### Task 14: Public view and the NPC planner

**Files:**
- Create: `lib/feud_hall/domain/public_view.ex`, `lib/feud_hall/domain/npc/planner.ex`
- Test: `test/feud_hall/domain/npc_planner_test.exs`

**Interfaces:**
- `PublicView.build(state) :: %{now, market: %{product => %{price, stock}}, stalls: [%{stall_id, restaurant_id, tier, open?, menu: %{recipe_id => price}}], demand: [summary]}` — a pure function of committed hall state; no rival cash, batches, orders, costs, or RNG.
- `Planner.plan(view :: map, own :: restaurant_map, profile :: map, catalog :: map, rng) :: {[action], rng}` where `action` is one of `{:open_stall, %{stall_id}}`, `{:unlock_recipe, ...}`, `{:set_menu_price, ...}`, `{:set_substitution_policy, ...}`, `{:submit_purchase_request, ...}`. Heuristics (builder's call, tunable via profile): open the stall when closed and the view's time is outside cleaning; unlock the cheapest locked recipe when cash ≥ 4 × its unlock cost; price each menu item at `suggested_price * price_permille / 1000`; set the profile's substitution policy on every line that has a substitute; request each product needed by the menu up to `restock_days` × the last summary's admitted trays' expected use, capped by storage, with a price limit of 1.5 × the published price.
- `Planner.choose_slot(view, layout, profile) :: slot_id` — the first vacant slot of `preferred_tier`, else of any tier by slot ID.

- [ ] **Step 1: Failing tests:** the planner's arity and argument list contain no hall state (assert `Planner.__info__(:functions)` and that `plan/5` works with a view built from a state whose rival restaurants hold sentinel cash/orders, and the sentinels appear nowhere in the inputs); each heuristic produces its action in a constructed view; identical inputs give identical outputs; `choose_slot` respects tier preference and vacancy.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Add the public view and the pure NPC planner"`

### Task 15: NPC bootstrap and planning slots

**Files:**
- Modify: `decider.ex`, `evolver.ex`, `command_workflow.ex`, `event_codec.ex`, `lib/feud_hall/infrastructure/hall_authority.ex`
- Test: `test/feud_hall/domain/npc_plan_test.exs`, `test/feud_hall/infrastructure/hall_authority_test.exs` (new `describe "NPCs"`)

**Interfaces:**
- `restaurant_created` with `owner_kind: :npc` also initialises `state.npcs[operator] = %{restaurant_id, profile_id, next_slot_at: next hall-hour boundary, rng: Random.new(Random.derive(seed, "npc:" <> operator))}`.
- Command `{:npc_plan, %{operator, slot, actions: [action], rng}}` from `{:npc, operator}` with command ID `"npc:#{operator}:#{slot}"`: valid only when `slot == latest hour boundary <= now` and `slot >= npcs[operator].next_slot_at`. The decider decides each action in order with ctx command ID `"npc:#{operator}:#{slot}:#{i}"`, evolving an intermediate state; a rejected action contributes no events. It emits `npc_planned %{operator, slot, next_slot_at: slot + hour, rng, outcomes: [:accepted | {:rejected, reason}]}` followed by the accepted actions' events — one atomic batch, one receipt.
- `HallAuthority`: after a successful `initialize_hall` commit, issues `create_restaurant` for each `npc_profiles` entry as `{:npc, profile.id}` with ID `"npc:#{id}:create"`, slot from `Planner.choose_slot/3`, name `"NPC #{id}"`. After each committed batch, for every NPC (sorted) with `next_slot_at <= hall.now`, builds the view, runs `Planner.plan/5`, and executes the `npc_plan` command; failures emit `:npc_planner_failed` diagnostics and do not stop the authority. Planning also happens during cleaning.

- [ ] **Step 1: Failing tests:**
  - domain: a plan with one valid and one invalid action commits atomically with outcomes `[:accepted, {:rejected, reason}]`; a second `npc_plan` for the same slot is `:slot_already_planned`; a stale slot is rejected; replaying the events reproduces the NPC state without calling the planner (planner module replaced by a flunking stub in the replay);
  - an identical `set_menu_price` from a principal and from an NPC produces identical restaurant state;
  - authority: initializing the hall creates three NPC restaurants in their preferred tiers; advancing 3 game hours produces exactly one `npc_planned` per NPC per crossed hour boundary (once at the latest crossed slot when several are crossed in one advance);
  - **(Review Focus 4)** an NPC with zero cash and empty storage commits a plan whose purchase actions are rejected with reasons, its `next_slot_at` advances, and the authority keeps running;
  - planning during cleaning commits.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** both files plus `recovery_test.exs` — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Bootstrap NPC owners and run their planning slots"`

### Task 16: Recovery invariants, codec, snapshots, and golden fixtures

**Files:**
- Modify: `lib/feud_hall/domain/hall/invariants.ex`, `lib/feud_hall/infrastructure/event_codec.ex`, `lib/feud_hall/infrastructure/snapshot.ex`
- Create: `test/fixtures/events/` (one JSON file per new event type), `test/feud_hall/infrastructure/event_fixtures_test.exs`
- Test: `test/feud_hall/domain/invariants_test.exs`, `test/feud_hall/application/recovery_test.exs`

**Interfaces:**
- `Invariants.check/1` adds: every pending request references a live restaurant and appears in `by_key`; market stock non-negative; stage queues reference live orders whose stage matches; counter item exists; `arrival_seq` and stats consistent; every PRNG state is an integer in 0..2^64-1; `next_arrival_at`, `next_clear_at`, and NPC `next_slot_at` are ≥ `now` or nil.
- Snapshot evolution version 3; older snapshots are incompatible (genesis fallback).
- Golden fixtures: for each event type added in Tasks 1–15, a JSON file holding one encoded event; the test decodes each, re-encodes it byte-identically, and evolves it onto a minimal state without error. Decoders for Milestone 1 and Project A events (including `stock_purchased`, `preparation_started`, `preparation_completed`) remain and keep their fixtures.

- [ ] **Step 1: Failing tests:** each new invariant detects a hand-corrupted state; recovery from a snapshot taken mid-day (pending requests, queued work, accumulator mid-hour, NPC slots) reproduces live state and resumes producing identical events to an uninterrupted run; every fixture round-trips; an evolution-2 snapshot is skipped as incompatible.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS, plus `snapshot_store_test.exs`, `hall_authority_test.exs`.
- [ ] **Step 3: Commit** — `git commit -m "Extend recovery checks, codec, snapshots, and event fixtures"`

### Task 17: Simulation diagnostics

**Files:**
- Modify: `lib/feud_hall/application/diagnostics.ex`, `lib/feud_hall/infrastructure/hall_authority.ex`
- Test: `test/feud_hall/application/diagnostics_test.exs`, `hall_authority_test.exs`

**Interfaces:**
- After each committed batch the authority emits (from the committed events only, never from intent): `:market_cleared` (`batch`, `fills`, `unfilled` counts), `:arrivals` aggregated per batch (`arrivals`, `admitted`, `left`), `:course_lifecycle` aggregated per batch (`stages_started`, `served`, `cancelled`), `:cleaning_boundary` (`:started | :ended`), `:npc_plan` (`operator`, accepted/rejected counts), and `:npc_planner_failed`. Allowlist adds those count fields and `operator`; no restaurant names, prices of individual guests, or payloads.

- [ ] **Step 1: Failing tests:** each record appears with only allowlisted fields after a scripted day; a sentinel restaurant name never appears; with an exporter whose export raises, hall state and receipts equal a run without diagnostics.
- [ ] **Step 2: Run** — FAIL; **implement**; **run** — PASS.
- [ ] **Step 3: Commit** — `git commit -m "Report market, arrival, kitchen, and NPC activity in diagnostics"`

### Task 18: Trace properties and oracles

**Files:**
- Modify: `test/support/hall_trace.ex`, `test/support/oracle.ex`, `test/feud_hall/properties/hall_trace_property_test.exs`, `test/feud_hall/properties/postgres_trace_property_test.exs`

**Interfaces:**
- `HallTrace.action/0` adds `{:request, idx, qty}`, `{:cancel_request, idx}`, `{:market_clear}` (macro: advance to the next clearing), `{:meal_peak}` (macro: advance through 12:00–13:00), `{:npc_slot}` (macro: advance to the next hour boundary and run each due NPC's plan through the planner), and keeps guest visits; the hall is initialised with NPCs so traces include them.
- Oracle adds market conservation (`initial + replenishments = fills + stock`), arrival accounting by source and reason, stage-queue consistency, and NPC slot monotonicity.
- Structural floors per run (both properties): at least one market clearing with a fill, one arrival admitted and one that left, one tray served by the automatic kitchen, one NPC plan committed.

- [ ] **Step 1:** Extend actions and oracles; run the M1 property and the PostgreSQL property with seeds 1..10 each — PASS; record floors, runtime, and peak RSS.
- [ ] **Step 2:** Show sensitivity: temporarily break market conservation (skip the stock decrement) and arrival accounting (drop a `left` count); each property fails; restore.
- [ ] **Step 3: Commit** — `git commit -m "Trace the market, diners, kitchen, and NPCs"`

### Task 19: Mutation cohort, architecture, docs, and evidence

**Files:**
- Modify: `scripts/mutation_cohort.exs`, `test/feud_hall/architecture_test.exs`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `AGENTS.md`, `docs/superpowers/specs/2026-11-09-milestone-2-design.md` (decisions settled while building)

- [ ] **Step 1: Architecture test:** `Npc.Planner` and `PublicView` may not reference `FeudHall.Domain.Hall.Decider`, `Evolver`, or `Admission` (the planner sees only its inputs); planted-violation case.
- [ ] **Step 2: Mutants** (exact current source strings; each killed by a named behavioural test): rotation tie-break fixed at 0 (`market_test`); price clamp removed (`market_test`); market stock not decremented (`market_flow_test`); arrivals during cleaning (quota not zeroed) (`arrivals_test`); exposure applied twice (`choice_test`); incompatible food allowed in choice (`choice_test`); handover allowed during cleaning (`automatic_kitchen_test`); queue kept across cleaning (`automatic_kitchen_test`); stage capacity bypassed (`automatic_kitchen_test`); consumed ingredients posted twice (`automatic_kitchen_test`); planner given full hall state (`npc_planner_test`); NPC slot not advanced (`npc_plan_test`); an event dropped from `day_closed` replenishment (`demand_forecast_test`). Run the cohort against `feud_hall_mutation` with RSS sampled; every curated mutant killed or any survivor reported and reviewed per Testing.
- [ ] **Step 3: Docs:** implementation status (modules, scheduling classes, temporary seams removed), testing entry points (new property actions, cohort), AGENTS start-here sentence; add any decisions settled while building to the design's "Decisions recorded" section (as a new Project B subsection).
- [ ] **Step 4: Evidence:** full suite `mix test --max-cases 1` for three seeds with combined RSS sampled (abort above 2 GiB); `mix format --check-formatted`; both `--warnings-as-errors` compiles. Report exact results.
- [ ] **Step 5: Commit** — `git commit -m "Guard the shared simulation with mutants and document it"`
