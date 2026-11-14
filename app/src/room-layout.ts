import { stallBlocks, toHall, toStall } from "./hall-layout";

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
export type Point = { x: number; z: number };

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
  // Two rings of four on the diagonals, clear of the doorway and entrance lines.
  return [
    at(-5.5, -5.5),
    at(5.5, -5.5),
    at(-5.5, 5.5),
    at(5.5, 5.5),
    at(-9.5, -9.5),
    at(9.5, -9.5),
    at(-9.5, 9.5),
    at(9.5, 9.5),
  ];
}

export type Seat = {
  room: number;
  index: number;
  x: number;
  z: number;
  yaw: number;
  tableX: number;
  tableZ: number;
};

/** Seat offsets around a table, in table-local coordinates. */
export const SEAT_OFFSETS: readonly (readonly [number, number])[] = [
  [0, 0.95],
  [0, -0.95],
  [0.95, 0],
  [-0.95, 0],
];

/** The 32 seats of a room: tableSpots(room) x SEAT_OFFSETS, each facing its table. */
export function seatSpots(room: number): Seat[] {
  return tableSpots(room).flatMap((table, t) =>
    SEAT_OFFSETS.map(([dx, dz], k) => {
      const { x, z } = toHall(table, dx, dz);
      return {
        room,
        index: t * SEAT_OFFSETS.length + k,
        x,
        z,
        yaw: Math.atan2(table.x - x, table.z - z),
        tableX: table.x,
        tableZ: table.z,
      };
    }),
  );
}

/** Just inside the room's outside entrance, and a point on the street beyond it. */
export function entrance(room: number): { inside: Point; outside: Point } {
  const c = roomCentre(room);
  return {
    inside: { x: c.x, z: c.z + HALF - 0.6 },
    outside: { x: c.x, z: c.z + HALF + 2 },
  };
}

/*
 * Walking routes. Every room has the same layout about its centre, so routes
 * are found in room-relative coordinates over a fixed grid of aisle points:
 * the room's centre lines, the aisle between the two rings of tables (7.5) and
 * the aisle between the outer tables and the queues (11). A route joins its
 * two ends to whichever aisle points they can walk to in a straight line and
 * takes the shortest way through the grid. Collisions are cosmetic; this keeps
 * figures out of booths and off tables, not out of each other's way.
 */
const AISLES = [-11, -7.5, 0, 7.5, 11];
/** Keep this far from a table's centre: the table and most of its chairs. */
const TABLE_CLEAR = 1.2;
/** Keep this far from a booth's box and from the walls. */
const BOOTH_CLEAR = 0.25;
const WALL_CLEAR = 0.3;
/** A route's ends may sit beside a table or in front of a booth. */
const END_GRACE = 1;
const SAMPLE = 0.1;

type Floor = {
  booths: SpotPlacement[];
  tables: Point[];
  nodes: Point[];
  /** Straight-line clear distances between aisle points; Infinity if blocked. */
  links: number[][];
};
let floorCache: Floor | null = null;

/** The room-relative floor plan, with clear links between aisle points. */
function floor(): Floor {
  if (floorCache) return floorCache;
  const c = roomCentre(1);
  const booths = Array.from({ length: SPOTS_PER_ROOM }, (_, p) => {
    const at = spotPlacement(1, p);
    return { ...at, x: at.x - c.x, z: at.z - c.z };
  });
  const tables = tableSpots(1).map((t) => ({ x: t.x - c.x, z: t.z - c.z }));
  const nodes = AISLES.flatMap((x) => AISLES.map((z) => ({ x, z })));
  const plan: Floor = { booths, tables, nodes, links: [] };
  plan.links = nodes.map((a) =>
    nodes.map((b) =>
      a === b ? 0 : clear(plan, a, b, false, false) ? dist(a, b) : Infinity,
    ),
  );
  floorCache = plan;
  return plan;
}

function dist(a: Point, b: Point) {
  return Math.hypot(b.x - a.x, b.z - a.z);
}

function open(plan: Floor, x: number, z: number): boolean {
  if (Math.abs(x) > HALF - WALL_CLEAR || Math.abs(z) > HALF - WALL_CLEAR)
    return false;
  for (const t of plan.tables)
    if (Math.hypot(t.x - x, t.z - z) <= TABLE_CLEAR) return false;
  for (const b of plan.booths) {
    const local = toStall(b, x, z);
    if (
      Math.abs(local.x) < 1.92 + BOOTH_CLEAR &&
      local.z > -1.27 - BOOTH_CLEAR &&
      local.z < 1.44 + BOOTH_CLEAR
    )
      return false;
  }
  return true;
}

/** Whether a straight walk from a to b is clear, apart from the graced ends. */
function clear(
  plan: Floor,
  a: Point,
  b: Point,
  graceA: boolean,
  graceB: boolean,
) {
  const length = dist(a, b);
  const steps = Math.max(1, Math.ceil(length / SAMPLE));
  for (let i = 0; i <= steps; i++) {
    const m = (length * i) / steps;
    if (graceA && m < END_GRACE) continue;
    if (graceB && length - m < END_GRACE) continue;
    const t = length === 0 ? 0 : m / length;
    if (!open(plan, a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t)) return false;
  }
  return true;
}

/** Waypoints from one floor point to another inside one room, both included. */
export function routeWithin(room: number, from: Point, to: Point): Point[] {
  const c = roomCentre(room);
  const plan = floor();
  const start = { x: from.x - c.x, z: from.z - c.z };
  const end = { x: to.x - c.x, z: to.z - c.z };
  const ends = [
    { x: from.x, z: from.z },
    { x: to.x, z: to.z },
  ];
  if (clear(plan, start, end, true, true)) return ends;
  const { nodes, links } = plan;
  const n = nodes.length;
  const fromStart = nodes.map((p) =>
    clear(plan, start, p, true, false) ? dist(start, p) : Infinity,
  );
  const toEnd = nodes.map((p) =>
    clear(plan, p, end, false, true) ? dist(p, end) : Infinity,
  );
  // An end that reaches no aisle point in a straight line joins the nearest.
  for (const [costs, at] of [
    [fromStart, start],
    [toEnd, end],
  ] as const)
    if (costs.every((d) => d === Infinity)) {
      const nearest = nodes.reduce(
        (best, p, i) => (dist(p, at) < dist(nodes[best]!, at) ? i : best),
        0,
      );
      costs[nearest] = dist(nodes[nearest]!, at);
    }
  // Dijkstra over the aisle points, seeded from the start.
  const best = fromStart.slice();
  const previous = nodes.map(() => -1);
  const done = nodes.map(() => false);
  for (;;) {
    let u = -1;
    for (let i = 0; i < n; i++)
      if (!done[i] && best[i]! < Infinity && (u < 0 || best[i]! < best[u]!))
        u = i;
    if (u < 0) break;
    done[u] = true;
    for (let v = 0; v < n; v++) {
      const d = best[u]! + links[u]![v]!;
      if (!done[v] && d < best[v]!) {
        best[v] = d;
        previous[v] = u;
      }
    }
  }
  let last = -1;
  for (let i = 0; i < n; i++)
    if (best[i]! + toEnd[i]! < Infinity)
      if (last < 0 || best[i]! + toEnd[i]! < best[last]! + toEnd[last]!)
        last = i;
  if (last < 0) return ends;
  const middle: Point[] = [];
  for (let i = last; i >= 0; i = previous[i]!)
    middle.unshift({ x: nodes[i]!.x + c.x, z: nodes[i]!.z + c.z });
  return [ends[0]!, ...middle, ends[1]!];
}

/** Total length of a polyline. */
export function routeLength(points: Point[]): number {
  let length = 0;
  for (let i = 1; i < points.length; i++)
    length += dist(points[i - 1]!, points[i]!);
  return length;
}

/** The point `metres` along a polyline and the heading there (atan2(dx, dz)). */
export function routeAt(
  points: Point[],
  metres: number,
): { x: number; z: number; yaw: number } {
  let left = Math.max(metres, 0);
  let yaw = 0;
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1]!,
      b = points[i]!;
    const length = dist(a, b);
    if (length === 0) continue;
    yaw = Math.atan2(b.x - a.x, b.z - a.z);
    if (left <= length) {
      const t = left / length;
      return { x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t, yaw };
    }
    left -= length;
  }
  const end = points[points.length - 1] ?? { x: 0, z: 0 };
  return { x: end.x, z: end.z, yaw };
}
