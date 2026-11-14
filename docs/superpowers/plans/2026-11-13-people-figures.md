# People Figures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hall's capsule-and-ball people with the rounded, code-built figures the owner approved, drawn in batches and reusable by later scenes.

**Architecture:** A pure module (`people.ts`) turns a stable serial into a look and a pose into per-part transforms; a small Three.js module (`people-mesh.ts`) owns one instanced mesh per body part and fills it each frame; `hall-scene.ts` stops building bodies itself and calls that renderer. A dev-only bench page measures frame delivery before and after.

**Tech Stack:** TypeScript, Three.js 0.187, Bun 1.4.4, Playwright test runner with fast-check (pure-logic specs live beside browser specs in `app/test/browser/`), Vite dev server for the bench.

**Spec:** [docs/superpowers/specs/2026-11-13-livelier-hall-design.md](../specs/2026-11-13-livelier-hall-design.md), section "Project 1: People". Read it and [AGENTS.md](../../../AGENTS.md) before starting.

## Global Constraints

- Figures are built in code from basic shapes. No imported or downloaded models, no new art files, no new dependencies.
- Figures stay batched: one instanced mesh per body part, no per-person draw calls.
- Every person uses the figure: diners, kitchen staff and owners. The first-person pickup arms in `app/src/hall-pickup.ts` are unchanged.
- A person's look is a pure function of a stable serial and a role. It never changes between frames or snapshots.
- Owners wear an apron. Nobody else does.
- This plan adds the standing, walking and tray-carrying poses the hall uses today. The seated and cart-pushing poses the spec mentions are added to the same module by Projects 3 and 5, not here.
- This is presentation only. No command is sent, no server file changes, and `app/src/hall-layout.ts` stall placement is not touched (that is Project 2).
- Pass bar: on this workstation, the bench at `stalls=150&detail=0` delivers at least 29.5 frames per second with at most 5% late frames (the scene paces active frames at 32 ms, so 30 fps is its ceiling). A result below that sends the work back to simplify the figure.
- Never run local `tsc`. Never run a full test suite: always pass `--grep`. Run checks serially; stop anything above 2 GiB combined RSS. Prefix every command that launches Node with `NODE_OPTIONS=--max-old-space-size=1536`.
- All commands run from `app/` unless a step says otherwise.
- Work on a branch named `people-figures` cut from `main`. Do not push. End every commit message with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- No user-facing strings are added, so there are no English or Japanese catalog changes.

## Review Focus

1. **Motion switched off.** With reduced motion the scene passes no gait. A person posed with `walking: false` must ignore any `stride` value and stand still. Test in Task 3.
2. **Any serial at all.** Diner serials grow without bound and may be hashed from negative numbers. Every integer must yield in-range colours and finite sizes. Test in Task 2.
3. **More people than slots.** A full hall can ask for more figures than the batch holds. Extra people are dropped whole, never written past the buffer and never half-drawn. Test in Task 4.
4. **Fully faded walkers.** A walker whose opacity has reached zero must take no batch slot. Test in Task 4.
5. **Teardown.** Leaving the hall or losing WebGL disposes the scene. Every geometry and material the people renderer made must be disposed exactly once. Test in Task 4.

## File Structure

| File | Responsibility |
| --- | --- |
| `app/src/people.ts` (create) | Pure. Figure proportions, `personLook`, `posePerson`, `carryPoint`. Imports only Three.js maths. |
| `app/src/people-mesh.ts` (create) | Three.js. One instanced mesh per part, per-frame fill, disposal. |
| `app/src/hall-layout.ts` (modify) | Gains the stall-local `QUEUE_SPOTS` and `STAFF_SPOTS` moved out of the scene. |
| `app/src/hall-scene.ts` (modify) | Drops its own body, head, leg and arm batches and pose maths; calls the people renderer. Gains an optional frame callback and a people count attribute. |
| `app/bench.html`, `app/src/bench/hall-bench.ts` (create) | Dev-only page that mounts the real scene with a synthetic hall and reports frame delivery. |
| `app/test/browser/people.spec.ts` (create) | Pure tests for look, pose, renderer and queue spacing. |
| `app/test/browser/people-scene.spec.ts` (create) | Browser regression that the live hall draws people. |
| `docs/superpowers/reports/2026-11-13-people-frame-time.md` (create) | Before and after measurements with hardware. |
| `docs/TESTING.md`, `docs/GAME_DESIGN.md` (modify) | How to run the bench; what people look like. |

---

### Task 1: Frame bench and baseline

Measure today's figures before changing them.

**Files:**
- Create: `app/bench.html`, `app/src/bench/hall-bench.ts`
- Modify: `app/src/hall-scene.ts` (the `Actions` type near line 34 and the end of `draw()` near line 1300)
- Modify: `docs/TESTING.md` (section "Management and web checks")
- Create: `docs/superpowers/reports/2026-11-13-people-frame-time.md`

**Interfaces:**
- Produces: `Actions.frame?: (drawMs: number) => void`, called once at the end of every `draw()` with that call's duration in milliseconds.
- Produces: the bench URL `/bench.html?stalls=<1..150>&detail=<0|1>&seconds=<n>` and, when the run ends, an element `[data-bench-result]` whose text is JSON `{ stalls, detail, seconds, frames, fps, lateShare, meanDrawMs, p95DrawMs, renderer }`. `lateShare` is the fraction of intervals between consecutive frames longer than 40 ms. `renderer` is the WebGL unmasked renderer string, or `"unknown"`.

- [ ] **Step 1: Create the branch**

```bash
git -C .. switch -c people-figures
```

- [ ] **Step 2: Add the optional frame callback**

In `Actions`, add `frame?: (drawMs: number) => void`. In `draw()`, record `performance.now()` on entry and call `actions.frame?.(elapsed)` after the `renderer.render` try/catch. `HallScene.svelte` does not pass it, so the app is unaffected.

- [ ] **Step 3: Write the bench**

`app/bench.html` is a bare page with a full-window `<div id="hall">` and a module script loading `/src/bench/hall-bench.ts`.

`hall-bench.ts` calls `createHallScene(host, actions)` with no-op actions plus `frame`, then `scene.update(appearance)` with a synthetic `Appearance`: `stalls` generated stalls, each open, with `activity` of 9 workers, 4 waiting, 2 cooking and `staffed: true`; `detail` from the query; `motion: true`; no tablet, no pickups, empty labels. Read the `Stall` type in `app/src/api.ts` for required fields. It keeps the scene animating for `seconds`, collects every `frame` duration and timestamp, then writes the result element. Defaults: `stalls=150`, `detail=0`, `seconds=20`.

- [ ] **Step 4: Run the baseline**

Start the dev server and open both URLs in a GPU-backed browser window that stays visible and focused for the whole run (a hidden tab stops the scene drawing):

```bash
NODE_OPTIONS=--max-old-space-size=1536 bun run dev -- --port 5199
```

- `http://localhost:5199/bench.html?stalls=150&detail=0&seconds=20`
- `http://localhost:5199/bench.html?stalls=150&detail=1&seconds=20`

Expected: each page ends showing a JSON result with `frames` above 0. Run each twice and keep the second.

- [ ] **Step 5: Record the baseline**

Create the report with: date, machine model, GPU (`renderer`), browser and version, display refresh rate, the commit measured, and a table with one row per run (`detail`, `fps`, `lateShare`, `meanDrawMs`, `p95DrawMs`) under the heading "Before: capsule figures". Add a short "How to run the frame bench" entry to `docs/TESTING.md` giving the command and URLs above and stating that software-rendered browsers are not valid evidence.

- [ ] **Step 6: Check and commit**

```bash
bun run format:check && bun run lint && bun check
git -C .. add app/bench.html app/src/bench app/src/hall-scene.ts docs/TESTING.md docs/superpowers/reports/2026-11-13-people-frame-time.md
git -C .. commit -m "Add a hall frame bench and record the baseline"
```

Expected: all three checks pass before the commit.

---

### Task 2: A person's look

**Files:**
- Create: `app/src/people.ts`
- Test: `app/test/browser/people.spec.ts`

**Interfaces:**
- Produces:

```ts
export type Role = "diner" | "owner" | "worker";
export type HairStyle = "short" | "long" | "bun" | "cap";
export type Look = {
  shirt: number; skin: number; hair: number; trousers: number; hat: number; // 0xRRGGBB
  hairStyle: HairStyle; skirt: boolean; shortSleeves: boolean; apron: boolean;
  height: number; // world units
  width: number;  // multiplier on body width
};
export function personLook(serial: number, role: Role): Look;
```

Values the spec and the approved preview pin:

- Height is `1.5 × f` with `f` in `[0.92, 1.08]`; width is in `[0.9, 1.1]`.
- Shirt palette (the scene's existing nine): `e27158 548bd3 cca756 5d9c79 9766bd c36491 aab6c0 3a807d ad855f`.
- Skin palette (the scene's existing six): `f1c3a0 9d6146 c28a63 e6ad79 704331 b57a57`.
- Hair palette: `2a1d17 4a3222 111014 8a5a2e b9b2aa 5c2e1e`. Trousers palette: `515068 3b4252 6b5a4a 2f3440 7a6f8a`.
- `hat` is a shirt-palette colour different from `shirt`; it colours the cap when `hairStyle` is `"cap"`.
- Owner: `shirt` is `0xff9e57` and `apron` is true. Worker: `shirt` is `0x8de2d1`. Only owners have `apron` true.
- Traits are drawn from independent bits of a 32-bit mix of the serial, so hair style, skirt and sleeves are not correlated.

- [ ] **Step 1: Write the failing tests**

```ts
import fc from "fast-check";
import { expect, test } from "./hall";
import { personLook } from "../../src/people";

test("people: a look is a pure function of serial and role", () => {
  expect(personLook(42, "diner")).toEqual(personLook(42, "diner"));
  fc.assert(
    fc.property(fc.integer(), fc.constantFrom("diner", "owner", "worker"), (serial, role) => {
      const look = personLook(serial, role);
      expect(look.height).toBeGreaterThanOrEqual(1.38);
      expect(look.height).toBeLessThanOrEqual(1.62);
      expect(look.width).toBeGreaterThanOrEqual(0.9);
      expect(look.width).toBeLessThanOrEqual(1.1);
      for (const colour of [look.shirt, look.skin, look.hair, look.trousers, look.hat])
        expect(Number.isInteger(colour) && colour >= 0 && colour <= 0xffffff).toBe(true);
    }),
  );
});

test("people: roles dress as the design says", () => {
  for (let serial = 0; serial < 200; serial++) {
    expect(personLook(serial, "owner")).toMatchObject({ apron: true, shirt: 0xff9e57 });
    expect(personLook(serial, "worker")).toMatchObject({ apron: false, shirt: 0x8de2d1 });
    expect(personLook(serial, "diner").apron).toBe(false);
  }
});

test("people: a queue of diners is not a row of clones", () => {
  const looks = Array.from({ length: 1000 }, (_, serial) => personLook(serial, "diner"));
  expect(new Set(looks.map((l) => l.shirt)).size).toBe(9);
  expect(new Set(looks.map((l) => l.skin)).size).toBe(6);
  expect(new Set(looks.map((l) => `${l.hairStyle}/${l.skirt}/${l.shortSleeves}`)).size).toBe(16);
  const twins = looks.filter(
    (l, i) => i > 0 && l.shirt === looks[i - 1].shirt && l.hairStyle === looks[i - 1].hairStyle,
  ).length;
  expect(twins).toBeLessThan(100);
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people: (a look|roles|a queue)'`
Expected: FAIL, `personLook` is not exported.

- [ ] **Step 3: Implement `personLook` in `app/src/people.ts`**

- [ ] **Step 4: Run them and see them pass**

Run the Step 2 command. Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git -C .. add app/src/people.ts app/test/browser/people.spec.ts
git -C .. commit -m "Derive a stable look for each person"
```

---

### Task 3: Posing a person

**Files:**
- Modify: `app/src/people.ts`
- Test: `app/test/browser/people.spec.ts`

**Interfaces:**
- Consumes: `Look` from Task 2.
- Produces:

```ts
export type PartKind =
  | "torso" | "skirt" | "apron" | "neck" | "head"
  | "hairCap" | "hairLong" | "hairBun" | "hairBrim"
  | "upperLeg" | "lowerLeg" | "foot" | "upperArm" | "forearm" | "hand";
export const PART_KINDS: readonly PartKind[]; // all fifteen, in the order above
export type Detail = "full" | "simple";
export type Pose = {
  x: number; z: number;  // hall position of the feet
  yaw: number;           // body heading; forward is +Z at yaw 0
  faceYaw: number;       // extra head turn
  stride: number;        // -1..1, sign picks the leading leg
  walking: boolean;
  carrying: boolean;     // both hands hold a tray in front
};
export const FIGURE: { readonly headY: number; readonly [joint: string]: number }; // unit-height proportions from the table below
export const FIGURE_MAX_SPAN: number; // widest shoulder span of any look, world units
export function posePerson(
  look: Look, pose: Pose, detail: Detail,
  emit: (kind: PartKind, matrix: T.Matrix4, colour: number) => void,
): void;
export function carryPoint(look: Look, stride?: number): { y: number; forward: number }; // stride defaults to 0
```

Rules the tests rely on:

- `emit` receives a reused matrix; callers copy it before the next call.
- A paired part is emitted left (−X) first, then right (+X).
- Each part's geometry is authored for a figure one unit tall and centred on that part's own reference point: the centre for torso, head, neck, foot, hand, skirt, apron and hair parts; the upper joint (hip, knee, shoulder, elbow) for limb segments. The emitted matrix places that reference point, so its translation is where the part is. `posePerson` applies the person's root: translate to `(x, 0, z)`, rotate by `yaw`, scale by `(height × width, height, height × width)`.
- `walking: false` ignores `stride`.
- `"full"` emits torso, neck, head, hairCap, two each of upperLeg, lowerLeg, foot, upperArm, forearm and hand; plus skirt when `look.skirt`, apron when `look.apron`, and one of hairLong, hairBun or hairBrim when the style is long, bun or cap.
- `"simple"` emits torso, head, hairCap, two upperLeg and two upperArm, each limb drawn as one longer piece; plus skirt and apron on the same conditions. Nothing else.
- Colours: torso, upperArm and skirt use `shirt`; forearm uses `skin` with short sleeves, else `shirt`; legs use `trousers`, or `skin` under a skirt; head, neck and hand use `skin`; hair parts use `hair`, except hairCap and hairBrim use `hat` for the cap style; apron is `0xf3e6d0`; foot is `0x2b2623`.
- `carryPoint` returns the height and forward offset of the midpoint between the hands in the carrying pose at that stride, including the walking bob, so a carried tray stays in the hands.
- `FIGURE_MAX_SPAN` is the outer shoulder-to-shoulder width, arms included, of the tallest and widest look.

Unit-figure proportions from the approved preview. Treat them as the starting point; adjust only to fix a visible fault:

| Joint or part | Value (figure height = 1) |
| --- | --- |
| Hip pivots | y 0.44, x ±0.065 |
| Knee below hip, ankle below knee | 0.22, 0.20 |
| Upper and lower leg radius | 0.052, 0.043 |
| Torso | centre y 0.60, radius 0.115, straight length 0.17, 1.12 wide, 0.78 deep |
| Neck, head centre, head radius | y 0.82, y 0.92, 0.10 (head 1.1 tall) |
| Shoulder pivots | y 0.745, x ±0.165, arms angled out 0.12 rad |
| Elbow below shoulder, hand below elbow | 0.18, 0.185 |
| Upper arm, forearm, hand radius | 0.040, 0.034, 0.040 |
| Walk at full stride | hip swing ±0.55 rad, trailing knee bend 0.9 rad, arm swing ±0.5 rad opposite the same-side leg, bob 0.015 |

- [ ] **Step 1: Write the failing tests**

Add to `people.spec.ts` (extend the imports with `* as T from "three"` and the new names):

```ts
const stand: Pose = { x: 0, z: 0, yaw: 0, faceYaw: 0, stride: 0, walking: false, carrying: false };
function parts(look: Look, pose: Pose = stand, detail: Detail = "full") {
  const out: { kind: PartKind; at: T.Vector3; colour: number }[] = [];
  posePerson(look, pose, detail, (kind, matrix, colour) =>
    out.push({ kind, at: new T.Vector3().setFromMatrixPosition(matrix), colour }),
  );
  return out;
}
const count = (list: { kind: PartKind }[], kind: PartKind) => list.filter((p) => p.kind === kind).length;
const lookWith = (wanted: Partial<Look>, role: Role = "diner") => {
  for (let serial = 0; serial < 5000; serial++) {
    const look = personLook(serial, role);
    if (Object.entries(wanted).every(([k, v]) => look[k as keyof Look] === v)) return look;
  }
  throw new Error("no such look");
};

test("people: a full figure has every part once per side", () => {
  const plain = parts(lookWith({ hairStyle: "short", skirt: false }));
  expect(plain.map((p) => p.kind).sort()).toEqual(
    ["torso", "neck", "head", "hairCap",
     "upperLeg", "upperLeg", "lowerLeg", "lowerLeg", "foot", "foot",
     "upperArm", "upperArm", "forearm", "forearm", "hand", "hand"].sort(),
  );
  expect(count(parts(lookWith({ skirt: true })), "skirt")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "bun" })), "hairBun")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "long" })), "hairLong")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "cap" })), "hairBrim")).toBe(1);
  expect(count(parts(personLook(3, "owner")), "apron")).toBe(1);
});

test("people: a simple figure keeps the silhouette and the owner's apron", () => {
  const simple = parts(lookWith({ hairStyle: "bun", skirt: false }, "owner"), stand, "simple");
  expect(simple.map((p) => p.kind).sort()).toEqual(
    ["torso", "head", "hairCap", "apron", "upperLeg", "upperLeg", "upperArm", "upperArm"].sort(),
  );
});

test("people: a figure stands on the floor at its own height", () => {
  const look = personLook(7, "diner");
  const list = parts(look);
  for (const part of list) expect(part.at.y).toBeGreaterThanOrEqual(0);
  const head = list.find((p) => p.kind === "head")!;
  expect(head.at.y).toBeCloseTo(look.height * FIGURE.headY, 6);
  expect(head.at.x).toBeCloseTo(0, 6);
  expect(head.at.z).toBeCloseTo(0, 6);
});

test("people: turning the body turns every part about the feet", () => {
  fc.assert(
    fc.property(fc.integer(), fc.double({ min: -Math.PI, max: Math.PI, noNaN: true }),
      fc.double({ min: -50, max: 50, noNaN: true }), fc.double({ min: -50, max: 50, noNaN: true }),
      (serial, yaw, x, z) => {
        const look = personLook(serial, "diner");
        const base = parts(look);
        const turned = parts(look, { ...stand, x, z, yaw });
        base.forEach((part, i) => {
          const want = part.at.clone().applyAxisAngle(new T.Vector3(0, 1, 0), yaw).add(new T.Vector3(x, 0, z));
          expect(turned[i].at.distanceTo(want)).toBeLessThan(1e-6);
        });
      }),
  );
});

test("people: walking swings opposite legs and arms, and standing ignores stride", () => {
  const look = personLook(11, "diner");
  const walk = (stride: number) => parts(look, { ...stand, stride, walking: true });
  const feet = (list: ReturnType<typeof parts>) => list.filter((p) => p.kind === "foot");
  const hands = (list: ReturnType<typeof parts>) => list.filter((p) => p.kind === "hand");
  const [left, right] = feet(walk(0.8));
  expect(Math.sign(left.at.z)).toBe(-Math.sign(right.at.z));
  expect(Math.sign(feet(walk(-0.8))[0].at.z)).toBe(-Math.sign(left.at.z));
  expect(Math.sign(hands(walk(0.8))[0].at.z)).toBe(-Math.sign(left.at.z));
  const [lead, trail] = left.at.z > right.at.z ? [left, right] : [right, left];
  expect(trail.at.y).toBeGreaterThan(lead.at.y);
  expect(parts(look, { ...stand, stride: 0.8, walking: false })).toEqual(parts(look));
});

test("people: carrying holds both hands level in front, where carryPoint says", () => {
  const look = personLook(5, "diner");
  for (const stride of [0, 0.8, -0.8]) {
    const [left, right] = parts(look, { ...stand, stride, walking: true, carrying: true })
      .filter((p) => p.kind === "hand");
    expect(left.at.y).toBeCloseTo(right.at.y, 6);
    expect(left.at.z).toBeCloseTo(right.at.z, 6);
    expect(left.at.z).toBeGreaterThan(0.15 * look.height);
    expect(carryPoint(look, stride).y).toBeCloseTo(left.at.y, 6);
    expect(carryPoint(look, stride).forward).toBeCloseTo(left.at.z, 6);
  }
});

test("people: every pose is finite, and no look is wider than the stated span", () => {
  fc.assert(
    fc.property(fc.integer(), fc.double({ min: -1, max: 1, noNaN: true }), fc.boolean(), fc.boolean(),
      fc.constantFrom<Detail>("full", "simple"), (serial, stride, walking, carrying, detail) => {
        const look = personLook(serial, "diner");
        posePerson(look, { ...stand, stride, walking, carrying }, detail, (_kind, matrix) => {
          expect(matrix.elements.every(Number.isFinite)).toBe(true);
        });
        const xs = parts(look).filter((p) => p.kind === "upperArm").map((p) => p.at.x);
        expect(Math.abs(xs[1] - xs[0])).toBeLessThanOrEqual(FIGURE_MAX_SPAN);
      }),
  );
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people:'`
Expected: the three Task 2 tests pass; the seven new ones FAIL on missing exports.

- [ ] **Step 3: Implement `FIGURE`, `FIGURE_MAX_SPAN`, `PART_KINDS`, `posePerson` and `carryPoint` in `app/src/people.ts`**

Compose joints with reused `T.Object3D` or matrix objects held at module level; allocate nothing per call.

- [ ] **Step 4: Run them and see them pass**

Run the Step 2 command. Expected: 10 passed.

- [ ] **Step 5: Commit**

```bash
git -C .. add app/src/people.ts app/test/browser/people.spec.ts
git -C .. commit -m "Pose a rounded figure from a look and a gait"
```

---

### Task 4: The batched renderer

**Files:**
- Create: `app/src/people-mesh.ts`
- Test: `app/test/browser/people.spec.ts`

**Interfaces:**
- Consumes: `Look`, `Pose`, `Detail`, `PartKind`, `PART_KINDS`, `FIGURE`, `posePerson` from Tasks 2 and 3.
- Produces:

```ts
export type People = {
  begin(): void;                                   // start a frame: nobody drawn yet
  add(look: Look, pose: Pose, detail: Detail, opacity?: number): void; // opacity defaults to 1
  end(): void;                                     // flag buffers for upload
  readonly count: number;                          // people accepted since begin()
  mesh(kind: PartKind): T.InstancedMesh;
  readonly meshes: readonly T.InstancedMesh[];     // one per PartKind
  dispose(): void;
};
export function createPeople(capacity: number, faces: T.Texture | null): People;
```

Decisions:

- One `T.InstancedMesh` per `PartKind`, fifteen in all whatever the capacity. Paired kinds hold `2 × capacity` instances, the rest `capacity`.
- Each geometry is authored for the unit figure in `FIGURE`, so the matrices from `posePerson` place it directly.
- Per-instance colour and opacity use an instanced four-component `color` attribute read as vertex colours, the technique `translucentActors` in `hall-scene.ts` uses today.
- Material: `MeshStandardMaterial` with `roughness: 0.9`, `vertexColors: true` and `alphaHash: true`. Alpha hashing keeps depth writes on, so a fading figure's own limbs do not show through its body, and one mesh serves both solid and fading people. The head material also takes `map: faces`.
- If Task 5's visual check shows the pinned Three.js not fading people with this material, fall back to what the scene does today, a second transparent set of meshes with depth writes off for people whose opacity is below 1, behind the same `People` interface. Record which approach shipped in the Task 6 report.
- A person who does not fit, or whose opacity is 0 or less, is skipped whole: no part written, `count` unchanged.
- Meshes are created with `frustumCulled = false`, `count = 0` and dynamic usage on the matrix and colour buffers, as the scene does for its current batches. The caller adds them to its scene.

- [ ] **Step 1: Write the failing tests**

```ts
test("people: each person fills one batch slot per part, and a frame starts empty", () => {
  expect(createPeople(1, null).meshes.length).toBe(15);
  expect(createPeople(500, null).meshes.length).toBe(15);
  const people = createPeople(4, null);
  people.begin();
  people.add(lookWith({ hairStyle: "short", skirt: false }), stand, "full");
  people.end();
  expect(people.count).toBe(1);
  expect(people.mesh("head").count).toBe(1);
  expect(people.mesh("upperLeg").count).toBe(2);
  expect(people.mesh("skirt").count).toBe(0);
  people.begin();
  people.end();
  expect(people.count).toBe(0);
  for (const mesh of people.meshes) expect(mesh.count).toBe(0);
});

test("people: someone who does not fit, or has faded out, is skipped whole", () => {
  const people = createPeople(1, null);
  people.begin();
  people.add(personLook(1, "diner"), stand, "full", 0);
  expect(people.count).toBe(0);
  people.add(personLook(1, "diner"), stand, "full");
  people.add(personLook(2, "diner"), stand, "full");
  people.end();
  expect(people.count).toBe(1);
  expect(people.mesh("head").count).toBe(1);
  expect(people.mesh("hand").count).toBe(2);
});

test("people: colour and opacity are written per person", () => {
  const people = createPeople(2, null);
  const look = personLook(9, "diner");
  people.begin();
  people.add(look, stand, "full", 0.4);
  people.end();
  const colour = people.mesh("head").geometry.getAttribute("color");
  const skin = new T.Color(look.skin);
  expect(colour.getX(0)).toBeCloseTo(skin.r, 5);
  expect(colour.getY(0)).toBeCloseTo(skin.g, 5);
  expect(colour.getZ(0)).toBeCloseTo(skin.b, 5);
  expect(colour.getW(0)).toBeCloseTo(0.4, 5);
});

test("people: disposing releases every geometry and material once", () => {
  const people = createPeople(2, null);
  let released = 0;
  for (const mesh of people.meshes) {
    mesh.geometry.addEventListener("dispose", () => released++);
    (mesh.material as T.Material).addEventListener("dispose", () => released++);
  }
  people.dispose();
  expect(released).toBe(30);
});
```

- [ ] **Step 2: Run them and see them fail**

Run: `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people:'`
Expected: 10 pass; the four new ones FAIL, `createPeople` is not exported.

- [ ] **Step 3: Implement `createPeople` in `app/src/people-mesh.ts`**

- [ ] **Step 4: Run them and see them pass**

Run the Step 2 command. Expected: 14 passed.

- [ ] **Step 5: Commit**

```bash
git -C .. add app/src/people-mesh.ts app/test/browser/people.spec.ts
git -C .. commit -m "Draw people as one instanced batch per body part"
```

---

### Task 5: Use the figures in the hall

**Files:**
- Modify: `app/src/hall-layout.ts` (add exports)
- Modify: `app/src/hall-scene.ts` (the `Diner` type near line 61; `staffPositions`, `queuePositions` near 119–135; the actor batches near 758–866; `staffActor`, `dinerPose` near 893–967; `updateQueue` near 1010; `walkDiner` near 1049; `draw` near 1173; `dispose` near 2136)
- Test: `app/test/browser/people.spec.ts`, `app/test/browser/people-scene.spec.ts`

**Interfaces:**
- Consumes: `personLook`, `carryPoint`, `FIGURE_MAX_SPAN`, `Look` from `people.ts`; `createPeople` from `people-mesh.ts`.
- Produces: `QUEUE_SPOTS` and `STAFF_SPOTS` exported from `hall-layout.ts` as `readonly (readonly [number, number])[]` in stall-local coordinates. `STAFF_SPOTS` keeps today's nine values. `QUEUE_SPOTS` becomes `[-0.7, 1.55], [0.08, 1.55], [-0.7, 2.3], [0.08, 2.3]`, wide enough that the larger figures do not overlap.
- Produces: the scene host element carries `data-hall-people`, the number of people drawn in the latest frame, updated only when it changes.

What changes in `hall-scene.ts`:

| Today | After |
| --- | --- |
| `body`, `heads`, `walkingBodies`, `walkingHeads`, `dinerLegs`, `carryingArms` and their geometries | One `createPeople(ACTOR_LIMIT + QUEUE_LIMIT * 2, faceTexture())`; its meshes are added to the scene and to `animatedMeshes` |
| `staffActor(...)` | `people.add(look, pose, detail)` with role `"owner"` or `"worker"`, serial `model.index * 16` for the owner and `model.index * 16 + n + 1` for worker `n`, `faceYaw` from the existing glance |
| `dinerPose(...)` for a queued diner | `people.add(diner.look, pose, detail)`; when the stall is detailed and motion is on, add `staffGlance(time, model.index, n + 10)` to the diner's `faceYaw` so waiting diners look around |
| `walkDiner(...)` | `people.add(diner.look, pose, "full", opacity)` with `walking: true`, the existing `stride`, and `carrying` when a tray is carried |
| `Diner.torso`, `Diner.head`, `Diner.height` | `Diner.look`, from `personLook(serial, "diner")` in `updateQueue` |
| Carried tray height `0.16 + 0.38 * height * 0.85` plus bob, and forward offset `0.29` | `carryPoint(diner.look, stride)` |
| Per-stall `detailed` choosing how many people to draw | Unchanged, and it also chooses `"full"` or `"simple"` |
| `draw()` resetting and flagging each batch | `people.begin()` before the stall loop, `people.end()` after `drawDepartures` |
| `steam` reusing `headGeometry` | Its own small sphere geometry, disposed with the scene |

The owner's own figure is still hidden while the view is inside that stall. `staffGlance`, `queueSway`, `aisleDistance`, departures and tray handover logic are unchanged.

- [ ] **Step 1: Write the failing queue-spacing test**

Add to `people.spec.ts`:

```ts
test("people: queue spots are far enough apart for the widest figure", () => {
  for (const [i, a] of QUEUE_SPOTS.entries())
    for (const b of QUEUE_SPOTS.slice(i + 1))
      expect(Math.hypot(a[0] - b[0], a[1] - b[1])).toBeGreaterThanOrEqual(FIGURE_MAX_SPAN);
  expect(STAFF_SPOTS.length).toBe(9);
});
```

- [ ] **Step 2: Write the failing browser regression**

Create `people-scene.spec.ts` with the same `test.use` block as `owner-view.spec.ts`. Copy that file's first test from `page.goto` through `page.route("**/api/state", ...)` (guest, operator seed, two leases, frozen snapshot), with one change to the snapshot loop: a stall the owner does not own is closed and idle, so only the two owned stalls draw anyone.

```ts
test("people: the hall draws the owner, workers and queue of each open stall", async ({ page, hall }) => {
  // ... setup copied from owner-view.spec.ts, with this loop:
  for (const stall of snapshot.hall.stalls) {
    const mine = owned.includes(stall.stall_id);
    stall["open?"] = mine;
    stall.activity = {
      waiting: mine ? 3 : 0, cooking: 0, handover: false,
      staffed: mine, workers: mine ? 2 : 0, staging: false, paused: false,
    };
  }
  await page.route("**/api/state", (route) => route.fulfill({ json: snapshot }));
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  // Two stalls, each: 1 owner + 2 workers + 3 queued diners.
  await expect.poll(async () => Number(await host.getAttribute("data-hall-people"))).toBe(12);
});
```

Twelve assumes both stalls are within the scene's detail distance, which holds in this small hall. If the run shows 6 (one owner, one worker and one diner per stall), the stalls are being drawn at reduced detail: select one of the owned stalls in the test before polling, and expect 9.

- [ ] **Step 3: Run both and see them fail**

```bash
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people: queue spots'
NODE_OPTIONS=--max-old-space-size=1536 bun run --bun build
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people: the hall draws'
```

Expected: the first FAILS on the missing exports; the last FAILS because `data-hall-people` is absent. The browser run needs the local PostgreSQL described in `docs/TESTING.md`.

- [ ] **Step 4: Move the spots and rewire the scene**

Make the changes in the table above. Delete code the table makes dead; do not leave unused batches or helpers behind.

- [ ] **Step 5: Run the focused tests and the existing hall regressions, one at a time**

```bash
NODE_OPTIONS=--max-old-space-size=1536 bun run --bun build
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people:'
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser owner-view.spec.ts
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser tray-pickup.spec.ts
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser hall-navigation.spec.ts
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser hall-interactions.spec.ts
```

Expected: 16 `people:` tests pass, and each named spec file passes as it does on `main`. If a spec fails on `main` too, record that instead of changing it.

- [ ] **Step 6: Look at it**

With the dev server from Task 1, open `http://localhost:5199/bench.html?stalls=4&detail=1&seconds=600` and check by eye: figures stand on the floor, face the counter in the queue, staff stand behind it, walkers fade in and out without limbs showing through bodies, carried trays sit in the hands, owners wear aprons. Save one screenshot for the owner; do not commit it.

- [ ] **Step 7: Check and commit**

```bash
bun run format:check && bun run lint && bun check
git -C .. add app/src app/test/browser/people.spec.ts app/test/browser/people-scene.spec.ts
git -C .. commit -m "Draw the hall's people as rounded figures"
```

---

### Task 6: Measure, decide, document

**Files:**
- Modify: `docs/superpowers/reports/2026-11-13-people-frame-time.md`
- Modify: `docs/GAME_DESIGN.md` (section 15, "Visual language")
- Possibly modify: `app/src/people.ts`, `app/src/hall-scene.ts`

- [ ] **Step 1: Re-run the bench**

Same machine, browser, window size and URLs as Task 1 Step 4, each twice, keeping the second.

- [ ] **Step 2: Apply the pass bar**

Pass: at `detail=0`, `fps ≥ 29.5` and `lateShare ≤ 0.05`. If it fails, simplify in this order, re-measuring after each, and stop at the first that passes:

1. In the scene, lower the distance at which a stall counts as nearby from 28 to 20 units, so fewer people are drawn in full.
2. In `people-mesh.ts`, halve the segment counts of the capsule and sphere geometries.
3. In `posePerson`, drop the neck and hands from `"full"` and update the Task 3 part-list test to match.

If it still fails, stop and report the numbers; do not ship a figure below the bar.

- [ ] **Step 3: Record the result**

Add "After: rounded figures" to the report with the same columns, the commit measured, which simplifications were applied if any, and one line stating pass or fail against the bar. Note that Project 3 re-measures after adding diners.

- [ ] **Step 4: Update the game design**

In section 15 "Visual language", replace the description of people with: proportioned figures built in code with limbs, hair styles and clothing variety; owners wear an apron; distant and reduced-detail people are drawn simpler; a person's look is stable. Keep it to a short paragraph and do not describe implementation.

- [ ] **Step 5: Check and commit**

```bash
bun run format:check && bun run lint && bun check
NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser --grep 'people:'
git -C .. add docs app/src app/test/browser/people.spec.ts
git -C .. commit -m "Record people frame times and describe the new figures"
```

Expected: checks pass and 16 `people:` tests pass.

- [ ] **Step 6: Report**

State exactly which checks ran and what was not verified: the full browser suite and hosted CI were not run locally; Japanese and English text is unaffected; the measurement covers this workstation only.
