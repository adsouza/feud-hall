// Shutter roll model: a pure function of a recorded roll and the current time.
// Levels run from 0 (fully up, open) to 1 (fully down, closed). Nothing here
// reads a clock or touches Three.js; callers supply `now` and render the level.

/** Time for a shutter to travel the full height, from 0 to 1. */
export const SHUTTER_ROLL_MS = 1200;

/** A roll from `from` to `to` that began at `start` (same clock as `now`). */
export type ShutterRoll = { from: number; to: number; start: number };

function travelMs(roll: ShutterRoll): number {
  return SHUTTER_ROLL_MS * Math.abs(roll.to - roll.from);
}

// Sine ease-in-out: slow at both ends, maximum speed at the midpoint.
function easeInOut(t: number): number {
  return 0.5 - 0.5 * Math.cos(Math.PI * t);
}

/** Shutter level at `now`, eased and clamped to the roll's direction. */
export function shutterLevel(roll: ShutterRoll, now: number): number {
  const duration = travelMs(roll);
  if (duration === 0) return roll.to;
  const elapsed = now - roll.start;
  if (elapsed <= 0) return roll.from;
  if (elapsed >= duration) return roll.to;
  const eased = easeInOut(elapsed / duration);
  return roll.from + (roll.to - roll.from) * eased;
}

/**
 * Roll toward `closed` (1) or open (0) from the level the shutter has now.
 * A first sighting rests at its target. A repeated target keeps the roll
 * already in progress, so per-frame calls do not restart the animation.
 */
export function rollTo(
  roll: ShutterRoll | undefined,
  closed: boolean,
  now: number,
): ShutterRoll {
  const target = closed ? 1 : 0;
  if (roll === undefined) return { from: target, to: target, start: now };
  if (roll.to === target) return roll;
  return { from: shutterLevel(roll, now), to: target, start: now };
}

/** True while the shutter is still travelling at `now`. */
export function rolling(roll: ShutterRoll | undefined, now: number): boolean {
  if (roll === undefined) return false;
  const duration = travelMs(roll);
  return duration > 0 && now - roll.start < duration;
}
