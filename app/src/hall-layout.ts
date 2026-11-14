/** Where staff stand behind a counter, in stall-local coordinates. */
export const STAFF_SPOTS: readonly (readonly [number, number])[] = [
  [0.65, 0.06],
  [-0.1, -0.43],
  [0.91, -0.43],
  [-1.12, -0.43],
  [0.15, 0.06],
  [-1.15, 0.06],
  [1.16, 0.06],
  [-0.62, -0.43],
  [0.41, -0.43],
];
/**
 * Where diners wait in front of a counter, far enough apart for the widest
 * figure, and left of the handover point so the tray pickup view (looking
 * down the centre line at the tray) passes no one waiting. The diner at the
 * last occupied spot is the one served; see `collectTray` for their way out.
 */
export const QUEUE_SPOTS: readonly (readonly [number, number])[] = [
  [-1.45, 1.55],
  [-0.55, 1.55],
  [-1.45, 2.45],
  [-0.55, 2.45],
];
/** Where a finished tray waits on the counter, in stall-local coordinates. */
export const COUNTER_TRAY: readonly [number, number] = [0, 0.88];
/**
 * Where a served diner stands to take their tray: at the counter, right of the
 * handover point, so neither they nor the tray's short trip to their hands
 * touches the queue on the left or the pickup view down the centre line.
 */
export const PICKUP_SPOT: readonly [number, number] = [0.55, 1.55];
/** How long the tray takes to pass from the counter into a diner's hands. */
export const TAKE_MS = 300;

export type Collecting = {
  x: number;
  z: number;
  yaw: number;
  /** Distance walked so far, for the gait. */
  metres: number;
  walking: boolean;
  /** 0 while the tray is on the counter, 1 once it is in the diner's hands. */
  take: number;
};

const COLLECT_SPEED = 0.0016; // metres per millisecond, a brisk walk

/** How long a diner called from this point takes to walk over and take a tray. */
export function collectMs(fromX: number, fromZ: number): number {
  const metres =
    Math.abs(PICKUP_SPOT[0] - fromX) + Math.abs(PICKUP_SPOT[1] - fromZ);
  return metres / COLLECT_SPEED + TAKE_MS;
}

/**
 * Where a diner called for their tray is, `ms` after the call, in stall-local
 * coordinates: sideways along their own row into the pickup lane, forward to
 * the pickup spot, then still while the tray comes into their hands. The last
 * diner in the queue is the one served, so their row is empty to their right
 * and the route passes no one who is still waiting.
 */
export function collectTray(fromX: number, fromZ: number, ms: number) {
  const [spotX, spotZ] = PICKUP_SPOT;
  const across = Math.abs(spotX - fromX);
  const forward = Math.abs(spotZ - fromZ);
  const metres = Math.min(Math.max(ms, 0) * COLLECT_SPEED, across + forward);
  const pose: Collecting = {
    x: fromX,
    z: fromZ,
    yaw: 0,
    metres,
    walking: metres < across + forward,
    take: 0,
  };
  if (metres < across) {
    pose.x = fromX + Math.sign(spotX - fromX) * metres;
    pose.yaw = Math.atan2(spotX - fromX, 0);
  } else if (pose.walking) {
    pose.x = spotX;
    pose.z = fromZ + Math.sign(spotZ - fromZ) * (metres - across);
    pose.yaw = Math.atan2(0, spotZ - fromZ);
  } else {
    pose.x = spotX;
    pose.z = spotZ;
    pose.yaw = Math.atan2(COUNTER_TRAY[0] - spotX, COUNTER_TRAY[1] - spotZ);
    const held = (ms - (across + forward) / COLLECT_SPEED) / TAKE_MS;
    const t = Math.min(Math.max(held, 0), 1);
    pose.take = t * t * (3 - 2 * t);
  }
  return pose;
}
/** A booth's pose in the hall; stall-local +z points out of its counter. */
type Frame = { x: number; z: number; yaw: number };
export function toHall(pose: Frame, x: number, z: number) {
  const c = Math.cos(pose.yaw),
    s = Math.sin(pose.yaw);
  return { x: pose.x + c * x + s * z, z: pose.z - s * x + c * z };
}
export function toStall(pose: Frame, x: number, z: number) {
  const c = Math.cos(pose.yaw),
    s = Math.sin(pose.yaw),
    dx = x - pose.x,
    dz = z - pose.z;
  return { x: c * dx - s * dz, z: s * dx + c * dz };
}

export function stallBlocks(pose: Frame, x: number, z: number) {
  const local = toStall(pose, x, z);
  return Math.abs(local.x) < 1.92 && local.z > -1.27 && local.z < 1.44;
}
