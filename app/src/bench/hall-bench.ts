// Development-only frame bench. Mounts the real hall scene with a synthetic
// hall and reports frame delivery. Open /bench.html?stalls=150&detail=0&seconds=20
// in a visible, GPU-backed browser window; a hidden tab stops the scene drawing.
// Add near=1 to start the camera among the stalls instead of at the overview,
// or eye=1 to stand at eye height looking east through the room's doorway
// (eye=2: looking south through the entrance onto the street).
// room=<1..10> picks the room to show (default 1) and rooms=<1..10> how many
// rooms are open (default 10). Vacant spots of open rooms are "to let" bays.
// floor=1 also sends today's diner totals and a queue limit of six, so the
// floor has deeper queues and diners who walk in and out without buying, on
// top of the served diners who sit and eat (floor=0, the default, sends
// neither, as a server without them does).
import type { Stall } from "../api";
import {
  createHallScene,
  type Appearance,
  type CameraState,
  type HallVacancy,
} from "../hall-scene";
import { SPOTS_PER_ROOM, assignSpots, roomCentre } from "../room-layout";

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
const near = number("near", 0, 0, 1) === 1;
const eye = number("eye", 0, 0, 2);
const open = number("rooms", 10, 1, 10);
const room = Math.min(number("room", 1, 1, 10), open);
const floor = number("floor", 0, 0, 1) === 1;
const centre = roomCentre(room).x;
// Low over the middle of the room, so many stalls are within the scene's
// detail distance (28 units) instead of all being drawn at reduced detail.
const NEAR_CAMERA: CameraState = {
  position: [centre, 10, 12],
  target: [centre, 1, 0],
};
// Standing west of the room's centre, looking east along the doorway line:
// through an open doorway into the next room, or at a shut door.
const EYE_CAMERA: CameraState =
  eye === 2
    ? { position: [centre - 3, 1.55, 4], target: [centre, 1.55, 12] }
    : { position: [centre - 6, 1.55, 0], target: [centre, 1.55, 0] };
// Stall i takes its room and position from the fallback for stalls without
// room data: stall IDs in order, fifteen to a room.
const spots = assignSpots(
  Array.from({ length: count }, (_, index) => ({ stall_id: id(index) })),
);
const taken = new Set(
  [...spots.values()].map((s) => `${s.room}:${s.position}`),
);
const vacancies: HallVacancy[] = [];
for (let r = 1; r <= open; r++)
  for (let position = 0; position < SPOTS_PER_ROOM; position++)
    if (!taken.has(`${r}:${position}`))
      vacancies.push({
        stall_id: `vacant-${r}-${position}`,
        tier: "standard",
        room: r,
        position,
      });

function id(index: number) {
  return `bench-${index}`;
}

/** With floor=1: each stall's queue, and walk-outs a second per open room. */
const FLOOR_WAITING = 6;
const WALK_OUTS_PER_ROOM = 2;

function stall(index: number, service: number): Stall {
  return {
    stall_id: id(index),
    ...spots.get(id(index))!,
    restaurant_id: `bench-restaurant-${index}`,
    tier: "standard",
    name: `Bench ${index + 1}`,
    cuisine: "italian",
    menu: {},
    "open?": true,
    last_service: `bench-service-${service}`,
    activity: {
      waiting: floor ? FLOOR_WAITING : 4,
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
    rooms: { count: 10, open },
    vacancies,
    toLetLabel: "To let",
    serving: true,
    // Each second every stall serves one diner and admits one more, and some
    // arrivals in every open room leave without buying.
    ...(floor
      ? {
          today: {
            arrivals: service * (count + WALK_OUTS_PER_ROOM * open),
            admitted: service * count,
            left: 0,
          },
          queueLimit: FLOOR_WAITING,
        }
      : {}),
  };
}

const host = document.getElementById("hall") as HTMLDivElement;
const WARM_UP_MS = 2000;
let measuring = false;
const draws: number[] = [];
const stamps: number[] = [];
let people = 0; // the most people the scene drew in one measured frame
let walking = 0; // the most floor figures drawn walking (or collecting)
let seated = 0; // the most floor figures drawn seated
const scene = createHallScene(
  host,
  {
    select: () => {},
    interact: () => {},
    tablet: () => {},
    hover: () => {},
    fail: () => {},
    inside: () => {},
    walk: () => {},
    collect: () => false,
    collected: () => {},
    room: () => {},
    vacancy: () => {},
    frame: (drawMs) => {
      if (!measuring) return;
      draws.push(drawMs);
      stamps.push(performance.now());
      people = Math.max(people, Number(host.getAttribute("data-hall-people")));
      walking = Math.max(
        walking,
        Number(host.getAttribute("data-hall-walking")),
      );
      seated = Math.max(seated, Number(host.getAttribute("data-hall-seated")));
    },
  },
  eye ? EYE_CAMERA : near ? NEAR_CAMERA : undefined,
);

// Give every stall a new last_service each second. The floor reads a changed
// value as a served order: one diner per stall collects a tray and goes to a
// seat (or straight out once the room's seats are taken), and the waiting
// count, unchanged, brings one more diner to the queue. A 1000 ms cadence
// always has diners collecting or walking, so the scene keeps drawing in both
// detail modes. The first update only sets the initial values (a baseline);
// the second is the first to count as served.
let service = 0;
scene.update(appearance(service));
if (!near && !eye) scene.showRoom(room);
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
      near: near ? 1 : 0,
      eye,
      room: scene.room(),
      rooms: open,
      floor: floor ? 1 : 0,
      seconds,
      frames,
      fps: span > 0 ? round((frames - 1) / span) : 0,
      lateShare: intervals.length ? round(late / intervals.length) : 0,
      meanDrawMs: frames ? round(draws.reduce((a, b) => a + b, 0) / frames) : 0,
      p95DrawMs: round(percentile(sorted, 0.95)),
      people,
      walking,
      seated,
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
