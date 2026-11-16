import { expect, test } from "./hall";
import {
  SHUTTER_ROLL_MS,
  rollTo,
  rolling,
  shutterLevel,
} from "../../src/shutter-roll";

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

test("shutter roll: a repeated target keeps the roll in progress", () => {
  const closing = rollTo(rollTo(undefined, false, 0), true, 0);
  expect(rollTo(closing, true, SHUTTER_ROLL_MS / 2)).toBe(closing);
});

test("shutter roll: a reversal continues from the current level", () => {
  const closing = rollTo(rollTo(undefined, false, 0), true, 0);
  const at = SHUTTER_ROLL_MS / 2;
  const level = shutterLevel(closing, at);
  const opening = rollTo(closing, false, at);
  expect(shutterLevel(opening, at)).toBeCloseTo(level, 6);
  expect(shutterLevel(opening, at + SHUTTER_ROLL_MS * level)).toBe(0);
});
