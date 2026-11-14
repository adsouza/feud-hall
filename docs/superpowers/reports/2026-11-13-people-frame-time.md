# People figures frame time

Frame delivery of the 3D hall scene, measured with the dev-only bench. See
[How to run the frame bench](../../TESTING.md#how-to-run-the-frame-bench).

## Environment

- Date: 2026-11-13
- Machine model: Mac16,10 (Apple M4), macOS 27.0.1
- GPU (`renderer`): ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)
- Browser and version: Playwright's bundled Chromium 158.0.8127.18, headless,
  1280×800 viewport, device pixel ratio 1
- Display refresh rate: 60 Hz (the headless browser paces itself; no window is shown)
- Commit measured: cf99912

## Method

The owner was away, so the desktop app's browser pane was hidden. A hidden pane
throttles animation (a trial there delivered 3 frames per second with 69% late
frames), so it is not valid evidence. The runs below used Playwright's Chromium
with hardware rendering and background throttling switched off, which does not
depend on a visible window:

- `channel: "chromium"`, `headless: true`;
- `--use-angle=metal --enable-gpu --ignore-gpu-blocklist`;
- `--disable-renderer-backgrounding --disable-backgrounding-occluded-windows
  --disable-background-timer-throttling`.

The `renderer` string above confirms the Apple M4 GPU, not a software
rasterizer. Each URL was loaded twice in a fresh page and the second result
kept. The scene paces active frames at 32 ms, so about 31 frames per second is
its ceiling; the bench also triggers one extra draw per second through its
keep-alive update.

`meanDrawMs` and `p95DrawMs` are CPU-side time in `draw()`, including the render
submit. GPU cost shows through `fps` and `lateShare`.

## Before: capsule figures

150 stalls, 20 seconds per run after a 2-second warm-up, second run of each kept.
Every stall is open with 9 workers, 4 queued diners and one diner walking off
with a tray each second.

| detail | frames | fps   | lateShare | meanDrawMs | p95DrawMs |
| ------ | ------ | ----- | --------- | ---------- | --------- |
| 0      | 620    | 30.97 | 0         | 5.44       | 7.5       |
| 1      | 620    | 30.95 | 0         | 4.90       | 6.7       |

The first runs agreed closely: 30.97 fps and 5.15 ms mean at `detail=0`, 30.96 fps
and 5.22 ms mean at `detail=1`, with no late frames.
