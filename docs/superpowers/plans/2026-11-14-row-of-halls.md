# Row of Halls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single hall into a row of ten square rooms of fifteen spots each that open in order, with location quality tied to position, a rent that rises as a class fills, and a scene that draws one room at a time.

**Architecture:** Room membership and the room rules are versioned catalog data (launch catalog version 3). A pure domain module, `Rooms`, derives which rooms are open and each class's rent quote from committed state; nothing new is stored, so the view and the lease check cannot disagree. Existing managed halls receive version 3 through the existing recorded `hall_catalog_expanded` event at start-up. The client replaces its computed placement with a fixed lookup from (room, position) to coordinates and draws the viewer's room in full, open neighbours simply, and shut doors for the rest.

**Tech Stack:** Elixir 1.x / Phoenix / Ecto (domain under `server/lib/feud_hall/domain`), StreamData property tests, Svelte 5, TypeScript, Three.js 0.187, Bun 1.4.4, Playwright with fast-check.

**Spec:** [docs/superpowers/specs/2026-11-13-livelier-hall-design.md](../specs/2026-11-13-livelier-hall-design.md), section "Project 2: Row of halls", plus its Goals, Non-goals, Anti-goals and "Existing contracts" sections. Read those and [AGENTS.md](../../../AGENTS.md) before starting any task.

## Global Constraints

- A **room** is one of the ten small halls. Player-facing text says "Hall 1" to "Hall 10" (Japanese: 「ホール1」 to 「ホール10」). "The hall" keeps meaning the whole economic place.
- Ten rooms, fifteen spots each, 150 spot IDs `s001`–`s150`. A spot's room and position never change. A stall never moves.
- Existing quality classes do not change: 40 quiet (`s001`–`s040`), 60 standard (`s041`–`s100`), 35 busy (`s101`–`s135`), 15 prime (`s136`–`s150`). Odd rooms hold 4 quiet, 6 standard, 3 busy, 2 prime; even rooms hold 4 quiet, 6 standard, 4 busy, 1 prime. Within a class, ascending spot IDs fill rooms in order.
- "Open" is derived from committed state and never stored: room 1 is always open; room *k*+1 is open when rooms 1..*k* are open and every spot of at least one class in rooms 1..*k* is leased; a room is also open when it or any later room holds a lease or a draft reservation (first-location offers are draft reservations). Drafts do not count as leased.
- A spot in a closed room cannot be reserved, leased, offered from the waiting list or chosen by a computer-run owner.
- Scarcity rent applies to new quotes only. A draft or offer holds the rent it was quoted until its existing deadline, and a lease records the rent it was quoted and keeps it. No existing lease, draft or accepted order changes terms.
- Proposed tuning, recorded in the catalog as `rules.rooms`: `%{version: 1, count: 10, per_room: 15, scarcity_cap_permille: 1_500, class_gap: 100}`. Base rents stay in `Management.rules/0` `lease_rates`.
- Rent arithmetic is integer minor units with one rounding rule: every division rounds down. The rent shown, quoted and recorded are the same number.
- The exposure factor does not change. Scarcity never changes how many diners pass a spot, and the hall-wide arrival pool does not grow because rooms open.
- The slice catalog (`id: "slice"`) is not changed: no room data, no room rule. It stays available for replay and focused tests.
- Events before the change replay under the old rule. Live, genesis-replay and snapshot-tail state agree at the same committed position.
- The domain stays pure: no Phoenix, Ecto, clocks or global configuration in `Rooms` or the catalog code.
- Queries do not write. Everything new in a view is derived from committed state.
- The scene emits intents only. Reserving and leasing go through the existing `submit(kind, payload)` use cases in `App.svelte`; there is no second submitting path.
- Every new string exists in English and Japanese with a stable key. Money crosses the wire as canonical decimal integer strings.
- The HTML list view, the no-WebGL fallback and phone layouts expose every action the 3D scene does.
- Never run `tsc`. Never run a whole test suite without a file name; run test files one at a time. Cap Node with `NODE_OPTIONS=--max-old-space-size=1536`. Server commands run from `server/`, client commands from `app/`.
- Frame bar, unchanged from Project 1: on this workstation the bench at `stalls=150&detail=0` delivers at least 29.5 frames per second with at most 5% late frames.
- Commit messages end, after a blank line, with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push.

## Review Focus

Each line names a condition the spec implies and the behaviour a person would expect. The test that pins it is in the task named.

1. **A hall that already has leases in later rooms when the rule arrives.** Those rooms and every room before them are open after the upgrade; nobody is evicted and no lease changes rent. (Task 4)
2. **A draft quoted at one rent while the class keeps filling.** The lease made from that draft records the draft's rent, not the higher current quote. (Task 3)
3. **A lease that opens the next room while someone is on the waiting list.** The waiting owner is offered a spot in the newly opened room in FIFO order, in the same batch. (Task 3)
4. **A hall whose stalls carry no room data** (slice halls, test halls, a client newer than its server). The client places them deterministically, fifteen to a room in stall-ID order, and nothing overlaps. (Task 6)
5. **The viewer is in a room that closes, or the selected stall disappears.** The camera moves to the highest open room at or below the one it was in; the view is never blank and never shows a closed room's inside. (Task 7)

---

## File Structure

Server (new):
- `server/lib/feud_hall/domain/content/room_layout.ex` — assigns a room and position to each spot of a 150-spot layout. Pure data.
- `server/lib/feud_hall/domain/hall/rooms.ex` — the room rule: which rooms are open, class counts, rent quotes.
- `server/test/feud_hall/domain/room_layout_test.exs`, `server/test/feud_hall/domain/rooms_test.exs`, `server/test/feud_hall/application/rooms_test.exs`.

Server (modified): `domain/content/launch_catalog.ex`, `domain/content.ex`, `domain/hall/management.ex`, `domain/hall/decider.ex`, `domain/hall/progression.ex`, `domain/hall/population.ex`, `domain/hall/catalog_expansion.ex`, `domain/public_view.ex`, `application/management.ex`, `infrastructure/hall_authority.ex`, `infrastructure/event_codec.ex`, `web/protocol.ex`, and the tests named in each task.

Client (modified): `app/src/hall-layout.ts` (placement becomes a lookup), `app/src/hall-shell.ts` (walls per room with doorways), `app/src/hall-scene.ts`, `app/src/HallScene.svelte`, `app/src/App.svelte`, `app/src/api.ts`, `app/src/i18n.ts`, `app/src/refusals.ts`, `app/src/bench/hall-bench.ts`.

Client (new): `app/test/browser/hall-rooms.spec.ts`. `app/test/browser/hall-layout.spec.ts` is rewritten.

Position indices, used by server and client alike, run clockwise from the north-west corner. The outside entrance is in the middle of the south wall; doorways to neighbouring rooms are in the middle of the west and east walls.

| index | where | kind |
| --- | --- | --- |
| 0, 6, 9, 12 | NW, NE, SE, SW corners | quiet |
| 1–5 | north wall, west to east | standard |
| 7, 8 | east wall, north and south of the doorway | busy |
| 10, 11 | south wall, east and west of the entrance | prime |
| 13, 14 | west wall, south and north of the doorway | busy |

Odd rooms have three busy spots, so position 13 holds a standard spot there. Even rooms have one prime spot, so position 11 holds a standard spot there.

---

### Task 1: Room layout data and launch catalog version 3

**Files:**
- Create: `server/lib/feud_hall/domain/content/room_layout.ex`
- Modify: `server/lib/feud_hall/domain/content/launch_catalog.ex` (`catalog/0`), `server/lib/feud_hall/domain/content.ex` (`layout_problems/1` near line 248, rules validation), `server/lib/feud_hall/infrastructure/event_codec.ex` (`@atoms`), `server/lib/feud_hall/web/protocol.ex` (atom lists near lines 13–16)
- Test: `server/test/feud_hall/domain/room_layout_test.exs`, `server/test/feud_hall/domain/launch_catalog_test.exs`, `server/test/feud_hall/infrastructure/event_fixtures_test.exs`

**Interfaces:**
- Produces: `FeudHall.Domain.Content.RoomLayout.assign(layout :: [%{slot_id: String.t(), tier: atom()}]) :: [%{slot_id:, tier:, room: 1..10, position: 0..14}]` and `RoomLayout.kind(room :: pos_integer(), position :: 0..14) :: :quiet | :standard | :busy | :prime` (the class a position holds in that room, per the table above).
- Produces: `LaunchCatalog.catalog/0` with `version: 3`, `layout: RoomLayout.assign(slice layout)`, `rules.rooms` exactly as in Global Constraints, and the `premium` profile's `preferred_tier: :standard`. Budget and mainstream profiles are unchanged.
- Produces: `Content.validate/1` accepts a layout without room data when `rules[:rooms]` is absent. When `rules.rooms` is present it reports `{:layout, :slot_without_room, slot_id}`, `{:layout, :room_out_of_range, slot_id}`, `{:layout, :position_out_of_range, slot_id}`, `{:layout, :duplicate_position, {room, position}}` and `{:rules, :rooms, key}` for a missing or non-positive rule value.

- [ ] **Step 1: Write the failing tests** in `room_layout_test.exs`:
  - `"each room holds its stated mix"`: for rooms 1..10, the tiers of `assign(layout)` filtered by room count to `%{quiet: 4, standard: 6, busy: 3, prime: 2}` for odd rooms and `%{quiet: 4, standard: 6, busy: 4, prime: 1}` for even rooms.
  - `"room 1 holds the lowest IDs of every class"`: its slot IDs are exactly `s001`–`s004`, `s041`–`s046`, `s101`–`s103`, `s136`, `s137`.
  - `"every spot has a distinct room and position"`: 150 distinct `{room, position}` pairs, rooms 1..10, positions 0..14.
  - `"a spot's class is the class of its position"`: for every entry, `tier == RoomLayout.kind(room, position)`; and `kind(1, 13) == :standard`, `kind(2, 13) == :busy`, `kind(1, 11) == :prime`, `kind(2, 11) == :standard`.
  - `"within a room a class fills its positions in ascending order"`: room 1 maps `s001→0, s002→6, s003→9, s004→12`, `s041..s045→1..5`, `s046→13`, `s101→7, s102→8, s103→14`, `s136→10, s137→11`; room 2 maps `s047..s051→1..5`, `s052→11`, `s104→7, s105→8, s106→13, s107→14`, `s138→10`.
  - `"tiers are untouched"`: `Enum.map(assign(l), &{&1.slot_id, &1.tier}) == Enum.map(l, &{&1.slot_id, &1.tier})`.
- [ ] **Step 2: Add to `launch_catalog_test.exs`**: version is 3; `Content.validate(LaunchCatalog.catalog()) == :ok`; `rules.rooms` equals the Global Constraints map; the premium profile prefers `:standard`; the slice catalog has no `rules[:rooms]` and no `:room` key in any layout entry. Add validation tests for each problem tuple listed under Interfaces (remove one spot's `:room`, set a room to 11, a position to 15, duplicate a pair, drop `scarcity_cap_permille`).
- [ ] **Step 3: Run** `mix test test/feud_hall/domain/room_layout_test.exs test/feud_hall/domain/launch_catalog_test.exs` — expect failures naming `RoomLayout` and version 3.
- [ ] **Step 4: Implement** `RoomLayout` and the catalog and validation changes. Room counts per class come from the odd/even mix; do not hardcode 150 spot IDs.
- [ ] **Step 5: Register codec atoms.** Add every new atom that can appear in a stored catalog or event (`room`, `position`, `rooms`, `count`, `per_room`, `scarcity_cap_permille`, `class_gap`, and any not already present) to `@atoms` in `event_codec.ex`; the catalog rides inside `hall_initialized` and `hall_catalog_expanded`. No tuples in catalog data.
- [ ] **Step 6: Add a codec test** in `event_fixtures_test.exs`: a `hall_initialized` event built from `LaunchCatalog.catalog()` survives encode then decode unchanged. Regenerate golden fixtures only if the existing fixture scenarios use the launch catalog; say in the report which files changed and why.
- [ ] **Step 7: Run** the three test files above plus `mix test test/feud_hall/domain/dietary_and_content_test.exs test/feud_hall/domain/layout_test.exs` — all pass.
- [ ] **Step 8: Commit** — "Give each launch spot a room and position".

### Task 2: The room rule

**Files:**
- Create: `server/lib/feud_hall/domain/hall/rooms.ex`
- Test: `server/test/feud_hall/domain/rooms_test.exs`

**Interfaces:**
- Consumes: `state.catalog.layout` entries with `:room`/`:position`, `state.catalog.rules[:rooms]`, `state.stalls` (leased spots, keyed by spot ID), `state.management.draft_by_stall`, `state.management.rules.lease_rates`.
- Produces, in `FeudHall.Domain.Hall.Rooms`:
  - `enabled?(state) :: boolean` — true when `state.catalog.rules[:rooms]` is a map.
  - `room(state, slot_id) :: pos_integer() | nil`.
  - `summary(state) :: %{open: pos_integer(), count: pos_integer(), classes: %{tier => %{leased: non_neg_integer(), total: pos_integer(), base_rent: integer(), rent: integer(), holding: integer()}}}` — computed once per call from committed state. When not enabled, returns `%{open: 0, count: 0, classes: ...}` with `rent` and `holding` equal to the base rates and `leased`/`total` counted over the whole layout.
  - `open?(state, slot_id, summary \\ nil) :: boolean` — true when not enabled, or when the spot's room is at most `summary.open`.
  - `quote(summary, tier) :: %{rent:, holding:, base_rent:, leased:, total:}`.
- Rule for `summary.open`: start at the highest room that holds a lease or a draft (at least 1); then, while it is below `count` and some class has every one of its spots in rooms 1..open leased, add one.
- Rule for a class's rent, with `cap = scarcity_cap_permille`, counting only spots in open rooms:
  - `raw = div(base * cap, 1000)` when `total <= 1` or `leased >= total - 1`; otherwise `raw = div(base * (1000 * (total - 1) + (cap - 1000) * leased), 1000 * (total - 1))`.
  - Prime's rent is its `raw`. Each lower class's rent is `min(raw, rent_of_next_class_up - class_gap)`, working down from prime.
  - `holding = div(base_holding * rent, base_rent)`.

- [ ] **Step 1: Write the failing example tests** (build states with a small helper that takes leased spot IDs and drafted spot IDs over `LaunchCatalog.catalog()` and `Management.rules()`):
  - `"room 1 is open in an empty hall"`: `summary.open == 1`, `count == 10`.
  - `"the last spot of a class opens the next room"`: leasing `s136` leaves `open == 1`; leasing `s136` and `s137` gives `open == 2`.
  - `"a draft does not count as leased"`: `s136` leased and `s137` drafted gives `open == 1`.
  - `"a surrender that reopens a class closes an empty next room"`: from `s136`, `s137` leased (`open == 2`), removing `s137` gives `open == 1`.
  - `"a lease or draft keeps its room and every earlier room open"`: a lone lease on `s009` (room 3) gives `open == 3`; a lone draft on `s005` (room 2) gives `open == 2`.
  - `"rooms open in a chain"`: leasing all quiet spots of rooms 1 and 2 (`s001`–`s008`) gives `open == 3`.
  - `"all ten rooms can open and no more"`: every spot leased gives `open == 10`.
  - Rent examples, room 1 only open: nothing leased gives rents `%{quiet: 8_000, standard: 10_000, busy: 15_000, prime: 22_000}`; `s001` leased gives quiet `9_333`; `s041`, `s042` leased gives standard `12_000`; `s136` leased gives prime `33_000` and holding `3_300`; `s001`–`s003` leased with standard untouched gives quiet `9_900` (clamped below standard's `10_000` by the gap) and holding `990`.
  - `"a room opening lowers new quotes"`: `s041`–`s046` leased gives `open == 2` and standard `12_727` (6 of 12).
  - `"not enabled means base rents and every spot open"` using the slice catalog.
- [ ] **Step 2: Write the failing properties** (StreamData, `max_runs: 200`): generate a set of leased spot IDs and a disjoint set of drafted ones.
  - `"open rooms are a prefix that covers every lease and draft"`: `1 <= open <= 10` and every leased or drafted spot's room is `<= open`.
  - `"class order is preserved"`: `quiet.rent < standard.rent < busy.rent < prime.rent`.
  - `"within fixed open rooms a class's quote never falls as it fills"`: lease one more vacant spot of a class in an open room; if `open` is unchanged, that class's `rent` is `>=` its previous value. Assert the property is not vacuous: at least a fifth of runs keep `open` unchanged.
  - `"rent stays between base and the cap, except where the gap holds it lower"`: `rent <= div(base_rent * 1500, 1000)` and `rent >= min(base_rent, rent_of_next_class_up - 100)` (prime: `rent >= base_rent`).
- [ ] **Step 3: Run** `mix test test/feud_hall/domain/rooms_test.exs` — fails with `Rooms` undefined.
- [ ] **Step 4: Implement** `Rooms`. One pass over the layout builds per-room, per-class totals; do not call `summary/1` from inside `open?/3` when a summary is supplied.
- [ ] **Step 5: Run** the test file — passes.
- [ ] **Step 6: Commit** — "Derive open rooms and scarcity rent from committed state".

### Task 3: Enforce the rule and quote the rent

**Files:**
- Modify: `server/lib/feud_hall/domain/hall/management.ex` (`lease_quote/2` near line 300, `offer_waitlist/1`, callers), `server/lib/feud_hall/domain/hall/decider.ex` (`create_restaurant` near lines 95–127), `server/lib/feud_hall/domain/hall/progression.ex` (`lease_location` near lines 72–112), `server/lib/feud_hall/domain/hall/population.ex` (`restore/2` near line 113), `server/lib/feud_hall/infrastructure/hall_authority.ex` (`create_npcs/1` near line 531), `server/lib/feud_hall/application/management.ex` (`available_slots/1` near line 286)
- Test: `server/test/feud_hall/application/rooms_test.exs` (new), `server/test/feud_hall/domain/npc_planner_test.exs`, `server/test/feud_hall/infrastructure/hall_authority_test.exs`, `server/test/feud_hall/application/management_test.exs`

**Interfaces:**
- Consumes: `Rooms.summary/1`, `Rooms.open?/3`, `Rooms.quote/2`.
- Produces: `Management.lease_quote(state, sid, summary \\ nil)` returns `nil` for a spot in a closed room; otherwise its `rent` and `holding` are the class quote, and it gains `base_rent`, `class_leased`, `class_total`, `room` and `position`. Those five extra keys are **not** copied into `stall_draft_reserved` or `stall_leased` events; `draft/3` and `lease_event/5` keep emitting exactly the fields they emit today.
- Produces: `decide` for `:create_restaurant` and `:lease_location` returns `{:error, :room_closed}` for a spot in a closed room, checked before occupancy.
- Produces: computer-run owners only ever choose among spots in open rooms (the layout passed to `Planner.choose_slot/3` is filtered; `choose_slot/3` itself is unchanged).
- Produces: after a `stall_leased` event the deciding function appends `Management.vacancy_events/1` evaluated on the post-lease state, so a waiting owner is offered a spot in a room that lease opened.

- [ ] **Step 1: Write the failing tests** in `application/rooms_test.exs`, all through the application boundary (the command workflow used by `management_test.exs`), on a managed launch hall:
  - `"a reservation in a closed room is refused"`: `reserve_stall` for `s005` returns `:slot_unavailable`; for `s004` it succeeds.
  - `"a computer-run owner cannot be placed in a closed room"`: `create_restaurant` as an NPC actor on `s138` returns `:room_closed`.
  - `"the last prime spot opens room 2 for everyone"`: after leases on `s136` and `s137`, `reserve_stall` for `s005` succeeds.
  - `"the lease records the rent it was quoted"`: reserve `s136` when prime is at base (`22_000`); lease `s137` through an NPC; confirm the first owner's restaurant; its `stall_leased` event and stored lease carry `rent: 22_000`, while a fresh quote for prime now differs. (Review Focus 2.)
  - `"an existing lease's rent is unchanged by later quotes"`: lease `s041` at `10_000`, then lease `s042`–`s045`; the first lease still has `rent: 10_000` and its next `operating_costs_charged` uses it.
  - `"a lease that opens a room offers it to the waiting list"`: an owner waits for `[:prime]` with room 1's prime spots taken or being taken; when the lease that fills prime commits, the same batch contains a `stall_draft_reserved` for `s138` for that owner. (Review Focus 3.)
  - `"offers keep FIFO order and are only made in open rooms"`: two waiting owners, one vacancy in an open room; the earlier one is offered it and no draft is made for a closed room.
  - `"a new hall's three computer-run restaurants stand in room 1"`: genesis NPCs hold `s001`, `s041`, `s042` with rents `8_000`, `10_000`, `11_000`.
  - `"removing the guard is noticed"`: tag `@tag :guard_sensitivity`; call the decision with a state whose `catalog.rules` has `:rooms` deleted and assert the same reservation for `s005` now succeeds. This shows the tests above depend on the rule and not on some other refusal.
- [ ] **Step 2: Write the failing property** `"nothing is ever placed in a room that was closed at that moment"`: generate up to 40 actions (reserve, confirm, cancel, NPC lease, surrender, advance past the draft deadline) over at least 6 owners; after each accepted batch, for every `stall_draft_reserved` and `stall_leased` in it, `Rooms.open?(state_before_batch_plus_earlier_events, stall_id)` held when that event was produced. Include a macro action "fill a class in the open rooms" and assert that at least a tenth of runs open room 2, so the property is exercised.
- [ ] **Step 3: Run** `mix test test/feud_hall/application/rooms_test.exs` — the examples fail because closed-room spots are still quotable and rents are base.
- [ ] **Step 4: Implement.** `available_slots/1` computes the summary once and passes it to each `lease_quote`. Filter the layout given to `Planner.choose_slot/3` in both `create_npcs/1` and `Population.restore/2`.
- [ ] **Step 5: Update the two existing expectations this rule changes**, and nothing else: the genesis-tier assertion in `hall_authority_test.exs` (near line 731) becomes `[:quiet, :standard, :standard]` for launch halls; any launch-catalog expectation of `s136` for the premium profile in `npc_planner_test.exs`. Slice-catalog expectations stay as they are.
- [ ] **Step 6: Run** `mix test test/feud_hall/application/rooms_test.exs`, then `test/feud_hall/application/management_test.exs`, `test/feud_hall/application/progression_test.exs`, `test/feud_hall/domain/npc_planner_test.exs`, `test/feud_hall/infrastructure/hall_authority_test.exs`, `test/feud_hall/domain/invariants_test.exs`, `test/feud_hall/architecture_test.exs`, one file at a time — all pass.
- [ ] **Step 7: Commit** — "Refuse closed rooms and quote scarcity rent".

### Task 4: Deliver the rule to existing halls

**Files:**
- Modify: `server/lib/feud_hall/domain/hall/catalog_expansion.ex` (`decide/2`)
- Test: `server/test/feud_hall/application/progression_test.exs` (catalog expansion tests near lines 81–180), `server/test/feud_hall/application/recovery_test.exs`, `server/test/feud_hall/application/rooms_test.exs`

**Interfaces:**
- Consumes: `LaunchCatalog.catalog/0` version 3, the existing start-up path in `server/lib/feud_hall/web/bootstrap.ex` (it already issues `{:expand_catalog, %{catalog: catalog}}` with command ID `"web-launch-catalog:#{version}"` when the pinned launch version is lower; it needs no change).
- Produces: `CatalogExpansion.decide/2`, when the incoming launch catalog has `rules.rooms`: each pinned layout entry gains the `room` and `position` of the same `slot_id` in the launch layout and keeps its pinned `tier`; `rules.rooms` is the pinned value if one exists, else the launch value; each pinned computer-run profile takes `preferred_tier` from the launch profile with the same `id` and keeps everything else. A pinned spot ID absent from the launch layout makes validation fail with `{:invalid_content, problems}` and no event is emitted. The event stays `hall_catalog_expanded` with the same fields.

- [ ] **Step 1: Write the failing tests:**
  - `"a version 2 launch hall gains rooms once"`: build a managed hall pinned to a version 2 launch catalog (construct it by taking version 3 and removing `rules.rooms`, the layout's `room`/`position`, and restoring `preferred_tier: :prime`), expand with version 3: one `hall_catalog_expanded`; afterwards `Rooms.enabled?` is true, the layout tiers are unchanged, the premium profile prefers `:standard`; expanding again returns `:catalog_expansion_unavailable`.
  - `"leases in later rooms survive the upgrade"`: before the upgrade lease `s020` (room 5) and `s150` (room 10); after it `Rooms.summary(state).open == 10`, both leases have the rent they had, and reserving `s040` (room 10) succeeds. (Review Focus 1.)
  - `"events before the upgrade replay under the old rule"`: record a history that reserves `s005` (room 2) before the upgrade and has that draft still live across it, then expands; replaying the history from genesis yields the same state as live, including the draft; and after the upgrade a new `reserve_stall` for `s009` (room 3) is refused while `s006` (room 2, kept open by the draft) succeeds.
  - `"live, genesis replay and snapshot tail agree"`: at the position just after the upgrade and again ten events later, compare the three states for equality. Include a snapshot taken at the head position (empty tail).
  - `"a pinned spot outside the launch layout stops the upgrade"`: add `%{slot_id: "x999", tier: :quiet}` to the pinned layout; `decide` returns `{:error, {:invalid_content, problems}}` and `problems` names `x999`.
  - In `recovery_test.exs`: a sampled PostgreSQL restart across the upgrade recovers the same state and does not emit a second `hall_catalog_expanded`.
- [ ] **Step 2: Run** the named tests — fail because the expansion keeps the old layout and rules.
- [ ] **Step 3: Implement** the merge in `CatalogExpansion.decide/2`. `evolve/2` needs no change: `Rooms` reads the catalog.
- [ ] **Step 4: Run** `mix test test/feud_hall/application/progression_test.exs`, `test/feud_hall/application/recovery_test.exs`, `test/feud_hall/application/rooms_test.exs`, `test/feud_hall/infrastructure/event_fixtures_test.exs`, one at a time — pass.
- [ ] **Step 5: Commit** — "Upgrade existing halls to rooms through the catalog expansion".

### Task 5: Rooms in the views

**Files:**
- Modify: `server/lib/feud_hall/domain/public_view.ex` (`stalls/1` near line 42), `server/lib/feud_hall/application/management.ex` (`view/3` hall keys near lines 110–127, `available_slots/1`, `encode_lease/1` near line 295), `server/lib/feud_hall/web/protocol.ex`, `app/src/api.ts` (`Stall`, `Slot`, `View["hall"]`), `app/src/refusals.ts`, `app/src/i18n.ts`
- Test: `server/test/feud_hall/application/rooms_test.exs`, `server/test/feud_hall/domain/npc_planner_test.exs` (public view section), `app/test/browser/journeys.spec.ts` is not changed

**Interfaces:**
- Produces in `GET /api/state`:
  - each `hall.stalls[]` entry gains `room` and `position` (integers) when rooms are enabled, and omits both otherwise;
  - `hall.rooms`: `{"count": 10, "open": k}` when enabled, absent otherwise;
  - `hall.vacancies`: for every vacant, unreserved spot in an open room, `{stall_id, tier, room, position, exposure, rent, holding, setup_fee, base_rent, class_leased, class_total}` with money as decimal integer strings; absent when rooms are not enabled;
  - `profile.slots[]`, `profile.draft` and `profile.waitlisted` entries gain `room`, `position`, `base_rent`, `class_leased`, `class_total`. A draft's `rent` is the rent held by the draft; its `base_rent` and class counts are current.
- Produces: the refusal code `room_closed` reaches the client as a stable code; `app/src/refusals.ts` maps it to the key `refusalRoomClosed` ("That hall isn't open yet." / 「そのホールはまだ開いていません。」).
- Produces in `app/src/api.ts`: `Stall.room?: number; Stall.position?: number`; `Slot` gains `room?: number; position?: number; base_rent?: Money; class_leased?: number; class_total?: number`; `type Vacancy = Slot`; `View["hall"].rooms?: { count: number; open: number }`; `View["hall"].vacancies?: Vacancy[]`.

- [ ] **Step 1: Write the failing server tests** in `application/rooms_test.exs`: the view of a new launch hall has `rooms == %{count: 10, open: 1}`; its three stalls carry `room: 1` and positions `0`, `1`, `2`; `vacancies` has exactly 12 entries, all `room: 1`, none of `s001`, `s041`, `s042`, and none reserved; the `s043` vacancy shows `rent: "12000"`, `base_rent: "10000"`, `class_leased: 2`, `class_total: 6` (two of six standard spots are leased); a slice hall's view has no `rooms` or `vacancies` key and its stalls have no `room`; the view function performs no write (state position unchanged). Add one test that the computer-run planner's view and `vacancies` name the same vacant spots.
- [ ] **Step 2: Run** `mix test test/feud_hall/application/rooms_test.exs` — the new tests fail.
- [ ] **Step 3: Implement** the server view fields, computing `Rooms.summary/1` once per view. Then the client types, the refusal mapping and both translations.
- [ ] **Step 4: Run** the server test file and `mix test test/feud_hall/architecture_test.exs`; from `app/`, `bun run format:check`, `bun run lint`, `bun check`.
- [ ] **Step 5: Commit** — "Show rooms, vacancies and rent quotes in the views".

### Task 6: Fixed room layout on the client

**Files:**
- Modify: `app/src/hall-layout.ts`
- Rewrite: `app/test/browser/hall-layout.spec.ts`; modify `app/test/browser/hall-navigation.spec.ts` (its first test)

**Interfaces:**
- Removes: `nextPerimeter`, `nextStallSlot`, `hallLayout`, `layoutStalls`, `StallSlot`, the island constants. Keeps: `toHall`, `toStall`, `stallBlocks`, `STAFF_SPOTS`, `QUEUE_SPOTS`, `COUNTER_TRAY`, `PICKUP_SPOT`, `TAKE_MS`, `collectMs`, `collectTray`.
- Produces:
  - `ROOM_COUNT = 10`, `SPOTS_PER_ROOM = 15`, `ROOM_SIDE` (interior side of a room, in scene units), `DOOR_WIDTH`, `ENTRANCE_WIDTH`.
  - `type Spot = { room: number; position: number }` and `type StallPlacement = Spot & { x: number; z: number; yaw: number }`.
  - `roomCentre(room: number): { x: number; z: number }` — rooms run along +x; room 1 is centred on the origin.
  - `spotPlacement(room: number, position: number): StallPlacement` — a fixed lookup. Corner spots face the room's centre diagonally; wall spots face straight out from their wall.
  - `positionKind(room: number, position: number): "quiet" | "standard" | "busy" | "prime"` — the table in File Structure.
  - `assignSpots(stalls: { stall_id: string; room?: number; position?: number }[]): Map<string, Spot>` — uses the server's room and position when present on every stall; otherwise sorts by `stall_id` and gives stall *i* room `floor(i / 15) + 1`, position `i % 15`.
  - `roomAt(x: number, z: number): number | null` — the room whose interior contains the point.
  - `walkable(x: number, z: number, openRooms: number, placements: Iterable<StallPlacement>): boolean` — inside an open room and not inside a booth, or inside the doorway between two open rooms. The outside entrance is not walkable through.
  - `walkingEntrance(stalls: { id: string; open: boolean; placement: StallPlacement }[], selected: string, room: number): { stall: string; position: { x: number; z: number }; target: { x: number; z: number } }` — an eye-level starting point inside `room`, facing an open counter there if any.
  - `tableSpots(room: number): { x: number; z: number; yaw: number }[]` — at least six table positions in the middle of the room, clear of every queue and of the lines between doorways and the entrance.
- Proposed dimensions, the builder may adjust within the tests below: `ROOM_SIDE = 30`, `DOOR_WIDTH = 4`, `ENTRANCE_WIDTH = 5`, rooms pitched `ROOM_SIDE + 0.5` apart.

- [ ] **Step 1: Write the failing pure tests** in `hall-layout.spec.ts` (title prefix `rooms:`):
  - `"150 spots have 150 distinct placements inside their own room"`: for all rooms and positions, placements are pairwise distinct, `roomAt(x, z) === room`, and every booth corner (the `stallBlocks` box: local `|x| < 1.92`, `-1.27 < z < 1.44`) lies inside the room.
  - `"no two booths or queues overlap"`: for every pair in a room, the two booth boxes extended to local `z = 2.9` (the queue) do not intersect.
  - `"doorways and the entrance are clear"`: no booth box or queue comes within `DOOR_WIDTH / 2` of the centre line of either doorway or within `ENTRANCE_WIDTH / 2` of the entrance's.
  - `"every counter faces into its room"`: the point 3 units in front of each counter is closer to the room's centre than the counter is.
  - `"quality follows position"`: `positionKind` equals the table for odd and even rooms; the two positions nearest the entrance are 10 and 11; the four nearest a doorway are 7, 8, 13, 14; the four nearest a corner are 0, 6, 9, 12.
  - `"the room mix matches the catalog"`: counting `positionKind` over a room gives 4/6/3/2 for odd rooms and 4/6/4/1 for even.
  - `"stalls without room data are placed fifteen to a room in ID order"` (Review Focus 4): fast-check over 0..150 arbitrary distinct IDs: distinct spots, at most 15 per room, rooms used are a prefix, and the result is the same for any input order. With room data present on every stall it is returned unchanged.
  - `"walking stays inside open rooms"`: fast-check points: `walkable` is false outside every room, false inside a booth, false in a room above `openRooms`, true at each open room's centre, true in the middle of the doorway between rooms 1 and 2 when `openRooms >= 2` and false there when `openRooms === 1`.
  - `"tables stand clear"`: every `tableSpots` entry is `walkable`-adjacent (not inside a booth), at least 2.5 from any queue spot, and at least 2 from the three centre lines.
  - `"coordinates round trip"`: keep the existing `toHall`/`toStall` property.
- [ ] **Step 2: Rewrite the first test of `hall-navigation.spec.ts`** to use `walkingEntrance(..., room)` over every room with 0..15 stalls: the point is `walkable`, at least 4 and at most 6 units in front of the counter it faces, and inside `room`.
- [ ] **Step 3: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser hall-layout.spec.ts --grep 'rooms:'` — fails on missing exports. (The scene does not compile against the new module until Task 7; run only the pure tests here.)
- [ ] **Step 4: Implement** the lookup. Keep the old exports as thin deprecated re-exports only if needed to keep `hall-scene.ts` compiling until Task 7 lands; Task 7 deletes them.
- [ ] **Step 5: Run** the pure tests and `bun check` — pass.
- [ ] **Step 6: Commit** — "Place stalls by room and position".

### Task 7: The scene draws rooms

**Files:**
- Modify: `app/src/hall-shell.ts`, `app/src/hall-scene.ts`, `app/src/bench/hall-bench.ts`
- Test: `app/test/browser/hall-rooms.spec.ts` (new), `app/test/browser/people-scene.spec.ts`, `app/test/browser/hall-navigation.spec.ts`

**Interfaces:**
- Consumes: Task 6's layout module; `Stall.room`/`position`, `hall.rooms`, `hall.vacancies` from Task 5.
- Produces in `hall-shell.ts`: `createHallShell(scene, redraw)` returns `{ show(rooms: { room: number; detail: "full" | "simple" }[], openRooms: number), update(camera), dispose() }`. Each shown room has four walls with a gap of `ENTRANCE_WIDTH` in the south wall and `DOOR_WIDTH` gaps toward neighbours that exist; a gap toward a closed room, and the entrance, is filled with a shut door. End rooms have a blank wall in place of the missing doorway. `resize` is removed.
- Produces in `hall-scene.ts`:
  - `Appearance` gains `rooms: { count: number; open: number }` and `vacancies: { stall_id: string; tier: string; room: number; position: number }[]`.
  - `Counter.placement` comes from `spotPlacement(assignSpots(...))`; the "first free scene slot" logic, `floorSignature` rescaling and island floors are removed. `Counter.index` stays as a stable per-stall number for animation phase only.
  - The scene has a current room. Stalls, staff, queues and departures are drawn for the current room at the existing detail rule, for open rooms directly adjacent at reduced detail (`detailed = false`), and not at all for other rooms.
  - Returned object gains `room(): number` and `showRoom(room: number): void` (moves the camera to that room's overview; ignored for a closed room). `focus(id)` moves to the stall's room first. `reset()` frames the current room.
  - `Actions` gains `room(room: number): void`, called whenever the current room changes (including by walking through a doorway), and `vacancy(stallId: string): void`, called when a "to let" bay is selected.
  - The host element carries `data-hall-room` (current room) and keeps `data-hall-people`.
  - A vacant spot in a shown open room is an open bay with a "to let" sign (text supplied through `Appearance.toLetLabel: string`), selectable by pointer and included in the keyboard order after the room's stalls.
  - Each shown room's centre has tables and seats as instanced scenery at `tableSpots(room)`.
- Walking uses `walkable(x, z, appearance.rooms.open, placements)`; crossing a doorway changes the current room. Orbit limits are set per room so the overview frames one room.

- [ ] **Step 1: Write the failing browser tests** in `hall-rooms.spec.ts` (`launch: true`), routing `/api/state` to add stalls and rooms where a real hall cannot easily be driven there:
  - `"a new hall shows Hall 1 with its three stalls and twelve to-let bays"`: `data-hall-room="1"`; the accessible list of scene targets names three stalls and twelve bays.
  - `"only the current room and open neighbours are drawn"`: with stalls in rooms 1, 2 and 3 and `rooms.open = 3`, in room 1 the people count covers rooms 1 and 2 only (room 2 at one owner, one worker, one queued diner per open stall); after `showRoom(3)` it covers rooms 2 and 3.
  - `"a closed room is not entered"`: with `rooms.open = 1`, walking east from room 1's centre stops at the wall and `data-hall-room` stays `1`; with `rooms.open = 2` the same walk ends with `data-hall-room="2"`.
  - `"the camera leaves a room that closes"` (Review Focus 5): in room 3, the next state has `rooms.open = 2`; `data-hall-room` becomes `2` and the canvas is not blank (more than 15% non-background pixels).
  - `"selecting a stall in another room moves there"`: selecting a room 2 stall from the list sets `data-hall-room="2"`.
  - `"a stall never moves"`: a stall's on-screen position in a fixed camera is identical before and after other stalls are added and removed.
  - `"150 stalls across ten rooms render"`: with 150 synthetic stalls and `rooms.open = 10`, each room shown in turn has 15 selectable stalls and a canvas more than 15% non-background. This replaces the old test that rendered 150 stalls on a ring and islands.
- [ ] **Step 2: Update `people-scene.spec.ts`** so its counts are stated per room (the launch hall's three stalls are all in room 1; the assertions of 6 then 12 should hold unchanged; if the overview distance changed, assert the same two facts by `showRoom(1)` then selecting an owned stall). Update the remaining `hall-navigation.spec.ts` tests to the new `walkingEntrance` signature without weakening what they assert.
- [ ] **Step 3: Run** `hall-rooms.spec.ts` after a build — fails.
- [ ] **Step 4: Implement** shell, scene and bench. The bench gives stall *i* `room` and `position` through the fallback and gains a `room=<1..10>` parameter (default 1) and `rooms=<1..10>` open count (default 10); its result JSON gains `room`.
- [ ] **Step 5: Run**, one at a time after `NODE_OPTIONS=--max-old-space-size=1536 bun run --bun build`: `hall-rooms`, `hall-layout`, `hall-navigation`, `people-scene`, `people`, `tray-pickup`, `hall-interactions`, `owner-view`, `visitor-play`, `phone-layout`, `launch` spec files. Fix what this task broke; report anything else.
- [ ] **Step 6: Look at it.** With the dev server and the screenshot driver from Project 1's report, capture room 1 of a new hall, a full room, and the doorway view into an open and a closed neighbour. Confirm by eye: walls, doors, entrance, bays with signs, tables, no stall in a doorway.
- [ ] **Step 7: Commit** — "Draw the hall as a row of rooms".

### Task 8: Room control, selection and the grouped list

**Files:**
- Modify: `app/src/HallScene.svelte`, `app/src/App.svelte` (hall page: mode toggle near line 2255, list near lines 2426–2464, side inspector near line 2354, phone picker near line 2269), `app/src/i18n.ts`, `app/src/style.css`
- Test: `app/test/browser/hall-rooms.spec.ts`, `app/test/browser/phone-layout.spec.ts`

**Interfaces:**
- Consumes: `hall.room()`, `hall.showRoom(n)`, `Actions.room`.
- Produces: a labelled group "Halls" below the scene with one button per open room ("Hall 1"…), the current one marked `aria-pressed="true"`, and closed rooms shown as disabled buttons with the reason "Opens when a class of spots is full" as accessible description. Keys `[` and `]` with the scene focused move to the previous and next open room.
- Produces: `HallScene.svelte` props `rooms`, `vacancies`, `room` (bindable current room), `onVacancy(stallId)`.
- Produces: the HTML list view groups stall cards under a heading per room ("Hall 2 · 4 stalls"), lists only rooms that are open, and under each open room shows its vacant spots as cards with class, rent and a "View spot" button. The Location pickers (desktop and phone) group options by room with `<optgroup label="Hall N">`.
- Produces: an owner's first view frames the room of their first stall; a visitor's frames room 1. The saved camera (`CameraState`) gains `room?: number` and restores it.
- New i18n keys in English and Japanese: `hallRoom` ("Hall {n}" / 「ホール{n}」), `hallRooms`, `hallRoomClosed`, `hallRoomStalls`, `toLet` ("To let" / 「貸店舗」), `viewSpot`.

- [ ] **Step 1: Write the failing tests** in `hall-rooms.spec.ts`: the Halls group has ten buttons, one pressed, nine disabled in a new hall; clicking "Hall 2" when open sets `data-hall-room="2"` and moves `aria-pressed`; `]` does the same from the keyboard; with the list view selected, headings "Hall 1" and "Hall 2" each contain their stalls and vacant spots and no closed room appears; with WebGL unavailable (the existing technique in the suite for forcing `onUnavailable`) the grouped list offers the same "View spot" action; returning to the hall page restores the room last viewed; switching language to Japanese shows 「ホール1」.
- [ ] **Step 2: Add to `phone-layout.spec.ts`**: at phone width the Halls group and the grouped picker are reachable and the room buttons are at least 44 px tall.
- [ ] **Step 3: Run** — fails. **Step 4: Implement.** **Step 5: Run** `hall-rooms`, `phone-layout`, `hall-interactions`, `launch` files one at a time, plus `bun run format:check`, `bun run lint`, `bun check`.
- [ ] **Step 6: Commit** — "Add the room control and group the list by hall".

### Task 9: "To let" bays and the rent explanation

**Files:**
- Modify: `app/src/App.svelte` (first-business form near lines 2488–2550, expansion form near lines 2752–2829, `expansionEstimate` near line 499, hall inspector), `app/src/HallScene.svelte`, `app/src/i18n.ts`
- Test: `app/test/browser/hall-rooms.spec.ts`, `app/test/browser/journeys.spec.ts` (only if an existing assertion on a rent string changes)

**Interfaces:**
- Consumes: `hall.vacancies`, `profile.slots`, `profile.draft`, `Actions.vacancy`, the existing `submit("reserve_stall", { stall_id })`, `submit("create_restaurant", …)`, `submit("lease_location", …)`, and the existing draft state `chosenSlot` / `expansionStallId`.
- Produces: selecting a bay (in the scene or by "View spot" in the list) opens a spot panel in the hall inspector showing class, exposure, rent, holding fee and set-up fee from the vacancy, and one line from `rentExplanation(slot)`.
- Produces: `rentExplanation(slot: Slot): string` in `App.svelte`'s script (or a small module if it needs a unit test): when `rent > base_rent`, key `rentScarcity` with typed parameters ("{leased} of {total} {tier} spots are taken, so rent is {percent}% above the usual {base}." / Japanese equivalent); when equal, key `rentUsual` ("The usual rent for a {tier} spot."). `percent` is `floor((rent - base) * 100 / base)` computed with `BigInt` on the decimal strings.
- Produces: the same line under every rent shown: both location forms, the expansion estimate and break-even block, and a held draft (for a draft: key `rentHeld`, "Held at this rent until {time}.").
- Produces: the panel's action. If the viewer's `profile.slots` contains the spot: for an owner with no business, "Reserve this spot" sets `chosenSlot` and calls the existing first-business submit path; for an owner who can expand, "Lease this spot" sets `expansionStallId` and opens the existing expansion form with that spot chosen. Otherwise the panel explains why not, reusing existing keys (no profile, no licence, location limit reached).
- New i18n keys, both languages: `rentScarcity`, `rentUsual`, `rentHeld`, `spotPanelTitle`, `reserveThisSpot`, `leaseThisSpot`.

- [ ] **Step 1: Write the failing tests** in `hall-rooms.spec.ts`:
  - `"leasing from a to-let bay"`: an invited owner with no business selects the bay at `s043`, sees "Standard", the rent `$120.00` and "2 of 6 standard spots are taken, so rent is 20% above the usual $100.00.", presses "Reserve this spot", and the first-business form shows `s043` reserved with "Held at this rent until …"; exactly one `reserve_stall` command was sent, with a command ID the form's own retry would reuse.
  - `"the lease list and the bay agree"`: for every vacancy the list's rent text equals the bay panel's.
  - `"a visitor sees the bay but cannot reserve it"`: the panel shows class and rent and the existing "create a profile" explanation; no reserve button.
  - `"the expansion estimate explains its rent"`: an owner with one stall opens the expansion form on a scarce class; the estimate block contains the scarcity line and the break-even figure uses the quoted rent.
  - `"Japanese shows the same numbers"`: the line renders in Japanese with the same figures.
  - `"a spot taken while the panel is open"`: the next state drops the vacancy; the panel says the spot is no longer available (existing `slot_unavailable` wording) and offers no action.
- [ ] **Step 2: Run** — fails. **Step 3: Implement.** No new command kinds, no new fetch.
- [ ] **Step 4: Run** `hall-rooms`, `journeys`, `launch`, `participation`, `phone-layout` files one at a time, plus format, lint and `bun check`.
- [ ] **Step 5: Commit** — "Offer vacant spots from the hall and explain their rent".

### Task 10: Measure, document, and check the whole

**Files:**
- Modify: `docs/GAME_DESIGN.md` (§6 "Location quality and lease pricing" near line 278 and "Admission and dormant leases" near line 301; §14 near line 996; §15 "Visual language"; "Required correctness scenarios" near line 1426; §21 tuning register near line 1568), `docs/ARCHITECTURE.md` (the hall presentation paragraph near line 414 and "Implementation status" near line 1080), `docs/TESTING.md` (bench parameters; new test files), `AGENTS.md` ("Start here" paragraph: launch catalog version 3 and rooms)
- Create: `docs/superpowers/reports/2026-11-14-row-of-halls.md`

- [ ] **Step 1: Measure.** With the method in `docs/superpowers/reports/2026-11-13-people-frame-time.md` (headless Chromium, Metal), run `stalls=150&rooms=10&room=5&detail=0`, `...&detail=1`, and `...&near=1&detail=1`, each twice, 20 seconds; record people, frames, fps, late share, mean and p95 draw time in the new report with the commit measured. State pass or fail against the bar in Global Constraints. If it fails, simplify adjacent rooms first and re-measure; record what changed.
- [ ] **Step 2: Document the rules** in the game design: rooms and the opening rule; quality by position with the odd/even mix; the closed-room lease rule and that the newcomer vacancy reserve is still not implemented; scarcity rent replacing "published fixed tiers", with the formula, rounding rule, cap, class gap and worked figures from Task 2's tests; computer-run spot choice (open rooms only; premium prefers standard); the look of rooms, doors, bays and tables. Mark owner decisions and proposed tuning as the spec does. Add correctness scenarios matching Task 2–4's tests. Update the tuning register (`scarcity_cap_permille`, `class_gap`, rooms and spots per room).
- [ ] **Step 3: Document the mechanics** in the architecture: `Rooms` as derived state, the view fields, delivery through `hall_catalog_expanded` version 3, client lookup and fallback. Update Testing and AGENTS.md entry points. Check every link added resolves.
- [ ] **Step 4: Run the checks**, one at a time. Server, from `server/`: `mix format --check-formatted`; each test file named in Tasks 1–5; `test/feud_hall/properties/hall_trace_property_test.exs`. Client, from `app/`: `bun run format:check`, `bun run lint`, `bun check`, a build, then every spec file in `app/test/browser/`, each run on its own by file name, with each result recorded in the report. (Running every file singly is this plan's bounded stand-in for the full suite, which the project rules leave to hosted CI.) Say plainly which server suites were not run.
- [ ] **Step 5: Try the upgrade on a copy of a real hall.** Create a copy of the owner's `feud_hall_management` database under a new name with `createdb -T`, start the server against the copy on another port with the same secret, and confirm in the log exactly one `hall_catalog_expanded`, that existing stalls kept their spots and rents, and that the hall page shows Hall 1. Drop only the copy afterwards. Do not start the server against `feud_hall_management` itself; that is the owner's step.
- [ ] **Step 6: Commit** — "Document and measure the row of halls".
