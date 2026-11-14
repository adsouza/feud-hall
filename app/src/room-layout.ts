import { stallBlocks, toHall } from "./hall-layout";

export const ROOM_COUNT = 10;
export const SPOTS_PER_ROOM = 15;
/** Interior side of a room, wall to wall, in scene units. */
export const ROOM_SIDE = 34;
/** Width of the opening between two neighbouring rooms. */
export const DOOR_WIDTH = 4;
/** Width of the outside entrance in the middle of each room's south wall. */
export const ENTRANCE_WIDTH = 5;
/** Wall thickness: the gap between two neighbouring rooms' interiors. */
const WALL = 0.5;
const PITCH = ROOM_SIDE + WALL;
const HALF = ROOM_SIDE / 2;
/** A booth's back (local z = -1.27) sits just off the wall. */
const BACK = 1.37;
/** A corner booth's far back corner is 2.256 from each wall; keep it inside. */
const CORNER_INSET = 2.31;
/** Along-wall spacing of the five north-wall booths (width 3.84 plus a gap). */
const NORTH_STEP = 4.4;
/** Distance from the room centre line to a booth beside a doorway or the entrance. */
const BESIDE_DOOR = 6.5;

export type Spot = { room: number; position: number };
export type SpotPlacement = Spot & { x: number; z: number; yaw: number };
export type SpotKind = "quiet" | "standard" | "busy" | "prime";
type Point = { x: number; z: number };

export function roomCentre(room: number): Point {
  return { x: (room - 1) * PITCH, z: 0 };
}

/**
 * Where a spot's booth stands. Positions run clockwise from the north-west
 * corner: 0 NW corner, 1-5 north wall, 6 NE, 7-8 east wall, 9 SE, 10-11 south
 * wall, 12 SW, 13-14 west wall. The north wall is negative z.
 */
export function spotPlacement(room: number, position: number): SpotPlacement {
  const c = roomCentre(room);
  const wall = HALF - BACK;
  const corner = HALF - CORNER_INSET;
  // Offset from the room centre, and the facing.
  let dx: number, dz: number, yaw: number;
  const diagonal = (sx: number, sz: number) => {
    dx = sx * corner;
    dz = sz * corner;
    yaw = Math.atan2(-dx, -dz);
  };
  dx = dz = yaw = 0;
  if (position === 0) diagonal(-1, -1);
  else if (position >= 1 && position <= 5) {
    dx = (position - 3) * NORTH_STEP;
    dz = -wall;
    yaw = 0;
  } else if (position === 6) diagonal(1, -1);
  else if (position === 7 || position === 8) {
    dx = wall;
    dz = position === 7 ? -BESIDE_DOOR : BESIDE_DOOR;
    yaw = -Math.PI / 2;
  } else if (position === 9) diagonal(1, 1);
  else if (position === 10 || position === 11) {
    dx = position === 10 ? BESIDE_DOOR : -BESIDE_DOOR;
    dz = wall;
    yaw = Math.PI;
  } else if (position === 12) diagonal(-1, 1);
  else if (position === 13 || position === 14) {
    dx = -wall;
    dz = position === 13 ? BESIDE_DOOR : -BESIDE_DOOR;
    yaw = Math.PI / 2;
  } else throw new RangeError(`position ${position} is not 0..14`);
  return { room, position, x: c.x + dx, z: c.z + dz, yaw };
}

export function positionKind(room: number, position: number): SpotKind {
  if (position === 0 || position === 6 || position === 9 || position === 12)
    return "quiet";
  if (position >= 1 && position <= 5) return "standard";
  if (position === 7 || position === 8 || position === 14) return "busy";
  const odd = room % 2 === 1;
  if (position === 10) return "prime";
  if (position === 11) return odd ? "prime" : "standard";
  return odd ? "standard" : "busy"; // 13
}

type StallLike = { stall_id: string; room?: number; position?: number };

/**
 * The server's room and position for each stall when every stall has both;
 * otherwise a deterministic fallback: stall IDs in order, fifteen to a room.
 */
export function assignSpots(stalls: StallLike[]): Map<string, Spot> {
  const spots = new Map<string, Spot>();
  if (
    stalls.every(
      (s) => typeof s.room === "number" && typeof s.position === "number",
    )
  ) {
    for (const s of stalls)
      spots.set(s.stall_id, { room: s.room!, position: s.position! });
    return spots;
  }
  const ids = stalls
    .map((s) => s.stall_id)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  ids.forEach((id, i) =>
    spots.set(id, {
      room: Math.floor(i / SPOTS_PER_ROOM) + 1,
      position: i % SPOTS_PER_ROOM,
    }),
  );
  return spots;
}

/** The room whose interior contains the point, if any. */
export function roomAt(x: number, z: number): number | null {
  if (Math.abs(z) >= HALF) return null;
  const room = Math.round(x / PITCH) + 1;
  if (room < 1 || room > ROOM_COUNT) return null;
  return Math.abs(x - roomCentre(room).x) < HALF ? room : null;
}

/** The doorway between room k and k+1 holds this x range. */
function doorwayBetween(x: number): number | null {
  for (let room = 1; room < ROOM_COUNT; room++) {
    const lo = roomCentre(room).x + HALF;
    if (x >= lo && x <= lo + WALL) return room;
  }
  return null;
}

/**
 * Inside an open room and not inside a booth, or inside the doorway between
 * two open rooms. The outside entrance is not walkable through.
 */
export function walkable(
  x: number,
  z: number,
  openRooms: number,
  placements: Iterable<{ x: number; z: number; yaw: number }>,
): boolean {
  const room = roomAt(x, z);
  if (room !== null) {
    if (room > openRooms) return false;
    for (const p of placements) if (stallBlocks(p, x, z)) return false;
    return true;
  }
  if (Math.abs(z) >= DOOR_WIDTH / 2) return false;
  const left = doorwayBetween(x);
  return left !== null && left + 1 <= openRooms;
}

/** Enter walking at eye level in a clear aisle, with an open counter ahead. */
export function walkingEntrance(
  stalls: { id: string; open: boolean; placement: SpotPlacement }[],
  selected: string,
  room: number,
): { stall: string; position: Point; target: Point } {
  const here = stalls.filter((s) => s.placement.room === room);
  const open = here.filter((s) => s.open);
  const candidates = open.length ? open : here;
  const preferred = candidates.find((s) => s.id === selected);
  const ordered = preferred
    ? [preferred, ...candidates.filter((s) => s !== preferred)]
    : candidates;
  const centre = roomCentre(room);
  for (const stall of ordered)
    for (const distance of [4.6, 5.2, 6])
      for (const offset of [0, -0.8, 0.8]) {
        const position = toHall(stall.placement, offset, distance);
        if (
          Math.abs(position.x - centre.x) > HALF - 0.3 ||
          Math.abs(position.z - centre.z) > HALF - 0.3 ||
          here.some((other) =>
            stallBlocks(other.placement, position.x, position.z),
          )
        )
          continue;
        return {
          stall: stall.id,
          position,
          target: toHall(stall.placement, 0, 0.6),
        };
      }
  return {
    stall: "",
    position: { ...centre },
    target: { x: centre.x, z: centre.z - 6 },
  };
}

/** Table positions in the middle of a room, clear of queues and walkways. */
export function tableSpots(room: number): (Point & { yaw: number })[] {
  const c = roomCentre(room);
  const at = (dx: number, dz: number) => ({
    x: c.x + dx,
    z: c.z + dz,
    yaw: Math.atan2(-dx, -dz),
  });
  return [
    at(-5.5, -5.5),
    at(5.5, -5.5),
    at(-5.5, 5.5),
    at(5.5, 5.5),
    at(0, -8),
    at(-9.5, -9.5),
  ];
}
