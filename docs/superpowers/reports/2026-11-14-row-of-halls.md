# Row of halls: frame time, checks and trial upgrade

Evidence for the row of ten rooms ("Hall 1" to "Hall 10"): frame delivery of
the 3D hall scene with rooms, the file-by-file checks run on the branch, and a
trial of the catalog version 3 upgrade on a copy of a real hall. The rules are
in the game design's [Rooms](../../GAME_DESIGN.md#rooms) and
[Scarcity rent](../../GAME_DESIGN.md#scarcity-rent) sections; the mechanics in
the architecture's [rooms and lease quotes](../../ARCHITECTURE.md#rooms-and-lease-quotes).

## Frame time

Measured with the dev-only bench. See
[How to run the frame bench](../../TESTING.md#how-to-run-the-frame-bench).

### Environment

- Date: 2026-11-14
- Machine model: Mac16,10 (Apple M4, 16 GB)
- GPU (`renderer`): ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)
- Browser and version: Playwright's bundled Chromium 158.0.8127.18, headless, 1280×800
- Commit measured: ae6f898

### Method

Same method as the
[people frame-time report](2026-11-13-people-frame-time.md#method). A hidden
desktop browser pane throttles animation, so it is not valid evidence. The runs
use Playwright's Chromium with hardware rendering and background throttling
switched off, which does not depend on a visible window. The driver is a short
Playwright script kept outside the repository; it opens each bench URL with
these launch options:

- `channel: "chromium"`, `headless: true`;
- `--use-angle=metal --enable-gpu --ignore-gpu-blocklist`;
- `--disable-renderer-backgrounding --disable-backgrounding-occluded-windows
  --disable-background-timer-throttling`.

The `renderer` string must name the GPU, not a software rasterizer. Each URL is
loaded twice in a fresh page and the second result kept. The scene paces active
frames at 32 ms, so about 31 frames per second is its ceiling; the bench also
triggers one extra draw per second through its keep-alive update.

`meanDrawMs` and `p95DrawMs` are CPU-side time in `draw()`, including the render
submit. GPU cost shows through `fps` and `lateShare`.

### What is drawn

150 stalls, all ten rooms open, room 5 shown: a full middle room with both
neighbouring rooms (4 and 6) full and drawn at reduced detail; no other room is
drawn. 20 seconds per run after a 2-second warm-up. Every stall is open, and one
diner per stall walks off with a tray each second. `near=1` places the camera
low over the middle of room 5 (`cx, 10, 12` looking at `cx, 1, 0`, where `cx`
is room 5's centre), so with `detail=1` the stalls within 28 units are drawn in
full; that is the densest view. The bench accepts `near` together with `room`
and reports the scene's current room in its result.

URLs (from `app/`, dev server on port 5199):

- `/bench.html?stalls=150&rooms=10&room=5&detail=0&seconds=20`
- `/bench.html?stalls=150&rooms=10&room=5&detail=1&seconds=20`
- `/bench.html?stalls=150&rooms=10&room=5&near=1&detail=1&seconds=20`

### Results

| view | people | frames | fps | lateShare | meanDrawMs | p95DrawMs |
| --- | --- | --- | --- | --- | --- | --- |
| room 5 overview, `detail=0` | 315 | 620 | 30.95 | 0 | 3.68 | 5.6 |
| room 5 overview, `detail=1` | 315 | 620 | 30.95 | 0 | 3.24 | 6.0 |
| room 5, `near=1&detail=1` | 403 | 620 | 30.97 | 0 | 4.17 | 6.2 |

### Pass bar

Unchanged from Project 1: on this workstation the bench at `detail=0` delivers
at least 29.5 frames per second with at most 5% late frames
(`fps ≥ 29.5`, `lateShare ≤ 0.05`). If it fails, adjacent rooms are simplified
first and the runs repeated, and what changed is recorded here.

Result: **pass**. At `detail=0` the bench delivered 30.95 frames per second with no
late frames. Each URL was run twice and the second run kept; the first runs gave
30.96 fps and 3.76 ms mean at `detail=0`, 30.95 fps and 3.47 ms at `detail=1`,
and 30.96 fps and 4.34 ms at `near=1&detail=1`, all with no late frames. Mean
draw time is about half of Project 1's figure for 150 stalls (7.5 ms), because
only the current room and its two open neighbours are drawn (315 people against
1,050). One workstation with a capable GPU; weaker hardware is not covered.

## Checks run

Run on 2026-11-14 at commit d836408 (documentation on top of the code at
f02b77d, plus the peak-sessions script change in 2765696), one file at a time,
never a whole suite at once. Running every file singly is this plan's bounded
stand-in for the full suite; it is not the full suite.

Server, from `server/` (`mix test <file> --max-cases 1`):

| Check | Result |
| --- | --- |
| `mix format --check-formatted` | clean |
| `test/feud_hall/domain/room_layout_test.exs` | 6 passed |
| `test/feud_hall/domain/rooms_test.exs` | 22 passed (4 properties, 18 tests) |
| `test/feud_hall/domain/launch_catalog_test.exs` | 6 passed |
| `test/feud_hall/domain/layout_test.exs` | 8 passed |
| `test/feud_hall/domain/dietary_and_content_test.exs` | 30 passed |
| `test/feud_hall/domain/npc_planner_test.exs` | 20 passed |
| `test/feud_hall/domain/invariants_test.exs` | 35 passed |
| `test/feud_hall/application/rooms_test.exs` | 23 passed (1 property, 22 tests) |
| `test/feud_hall/application/management_test.exs` | 12 passed (3 properties, 9 tests) |
| `test/feud_hall/application/progression_test.exs` | 12 passed (1 property, 11 tests) |
| `test/feud_hall/application/recovery_test.exs` | 41 passed |
| `test/feud_hall/application/visitor_play_test.exs` | 11 passed (1 property, 10 tests) |
| `test/feud_hall/infrastructure/hall_authority_test.exs` | 81 passed |
| `test/feud_hall/infrastructure/event_fixtures_test.exs` | 34 passed |
| `test/feud_hall/properties/hall_trace_property_test.exs` | 2 passed (1 property, 1 test) |
| `test/feud_hall/architecture_test.exs` | 6 of 7 passed; the one failure is the known one (below) |

The architecture failure is "domain modules have no outer-layer, framework,
clock, or process dependencies". It flags the compile-time `File.read!` in
`domain/content/launch_catalog.ex`, fails the same way on `main`, and stops at
that first offender, so the domain files after it are not checked by the test
(see [Testing](../../TESTING.md#implemented-backend-entry-points)). As a manual
stand-in, every domain file this branch changed was searched for the test's
forbidden references; the only hits are the two known `File.read!` lines in
`launch_catalog.ex`.

Server test files **not run** (33 of 49): `app_test`,
`application/balances_projection_test`, `application/command_workflow_test`,
`application/daily_activity_test`, `application/diagnostics_test`,
`domain/admission_test`, `domain/arrivals_test`,
`domain/automatic_kitchen_test`, `domain/choice_test`,
`domain/cleaning_and_stock_test`, `domain/clock_test`, `domain/control_test`,
`domain/demand_forecast_test`, `domain/identity_property_test`,
`domain/kitchen_test`, `domain/market_flow_test`, `domain/market_test`,
`domain/npc_actor_test`, `domain/npc_plan_test`, `domain/random_test`,
`domain/retention_test`, `domain/slice_catalog_test`,
`domain/tray_lifecycle_test`, `infrastructure/daily_activity_projector_test`,
`infrastructure/exporter_test`, `infrastructure/in_memory_event_store_test`,
`infrastructure/postgres_atomicity_test`,
`infrastructure/postgres_event_store_test`, `infrastructure/projection_test`,
`infrastructure/schema_test`, `infrastructure/snapshot_store_test`,
`properties/postgres_trace_property_test`, `web/endpoint_test`. These are left
to hosted CI.

Client, from `app/` with `NODE_OPTIONS=--max-old-space-size=1536`:

| Check | Result |
| --- | --- |
| `bun run format:check` | clean |
| `bun run lint` | clean |
| `bun check` | no type errors in 729 files (about 190 MB peak RSS) |
| `bun run --bun build` | built |

Every spec file in `app/test/browser/`, each run on its own with
`bun run test:browser <file> --workers=1` after the build:

| Spec file | Result |
| --- | --- |
| `allowance.spec.ts` | 2 passed |
| `dining-model.spec.ts` | 1 passed |
| `hall-interactions.spec.ts` | 5 passed |
| `hall-navigation.spec.ts` | 2 passed |
| `hall-rooms.spec.ts` | 23 passed |
| `journeys.spec.ts` | 6 passed |
| `launch.spec.ts` | 2 passed |
| `owner-view.spec.ts` | 1 passed |
| `participation.spec.ts` | 1 passed |
| `people-scene.spec.ts` | 1 passed |
| `people.spec.ts` | 27 passed |
| `phone-layout.spec.ts` | 3 passed |
| `release.spec.ts` | 1 passed |
| `rent.spec.ts` | 5 passed |
| `review-model.spec.ts` | 1 passed |
| `room-layout.spec.ts` | 12 passed |
| `tablet-pages.spec.ts` | 1 passed |
| `tablet-text.spec.ts` | 1 passed |
| `tray-pickup.spec.ts` | 4 passed |
| `ui-zoom.spec.ts` | 5 passed |
| `visitor-play.spec.ts` | 2 passed |

The Chromium browser checks use software rendering; they are not frame-rate
evidence.

Not run: the capacity scripts (`scripts/peak_sessions.exs`,
`scripts/capacity_bench.exs`, `scripts/capacity_restore.exs`). The
peak-sessions script now takes its spot order from the catalog (quiet spots in
ascending ID order, then the rest). A pure check against `Rooms.open?/3`
confirmed that this order, in both the one-stall and three-stall scenarios,
only ever leases spots in open rooms and ends with all ten rooms open, and that
the check itself refuses `s005` after only `s001`. For the launch layout the
order is the same `s001`..`s150` the script used before, so the old script
already satisfied the rule. The capacity benchmark places its 150 computer-run
owners one at a time through `Management.npc_layout/1`, whose fallback to the
lowest vacant spot fills each room before the next opens; the restore script
only replays. Neither needed a change, but both now run under scarcity rent, so
their rent figures differ from earlier runs.

### Known limits

- "To let" bays in the 3D view are selectable by pointer only; the list's
  **View spot** buttons are the keyboard and no-WebGL route.
- A room two doorways away is not drawn.
- The newcomer vacancy reserve in the tuning register is still not implemented.

## Trial upgrade on a copy of a real hall

Done by the controller on 2026-11-14 at commit ae6f898, before the owner's hall was
ever started on this code.

- The owner's database `feud_hall_management` was copied with `pg_dump` into a new
  database, `feud_hall_trial_rooms`, while its own server was stopped. (`createdb -T`
  was not used: the tool was not on the path.) The server from this branch was
  started against the copy on port 4010 with the hall's own signing secret.
- It answered after about four seconds. The log shows one `expand_catalog` command,
  ID `web-launch-catalog:3`, accepted with one event, and no errors.
- The view then reported `rooms: {count: 10, open: 1}`, eleven vacancies, and the
  four existing stalls unmoved, all in room 1: `s001` (quiet, position 0), `s041`
  (standard, position 1), `s101` (busy, position 7) and `s136` (prime, position
  10). The computer-run premium restaurant keeps its prime spot. Quotes for new
  leases were 9333 quiet (1 of 4 taken), 11000 standard (1 of 6), 18750 busy
  (1 of 3) and 33000 prime (1 of 2).
- Event counts, original against copy: `hall_catalog_expanded` 2 and 3;
  `stall_leased` 4 and 4; `stall_draft_reserved` 1 and 1. The upgrade added one
  event and no lease event, so no existing lease changed.
- Stopped and started again, the server issued no `expand_catalog` at all and
  logged no error.
- The copy was dropped afterwards. The original was not started on this code.

Not covered: playing on the upgraded copy (reserving a spot, a full game day).
