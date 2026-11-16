# Hall Opening Intro and Animated Shutters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll stall shutters up and down in the live hall when stalls open and close, and play a film-framed 3D "hall opening" intro while a slow first load waits for the server.

**Architecture:** A pure shutter-roll module drives both scenes. The live scene (`hall-scene.ts`) applies rolls on committed `open?` changes. Stall, light and furniture builders are extracted from the live scene so a separate, lazily imported intro scene (`hall-intro.ts`, driven by a pure timeline module) can build a made-up room from the same parts. `App.svelte` mounts the intro in the starting state and dissolves it when the first view arrives.

**Tech Stack:** Svelte 5, TypeScript, Three.js, Bun, Playwright (browser and Node-side unit specs under `app/test/browser/`).

**Spec:** `docs/superpowers/specs/2026-11-15-hall-opening-intro-design.md`

## Global Constraints

- Never run `tsc`. Use `bun check`, `bun run lint`, and `./node_modules/.bin/prettier --check <files>` from `app/`.
- Browser checks: `bun run build` then `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep '<scenario>'` from `app/`. No full suite locally.
- Every new user-visible string has English and Japanese entries in `app/src/i18n.ts`.
- Live shutters follow only the committed `open?` flag; hit-testing, blocking and inspector text keep using the committed flag.
- Shutter roll about 1.2 s (`SHUTTER_ROLL_MS = 1200`, tunable 800–1500). Intro start threshold 1.5 s (`INTRO_DELAY_MS = 1500`). Dissolve about 0.5 s (`INTRO_DISSOLVE_MS = 500`).
- Intro beats: outside 0–4 s, lights 4–8 s, shutters 8–16 s, stools 16–24 s, rise 24–30 s, hold 30 s+.
- Intro content is made up: blank signs, no names, prices, counts or server data. Framed with letterbox bars and a soft vignette.
- No intro when: a view has already been shown, WebGL is unavailable, `prefers-reduced-motion: reduce`, or the document is hidden. Every slow launch plays the full sequence; no "seen" flag.
- The live view is applied immediately on arrival; the intro never delays it and ignores pointer input while dissolving.
- Intro canvas is `aria-hidden`; the waiting status line stays visible above it; the intro never takes focus.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. The first answer lands just before 1.5 s: the intro never mounts (Task 7 test `intro: an answer just before the threshold never mounts it`).
2. The server answers quickly with 503 instead of hanging: there is still no view, so the intro plays (Task 7 test `intro: quick 503 answers still play it`).
3. A stall flips open, then closed again mid-roll: the shutter turns back from where it is, without jumping (Task 1 test `shutter roll: a reversal continues from the current level`).
4. The first answer is `client_update_required`: the intro ends and the update banner shows (Task 7 test `intro: an update-required answer ends it`).
5. The language is switched to Japanese during the intro: the caption and skip hint change language (Task 7 test `intro: switching language updates caption and hint`).

---

### Task 1: Shutter roll model

**Files:**
- Create: `app/src/shutter-roll.ts`
- Test: `app/test/browser/shutter-roll.spec.ts` (Node-side, like `people.spec.ts`)

**Interfaces:**
- Produces:
  - `export const SHUTTER_ROLL_MS = 1200;`
  - `export type ShutterRoll = { from: number; to: number; start: number };` (levels: `0` = fully up/open, `1` = fully down/closed)
  - `export function shutterLevel(roll: ShutterRoll, now: number): number` — eased (ease-in-out), clamped to `[from, to]` direction, reaches `to` at `start + SHUTTER_ROLL_MS * |to - from|`.
  - `export function rollTo(roll: ShutterRoll | undefined, closed: boolean, now: number): ShutterRoll` — starts from `shutterLevel(roll, now)` (or the target if `roll` is undefined, i.e. a first sighting: `{from: target, to: target, start: now}`).
  - `export function rolling(roll: ShutterRoll | undefined, now: number): boolean`

- [ ] **Step 1: Write the failing tests**

```ts
import { expect, test } from "./hall";
import { SHUTTER_ROLL_MS, rollTo, rolling, shutterLevel } from "../../src/shutter-roll";

test("shutter roll: a first sighting rests at its target", () => {
  const roll = rollTo(undefined, true, 1000);
  expect(shutterLevel(roll, 1000)).toBe(1);
  expect(rolling(roll, 1000)).toBe(false);
});
test("shutter roll: closing runs from 0 to 1 over the roll time", () => {
  const roll = rollTo(rollTo(undefined, false, 0), true, 0);
  expect(shutterLevel(roll, 0)).toBe(0);
  const mid = shutterLevel(roll, SHUTTER_ROLL_MS / 2);
  expect(mid).toBeGreaterThan(0.3);
  expect(mid).toBeLessThan(0.7);
  expect(shutterLevel(roll, SHUTTER_ROLL_MS)).toBe(1);
  expect(rolling(roll, SHUTTER_ROLL_MS - 1)).toBe(true);
  expect(rolling(roll, SHUTTER_ROLL_MS)).toBe(false);
});
test("shutter roll: a reversal continues from the current level", () => {
  const closing = rollTo(rollTo(undefined, false, 0), true, 0);
  const at = SHUTTER_ROLL_MS / 2;
  const level = shutterLevel(closing, at);
  const opening = rollTo(closing, false, at);
  expect(shutterLevel(opening, at)).toBeCloseTo(level, 6);
  expect(shutterLevel(opening, at + SHUTTER_ROLL_MS * level)).toBe(0);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun run test:browser --grep 'shutter roll'`
Expected: FAIL, module `../../src/shutter-roll` not found.

- [ ] **Step 3: Implement `app/src/shutter-roll.ts` with the signatures above**

- [ ] **Step 4: Run to verify they pass**

Run: `bun run test:browser --grep 'shutter roll'`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add app/src/shutter-roll.ts app/test/browser/shutter-roll.spec.ts
git commit -m "Add a shutter roll model for animated stall shutters"
```

### Task 2: Roll shutters in the live hall

**Files:**
- Modify: `app/src/hall-scene.ts` (`Counter` type near line 110, `createCounter` near line 667, view application near line 1884, `draw` near line 992, `schedule` near line 1115)
- Test: `app/test/browser/hall-shutters.spec.ts`
- Modify: `docs/TESTING.md` (management and web checks: name the new spec)

**Interfaces:**
- Consumes: Task 1 (`rollTo`, `shutterLevel`, `rolling`).
- Produces: host attribute `data-hall-shutters-moving` = number of shutters mid-roll in the last drawn frame (same pattern as `data-hall-people`, `hall-scene.ts:1079`).

- [ ] **Step 1: Write the failing browser test**

Follow `people-scene.spec.ts`: lease one stall, take the served snapshot, route `/api/state` to return it with `"open?"` flipped and `hall.position += 1`, reset the camera to its room. Tests:

```ts
test("hall shutters: a stall that closes rolls its shutter down", async ({ page, hall }) => {
  // ...open stall visible in the hall...
  // serve the same stall closed at position + 1
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "1");
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "0");
});
test("hall shutters: reduced motion snaps without rolling", async ({ page, hall }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  // same flip; poll for 1.5 s that the attribute never reads above "0"
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun run build && bun run test:browser --grep 'hall shutters'`
Expected: FAIL, attribute `data-hall-shutters-moving` missing.

- [ ] **Step 3: Implement**

- Add `roll?: ShutterRoll` to `Counter`. In view application, replace `model.shutters.visible = !model.open` with `model.roll = rollTo(model.roll, !model.open, now)`; when `appearance.motion` is false, or the counter was just created, use the first-sighting form (no roll).
- Each frame, set the shutter from `shutterLevel`: anchor at the canopy (top of the shutter at `y = 1.38 + SHUTTER_HEIGHT / 2`), `scale.y = level`, `visible = level > 0`, position shifted so the bottom edge descends from the top.
- `model.reopening.visible` becomes true only when the level reaches 1 and the committed flag is closed; it hides as soon as an opening roll starts.
- In `schedule()`, any `rolling(model.roll, now)` counts as active motion.
- Set `data-hall-shutters-moving` with the frame's count.

- [ ] **Step 4: Run to verify they pass**

Run: `bun run build && bun run test:browser --grep 'hall shutters'`
Expected: 2 passed.

- [ ] **Step 5: Show the test catches a missing roll**

Temporarily make the view application use the first-sighting form always; rebuild; run `--grep 'hall shutters: a stall that closes'`. Expected: FAIL. Restore, rebuild, re-run: PASS.

- [ ] **Step 6: Run the neighbouring live-scene scenarios**

Run: `bun run test:browser --grep 'people: the hall draws|closed|rooms'`
Expected: all passed.

- [ ] **Step 7: Check, add the TESTING.md line, and commit**

Run: `bun check && bun run lint`. Expected: no errors.

```bash
git add app/src/hall-scene.ts app/test/browser/hall-shutters.spec.ts docs/TESTING.md
git commit -m "Roll live stall shutters when stalls open and close"
```

### Task 3: Extract shared stall, light and furniture builders

**Files:**
- Create: `app/src/stall-model.ts`, `app/src/hall-lights.ts`
- Modify: `app/src/hall-scene.ts` (move code out; behaviour unchanged), `app/src/hall-shell.ts` (export furniture parts)

**Interfaces:**
- Consumes: Task 2's roll handling (moves with the shutter).
- Produces:
  - `stall-model.ts`: `export type StallLook = { cuisine: string };` `export type StallParts = { root: T.Group; trim: T.Group; shutters: T.Mesh; sign: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial> };` `export function createStallKit(box: T.BoxGeometry): { build(look: StallLook, placement: SpotPlacement): StallParts; paintShutters(label: string): void; applyShutter(parts: StallParts, level: number): void; dispose(): void };` plus `shutterTexture` and the `SHUTTER_*` constants moved here. `build` covers what `createCounter` builds that needs no live view (walls, slate, canopy and trim, counter, shutters, sign plane); live-only parts (tablet, pickup, service lamp, placard, plaque, hit and edge meshes) stay in `hall-scene.ts`.
  - `hall-lights.ts`: `export function createHallLights(scene: T.Scene): { setLevel(level: number): void; dispose(): void };` (level `1` = today's intensities 2.4 / 2.2 / 0.95; `0` = night).
  - `hall-shell.ts`: `export function createFurniture(): { tableGeometry: T.BufferGeometry; seatGeometry: T.BufferGeometry; tableTop: T.Material; seat: T.Material; dispose(): void };` reused by the shell's own instanced tables and seats.

- [ ] **Step 1: Move the code; keep `createHallScene` calling the new builders**

- [ ] **Step 2: Verify behaviour is unchanged**

Run: `bun check && bun run lint && bun run build && bun run test:browser --grep 'hall shutters|people: the hall draws|closed|rooms|interactions'`
Expected: no type or lint errors; all passed.

- [ ] **Step 3: Commit**

```bash
git add app/src/stall-model.ts app/src/hall-lights.ts app/src/hall-scene.ts app/src/hall-shell.ts
git commit -m "Extract stall, light and furniture builders from the hall scene"
```

### Task 4: Intro timeline

**Files:**
- Create: `app/src/hall-intro-timeline.ts`
- Test: `app/test/browser/hall-intro-timeline.spec.ts` (Node-side)

**Interfaces:**
- Produces:
  - `export const INTRO_BEATS = { outside: 0, lights: 4000, shutters: 8000, stools: 16000, rise: 24000, hold: 30000 } as const;`
  - `export type Beat = keyof typeof INTRO_BEATS;`
  - `export type IntroFrame = { beat: Beat; camera: [number, number, number]; target: [number, number, number]; light: number; sign: boolean; shutterLevels: number[]; stoolProgress: number };`
  - `export function introFrame(ms: number, stalls: number, skippedAt?: number): IntroFrame` — pure. Camera starts outside `entrance(1).outside` at eye height 1.55, passes `entrance(1).inside` during lights, walks the aisle during shutters, rises to a high overview by 30 s, then orbits room 1's centre (one turn per 90 s) with `light = 1`, all shutters `0`, `stoolProgress = 1`. `skippedAt` jumps straight to the hold state, with the orbit phase measured from `skippedAt`.

- [ ] **Step 1: Write the failing tests**

```ts
// imports: introFrame from ../../src/hall-intro-timeline; roomAt from ../../src/room-layout
test("intro timeline: beats change at their boundaries", () => {
  expect(introFrame(0, 9).beat).toBe("outside");
  expect(introFrame(3999, 9).beat).toBe("outside");
  expect(introFrame(4000, 9).beat).toBe("lights");
  expect(introFrame(8000, 9).beat).toBe("shutters");
  expect(introFrame(16000, 9).beat).toBe("stools");
  expect(introFrame(24000, 9).beat).toBe("rise");
  expect(introFrame(30000, 9).beat).toBe("hold");
});
test("intro timeline: dark and shut outside, lit and open in the hold", () => {
  const start = introFrame(0, 9);
  expect(start.light).toBe(0);
  expect(start.sign).toBe(false);
  expect(start.shutterLevels).toEqual(Array(9).fill(1));
  const hold = introFrame(40000, 9);
  expect(hold.light).toBe(1);
  expect(hold.shutterLevels).toEqual(Array(9).fill(0));
  expect(hold.stoolProgress).toBe(1);
});
test("intro timeline: shutters rise one after another", () => {
  const f = introFrame(12000, 9);
  expect(f.shutterLevels[0]).toBe(0);
  expect(f.shutterLevels[8]).toBe(1);
});
test("intro timeline: the camera starts outside the entrance and keeps moving in the hold", () => {
  expect(introFrame(0, 9).camera[1]).toBeCloseTo(1.55);
  // outside the room footprint at the start
  expect(roomAt(introFrame(0, 9).camera[0], introFrame(0, 9).camera[2])).toBeNull();
  expect(introFrame(40000, 9).camera).not.toEqual(introFrame(50000, 9).camera);
});
test("intro timeline: a skip jumps to the hold", () => {
  expect(introFrame(5000, 9, 5000).beat).toBe("hold");
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun run test:browser --grep 'intro timeline'`. Expected: FAIL, module not found.

- [ ] **Step 3: Implement `introFrame` with the values above**

- [ ] **Step 4: Run to verify they pass**

Run: `bun run test:browser --grep 'intro timeline'`. Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add app/src/hall-intro-timeline.ts app/test/browser/hall-intro-timeline.spec.ts
git commit -m "Add the hall opening intro timeline"
```

### Task 5: Intro scene

**Files:**
- Create: `app/src/hall-intro.ts`

**Interfaces:**
- Consumes: Task 3 (`createStallKit`, `createHallLights`, `createFurniture`), `createHallShell` (walls for room 1), `createPeople` and `personLook` (`people-mesh.ts`, `people.ts`), `spotPlacement`, `tableSpots`, `seatSpots`, `entrance` (`room-layout.ts`), Task 4 (`introFrame`).
- Produces: `export function createHallIntro(host: HTMLElement, onFail: () => void): { skip(): void; dispose(): void } | null` — `null` if a WebGL renderer cannot be created. Builds room 1 with 9 made-up stalls in real spot positions (blank signs, shutters painted with an empty label), drives everything from `introFrame` on each animation frame (32 ms interval), pauses while `document.hidden`, and sets `host.dataset.introBeat` to the current beat. Staff use the worker look and slide the stools from offset positions to their seats as `stoolProgress` goes 0 → 1. During the hold, diners (diner looks) walk in from `entrance(1).outside` and queue at stalls, at most 4 per stall, figures only. On WebGL context loss it calls `onFail`.

- [ ] **Step 1: Implement `createHallIntro`**

- [ ] **Step 2: Check it compiles and lints**

Run: `bun check && bun run lint`. Expected: no errors. Behaviour is verified through the component in Task 7.

- [ ] **Step 3: Commit**

```bash
git add app/src/hall-intro.ts
git commit -m "Build the hall opening intro scene from shared parts"
```

### Task 6: Intro component

**Files:**
- Create: `app/src/HallIntro.svelte`
- Modify: `app/src/i18n.ts` (`introSkip` in both catalogs)

**Interfaces:**
- Consumes: Task 5 (`createHallIntro`).
- Produces: `HallIntro.svelte` with props `{ ending: boolean; t: (key: Key) => string; onEnded: () => void; onFail: () => void }`. It renders `<div data-hall-intro aria-hidden="true">` filling the page body area below the navigation, with letterbox bars and a radial vignette in CSS. A skip hint (`t("introSkip")`) shows for the first 6 s. Any `pointerdown` or `keydown` on the window calls `skip()` while not `ending`. When `ending` turns true, it fades to opacity 0 over `INTRO_DISSOLVE_MS = 500` with `pointer-events: none`, disposes the scene, then calls `onEnded`.
- Strings: `introSkip: "Click or press any key to skip"`, and in Japanese `introSkip: "クリックするか、いずれかのキーを押すとスキップします"`.

- [ ] **Step 1: Implement the component and the two catalog entries**

- [ ] **Step 2: Check**

Run: `bun check && bun run lint`. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add app/src/HallIntro.svelte app/src/i18n.ts
git commit -m "Add the film-framed hall intro component"
```

### Task 7: Play the intro during slow first loads

**Files:**
- Modify: `app/src/App.svelte` (starting state, `refresh()` near line 1203, the `{#if !view}` block near line 2455)
- Test: `app/test/browser/hall-intro.spec.ts`
- Modify: `docs/TESTING.md` (name the new spec)

**Interfaces:**
- Consumes: Task 6 (`HallIntro.svelte`, loaded with `import("./HallIntro.svelte")` only when it is about to mount).
- Produces: `INTRO_DELAY_MS = 1500` in `App.svelte`. The intro state is `"idle" | "playing" | "ending"`. It moves to `"playing"` when `INTRO_DELAY_MS` passes after the first `refresh()` starts, with no view, motion allowed, WebGL available and the document visible. It moves to `"ending"` as soon as `view` is set or `updateRequired` becomes true. `onEnded` and `onFail` return it to `"idle"` for good in this page load; a rejected dynamic import, or `createHallIntro` returning `null`, counts as `onFail`.

- [ ] **Step 1: Write the failing browser tests**

Install `page.clock` **before** `page.goto` (see the project note on fake clocks). Hold `/api/state` with a route that resolves only when the test releases it.

```ts
test("intro: an answer just before the threshold never mounts it", ...)  // release at 1400 ms; runFor(3000); expect [data-hall-intro] count 0
test("intro: a slow first load plays it after 1.5 s", ...)               // runFor(1499) count 0; runFor(2) visible; data-intro-beat "outside"
test("intro: the waiting status stays visible during it", ...)           // getByRole("status") has "Waiting for the hall to respond." while intro visible
test("intro: the answer shows the page at once and dissolves it", ...)   // release; hall controls (e.g. "Reset camera") clickable before runFor(500); after runFor(600) count 0
test("intro: a skip jumps to the hold", ...)                              // keyboard.press("Space"); data-intro-beat "hold"
test("intro: quick 503 answers still play it", ...)                       // fulfil 503 {error:"unavailable"}; runFor(1600); visible
test("intro: an update-required answer ends it", ...)                     // after visible, fulfil 426 client_update_required; intro gone; update text visible
test("intro: switching language updates caption and hint", ...)           // select ja; hint and status show the Japanese strings
test("intro: reduced motion or no WebGL keeps the text screen", ...)      // emulateMedia reducedMotion; and an addInitScript making getContext("webgl"/"webgl2") return null; count 0 after 2 s
test("intro: a second slow load plays it again", ...)                     // reload with the answer held; beat "outside" again
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun run build && bun run test:browser --grep 'intro:'`
Expected: FAIL, `[data-hall-intro]` never appears.

- [ ] **Step 3: Implement the trigger, mounting and ending in `App.svelte`**

- [ ] **Step 4: Run to verify they pass**

Run: `bun run build && bun run test:browser --grep 'intro:'`
Expected: 10 passed.

- [ ] **Step 5: Show the tests catch a missing guard**

Temporarily drop the `!view` condition from the trigger; rebuild; run `--grep 'intro: an answer just before'`. Expected: FAIL. Restore, rebuild, re-run: PASS.

- [ ] **Step 6: Re-run the starting-banner scenario and checks**

Run: `bun run test:browser --grep 'unanswered first load' && bun check && bun run lint`
Expected: passed; no errors.

- [ ] **Step 7: Format, add the TESTING.md line, commit**

Run: `./node_modules/.bin/prettier --check src test/browser` on the changed files and fix any reported.

```bash
git add app/src/App.svelte app/test/browser/hall-intro.spec.ts docs/TESTING.md
git commit -m "Play the hall opening intro while a slow first load waits"
```
