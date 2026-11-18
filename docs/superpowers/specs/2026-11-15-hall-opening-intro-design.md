# Hall opening intro and animated shutters: design

Status: draft for owner approval, 2026-11-15. Revised after the builder check.

## Intent

A sleeping Render instance takes about 32 s to answer the first request
(measured 2026-11-16, one sample). Until then the client shows
"Opening the hall…" and, after the first 8 s timeout, the banner
"Waiting for the hall to respond. An idle hall can take up to a minute to
start." The owner wants that wait to show **a bit of the game's
character**: a short 3D sequence of the hall opening for the day, from
outside, with lights coming on, shutters rolling up and stools being set
out, then the hall gently circling with people wandering in until the
server is ready.

Separately, the owner wants stall shutters in the **live** hall to roll
up and down when stalls open and close during play, instead of appearing
and disappearing instantly. The intro reuses that animation.

## Goals

1. Live hall: a stall's shutter rolls up when the committed view says it
   opened and rolls down when it says it closed.
2. Intro: on every slow first load, play a ~32 s opening sequence, framed
   as a short film, then hold in a slow loop until the first view arrives,
   then dissolve to the live page.
3. Normal (awake-server) launches look and behave exactly as today.

## Non-goals

- No intro on reconnects after a view has been shown; the existing
  "Connection lost" banner covers those.
- No intro on warm launches (the 1.5 s trigger below). Every slow launch
  plays the full sequence (owner's ruling); there is no "seen it" flag.
- No sound in the intro.
- No real hall data in the intro: no stall names, cuisines, prices,
  counts, players or queues taken from the server.
- No change to what the live scene's shutters mean: they still follow the
  committed `open?` flag.

## Anti-goals (would be a failure even if it works)

- Delaying a hall that is ready: the intro must never hold back the live
  view once the first answer arrives.
- Anything that reads as real trade or as the hall's current state: the
  intro is framed as a film and never camera-matches into the live hall.
- Making the live scene slower or less reliable. Its frame-time,
  interaction and accessibility behaviour must stay as it is.
- Flashing the intro for a fraction of a second on a warm launch.

## Constraints (from the project)

- The server owns outcomes; client animation cannot imply uncommitted
  state (AGENTS.md). Live shutter animation starts only from a committed
  view change. Intro content is made up and must not look like the
  current hall's state.
- The web and native clients share this UI; both get the intro.
- Provide a usable non-WebGL path; respect `prefers-reduced-motion`.
- English and Japanese for every new user-visible string.
- Local checks: no `tsc`; `bun check`, Oxlint, Prettier and focused
  Playwright scenarios only; memory-heavy checks serially.

## Approaches considered

1. **Teach the live hall scene to play the intro.** Load made-up stalls
   into `createHallScene` and add scripted camera, lights, shutters and
   staff to it. Seamless handoff, but puts intro code into the 2,130-line,
   performance-critical `hall-scene.ts` and through its tests.
2. **Separate intro scene built from shared parts. (Chosen.)** Extract
   the stall/counter model (including the shutter), lighting setup and
   the existing hall shell and people meshes into reusable builders. A
   new lazily loaded intro module owns its own timeline and dissolves to
   the live page when the answer arrives. The live scene is untouched
   apart from the extraction and the shutter animation below.
3. **Pre-rendered video.** Rejected: megabytes in every download, does not
   match the live art at all window sizes, cannot hand over smoothly.

Owner's ruling: approach 2, **plus** the sliding shutter is a live-scene
feature used whenever a stall opens or closes during the game, not only
in the intro.

## Part 1: animated shutters in the live scene

Today `hall-scene.ts` sets `model.shutters.visible = !model.open` when a
view arrives (around line 1884), so shutters pop in and out.

Decided behaviour:

- When a stall already on screen changes from open to closed in a newly
  applied view, its shutter rolls **down** from the canopy to the counter.
  From closed to open it rolls **up** into the canopy.
- Roll duration: about 1.2 s (builder may tune between 0.8 and 1.5 s).
  The shutter appears to roll into the canopy, not slide through it.
- A stall seen for the first time (initial load, newly leased, room
  change) shows its final state with no animation.
- Reduced motion (the scene's existing `appearance.motion` false): snap
  instantly, as today.
- The "reopening" placard shows once a closing roll finishes, and hides
  when an opening roll starts.
- A change that reverses mid-roll continues from the current position.
- While any shutter is moving, the scene's `schedule()` treats it as
  active motion so frames are drawn; it returns to idle afterwards.
- Hit-testing, blocking, inspector text and every interaction keep using
  the committed `open` flag, not the animation's position.

## Part 2: the intro

### When it plays

- Only in the "starting" state: no view has ever been confirmed in this
  page load.
- It starts if the first `/api/state` request has been outstanding for
  **1.5 s** without a successful answer (independent of the banner's 8 s
  timeout). Warm launches answer in about 0.15 s and never see it.
- It does not start when: WebGL is unavailable, `prefers-reduced-motion`
  is set, or the document is hidden. In those cases today's text-only
  waiting screen remains.
- The intro module is loaded with a dynamic import when it is about to
  start, so normal launches do not download it.

### What it shows (storyboard, ~32 s)

A made-up single room built with the real room layout (`room-layout.ts`):
roughly 8–10 stalls in real spot positions, with blank signs and no
names, prices or numbers. Night-to-day lighting.

| Time | Beat |
| --- | --- |
| 0–4 s | Outside the room's entrance before dawn, camera at walking height. Building dark, sign unlit. |
| 4–8 s | The sign flickers on, windows light one by one; the camera walks through the entrance. |
| 8–17.5 s | The camera walks along the stalls as each shutter rolls up in turn, revealing a lit counter and a cook. |
| 17.5–25.5 s | Staff bend to grip the tops of the stools, slide them into place within 4.5 s, then walk round the backs of the stalls. |
| 25.5–31.5 s | The camera rises to a high overview of the made-up room. |
| 31.5 s+ (hold) | The hall slowly rotates while made-up diners wander in through the entrance and queue at stalls, until the server answers. |

Staff use the existing worker look from `people.ts`; diners use the
existing diner looks. Queues show figures only, never counts.

### Framing (owner's ruling: keep the real art, frame it as a film)

- The intro uses the game's real art, unstylised, so it shows the game's
  character.
- While it plays it is framed as a short film: letterbox bars top and
  bottom and a soft vignette. This marks it as an opening sequence, not
  the hall's current state, even when the real hall turns out to be
  quiet, partly closed, or in the 03:00–05:00 cleaning window.

### Layout (my call)

- The intro fills the window below the navigation bar, where the page
  body is during the starting state. It does not try to match the live
  hall pane's size or position, which depend on the view.

### Handoff (owner's ruling: dissolve, no camera match)

- When the first view arrives, whatever the beat, the live page renders
  immediately underneath the intro with its normal controls usable, and
  the intro dissolves out over about 0.5 s and is disposed. The intro
  ignores pointer input during the dissolve so clicks reach the page.
- There is no camera glide into the live hall and no attempt to match
  poses: the live page may be the hall (first room, or an owner's own
  stall's room), the business page (owners land there on first view),
  the list view, or a page restored from history. All get the same
  dissolve.
- The answer is never delayed by the intro: the view is applied at once;
  only the visual dissolve takes up to ~0.5 s.

### Skip and accessibility

- A click, tap or any key press during the scripted beats jumps to the
  hold loop. My call: a small hint, "Click or press any key to skip",
  with a Japanese translation, appears for the first few seconds.
- The intro canvas is `aria-hidden`. The existing waiting status line
  stays visible as a caption over the intro, so screen readers and the
  text still explain the wait.
- The intro never takes keyboard focus away from the page's controls.

### Failure handling

- WebGL context loss or a load failure of the intro module: remove the
  intro and show today's text-only waiting screen.
- Frame budget: continuous animation at the live scene's active rate
  (32 ms interval) for the intro's lifetime, no more.

## Shared parts to extract

- The counter/stall model built by `createCounter` in `hall-scene.ts`,
  including shutter geometry and texture, into a module both scenes use.
- The shutter roll itself (state + per-frame update), used by Part 1 and
  the intro.
- Light setup (hemisphere, key and fill lights) with an intensity control
  the intro can drive from dark to day.
- `hall-shell.ts` (walls, tables, stools) and `people-mesh.ts` /
  `people.ts` (figures) are already separate; the intro needs stool
  instances it can move individually.

The live scene's visible behaviour must not change because of the
extraction, apart from Part 1.

## Verification

- Part 1: a browser scenario where a served view flips a visible stall's
  `open?`; assert the shutter is part-way during the roll and at rest
  after it; the reduced-motion variant snaps. Mutation check: removing
  the roll makes the part-way assertion fail.
- Intro: browser scenarios with the clock installed before navigation
  (see project memory on fake clocks) and `/api/state` held:
  - no intro canvas before 1.5 s; intro after;
  - releasing the answer shows the live page at once (its controls
    usable during the dissolve) and disposes the intro canvas;
  - a second slow load in the same browser plays the full sequence again;
  - a prompt answer (warm launch) never mounts the intro;
  - reduced motion and no-WebGL show text only;
  - skip jumps to the hold loop;
  - the waiting status text remains visible during the intro.
- Existing focused live-scene scenarios that touch shutters, closed
  stalls and frame time still pass.
- `bun check`, Oxlint, Prettier on changed files.

## Calls made while writing (owner to check)

- 1.5 s start threshold; ~1.2 s shutter roll; ~0.5 s dissolve.
- Skip jumps to the hold loop, with a short bilingual skip hint.
- Intro fills the area below the navigation; no pane matching.
- Live shutters: no animation for stalls seen for the first time; the
  reopening placard appears after a closing roll finishes.

## Left to the builder

- Exact camera curves, light timings, colours and easing within the
  storyboard, and the letterbox/vignette strength.
- How the stool-sliding animation is staged and how many staff appear.
- Internal module names and the shape of the shared builders.
- The made-up room's stall count (8–10) and colours.
