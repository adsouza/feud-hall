import { expect, test } from "./hall";
import { FACADE_FACE, FACADE_LIGHTS } from "../../src/hall-intro-facade";
import {
  INTRO_BEATS,
  INTRO_DOOR_MS,
  INTRO_STOOLS_SET_MS,
  INTRO_STREET_HOLD_MS,
  introFrame,
} from "../../src/hall-intro-timeline";
import {
  ENTRANCE_WIDTH,
  ROOM_SIDE,
  roomAt,
  roomCentre,
  spotPlacement,
} from "../../src/room-layout";

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

test("intro timeline: the stools are set early, leaving the staff time to go", () => {
  const set = INTRO_BEATS.stools + INTRO_STOOLS_SET_MS;
  expect(INTRO_STOOLS_SET_MS).toBeLessThan(
    INTRO_BEATS.rise - INTRO_BEATS.stools,
  );
  expect(introFrame(INTRO_BEATS.stools, 9).stoolProgress).toBe(0);
  expect(introFrame(set - 100, 9).stoolProgress).toBeLessThan(1);
  expect(introFrame(set, 9).stoolProgress).toBe(1);
});

test("intro timeline: the lights beat ends lit with the sign on", () => {
  expect(introFrame(7999, 9).light).toBeCloseTo(1, 1);
  expect(introFrame(8000, 9).light).toBe(1);
  expect(introFrame(7000, 9).sign).toBe(true);
});

test("intro timeline: shutters rise one after another", () => {
  const f = introFrame(12000, 9);
  expect(f.shutterLevels[0]).toBe(0);
  expect(f.shutterLevels[8]).toBe(1);
  expect(introFrame(16000, 9).shutterLevels).toEqual(Array(9).fill(0));
});

test("intro timeline: each shutter starts only once the camera has arrived at its stall", () => {
  const centre = roomCentre(1);
  const problems: string[] = [];
  for (let i = 0; i < 9; i++) {
    let start = -1;
    for (let ms = INTRO_BEATS.lights; ms <= INTRO_BEATS.stools; ms += 10) {
      if (introFrame(ms, 9).shutterLevels[i] < 1) {
        start = ms;
        break;
      }
    }
    if (start < 0) {
      problems.push(`stall ${i}: never rolled before the stools beat`);
      continue;
    }
    const stall = spotPlacement(1, i);
    const { camera, target } = introFrame(start, 9);
    // Looking at this stall...
    const aim = Math.hypot(target[0] - stall.x, target[2] - stall.z);
    // ...from the aisle walk's standpoint for it, not still on the way.
    const post = [
      centre.x + (stall.x - centre.x) * 0.45,
      centre.z + (stall.z - centre.z) * 0.45,
    ];
    const away = Math.hypot(camera[0] - post[0], camera[2] - post[1]);
    if (aim > 0.3 || away > 0.3)
      problems.push(
        `stall ${i} at ${start} ms: aim off by ${aim.toFixed(2)} m, camera ${away.toFixed(2)} m from its post`,
      );
  }
  expect(problems).toEqual([]);
});

type Vec = [number, number, number];
const sub = (a: Vec, b: Vec): Vec => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const dot = (a: Vec, b: Vec) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: Vec, b: Vec): Vec => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];
const unit = (a: Vec): Vec => {
  const l = Math.hypot(...a);
  return [a[0] / l, a[1] / l, a[2] / l];
};
/** Whether a point lies in a 42° vertical-FOV, 16:9 view from camera to target. */
function inView(camera: Vec, target: Vec, point: Vec) {
  const forward = unit(sub(target, camera));
  const right = unit(cross(forward, [0, 1, 0]));
  const up = cross(right, forward);
  const v = sub(point, camera);
  const depth = dot(v, forward);
  const tanV = Math.tan((21 * Math.PI) / 180);
  return (
    depth > 0 &&
    Math.abs(dot(v, up)) / depth <= tanV &&
    Math.abs(dot(v, right)) / depth <= (tanV * 16) / 9
  );
}

test("intro timeline: the street shot frames the entrance facade", () => {
  // hall-shell's wall height, doorway height and wall depth.
  const wallTop = 4.65;
  const doorwayTop = 3.05;
  const face = roomCentre(1).z + ROOM_SIDE / 2 + 0.22;
  const { camera, target } = introFrame(0, 9);
  expect(camera[1]).toBeCloseTo(1.55);
  expect(roomAt(camera[0], camera[2])).toBeNull();
  const distance = camera[2] - face;
  expect(distance).toBeGreaterThanOrEqual(8);
  expect(distance).toBeLessThanOrEqual(10.5);
  const x = roomCentre(1).x;
  const points: [string, Vec][] = [["wall top", [x, wallTop, face]]];
  for (const side of [-1, 1]) {
    const edge = x + (side * ENTRANCE_WIDTH) / 2;
    points.push(
      [`doorway side ${side} foot`, [edge, 0, face]],
      [`doorway side ${side} head`, [edge, doorwayTop, face]],
      [`wall top over doorway side ${side}`, [edge, wallTop, face]],
    );
  }
  for (const [name, point] of points)
    expect(inView(camera, target, point), name).toBe(true);
});

test("intro timeline: the camera keeps moving in the hold", () => {
  expect(introFrame(40000, 9).camera).not.toEqual(introFrame(50000, 9).camera);
});

test("intro timeline: the street shot holds, then walks in during the lights beat", () => {
  expect(introFrame(INTRO_STREET_HOLD_MS - 1, 9).camera).toEqual(
    introFrame(0, 9).camera,
  );
  expect(INTRO_DOOR_MS).toBeGreaterThan(INTRO_STREET_HOLD_MS);
  expect(INTRO_DOOR_MS).toBeLessThan(INTRO_BEATS.shutters);
});

test("intro timeline: the camera stays inside room 1 from the entrance to the end of the rise", () => {
  for (let ms = INTRO_DOOR_MS; ms <= 30000; ms += 100) {
    const [x, , z] = introFrame(ms, 9).camera;
    expect(roomAt(x, z), `at ${ms} ms`).toBe(1);
  }
});

test("intro timeline: facade windows light one after another in view", () => {
  const c = roomCentre(1);
  const face = c.z + FACADE_FACE;
  expect(FACADE_LIGHTS.length).toBeGreaterThanOrEqual(4);
  let previous = -Infinity;
  for (const [n, light] of FACADE_LIGHTS.entries()) {
    expect(
      light.at - previous,
      `gap before window ${n}`,
    ).toBeGreaterThanOrEqual(300);
    previous = light.at;
    expect(light.at, `window ${n}`).toBeGreaterThanOrEqual(INTRO_BEATS.lights);
    const { camera, target } = introFrame(light.at, 9);
    for (const sx of [-0.5, 0.5])
      for (const sy of [-0.5, 0.5]) {
        const corner: Vec = [
          c.x + light.x + sx * light.width,
          light.y + sy * light.height,
          face,
        ];
        expect(
          inView(camera, target, corner),
          `window ${n} corner ${sx},${sy} at ${light.at} ms`,
        ).toBe(true);
      }
  }
});

test("intro timeline: the hold orbits above the stalls", () => {
  for (let ms = 30000; ms <= 120000; ms += 1000)
    expect(introFrame(ms, 9).camera[1]).toBeGreaterThan(15);
});

test("intro timeline: the camera never jumps between frames", () => {
  let prev = introFrame(0, 9).camera;
  for (let ms = 50; ms <= 40000; ms += 50) {
    const cur = introFrame(ms, 9).camera;
    const d = Math.hypot(cur[0] - prev[0], cur[1] - prev[1], cur[2] - prev[2]);
    expect(d, `at ${ms} ms`).toBeLessThanOrEqual(1.0);
    prev = cur;
  }
});

test("intro timeline: a skip jumps to the hold", () => {
  expect(introFrame(5000, 9, 5000).beat).toBe("hold");
});
