// The decorative hall opening intro: a pure function from elapsed time to the
// camera, lights, shutters and stools of a made-up room 1. It reads no clock
// and touches no Three.js; the renderer supplies `ms` and draws the frame.
import { ROOM_SIDE, entrance, roomCentre, spotPlacement } from "./room-layout";
import { SHUTTER_ROLL_MS, shutterLevel } from "./shutter-roll";

export const INTRO_BEATS = {
  outside: 0,
  lights: 4000,
  shutters: 8000,
  stools: 16000,
  rise: 24000,
  hold: 30000,
} as const;

export type Beat = keyof typeof INTRO_BEATS;
type Vec3 = [number, number, number];
export type IntroFrame = {
  beat: Beat;
  camera: Vec3;
  target: Vec3;
  light: number;
  sign: boolean;
  shutterLevels: number[];
  stoolProgress: number;
};

const EYE = 1.55;
const ROOM = 1;
/** The camera passes the entrance this far into the lights beat. */
const THROUGH_DOOR_MS = 5500;
/**
 * Before dawn the camera stands this far out on the street beyond
 * `entrance().outside` (about 10 m from the entrance wall), so the facade,
 * its doorway and its top edge fill the frame rather than the doorway alone.
 */
const STREET_BACK = 8;
/** Height on the entrance wall the street shot looks at. */
const FACADE_GAZE_Y = 2.6;
/** Hold orbit: one turn per 90 s, high above the stalls. */
const ORBIT_MS = 90000;
const ORBIT_RADIUS = 14;
const ORBIT_HEIGHT = 28;
/** Where the orbit starts, as an angle about the centre. */
const ORBIT_START = Math.PI / 2;
/** Most stalls the aisle walk aims at; a room holds fifteen spots. */
const SPOTS = 15;
/** The aisle walk stays this share of the way from the centre to a stall. */
const AISLE_SHARE = 0.45;

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp01 = (t: number) => Math.min(1, Math.max(0, t));
const smooth = (t: number) => {
  const u = clamp01(t);
  return u * u * (3 - 2 * u);
};
const mix = (a: Vec3, b: Vec3, t: number): Vec3 => [
  lerp(a[0], b[0], t),
  lerp(a[1], b[1], t),
  lerp(a[2], b[2], t),
];
const span = (ms: number, from: number, to: number) =>
  (ms - from) / (to - from);

function beatAt(ms: number): Beat {
  if (ms >= INTRO_BEATS.hold) return "hold";
  if (ms >= INTRO_BEATS.rise) return "rise";
  if (ms >= INTRO_BEATS.stools) return "stools";
  if (ms >= INTRO_BEATS.shutters) return "shutters";
  if (ms >= INTRO_BEATS.lights) return "lights";
  return "outside";
}

/** The booth the aisle walk is looking at, as it moves from stall to stall. */
function aisleTarget(progress: number, stalls: number): Vec3 {
  const count = Math.max(1, Math.min(stalls, SPOTS));
  const at = clamp01(progress) * (count - 1);
  const i = Math.min(Math.floor(at), Math.max(0, count - 2));
  const a = spotPlacement(ROOM, i);
  const b = spotPlacement(ROOM, Math.min(i + 1, count - 1));
  const f = count === 1 ? 0 : at - i;
  return [lerp(a.x, b.x, f), 1.2, lerp(a.z, b.z, f)];
}

function aisleCamera(target: Vec3): Vec3 {
  const c = roomCentre(ROOM);
  return [
    lerp(c.x, target[0], AISLE_SHARE),
    EYE,
    lerp(c.z, target[2], AISLE_SHARE),
  ];
}

function orbitCamera(sinceMs: number): Vec3 {
  const c = roomCentre(ROOM);
  const a = ORBIT_START + (2 * Math.PI * sinceMs) / ORBIT_MS;
  return [
    c.x + ORBIT_RADIUS * Math.cos(a),
    ORBIT_HEIGHT,
    c.z + ORBIT_RADIUS * Math.sin(a),
  ];
}

function flicker(t: number): number {
  // Stuttering on and off, then a steady rise to full brightness.
  if (t < 0.4) return Math.floor(t * 25) % 2 === 1 ? 0.3 : 0;
  return smooth((t - 0.4) / 0.6);
}

export function introFrame(
  ms: number,
  stalls: number,
  skippedAt?: number,
): IntroFrame {
  const centre = roomCentre(ROOM);
  const look: Vec3 = [centre.x, 0.5, centre.z];
  if (skippedAt !== undefined) {
    return {
      beat: "hold",
      camera: orbitCamera(Math.max(0, ms - skippedAt)),
      target: look,
      light: 1,
      sign: true,
      shutterLevels: Array<number>(stalls).fill(0),
      stoolProgress: 1,
    };
  }

  const beat = beatAt(ms);
  const door = entrance(ROOM);
  const street: Vec3 = [door.outside.x, EYE, door.outside.z + STREET_BACK];
  const facade: Vec3 = [centre.x, FACADE_GAZE_Y, centre.z + ROOM_SIDE / 2];
  const inside: Vec3 = [door.inside.x, EYE, door.inside.z];
  const gaze: Vec3 = [centre.x, 1.8, centre.z];
  const firstTarget = aisleTarget(0, stalls);
  const lastTarget = aisleTarget(1, stalls);
  const aisleStart = aisleCamera(firstTarget);
  const aisleEnd = aisleCamera(lastTarget);
  const stoolsEnd: Vec3 = [centre.x, EYE, centre.z + 4];

  let camera: Vec3;
  let target: Vec3;
  if (ms < INTRO_BEATS.lights) {
    camera = street;
    target = facade;
  } else if (ms < THROUGH_DOOR_MS) {
    const t = smooth(span(ms, INTRO_BEATS.lights, THROUGH_DOOR_MS));
    camera = mix(street, inside, t);
    target = mix(facade, gaze, t);
  } else if (ms < INTRO_BEATS.shutters) {
    const t = smooth(span(ms, THROUGH_DOOR_MS, INTRO_BEATS.shutters));
    camera = mix(inside, aisleStart, t);
    target = mix(gaze, firstTarget, t);
  } else if (ms < INTRO_BEATS.stools) {
    const p = span(ms, INTRO_BEATS.shutters, INTRO_BEATS.stools);
    target = aisleTarget(p, stalls);
    camera = aisleCamera(target);
  } else if (ms < INTRO_BEATS.rise) {
    const t = smooth(span(ms, INTRO_BEATS.stools, INTRO_BEATS.rise));
    camera = mix(aisleEnd, stoolsEnd, t);
    target = mix(lastTarget, look, t);
  } else if (ms < INTRO_BEATS.hold) {
    const t = smooth(span(ms, INTRO_BEATS.rise, INTRO_BEATS.hold));
    camera = mix(stoolsEnd, orbitCamera(0), t);
    target = look;
  } else {
    camera = orbitCamera(ms - INTRO_BEATS.hold);
    target = look;
  }

  // Each shutter rolls up in turn; the last one finishes as the beat ends.
  const gap =
    stalls > 1
      ? (INTRO_BEATS.stools - INTRO_BEATS.shutters - SHUTTER_ROLL_MS) /
        (stalls - 1)
      : 0;
  const shutterLevels = Array.from({ length: stalls }, (_, i) =>
    shutterLevel({ from: 1, to: 0, start: INTRO_BEATS.shutters + i * gap }, ms),
  );

  const lightT = span(ms, INTRO_BEATS.lights, INTRO_BEATS.shutters);
  const light = lightT <= 0 ? 0 : lightT >= 1 ? 1 : flicker(lightT);
  const sign = lightT >= 0.15;
  const stoolProgress = smooth(span(ms, INTRO_BEATS.stools, INTRO_BEATS.rise));

  return { beat, camera, target, light, sign, shutterLevels, stoolProgress };
}
