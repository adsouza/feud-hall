# Visible diners: what was built, frame time and checks

Evidence for Project 3 of the livelier hall: diners drawn arriving, queuing,
eating and leaving in the 3D hall. The rules are in the game design's
[Diners on the floor](../../GAME_DESIGN.md#diners-on-the-floor); the contract is
in the architecture's
[Diners on the floor](../../ARCHITECTURE.md#diners-on-the-floor); the spec is
[Project 3](../specs/2026-11-13-livelier-hall-design.md#project-3-visible-diners).
The previous project's report is [Row of halls](2026-11-14-row-of-halls.md).

## What was built

Six tasks, in commit order (plan commit `e0457fc`):

| Commit | What |
| --- | --- |
| `dd40b41` | The hall view carries today's arrival totals (`today`: arrivals, admitted, left) and the queue limit (`queue_limit`). Totals only; no reasons. |
| `021f832` | A seated pose for figures (`Pose.seated`, `SEAT_HEIGHT`, `seatedTrayPoint`). |
| `781b4e4` | Seats, entrances, queue spots beyond the first four, and walking routes for each room (`app/src/room-layout.ts`, `app/src/hall-layout.ts`). |
| `b2e2f11`, `688e263` | The pure floor model `app/src/diner-floor.ts`: turns count changes into diners with timed legs. The second commit reworked queue staging to start from raw waiting counts. |
| `12913ad` | The scene draws the floor; the old departure animation is removed; the bench gains a `floor` knob and reports walking and seated counts. |
| this commit | Documentation and this report. |

The result: a stall's queue is drawn to the smaller of the server's queue limit
and a drawing cap of eight; diners walk in through the room entrance and pass a
stall or two; a served diner takes the tray, sits at a free seat for about a
minute and leaves; diners who leave without buying are drawn walking in and
out; the floor is empty from 03:00 to 05:00. Queued diners no longer sway. No
server rule, event, command or stored field changed.

## Rulings and builder's calls

Each with what it costs if wrong.

| Call | Reason | If wrong |
| --- | --- | --- |
| The queue limit is a second view field, `queue_limit`, though the spec's data table names only the totals. | The client cannot draw to the server's limit without it; it is public catalog data. | Remove the field and hard-code 6. |
| Totals are added in `PublicView.build` and copied into the hall view, not only in `Management.view`. | The spec names the public view's module documentation. | A caller that fingerprints the whole map would see it change; none of the four callers does. |
| Queues are drawn to the smaller of the queue limit and `QUEUE_DRAW_MAX` (8). | The cap is the drawing budget; clearance tests pass at 8. | A later catalog with a limit above 8 would draw short queues while the number stays exact. |
| Queue changes come from raw waiting counts in three steps: a service removes one; diners advancing from beyond the drawn queue appear standing in place and are not counted; what remains is joiners (walk in, counted) or a fall. | A served-and-replaced diner is a committed diner and must be counted, while a tail advance is not a new diner. Replaced the plan's "the capped count rose by k". | Tallies shift by one per service; no figure count changes. |
| `take` and `stall` are present for the whole collect leg (`take` 0 while the tray is on the counter). | It matches how the scene draws the tray on the counter. | The scene filters on `take > 0` instead. |
| `FloorFigure` gained `spot`, and carries `stall` while queued. | A simply drawn stall shows only its first queued diner, so the scene needs the stall and spot. | Task 5 would need another way to know which figure is first. |
| With browse off and animate on, a served diner collects at the counter, then is placed seated at once if a seat is free, otherwise walks out carrying. | The spec: browsing walks are skipped and eaters are static. | Reduced-detail eaters behave slightly differently; one branch. |
| A queue-bound figure whose browsing walk is thinned still counts in `toQueue` and adds one to `thinned`. | The figure exists at its spot, which keeps the count-true property exact. | Only the tally's meaning changes. |
| Seated thighs slope 17 to 31 degrees below level. | With level thighs on a 0.46 seat the feet hang 14 to 18 cm above the floor. | The seated figure looks slightly perched; pose only. |
| Routes reach queue and pickup spots by way of a point 1.1 m further from the counter. | The route test skips the first and last metre, and a route from a spot crossed a booth corner there. | A figure clips a booth corner when leaving a spot. |
| Seat reservation happens at service time; a seat counts as free once its holder's time has passed. | Keeps seat use consistent when figures are re-planned. | Two diners could briefly pick the same seat. |
| Helpers' commit trailers name the model that wrote the commit (Opus 5.5 for the Task 3 to 5 commits). | The attribution should be true. | Messages can be rewritten before any push. |

## Frame times

Measured by the controller at commit `12913ad`, 2026-11-14. See
[How to run the frame bench](../../TESTING.md#how-to-run-the-frame-bench).

### Environment and method

- Machine: Apple M4, ANGLE Metal renderer.
- Browser: headless Chromium 158 from Playwright 1.65, launched with
  `--use-angle=metal`, viewport 1440x900.
- Dev server (vite). One run per row; each row is not repeated, unlike the
  row-of-halls report, which kept the second of two runs.
- URLs: `/bench.html?stalls=150&rooms=10&room=5&...`. The bench serves every
  stall once a second, far busier than a real hall.

### Results

| view | seconds | people drawn (max) | walking (max) | seated (max) | fps | late frames | mean draw ms | p95 draw ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `detail=0&floor=1` | 40 | 523 | 292 | 96 | 30.60 | 0% | 5.74 | 8.4 |
| `detail=1&floor=1` | 40 | 561 | 346 | 94 | 30.67 | 0% | 6.25 | 9.0 |
| `near=1&detail=1&floor=1` | 40 | 665 | 346 | 94 | 30.68 | 0% | 6.63 | 9.3 |
| `detail=0&floor=0` | 20 | 488 | 257 | 96 | 30.32 | 0% | 6.06 | 8.3 |

"Walking" and "seated" are the largest counts drawn in any one frame, not
averages.

### Pass bar

Unchanged: at least 29.5 frames per second with at most 5% late frames at
`stalls=150&detail=0`, now with the floor populated. Result: **pass**
(30.60 fps, no late frames). Before this project the same `detail=0` view drew
315 people at 3.68 ms mean (row-of-halls report). The `floor=0` row is not
like-for-like with that one: served diners now walk to seats and eat instead of
fading out. Screenshots 30 s into the `detail=0` and `near=1` runs showed
walkers and seated diners present; seated figures sit on the stools with trays
on the table top.

Not measured: other hardware, a real hall's workload, the packaged native app.

## Checks run

One file at a time, never a whole suite at once, as each task's implementer
reported. Results are those reports'.

Server, from `server/`:

| Check | Result |
| --- | --- |
| `mix format --check-formatted` | clean |
| `test/feud_hall/domain/public_view_test.exs` | 1 passed (new) |
| `test/feud_hall/application/management_test.exs` | 13 passed (one test added) |
| `test/feud_hall/application/rooms_test.exs` | 30 passed |

Client, from `app/` with `NODE_OPTIONS=--max-old-space-size=1536`:

| Check | Result |
| --- | --- |
| `bun check` | no type errors (731 files at Task 4; the later run reported none) |
| `bun run lint` | exit 0, no findings |
| `bun run format:check` | clean |
| `bun run --bun build` | built |
| `people.spec.ts` | 30 passed (two seated-pose tests and one hands-and-feet test added) |
| `people-scene.spec.ts` | 1 passed |
| `room-layout.spec.ts` | 18 passed (six added; the routes test takes 35 to 50 s) |
| `diner-floor.spec.ts` | 26 passed (new; includes a seeded property with progress floors) |
| `visible-diners.spec.ts` | 5 passed (new; failed 5 of 5 on the unmodified scene) |
| `tray-pickup.spec.ts` | 4 passed |
| `hall-rooms.spec.ts` | 25 passed |
| `hall-interactions.spec.ts` | 5 passed |
| `hall-navigation.spec.ts` | 2 passed |

Sensitivity checks the implementers ran and reverted: counting walk-outs from
the "left" total failed five floor tests; the previous staging model failed the
five tests added with the raw-count rework; a router that returns the direct
line failed 17,052 of 70,227 routes. Existing tests changed: none; only
existing `Pose` literals gained `seated: false`.

The browser specs use software rendering and are not frame-rate evidence.

## Not verified

- **No full test suite was run**, server or client. Server test files other than
  the three above, and client spec files other than the nine above, were not run
  on this branch; they are left to hosted CI.
- **Nobody has watched a real hall with real diners on this code.** The browser
  specs use a mocked state feed, and the bench uses a synthetic stream.
- **Frame times come from one machine and a synthetic workload**: one run per
  row, one GPU, a bench that serves every stall every second. Weaker hardware is
  not covered.
- **The packaged native app was not rebuilt** on this branch.
- The bench's `floor=0` rows cannot be compared with earlier reports, and the
  bench reports only maxima, so it cannot show that walkers are present
  throughout a run.
- Figures past mesh capacity are skipped without a count; the model's budget
  limits new walkers only, so served and falling figures can exceed
  `ROOM_BUDGET` briefly.
- No capacity script or hall-trace property was run; no server rule changed.

### Deferred minor findings

Raised in review, not actioned.

- **Task 1:** one long line; a test name; the zero case is not tested.
- **Task 2:** `TABLE_TOP` is copied by hand from `hall-shell.ts`; one hand
  position assertion is partly circular.
- **Task 3:** routes shorter than 2 m skip all obstacle checks (a seat to the
  opposite seat crosses the table); the fallback for an end with no visible
  aisle point can clip a booth from a wall pocket; `routeWithin` costs about
  0.37 ms on average and up to 8 ms for mid-walk re-routes, with nothing cached;
  booth footprint literals are copied from `stallBlocks`; `routeAt([])` returns
  the origin; the routes test takes 35 to 50 s and never starts mid-walk.
- **Task 4:** on service stop, a just-entered walk-out runs its browse route
  instead of heading straight out; turning animate off while service is stopped
  skips the transition rule; `stopMotion` seats a collecting or walking figure
  for longer than `EAT_MS` and cuts the collect; a collect from a mid-walk point
  moves sideways through queued figures; focused tests are missing for browse
  off with a served seated or no-seat diner, a thinned queue walker in both
  tallies, leaving a seat avoiding its table, and a queue fall giving a tray-less
  walker via the entrance; the "stall moves" spec asserts `boundFor <= 2` where
  it should assert `== 2` and positions; `GAIT` is duplicated from
  `hall-scene.ts`; `diner-floor.ts` is 1034 lines (after the final review fixes) and its route and leg helpers
  would split cleanly; a cold route costs about 0.5 ms per miss, so the first
  busy snapshot may stall `apply` for tens of ms; spec helper names `rises` and
  `queueRises` keep old wording and the helper's served guard differs slightly
  from the model's.
- **Task 5:** figures skipped at mesh capacity are invisible; the new browser
  tests were shown failing only by absent attributes, not absent behaviour; the
  cleaning test does not assert queued figures are gone; the browser tests use
  real-time waits and "seated stays 1 for 50 s" has no slack; queued diners no
  longer sway; the pickup camera has no guard against walkers crossing in front
  of a counter; a collecting figure whose counter model is missing draws oddly;
  the bench cannot show "present throughout".

## Final review

A whole-branch review found two important problems, both fixed:

- **Queues looked one deep at the room overview.** A stall not drawn in detail
  drew only its first queued diner, while every walker in the viewer's room was
  drawn, so at the overview a joiner vanished on reaching the queue and a served
  diner appeared from nowhere. The viewer's room now draws every queued figure,
  in full when the stall is detailed and simply otherwise; neighbouring rooms
  keep the first queued diner and the eaters (`7dbe322`). The people-scene
  overview count is 10, not 6, and a new visible-diners test checks that a
  joiner is still drawn after reaching the queue at the overview.
- **Re-applying old data defeated the long-gap baseline.** The scene calls
  `update` on selection, tablet, pickup and label changes, and each call
  re-applied the last view, restarting the `STALE_MS` timer. `FloorInput` now
  carries `snapshot` (the scene passes `hall.position`, the bench its update
  counter); an apply with the previous snapshot changes no figure because of
  counts and leaves the gap timer alone, but still removes gone stalls' figures
  and applies motion turning off (`965f4dc`, `d3aecf1`).

Other fixes from the review:

- A stall that goes away removes every figure with a collect leg still ahead
  there, not only the one collecting now (`1689901`).
- Routes are cached room-relative and shared by all rooms, so ten rooms no
  longer route cold ten times or near the 50,000-entry cap (`86d6fbc`).
- The "stall moves" test asserts exactly two figures at the new position's
  spots 0 and 1, and a new test covers a queue fall: the last diner walks out
  of the entrance without a tray (`7c74dbb`).
- Documentation: the architecture section states what the tests refute, the
  `apply(input)` signature and `snapshot`, and what is drawn per room; the
  design says who takes the tray, what the budget does, that the viewer's room
  shows whole queues and that the gap is measured between server snapshots;
  the `PublicView` moduledoc no longer says reasons are never copied in (the
  closed-day summaries in `demand` keep them and are not sent to clients).

Browser fixtures that serve an edited copy of a real view now give it a new
`hall.position` (the visible-diners helper and the people-scene frozen view),
because the floor ignores counts from a position it has already applied.

Deliberately left:

- Two services at one stall in one snapshot show one as a lost diner.
- Per-frame work covers the whole hall, not only the drawn rooms.
- `moving()` is hall-wide, so a walker in an undrawn room keeps frames coming.
- `routeAt` and `toHall` allocate small objects per figure per frame.
- The property test's oracle mirrors the model's arithmetic.
- No scene test covers reopening after cleaning or returning from a hidden
  tab.

## Known limits

- Walkers and seated diners in a room two doorways away are not drawn, as for
  every figure.
- Tuning values (`EAT_MS` 60 s, `ROOM_BUDGET` 96, `QUEUE_DRAW_MAX` 8, walking
  speed 1.6 m/s, `CLEAR_MS` 8 s, `STALE_MS` 10 s) are proposed defaults, not
  validated by play.
- The HTML list view, the no-WebGL fallback and phone layouts were not changed.
