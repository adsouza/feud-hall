import { expect, test } from "./hall";
import { introFrame } from "../../src/hall-intro-timeline";
import { roomAt } from "../../src/room-layout";

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

test("intro timeline: the camera starts outside the entrance and keeps moving in the hold", () => {
  expect(introFrame(0, 9).camera[1]).toBeCloseTo(1.55);
  const c = introFrame(0, 9).camera;
  expect(roomAt(c[0], c[2])).toBeNull();
  expect(introFrame(40000, 9).camera).not.toEqual(introFrame(50000, 9).camera);
});

test("intro timeline: the camera stays inside room 1 from the entrance to the end of the rise", () => {
  for (let ms = 5500; ms <= 30000; ms += 100) {
    const [x, , z] = introFrame(ms, 9).camera;
    expect(roomAt(x, z), `at ${ms} ms`).toBe(1);
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
