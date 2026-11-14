# Visible Diners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the hall's real diners: people walk in past a stall or two and join the queue the server put them in, served diners carry their tray to a table and eat, and diners who leave without buying are seen leaving.

**Architecture:** The public hall view gains today's arrival totals and the kitchen's queue limit. A new pure client module, `diner-floor.ts`, turns the change in counts between two snapshots into figures and owns every diner on the floor from entrance to exit; it has no Three.js scene, no clock and no DOM, so it is tested as a model. `hall-scene.ts` stops keeping its own queue and departure lists and draws what the floor model reports.

**Tech Stack:** Elixir / Phoenix (view only, no rule change), Svelte 5, TypeScript, Three.js 0.187, Bun 1.4.4, Playwright with fast-check.

**Spec:** [docs/superpowers/specs/2026-11-13-livelier-hall-design.md](../specs/2026-11-13-livelier-hall-design.md), section "Project 3: Visible diners", plus its Goals, Non-goals, Anti-goals and "Existing contracts" sections. Read those and [AGENTS.md](../../../AGENTS.md) before starting any task.

## Global Constraints

- **Truthfulness.** Every drawn diner is staged from a diner the server committed. The client may delay, route, simplify and thin; it never adds a figure. No figure appears without a count change that accounts for it.
- Staging is count-true, not identity-true. The client never learns which diner is which.
- The "orders waiting" number on each stall is the server's `activity.waiting`, shown exactly at all times. Nothing in this project changes how that number is displayed.
- Walk-outs are staged from the change in **arrivals minus admitted**, never from the "left" total.
- The public view carries totals only: `arrivals`, `admitted`, `left` as three integers. Reasons for leaving and per-stall counts of lost diners stay out of every public payload.
- No server rule changes. No event, command, catalog version or stored field is added. The view is derived from committed state and a query writes nothing.
- From 03:00 to 05:00 hall time (the view's `access` is not `"open"`) the floor is empty.
- Tables are scenery. A full table never blocks, delays or changes a sale; a served diner with no free seat leaves as diners do today.
- Loading, reconnecting or returning to a hidden tab starts from the current counts: no replay and no burst of figures.
- Reduced motion (`Appearance.motion` false): nothing walks and eaters are static. Reduced detail (`Appearance.detail` false): browsing walks are skipped and eaters are static.
- A served diner eats for `EAT_MS = 60_000` milliseconds of real time.
- A diner bound for a stall enters by that stall's room entrance (middle of the south wall). Leavers are spread across open rooms' entrances deterministically.
- Looks stay deterministic: a figure's look is `personLook(serial, "diner")` with a serial derived from stable identifiers and a counter, never from `Math.random` or the clock.
- The model module is pure: `diner-floor.ts` imports no `three` scene objects, reads no clock (`now` is always a parameter) and touches no DOM.
- Client animation never awards money, finishes work or implies an uncommitted purchase.
- The HTML list view, the no-WebGL fallback and phone layouts are not changed by this project and must keep working.
- Never run `tsc`. Never run a whole test suite without a file name; run test files one at a time. Cap Node with `NODE_OPTIONS=--max-old-space-size=1536`. Server commands run from `server/`, client commands from `app/`. Check `df -m /System/Volumes/Data | tail -1` before each browser run and stop if under 1000 MB free. Never run two heavy commands at once.
- Frame bar, unchanged: on this workstation the bench at `stalls=150&detail=0` delivers at least 29.5 frames per second with at most 5% late frames, now with the floor populated.
- Commit messages end, after a blank line, with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push.

## Review Focus

Each line names a condition the spec implies and the behaviour a person would expect. The test that pins it is in the task named.

1. **A long gap between snapshots** (hidden tab, lost connection, laptop asleep) during which hundreds of diners arrived. On return the queues match the counts at once and nobody floods through the entrance. (Task 4)
2. **Midnight.** Today's totals drop to zero. No walk-outs are staged from the drop, and the first arrivals after it are staged normally. (Task 4)
3. **A server that sends no totals or queue limit** (an older server, a slice hall, the bench). Queues are still staged from each stall's waiting count, up to four as today, and no walk-outs are drawn. (Tasks 4 and 5)
4. **A stall or room that goes away while its diners are on the floor** (lease ended, stall list changed, the hall has fewer open rooms). Its figures are removed without an error and the counts for other stalls are unaffected. (Task 4)
5. **A diner served before their figure reaches the queue**, and a waiting count that falls and rises in one snapshot. The figure turns to the counter from where it is; the number of figures bound for a stall never exceeds its waiting count. (Task 4)

---

## File Structure

Server (modified): `server/lib/feud_hall/domain/public_view.ex` (today's totals), `server/lib/feud_hall/application/management.ex` (hall view carries them and the queue limit), `server/test/feud_hall/application/management_test.exs`, `server/test/feud_hall/domain/public_view_test.exs` (create if absent).

Client (new):
- `app/src/diner-floor.ts` — the floor model: which diners exist, what each is doing, where each is at a given time.
- `app/test/browser/diner-floor.spec.ts` — model tests.
- `app/test/browser/visible-diners.spec.ts` — browser regressions.

Client (modified):
- `app/src/people.ts` — seated pose.
- `app/src/room-layout.ts` — seats, entrances, routes.
- `app/src/hall-layout.ts` — queue spots beyond four.
- `app/src/hall-shell.ts` — takes seat offsets from `room-layout.ts`.
- `app/src/hall-scene.ts` — draws the floor model; its own queue and departure code is removed.
- `app/src/HallScene.svelte`, `app/src/App.svelte`, `app/src/api.ts`, `app/src/bench/hall-bench.ts`.

Docs: `docs/GAME_DESIGN.md` §15, `docs/ARCHITECTURE.md` (hall presentation), `docs/TESTING.md` (new spec files), `docs/superpowers/reports/2026-11-14-visible-diners.md`.

Coordinates: a room's north wall is negative z; the outside entrance is the middle of the south wall. Stall-local +z points out of the counter. All times are milliseconds from `performance.now()`.

---

### Task 1: Today's totals and the queue limit in the hall view

**Files:**
- Modify: `server/lib/feud_hall/domain/public_view.ex`
- Modify: `server/lib/feud_hall/application/management.ex` (the `hall` map in `view/3`, near line 113)
- Modify: `app/src/api.ts` (`View["hall"]`, near line 204)
- Test: `server/test/feud_hall/domain/public_view_test.exs`, `server/test/feud_hall/application/management_test.exs`

**Interfaces:**
- Produces (Elixir): `PublicView.build(state).today :: %{arrivals: non_neg_integer, admitted: non_neg_integer, left: non_neg_integer}`, where `left` is the sum of the values of `state.demand.today.left`.
- Produces (JSON hall view): `hall.today = {"arrivals": n, "admitted": n, "left": n}` and `hall.queue_limit = n` (from `state.catalog.rules.kitchen.queue_limit`).
- Produces (TypeScript): in `View["hall"]`, `today?: { arrivals: number; admitted: number; left: number }` and `queue_limit?: number`.

- [ ] **Step 1: Write the failing tests**

In `public_view_test.exs` (follow the state-building helpers used by `server/test/feud_hall/domain/rooms_test.exs`):

```elixir
test "today carries totals only" do
  state = put_in(hall_state().demand.today, %{arrivals: 9, admitted: 5, left: %{no_food: 3, queue_full: 2}, trays_served: 4})
  assert PublicView.build(state).today == %{arrivals: 9, admitted: 5, left: 5}
end
```

In `management_test.exs`, using that file's existing way of starting a hall and reading `Management.view/3` as a guest device with no account:

```elixir
test "the hall view carries today's totals and the queue limit, and no reasons" do
  {:ok, view} = Management.view(runtime, guest_device)
  assert Map.keys(view.hall.today) |> Enum.sort() == [:admitted, :arrivals, :left]
  assert Enum.all?(Map.values(view.hall.today), &is_integer/1)
  assert view.hall.queue_limit == runtime.state.catalog.rules.kitchen.queue_limit
  refute inspect(view.hall) =~ "queue_full"
end
```

Before the last assertion, drive the runtime's state so `demand.today.left` holds at least one reason key (set it directly on `runtime.state` if the file has no shorter way), and use whichever reason atom the domain really records; the assertion must fail if the reasons map were copied into the view.

- [ ] **Step 2: Run them and see them fail**

Run: `mix test test/feud_hall/domain/public_view_test.exs` and `mix test test/feud_hall/application/management_test.exs`
Expected: FAIL on the missing `today` key.

- [ ] **Step 3: Implement**

`PublicView.build/1` gains `today:` built by naming the three fields (do not `Map.take` the day map). `Management.view/3` adds `today: public.today` and `queue_limit:` to `hall`. Update the `PublicView` moduledoc's shape block and its sentence on what is never copied in: reasons for leaving and per-stall lost-diner counts are not public. Add the two optional fields to `api.ts`.

Before finishing, run `grep -rn "PublicView.build" server/lib` and confirm no caller stores, hashes or fingerprints the whole map (the planner and population callers read named fields). Report what you found.

- [ ] **Step 4: Run the tests and the callers' tests**

Run, one at a time: the two files above, then `mix test test/feud_hall/application/rooms_test.exs`, then `mix format --check-formatted`.
Expected: PASS.

- [ ] **Step 5: Commit** — `Show today's arrival totals and the queue limit in the hall view`

---

### Task 2: Seated pose

**Files:**
- Modify: `app/src/people.ts`
- Test: `app/test/browser/people.spec.ts`

**Interfaces:**
- Produces: `Pose` gains `seated: boolean`. `SEAT_HEIGHT = 0.46` is exported from `people.ts` (the seat top's height in world units; `hall-shell.ts` draws a seat 0.46 tall).
- Produces: `seatedTrayPoint(look: Look): { y: number; forward: number }` — where a tray rests in front of a seated figure (on the table), in the same units as `carryPoint`.
- Every existing `Pose` literal in `app/src` and `app/test` gains `seated: false`.

- [ ] **Step 1: Write the failing tests** in `people.spec.ts`, using that file's existing helper that collects emitted part matrices:

```ts
test("people: a seated figure sits on the seat with feet on the floor", () => {
  for (const serial of [1, 2, 3, 99, 4096]) {
    const look = personLook(serial, "diner");
    for (const detail of ["full", "simple"] as const) {
      const parts = partsOf(look, { ...STANDING, seated: true }, detail);
      // The hips are at seat height, whatever the figure's height.
      expect(hipHeight(parts)).toBeCloseTo(SEAT_HEIGHT, 2);
      // Nothing is below the floor and the head is lower than when standing.
      expect(lowestPoint(parts)).toBeGreaterThanOrEqual(-0.005);
      expect(headHeight(parts)).toBeLessThan(
        headHeight(partsOf(look, STANDING, detail)),
      );
    }
  }
});

test("people: seated ignores walking and stride", () => {
  const look = personLook(7, "diner");
  const a = partsOf(look, { ...STANDING, seated: true }, "full");
  const b = partsOf(look, { ...STANDING, seated: true, walking: true, stride: 0.8 }, "full");
  expect(b).toEqual(a);
});
```

Write `hipHeight`, `lowestPoint`, `headHeight` from the emitted matrices if the file has no equivalent.

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser people.spec.ts` — Expected: FAIL (unknown `seated`).

- [ ] **Step 3: Implement** in `poseParts`: when `pose.seated`, thighs point forward (+Z), shins hang down, the body is lowered so the hip joint is at `SEAT_HEIGHT` world units regardless of `look.height`, arms rest forward at table height, no stride or bob. The simple detail level keeps its single-piece limbs: one leg piece reaching from hip to foot. Keep `posePerson` allocation-free.

- [ ] **Step 4: Run** the same command, then `bun run test:browser people-scene.spec.ts`, then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.

- [ ] **Step 5: Commit** — `Add a seated pose for figures`

---

### Task 3: Seats, entrances, queue spots and routes

**Files:**
- Modify: `app/src/room-layout.ts`, `app/src/hall-layout.ts`, `app/src/hall-shell.ts`
- Test: `app/test/browser/room-layout.spec.ts`

**Interfaces (all produced here):**

```ts
// hall-layout.ts
/** Queue spot n (0-based) in stall-local coordinates; rows of two, 0.9 apart,
 *  continuing the pattern of QUEUE_SPOTS, which stays as the first four. */
export function queueSpot(n: number): readonly [number, number];
/** The most queue spots ever drawn at one stall. */
export const QUEUE_DRAW_MAX = 8;

// room-layout.ts
export type Seat = { room: number; index: number; x: number; z: number; yaw: number; tableX: number; tableZ: number };
/** Seat offsets around a table, in table-local coordinates (moved from hall-shell.ts). */
export const SEAT_OFFSETS: readonly (readonly [number, number])[];
/** The 32 seats of a room: tableSpots(room) x SEAT_OFFSETS, each facing its table. */
export function seatSpots(room: number): Seat[];
/** Just inside the room's outside entrance, and a point on the street beyond it. */
export function entrance(room: number): { inside: Point; outside: Point };
/** Waypoints from one floor point to another inside one room, both included. */
export function routeWithin(room: number, from: Point, to: Point): Point[];
/** Total length of a polyline. */
export function routeLength(points: Point[]): number;
/** The point `metres` along a polyline and the heading there (atan2(dx, dz)). */
export function routeAt(points: Point[], metres: number): { x: number; z: number; yaw: number };
```

`Point` is exported from `room-layout.ts`.

- [ ] **Step 1: Write the failing tests** in `room-layout.spec.ts`:

```ts
test("room layout: queue spots continue in rows of two and never overlap", () => {
  for (let n = 0; n < 4; n++) expect(queueSpot(n)).toEqual(QUEUE_SPOTS[n]);
  for (let a = 0; a < QUEUE_DRAW_MAX; a++)
    for (let b = a + 1; b < QUEUE_DRAW_MAX; b++)
      expect(Math.hypot(queueSpot(a)[0] - queueSpot(b)[0], queueSpot(a)[1] - queueSpot(b)[1]))
        .toBeGreaterThanOrEqual(FIGURE_MAX_SPAN);
});

test("room layout: every queue spot of every stall is clear of booths, tables and seats", () => {
  for (const room of [1, 2]) {
    const placements = Array.from({ length: 15 }, (_, p) => spotPlacement(room, p));
    for (const placement of placements)
      for (let n = 0; n < QUEUE_DRAW_MAX; n++) {
        const at = toHall(placement, ...queueSpot(n));
        expect(roomAt(at.x, at.z)).toBe(room);
        expect(placements.some((p) => stallBlocks(p, at.x, at.z))).toBe(false);
        for (const seat of seatSpots(room))
          expect(Math.hypot(seat.x - at.x, seat.z - at.z)).toBeGreaterThan(0.6);
      }
  }
});

test("room layout: a room has 32 seats, each facing its table", () => {
  const seats = seatSpots(3);
  expect(seats).toHaveLength(32);
  for (const seat of seats) {
    expect(seat.room).toBe(3);
    const toTable = Math.atan2(seat.tableX - seat.x, seat.tableZ - seat.z);
    expect(Math.cos(seat.yaw - toTable)).toBeCloseTo(1, 5);
  }
});

test("room layout: the entrance is the middle of the south wall", () => {
  const c = roomCentre(4), e = entrance(4);
  expect(e.inside.x).toBeCloseTo(c.x); expect(e.outside.x).toBeCloseTo(c.x);
  expect(roomAt(e.inside.x, e.inside.z)).toBe(4);
  expect(roomAt(e.outside.x, e.outside.z)).toBe(null);
  expect(e.outside.z).toBeGreaterThan(ROOM_SIDE / 2);
});

test("room layout: routes stay on the floor", () => {
  const room = 2;
  const placements = Array.from({ length: 15 }, (_, p) => spotPlacement(room, p));
  const ends: Point[] = [
    entrance(room).inside,
    ...seatSpots(room),
    ...placements.flatMap((p) => [0, QUEUE_DRAW_MAX - 1].map((n) => toHall(p, ...queueSpot(n)))),
  ];
  fc.assert(fc.property(fc.constantFrom(...ends), fc.constantFrom(...ends), (from, to) => {
    const route = routeWithin(room, from, to);
    expect(route[0]).toEqual({ x: from.x, z: from.z });
    expect(route[route.length - 1]).toEqual({ x: to.x, z: to.z });
    // Sample every 0.25 along the route, leaving out the first and last metre.
    const length = routeLength(route);
    for (let m = 1; m < length - 1; m += 0.25) {
      const at = routeAt(route, m);
      expect(roomAt(at.x, at.z)).toBe(room);
      expect(placements.some((p) => stallBlocks(p, at.x, at.z))).toBe(false);
      for (const table of tableSpots(room))
        expect(Math.hypot(table.x - at.x, table.z - at.z)).toBeGreaterThan(0.62);
    }
    expect(length).toBeLessThan(4 * ROOM_SIDE);
  }));
});

test("room layout: routeAt runs from the first point to the last", () => {
  const route = [{ x: 0, z: 0 }, { x: 3, z: 0 }, { x: 3, z: 4 }];
  expect(routeLength(route)).toBeCloseTo(7);
  expect(routeAt(route, 0)).toMatchObject({ x: 0, z: 0 });
  expect(routeAt(route, 5)).toMatchObject({ x: 3, z: 2 });
  expect(routeAt(route, 99)).toMatchObject({ x: 3, z: 4 });
  expect(routeAt(route, 1).yaw).toBeCloseTo(Math.PI / 2);
});
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser room-layout.spec.ts` — Expected: FAIL on missing exports.

- [ ] **Step 3: Implement.** `hall-shell.ts` imports `SEAT_OFFSETS` instead of its private `SEATS`; the drawn seats must not move. Routing is yours to design (the spec leaves routes to the builder): collisions are cosmetic, so a small fixed set of aisle waypoints per room is enough; no general path-finder. If a queue spot cannot satisfy the clearance test at `QUEUE_DRAW_MAX = 8` for some stall position, lower `QUEUE_DRAW_MAX` (not below 6) rather than moving booths or tables, and say so in your report.

- [ ] **Step 4: Run** the same file, then `hall-rooms.spec.ts` (tables and seats still draw), then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.

- [ ] **Step 5: Commit** — `Lay out seats, entrances and walking routes for each room`

---

### Task 4: The floor model

**Files:**
- Create: `app/src/diner-floor.ts`
- Test: `app/test/browser/diner-floor.spec.ts`

**Interfaces:**
- Consumes: Task 2's `Pose.seated`; Task 3's `queueSpot`, `QUEUE_DRAW_MAX`, `seatSpots`, `entrance`, `routeWithin`, `routeLength`, `routeAt`; `spotPlacement`, `toHall`, `collectTray`, `collectMs`, `PICKUP_SPOT`, `COUNTER_TRAY`, `personLook`, `serialFor`.
- Produces:

```ts
export const EAT_MS = 60_000;
/** A gap between snapshots longer than this starts again from the counts. */
export const STALE_MS = 10_000;
/** Once service stops, the floor is empty this long afterwards. */
export const CLEAR_MS = 8_000;
/** The most figures the model keeps walking or seated in one room. */
export const ROOM_BUDGET = 96;

export type FloorStall = {
  id: string; room: number; position: number;
  waiting: number; lastService: string | null;
};
export type FloorInput = {
  now: number;
  serving: boolean;                       // hall.access === "open"
  today?: { arrivals: number; admitted: number; left: number };
  queueLimit?: number;                    // absent: 4
  openRooms: number;
  stalls: FloorStall[];
  animate: boolean;                       // motion on
  browse: boolean;                        // detail on
};
export type FloorActivity = "walking" | "queued" | "collecting" | "seated";
export type FloorFigure = {
  look: Look; room: number;
  x: number; z: number; yaw: number; faceYaw: number;
  stride: number; activity: FloorActivity;
  carrying: boolean;                      // tray in hands
  /** 0..1 while the tray passes from the counter to the hands; else absent. */
  take?: number;
  /** The stall whose counter the tray comes from, while `take` is present. */
  stall?: string;
  /** Present while seated: where the tray rests on the table. */
  seat?: Seat;
  opacity: number;
};
export type FloorTally = {
  toQueue: number;    // figures created for a rise in a stall's waiting count
  walkOut: number;    // figures created for an arrival that was not admitted
  fromSeat: number;   // waiting rises staged by a seated diner going back (dessert)
  thinned: number;    // figures the budget declined to create
};
export function createDinerFloor(): {
  apply(input: FloorInput): void;
  /** Calls `visit` once per figure present at `now`; allocates no arrays. */
  figures(now: number, visit: (figure: FloorFigure) => void): void;
  /** How many figures are present at `now`. */
  count(now: number): number;
  /** True while any figure is walking or collecting at `now`. */
  moving(now: number): boolean;
  /** How many figures stand in or are bound for a stall's queue. */
  boundFor(stallId: string): number;
  readonly tally: FloorTally;
  clear(): void;
};
```

The `FloorFigure` passed to `visit` may be one reused object.

**Rules the model implements** (each has a test below):

1. *Baseline.* The first `apply`, the first after `clear()`, and any `apply` more than `STALE_MS` after the previous one: each stall's queue is set to `min(waiting, cap)` figures standing at their spots, with no walk; figures walking in are placed at their spots; no walk-outs are created; totals are remembered. `cap = min(queueLimit ?? 4, QUEUE_DRAW_MAX)`.
2. *Totals went down* (midnight) or `today` absent on either side: no walk-outs from this snapshot; remember the new totals.
3. *Queue rise.* A stall's `min(waiting, cap)` rose by k: k figures are bound for that stall. With `browse` true each enters at `entrance(room).outside`, walks in, passes one or two other stalls of the room (chosen from its serial), and ends at its queue spot. With `browse` false it appears at its queue spot. `tally.toQueue += k`.
4. *Dessert.* When `today` is present on both sides and the hall-wide sum of queue rises exceeds the rise in `admitted`, the excess rises (taken in stall-ID order) are each staged by a seated figure in that stall's room walking back to the queue, when one exists: `tally.fromSeat += 1` instead of `toQueue`. Its seat is freed. When none is seated there, rule 3 applies.
5. *Served.* A stall's `lastService` changed to a non-null value and it has a queued or inbound figure: the figure at the highest occupied spot collects (`collectTray` from where it stands, or from where it is on its way in), then walks carrying to a free seat of the room chosen from its serial, sits for `EAT_MS`, then walks to the entrance and out. With no free seat, or `browse` false, it walks to the entrance carrying and out; with `browse` false and a free seat it is placed seated at once instead and stays `EAT_MS`.
6. *Queue fall.* After rule 5, any remaining excess of figures over `min(waiting, cap)` leaves without a tray: highest spot first, walking to the entrance and out.
7. *Walk-out.* `(arrivals − admitted)` rose by w (rule 2 permitting) and `browse` is true: w figures, each entering at the entrance of open room `1 + (serial mod openRooms)`, passing one or two stalls, and walking out again. `tally.walkOut += w`. With `browse` false none is created.
8. *Budget.* A walk-out, or a browsing walk, that would put more than `ROOM_BUDGET` walking-or-seated figures in its room is not created as a walker: the walk-out is dropped and the queue-bound figure appears at its spot. `tally.thinned += 1`. Queue figures up to `cap` are never dropped.
9. *Service stops.* `serving` false: every figure walks to its room's entrance and out; `count(now)` is 0 from `CLEAR_MS` after that `apply`, and nothing is created while `serving` stays false.
10. *Stalls and rooms that go away.* A stall missing from `stalls`, or whose room or position changed, or a room above `openRooms`: its figures are removed at once.
11. *Reduced motion.* `animate` false: nothing walks or collects. A queue-bound figure appears at its spot; a served figure with a free seat is placed seated at once, stays `EAT_MS` and is then removed; every other figure that would walk away is removed at once; no walk-outs are created. Figures already walking when `animate` turns false are placed at their destination or removed in the same way.
12. *Never more than the count.* After every `apply`, `boundFor(id) <= min(waiting, cap)` for every stall, and equals it once walks have finished.

Walking speed is `1.6` metres per second for diners and the gait is driven by metres walked, as `collectDiner` does today in `hall-scene.ts` (read it and `hall-layout.ts`'s `collectTray` first; rule 5 must keep that pickup route). A figure fades in over its first 0.5 m outside the entrance and out over its last 0.5 m.

- [ ] **Step 1: Write the failing tests** in `diner-floor.spec.ts`. Helpers: `input(over)` builds a `FloorInput` for room 1's fifteen stalls (`id` `"s01"`…`"s15"`, positions 0–14) at `now: 0`, `serving: true`, `animate: true`, `browse: true`, `openRooms: 1`, `queueLimit: 6`, `today: {arrivals: 0, admitted: 0, left: 0}`, every `waiting` 0; `all(floor, now)` collects copies of the visited figures.

```ts
test("floor: the first snapshot fills queues standing, with no walkers", () => {
  const floor = createDinerFloor();
  floor.apply(input({ waiting: { s03: 3, s07: 9 }, today: { arrivals: 500, admitted: 300, left: 220 } }));
  const figures = all(floor, 0);
  expect(figures).toHaveLength(3 + 6);                 // s07 is capped at the queue limit
  expect(figures.every((f) => f.activity === "queued")).toBe(true);
  expect(floor.tally).toEqual({ toQueue: 0, walkOut: 0, fromSeat: 0, thinned: 0 });
});

test("floor: figures created equal the count changes received", () => {
  fc.assert(fc.property(snapshots(), (steps) => {       // see below
    const floor = createDinerFloor();
    let expected = { toQueue: 0, walkOut: 0 }, previous = steps[0];
    floor.apply(previous);
    for (const step of steps.slice(1)) {
      floor.apply(step);
      expected.toQueue += queueRises(previous, step);   // independent oracle, written in the test
      expected.walkOut += walkOutRise(previous, step);
      const t = floor.tally;
      expect(t.toQueue + t.fromSeat).toBe(expected.toQueue);
      expect(t.walkOut + t.thinned).toBeGreaterThanOrEqual(expected.walkOut);
      expect(t.walkOut).toBeLessThanOrEqual(expected.walkOut);
      for (const stall of step.stalls)
        expect(floor.boundFor(stall.id)).toBeLessThanOrEqual(Math.min(stall.waiting, 6));
      previous = step;
    }
  }), { numRuns: 200 });
});
```

`snapshots()` generates 2–30 steps, each 850 ms after the last, with per-stall waiting moving by −2..+2 within 0..8, `lastService` sometimes changing, and totals that only rise, `admitted` rising by at least the sum of queue rises (so no dessert in this property). Add a floor on progress: `fc.pre` or a counter asserting that across the run at least one rise and one walk-out occurred.

Then one focused test per rule, each asserting the exact numbers:

```ts
test("floor: nothing appears without a change", () => { /* apply the same input 20 times, 850 ms apart: count stays, tally stays zero */ });
test("floor: a walk-out enters and leaves by an open room's entrance", () => { /* arrivals +1, admitted +0: one walking figure; its first and last positions are entrance(room).outside for a room <= openRooms; count returns to before within 60 s */ });
test("floor: walk-outs come from arrivals minus admitted, not from left", () => { /* left +5, arrivals +0: tally.walkOut 0 */ });
test("floor: a served diner collects, sits for EAT_MS, then leaves", () => { /* waiting 1 -> 0 with lastService changed: activity goes collecting -> walking(carrying) -> seated (seat present, within 0.01 of a seatSpots(1) entry) for EAT_MS -> walking -> gone */ });
test("floor: with every seat taken the served diner leaves carrying", () => { /* serve 33 diners inside EAT_MS: 32 seated, the 33rd never seated */ });
test("floor: a dessert order is staged from a seated diner", () => { /* one seated; waiting +1 with admitted +0: tally.fromSeat 1, toQueue unchanged, count unchanged */ });
test("floor: a long gap starts again from the counts", () => { /* apply at 0, then at STALE_MS + 1 with waiting +5 everywhere and arrivals +400: all queued, no walking figure, tally unchanged */ });
test("floor: midnight stages no walk-outs", () => { /* totals fall to zero: walkOut unchanged; next snapshot arrivals 2 admitted 1: walkOut +1 */ });
test("floor: a server without totals stages queues only, four deep", () => { /* today and queueLimit absent, waiting 6: four queued; arrivals unknowable: walkOut 0 */ });
test("floor: served before reaching the queue", () => { /* waiting 0->1, then 400 ms later 1->0 with lastService changed: the same figure (same look) turns to collect; boundFor never exceeds waiting */ });
test("floor: a stall that goes away takes its figures with it", () => { /* drop s03 from stalls: its figures absent at once; other stalls' boundFor unchanged; no throw */ });
test("floor: a closed room's figures are removed", () => { /* two rooms, openRooms 2 -> 1 */ });
test("floor: the cleaning window clears the floor", () => { /* queues, walkers and seated present; serving false: count(now + CLEAR_MS) is 0; later inputs with serving false and rising counts create nothing */ });
test("floor: reduced motion and reduced detail", () => { /* animate false: no figure is ever walking or collecting, a served diner is seated at once and gone EAT_MS later, a queue fall removes at once; browse false: no walk-outs, queue figures appear at spots, a served diner still collects */ });
test("floor: the budget thins walk-outs, never queues", () => { /* arrivals +500 in one snapshot: walking-or-seated in a room never above ROOM_BUDGET; thinned + walkOut === 500; queues intact */ });
test("floor: looks are stable", () => { /* two floors fed the same inputs visit identical looks in identical order */ });
test("floor: figures walk on the floor", () => { /* over a 120 s scripted run sampled every 100 ms, every figure inside its room is not inside a booth (stallBlocks) */ });
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser diner-floor.spec.ts` — Expected: FAIL (module missing).

- [ ] **Step 3: Implement `createDinerFloor`.** Each figure is a look plus a list of timed legs (walk along a route, collect, sit until a time); its position at `now` is computed from the legs, so `figures` and `count` are pure functions of `now` and the applied inputs. Finished figures are dropped during `apply` and are skipped by `figures`.

- [ ] **Step 4: Run** the same file, then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS. Then show the tests are not vacuous: temporarily make rule 7 use the `left` total, run the file, confirm "walk-outs come from arrivals minus admitted" fails, and restore. Report the result.

- [ ] **Step 5: Commit** — `Add the diner floor model`

---

### Task 5: Draw the floor in the hall

**Files:**
- Modify: `app/src/hall-scene.ts`, `app/src/HallScene.svelte`, `app/src/App.svelte`, `app/src/bench/hall-bench.ts`
- Test: `app/test/browser/visible-diners.spec.ts`; existing `people-scene.spec.ts`, `tray-pickup.spec.ts`, `hall-rooms.spec.ts`, `hall-interactions.spec.ts`, `hall-navigation.spec.ts`

**Interfaces:**
- Consumes: Task 1's `hall.today`, `hall.queue_limit`; Task 2's seated pose and `seatedTrayPoint`; Task 4's `createDinerFloor` and types.
- Produces: `Appearance` gains `serving: boolean`, `today?: { arrivals: number; admitted: number; left: number }`, `queueLimit?: number`. The scene host gains `data-hall-walking` and `data-hall-seated` (counts of floor figures drawn this frame with that activity; `walking` includes collecting). `data-hall-people` keeps meaning every figure drawn.
- Produces (bench): `/bench.html?...&floor=1` feeds rising totals and service changes so that, in the shown room, seats fill and walkers are present throughout the run; the result line reports `walking` and `seated` drawn counts. Default `floor=0` keeps today's workload.

**What changes in `hall-scene.ts`:**
- `Diner`, `Departure`, `Counter.queue`, `Counter.visibleDiners`, `Counter.nextDiner`, `departures`, `updateQueue`, `departDiner`, `walkDiner`, `collectDiner`, `drawDepartures`, `aisleDistance` and `WALK_MS` are removed. One `createDinerFloor()` per scene replaces them.
- `update(next)` builds one `FloorInput` from `next` (stalls with their assigned room and position, `serving`, `today`, `queueLimit`, `openRooms`, `animate: next.motion`, `browse: next.detail`) and calls `floor.apply`. While the page is hidden do not apply; when it becomes hidden call `floor.clear()`, so the next `update` is a baseline.
- `draw(now)` calls `floor.figures(now, …)` and draws each figure whose room is shown. In the viewer's room: full detail when the room is drawn in full and `appearance.detail`, otherwise simple. In a neighbouring room: simple figures, and only those `queued` at spot 0 or `seated`. A carried tray uses the existing `carriedTrays` mesh; a seated figure's tray rests at `seatedTrayPoint`; a collecting figure's tray travels from the stall's counter as `holdTray` does today.
- Instanced capacities (`ACTOR_LIMIT`, the carried-tray mesh, `QUEUE_LIMIT`) are resized for three shown rooms: staff as today plus `3 × (15 × QUEUE_DRAW_MAX + ROOM_BUDGET)` floor figures. Adding beyond a mesh's capacity must be skipped, not thrown.
- `schedule()` runs at the active frame interval while `floor.moving(now)`; seated and queued figures alone do not keep it active beyond what today's rules already do.

- [ ] **Step 1: Write the failing browser tests** in `visible-diners.spec.ts`. Follow `people-scene.spec.ts`: seed an owner with a stall in room 1, capture a `View`, then serve mutated copies of it from `page.route("**/api/state", …)`. Install `page.clock` before `page.goto` so polling and animation time are driven by the test.

```ts
test("visible diners: a served diner sits, eats and leaves", async ({ page, hall }) => {
  // snapshot A: the owned stall has waiting 1, today {arrivals 1, admitted 1, left 0}.
  // snapshot B: waiting 0, last_service changed.
  // Expect: data-hall-seated becomes 1 within 30 s of clock time;
  // stays 1 at +50 s after sitting; becomes 0 within EAT_MS + 30 s;
  // and data-hall-walking returns to 0.
});

test("visible diners: a diner who leaves without buying is shown leaving", async ({ page, hall }) => {
  // B: arrivals +1, admitted +0, every waiting unchanged.
  // Expect: data-hall-walking becomes 1, then 0; data-hall-people is back to its value at A.
});

test("visible diners: the floor is empty during cleaning", async ({ page, hall }) => {
  // With one seated and two queued: serve a snapshot with access "cleaning" and waiting 0.
  // Expect within CLEAR_MS + 2 s: data-hall-seated 0, data-hall-walking 0.
});

test("visible diners: the queue is drawn to the server's queue limit", async ({ page, hall }) => {
  // waiting 6, queue_limit 6, camera focused on the stall: six diners at the stall
  // (data-hall-people = staff drawn + 6). With queue_limit absent: four.
});

test("visible diners: reduced motion shows no walking", async ({ page, hall }) => {
  // emulateMedia({ reducedMotion: "reduce" }); the served-diner script above:
  // data-hall-walking is never above 0; data-hall-seated becomes 1.
});
```

Use the value the server really sends for `access` during cleaning (read `Management.view/3` and the domain's access values). Assert exact numbers; each `expect.poll` must be one that fails if the behaviour is absent (check by running once against the unmodified scene).

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser visible-diners.spec.ts` — Expected: FAIL (attributes absent).

- [ ] **Step 3: Implement** the scene changes, pass `serving: view.hall.access === "open"`, `today: view.hall.today`, `queueLimit: view.hall.queue_limit` from `App.svelte` through `HallScene.svelte`, and add the bench's `floor` knob.

- [ ] **Step 4: Run, one file at a time,** `visible-diners.spec.ts`, `people-scene.spec.ts`, `tray-pickup.spec.ts`, `hall-rooms.spec.ts`, `hall-interactions.spec.ts`, `hall-navigation.spec.ts`, then `bun check`, `bun run lint`, `bun run format:check`.
Expected: PASS. Where an existing assertion fails only because a served diner now walks to a seat instead of fading out, or because a queue is now drawn deeper than four, change that assertion and list each such change with its reason in your report. The tray-pickup camera view must still pass no waiting or seated figure between the eye and the tray; do not weaken that check.

- [ ] **Step 5: Commit** — `Draw arriving, eating and leaving diners in the hall`

---

### Task 6: Bench evidence hooks, documentation and report

**Files:**
- Modify: `docs/GAME_DESIGN.md` (§15: what the floor shows, the truthfulness rule in one direction, thinning, cleaning window, reduced detail and motion), `docs/ARCHITECTURE.md` (hall presentation: the floor model's inputs, that it is count-true and pure, the two view fields and what stays private), `docs/TESTING.md` (the two new spec files and the bench's `floor` knob), `AGENTS.md` only if an entry point it lists changed.
- Create: `docs/superpowers/reports/2026-11-14-visible-diners.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the report, with a "Frame times" section left for the controller to fill from the bench (rows for `stalls=150&rooms=10&room=5` at `detail=0&floor=1`, `detail=1&floor=1`, `near=1&detail=1&floor=1`), listing for each: people drawn, walking, seated, frames per second, late frames, mean frame time, and the hardware.

- [ ] **Step 1:** Write the documentation changes. State gameplay in the game design and contracts in the architecture document; link rather than copy. Mark every tuning value introduced here (`EAT_MS`, `ROOM_BUDGET`, `QUEUE_DRAW_MAX`, walking speed, `CLEAR_MS`, `STALE_MS`) as a proposed default.
- [ ] **Step 2:** Write the report: what was built, each builder's call made in Tasks 1–5 with its reason, which checks ran with their results, and what is not verified (full suites, real-play observation, other hardware).
- [ ] **Step 3:** Run `bun run format:check` from `app/` and check every relative link you added resolves (`ls` each target).
- [ ] **Step 4: Commit** — `Document visible diners and report the work`
