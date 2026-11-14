// Development-only frame bench. Mounts the real hall scene with a synthetic
// hall and reports frame delivery. Open /bench.html?stalls=150&detail=0&seconds=20
// in a visible, GPU-backed browser window; a hidden tab stops the scene drawing.
import type { Stall } from "../api";
import { createHallScene, type Appearance } from "../hall-scene";

const params = new URLSearchParams(location.search);
function number(name: string, fallback: number, min: number, max: number) {
  const value = Number(params.get(name) ?? fallback);
  return Number.isFinite(value)
    ? Math.min(max, Math.max(min, Math.round(value)))
    : fallback;
}
const count = number("stalls", 150, 1, 150);
const detail = number("detail", 0, 0, 1) === 1;
const seconds = number("seconds", 20, 1, 600);

function stall(index: number, service: number): Stall {
  return {
    stall_id: `bench-${index}`,
    restaurant_id: `bench-restaurant-${index}`,
    tier: "standard",
    name: `Bench ${index + 1}`,
    cuisine: "italian",
    menu: {},
    "open?": true,
    last_service: `bench-service-${service}`,
    activity: {
      waiting: 4,
      cooking: 2,
      handover: false,
      staffed: true,
      workers: 9,
      staging: false,
      paused: false,
    },
  };
}

function appearance(service: number): Appearance {
  return {
    stalls: Array.from({ length: count }, (_, index) => stall(index, service)),
    ownedStalls: [],
    selected: "",
    pickup: "",
    pickups: [],
    closedLabel: "",
    cuisineLabel: () => "",
    reopeningHeading: "",
    reopeningTime: () => "",
    detail,
    motion: true,
    tablet: null,
    tabletLabel: "",
    tabletHint: "",
  };
}

const host = document.getElementById("hall") as HTMLDivElement;
const WARM_UP_MS = 2000;
let measuring = false;
const draws: number[] = [];
const stamps: number[] = [];
const scene = createHallScene(host, {
  select: () => {},
  interact: () => {},
  tablet: () => {},
  hover: () => {},
  fail: () => {},
  inside: () => {},
  walk: () => {},
  collect: () => false,
  collected: () => {},
  frame: (drawMs) => {
    if (!measuring) return;
    draws.push(drawMs);
    stamps.push(performance.now());
  },
});

// Give every stall a new last_service each second. The scene reads a changed
// value as a served order and sends one diner per stall off carrying a tray.
// A departure walk lasts 1500 ms, so a 1000 ms cadence always has walkers in
// flight and the scene keeps drawing in both detail modes. The first update
// only sets the initial value; the second is the first to count as served.
let service = 0;
scene.update(appearance(service));
const toggle = setInterval(() => {
  service++;
  scene.update(appearance(service));
}, 1000);

function percentile(sorted: number[], share: number) {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * share))];
}

function renderer() {
  try {
    const gl = host.querySelector("canvas")?.getContext("webgl2");
    const info = gl?.getExtension("WEBGL_debug_renderer_info");
    return info
      ? String(gl?.getParameter(info.UNMASKED_RENDERER_WEBGL))
      : "unknown";
  } catch {
    return "unknown";
  }
}

// Discard a warm-up so the idle second before the first departure, and any
// shader or buffer setup, stay outside the measured span.
setTimeout(() => {
  measuring = true;
}, WARM_UP_MS);

setTimeout(
  () => {
    clearInterval(toggle);
    const frames = draws.length;
    const intervals = stamps.slice(1).map((at, i) => at - stamps[i]);
    const late = intervals.filter((gap) => gap > 40).length;
    const sorted = [...draws].sort((a, b) => a - b);
    const span = frames > 1 ? (stamps[frames - 1] - stamps[0]) / 1000 : 0;
    const round = (value: number) => Math.round(value * 100) / 100;
    const result = {
      stalls: count,
      detail: detail ? 1 : 0,
      seconds,
      frames,
      fps: span > 0 ? round((frames - 1) / span) : 0,
      lateShare: intervals.length ? round(late / intervals.length) : 0,
      meanDrawMs: frames ? round(draws.reduce((a, b) => a + b, 0) / frames) : 0,
      p95DrawMs: round(percentile(sorted, 0.95)),
      renderer: renderer(),
    };
    const out = document.createElement("pre");
    out.setAttribute("data-bench-result", "");
    out.textContent = JSON.stringify(result);
    document.body.append(out);
    scene.dispose();
  },
  WARM_UP_MS + seconds * 1000,
);
