import { expect, test } from "./hall";
import fc from "fast-check";
import {
  QUEUE_DRAW_MAX,
  QUEUE_SPOTS,
  queueSpot,
  stallBlocks,
  toHall,
} from "../../src/hall-layout";
import { FIGURE_MAX_SPAN } from "../../src/people";
import {
  DOOR_WIDTH,
  ENTRANCE_WIDTH,
  ROOM_COUNT,
  ROOM_SIDE,
  SPOTS_PER_ROOM,
  assignSpots,
  entrance,
  positionKind,
  roomAt,
  roomCentre,
  routeAt,
  routeLength,
  routeWithin,
  seatSpots,
  spotPlacement,
  tableSpots,
  walkable,
  walkingEntrance,
  type Point,
  type SpotPlacement,
} from "../../src/room-layout";

type P = { x: number; z: number };
const rooms = Array.from({ length: ROOM_COUNT }, (_, i) => i + 1);
const positions = Array.from({ length: SPOTS_PER_ROOM }, (_, i) => i);
const all = rooms.flatMap((room) =>
  positions.map((position) => spotPlacement(room, position)),
);
const inRoom = (room: number) => all.filter((p) => p.room === room);

/** A booth's solid box, extended in front to the queue, as world corners. */
function box(p: SpotPlacement, front = 2.9): P[] {
  return [
    toHall(p, -1.92, -1.27),
    toHall(p, 1.92, -1.27),
    toHall(p, 1.92, front),
    toHall(p, -1.92, front),
  ];
}
function overlap(a: P[], b: P[]): boolean {
  for (const poly of [a, b])
    for (let i = 0; i < 4; i++) {
      const p = poly[i]!,
        q = poly[(i + 1) % 4]!;
      const nx = q.z - p.z,
        nz = p.x - q.x;
      const range = (shape: P[]) => {
        const d = shape.map((v) => v.x * nx + v.z * nz);
        return [Math.min(...d), Math.max(...d)] as const;
      };
      const [a0, a1] = range(a),
        [b0, b1] = range(b);
      if (a1 <= b0 + 1e-9 || b1 <= a0 + 1e-9) return false;
    }
  return true;
}
function segDist(p: P, a: P, b: P): number {
  const dx = b.x - a.x,
    dz = b.z - a.z;
  const t = Math.max(
    0,
    Math.min(1, ((p.x - a.x) * dx + (p.z - a.z) * dz) / (dx * dx + dz * dz)),
  );
  return Math.hypot(p.x - a.x - t * dx, p.z - a.z - t * dz);
}
function inside(poly: P[], p: P): boolean {
  return poly.every((v, i) => {
    const w = poly[(i + 1) % 4]!;
    return (w.x - v.x) * (p.z - v.z) - (w.z - v.z) * (p.x - v.x) >= 0;
  });
}
/** Distance between a convex box and a line segment. */
function boxToSegment(poly: P[], a: P, b: P): number {
  const cw = poly.slice().reverse();
  if (inside(poly, a) || inside(cw, a) || inside(poly, b) || inside(cw, b))
    return 0;
  let best = Infinity;
  for (let i = 0; i < 4; i++) {
    const p = poly[i]!,
      q = poly[(i + 1) % 4]!;
    best = Math.min(best, segDist(a, p, q), segDist(b, p, q));
    best = Math.min(best, segDist(p, a, b), segDist(q, a, b));
    const o = (u: P, v: P, w: P) =>
      Math.sign((v.x - u.x) * (w.z - u.z) - (v.z - u.z) * (w.x - u.x));
    if (o(p, q, a) !== o(p, q, b) && o(a, b, p) !== o(a, b, q)) return 0;
  }
  return best;
}

test("rooms: 150 spots have 150 distinct placements inside their own room", () => {
  const keys = new Set(
    all.map((p) => `${p.x.toFixed(3)},${p.z.toFixed(3)},${p.yaw.toFixed(3)}`),
  );
  expect(keys.size).toBe(150);
  for (const p of all) {
    expect(roomAt(p.x, p.z)).toBe(p.room);
    for (const corner of box(p, 1.44))
      expect(roomAt(corner.x, corner.z)).toBe(p.room);
    // The queue in front of each booth stays inside the same room.
    for (const corner of box(p, 2.9))
      expect(roomAt(corner.x, corner.z)).toBe(p.room);
  }
});

test("rooms: no two booths or queues overlap", () => {
  for (const room of rooms) {
    const here = inRoom(room);
    for (let i = 0; i < here.length; i++)
      for (let j = i + 1; j < here.length; j++)
        expect(
          overlap(box(here[i]!), box(here[j]!)),
          `room ${room}: ${i} and ${j}`,
        ).toBe(false);
  }
});

test("rooms: doorways and the entrance are clear", () => {
  const c = roomCentre(1);
  const half = ROOM_SIDE / 2;
  const lines: [P, P, number][] = [
    [{ x: c.x - half, z: 0 }, c, DOOR_WIDTH / 2],
    [c, { x: c.x + half, z: 0 }, DOOR_WIDTH / 2],
    [c, { x: 0, z: half }, ENTRANCE_WIDTH / 2],
  ];
  for (const p of inRoom(1))
    for (const [a, b, clear] of lines)
      expect(
        boxToSegment(box(p), a, b),
        `position ${p.position}`,
      ).toBeGreaterThanOrEqual(clear);
});

test("rooms: every counter faces into its room", () => {
  for (const p of all) {
    const c = roomCentre(p.room);
    const front = toHall(p, 0, 3);
    expect(Math.hypot(front.x - c.x, front.z - c.z)).toBeLessThan(
      Math.hypot(p.x - c.x, p.z - c.z),
    );
  }
});

test("rooms: quality follows position", () => {
  const table = (room: number) => positions.map((p) => positionKind(room, p));
  const odd = [
    "quiet",
    "standard",
    "standard",
    "standard",
    "standard",
    "standard",
    "quiet",
    "busy",
    "busy",
    "quiet",
    "prime",
    "prime",
    "quiet",
    "standard",
    "busy",
  ];
  const even = odd.slice();
  even[11] = "standard";
  even[13] = "busy";
  for (const room of [1, 3, 5, 7, 9]) expect(table(room)).toEqual(odd);
  for (const room of [2, 4, 6, 8, 10]) expect(table(room)).toEqual(even);
  const nearest = (to: P, n: number) =>
    inRoom(1)
      .map((p) => [Math.hypot(p.x - to.x, p.z - to.z), p.position] as const)
      .sort((a, b) => a[0] - b[0])
      .slice(0, n)
      .map((e) => e[1])
      .sort((a, b) => a - b);
  const half = ROOM_SIDE / 2;
  expect(nearest({ x: 0, z: half }, 2)).toEqual([10, 11]);
  expect(
    nearest({ x: -half, z: 0 }, 2)
      .concat(nearest({ x: half, z: 0 }, 2))
      .sort((a, b) => a - b),
  ).toEqual([7, 8, 13, 14]);
  expect(
    [-half, half]
      .flatMap((x) => [-half, half].map((z) => nearest({ x, z }, 1)[0]!))
      .sort((a, b) => a - b),
  ).toEqual([0, 6, 9, 12]);
});

test("rooms: the room mix matches the catalog", () => {
  const mix = (room: number) => {
    const counts = { quiet: 0, standard: 0, busy: 0, prime: 0 };
    for (const p of positions) counts[positionKind(room, p)]++;
    return [counts.quiet, counts.standard, counts.busy, counts.prime];
  };
  expect(mix(1)).toEqual([4, 6, 3, 2]);
  expect(mix(2)).toEqual([4, 6, 4, 1]);
});

test("rooms: stalls without room data are placed fifteen to a room in ID order", () => {
  fc.assert(
    fc.property(
      fc.uniqueArray(fc.string({ minLength: 1, maxLength: 6 }), {
        maxLength: 150,
      }),
      (ids) => {
        const spots = assignSpots(ids.map((stall_id) => ({ stall_id })));
        const keys = [...spots.values()].map((s) => `${s.room}:${s.position}`);
        expect(new Set(keys).size).toBe(ids.length);
        const counts = new Map<number, number>();
        for (const s of spots.values())
          counts.set(s.room, (counts.get(s.room) ?? 0) + 1);
        for (const n of counts.values()) expect(n).toBeLessThanOrEqual(15);
        const used = [...counts.keys()].sort((a, b) => a - b);
        expect(used).toEqual(used.map((_, i) => i + 1));
        const reversed = assignSpots(
          ids
            .slice()
            .reverse()
            .map((stall_id) => ({ stall_id })),
        );
        expect([...reversed].sort()).toEqual([...spots].sort());
      },
    ),
  );
  const given = [
    { stall_id: "b", room: 3, position: 4 },
    { stall_id: "a", room: 1, position: 0 },
  ];
  expect([...assignSpots(given)]).toEqual([
    ["b", { room: 3, position: 4 }],
    ["a", { room: 1, position: 0 }],
  ]);
  const fallback = assignSpots(
    Array.from({ length: 16 }, (_, i) => ({
      stall_id: `s${String(i + 1).padStart(3, "0")}`,
    })),
  );
  expect(fallback.get("s001")).toEqual({ room: 1, position: 0 });
  expect(fallback.get("s015")).toEqual({ room: 1, position: 14 });
  expect(fallback.get("s016")).toEqual({ room: 2, position: 0 });
});

test("rooms: walking stays inside open rooms", () => {
  const half = ROOM_SIDE / 2;
  fc.assert(
    fc.property(
      fc.double({ min: -30, max: 400, noNaN: true }),
      fc.double({ min: -40, max: 40, noNaN: true }),
      fc.integer({ min: 1, max: ROOM_COUNT }),
      (x, z, open) => {
        const room = roomAt(x, z);
        const result = walkable(
          x,
          z,
          open,
          inRoom(1).concat(...rooms.slice(1).map(inRoom)),
        );
        if (room === null && Math.abs(z) >= DOOR_WIDTH / 2)
          expect(result).toBe(false);
        if (room !== null && room > open) expect(result).toBe(false);
      },
    ),
  );
  for (const room of rooms) {
    const c = roomCentre(room);
    expect(walkable(c.x, c.z, room, all)).toBe(true);
    if (room > 1) expect(walkable(c.x, c.z, room - 1, all)).toBe(false);
  }
  for (const p of all) {
    expect(walkable(p.x, p.z, ROOM_COUNT, all)).toBe(false);
    expect(walkable(p.x, p.z, 0, all)).toBe(false);
  }
  const door =
    roomCentre(1).x +
    ROOM_SIDE / 2 +
    (roomCentre(2).x - roomCentre(1).x - ROOM_SIDE) / 2;
  expect(walkable(door, 0, 2, all)).toBe(true);
  expect(walkable(door, 0, 1, all)).toBe(false);
  expect(walkable(door, DOOR_WIDTH, 2, all)).toBe(false);
  expect(walkable(0, half + 1, ROOM_COUNT, all)).toBe(false);
  expect(walkable(-half - 1, 0, ROOM_COUNT, all)).toBe(false);
});

test("rooms: tables stand clear", () => {
  const half = ROOM_SIDE / 2;
  for (const room of rooms) {
    const c = roomCentre(room);
    const tables = tableSpots(room);
    expect(tables.length).toBeGreaterThanOrEqual(6);
    // The arrangement is symmetric about the room's north-south centre line.
    const key = (x: number, z: number) => `${x.toFixed(6)},${z.toFixed(6)}`;
    const mirrored = new Set(tables.map((t) => key(2 * c.x - t.x, t.z)));
    for (const t of tables) expect(mirrored.has(key(t.x, t.z))).toBe(true);
    for (const t of tables) {
      expect(walkable(t.x, t.z, room, inRoom(room))).toBe(true);
      for (const p of inRoom(room))
        for (const [qx, qz] of QUEUE_SPOTS) {
          const q = toHall(p, qx, qz);
          expect(Math.hypot(q.x - t.x, q.z - t.z)).toBeGreaterThanOrEqual(2.5);
        }
      for (const [a, b] of [
        [{ x: c.x - half, z: c.z }, c],
        [c, { x: c.x + half, z: c.z }],
        [c, { x: c.x, z: c.z + half }],
      ] as [P, P][])
        expect(segDist(t, a, b)).toBeGreaterThanOrEqual(2);
    }
  }
});

test("rooms: a walking entrance is clear, in the room and in front of a counter", () => {
  for (const room of rooms)
    for (let n = 0; n <= SPOTS_PER_ROOM; n++) {
      const stalls = positions.slice(0, n).map((position) => ({
        id: `s${position}`,
        open: position % 2 === 0,
        placement: spotPlacement(room, position),
      }));
      for (const selected of ["", "s1", "s2"]) {
        const e = walkingEntrance(stalls, selected, room);
        const placements = stalls.map((s) => s.placement);
        expect(roomAt(e.position.x, e.position.z)).toBe(room);
        expect(walkable(e.position.x, e.position.z, room, placements)).toBe(
          true,
        );
        const found = stalls.find((s) => s.id === e.stall);
        if (stalls.length) {
          expect(found).toBeTruthy();
          const local = toLocal(found!.placement, e.position);
          expect(local.z).toBeGreaterThanOrEqual(4 - 1e-9);
          expect(local.z).toBeLessThanOrEqual(6 + 1e-9);
        } else expect(e.stall).toBe("");
      }
    }
});

test("rooms: a walking entrance faces an open counter, the selected one, or the room", () => {
  for (const room of rooms) {
    const at = (id: string, position: number, open: boolean) => ({
      id,
      open,
      placement: spotPlacement(room, position),
    });
    // An open counter is preferred over a closed one, even a selected one.
    const mixed = [at("closed", 3, false), at("open", 8, true)];
    for (const selected of ["", "closed", "open"])
      expect(walkingEntrance(mixed, selected, room).stall).toBe("open");
    // With nothing open, the selected stall is faced.
    const shut = [at("a", 3, false), at("b", 8, false), at("c", 13, false)];
    for (const selected of ["a", "b", "c"])
      expect(walkingEntrance(shut, selected, room).stall).toBe(selected);
    // Stalls of other rooms do not count: an empty room uses its default.
    const elsewhere = [
      {
        id: "next",
        open: true,
        placement: spotPlacement(room === 1 ? 2 : room - 1, 3),
      },
    ];
    for (const stalls of [[], elsewhere]) {
      const e = walkingEntrance(stalls, "next", room);
      const centre = roomCentre(room);
      expect(e).toEqual({
        stall: "",
        position: centre,
        target: { x: centre.x, z: centre.z - 6 },
      });
      expect(roomAt(e.position.x, e.position.z)).toBe(room);
      expect(walkable(e.position.x, e.position.z, room, [])).toBe(true);
    }
    // The entrance stands in line with the counter it faces.
    for (let n = 1; n <= SPOTS_PER_ROOM; n++) {
      const stalls = positions
        .slice(0, n)
        .map((position) => at(`s${position}`, position, position % 3 !== 0));
      for (const selected of ["", "s0", "s1", "s4"]) {
        const e = walkingEntrance(stalls, selected, room);
        const found = stalls.find((s) => s.id === e.stall)!;
        expect(Math.abs(toLocal(found.placement, e.position).x)).toBeLessThan(
          1 + 1e-9,
        );
        expect(Math.abs(toLocal(found.placement, e.target).x)).toBeLessThan(
          1e-9,
        );
      }
    }
  }
});

function toLocal(pose: SpotPlacement, p: P) {
  const c = Math.cos(pose.yaw),
    s = Math.sin(pose.yaw),
    dx = p.x - pose.x,
    dz = p.z - pose.z;
  return { x: c * dx - s * dz, z: s * dx + c * dz };
}

test("rooms: coordinates round trip", () => {
  fc.assert(
    fc.property(
      fc.integer({ min: 1, max: ROOM_COUNT }),
      fc.integer({ min: 0, max: 14 }),
      fc.double({ min: -5, max: 5, noNaN: true }),
      fc.double({ min: -5, max: 5, noNaN: true }),
      (room, position, x, z) => {
        const pose = spotPlacement(room, position);
        const back = toLocal(pose, toHall(pose, x, z));
        expect(back.x).toBeCloseTo(x, 6);
        expect(back.z).toBeCloseTo(z, 6);
      },
    ),
  );
});

test("room layout: queue spots continue in rows of two and never overlap", () => {
  for (let n = 0; n < 4; n++) expect(queueSpot(n)).toEqual(QUEUE_SPOTS[n]);
  for (let a = 0; a < QUEUE_DRAW_MAX; a++)
    for (let b = a + 1; b < QUEUE_DRAW_MAX; b++)
      expect(
        Math.hypot(
          queueSpot(a)[0] - queueSpot(b)[0],
          queueSpot(a)[1] - queueSpot(b)[1],
        ),
      ).toBeGreaterThanOrEqual(FIGURE_MAX_SPAN);
});

test("room layout: every queue spot of every stall is clear of booths, tables and seats", () => {
  for (const room of [1, 2]) {
    const placements = Array.from({ length: 15 }, (_, p) =>
      spotPlacement(room, p),
    );
    for (const placement of placements)
      for (let n = 0; n < QUEUE_DRAW_MAX; n++) {
        const at = toHall(placement, ...queueSpot(n));
        expect(roomAt(at.x, at.z)).toBe(room);
        expect(placements.some((p) => stallBlocks(p, at.x, at.z))).toBe(false);
        for (const seat of seatSpots(room))
          expect(Math.hypot(seat.x - at.x, seat.z - at.z)).toBeGreaterThan(0.6);
      }
  }
});

test("room layout: a room has 32 seats, each facing its table", () => {
  const seats = seatSpots(3);
  expect(seats).toHaveLength(32);
  for (const seat of seats) {
    expect(seat.room).toBe(3);
    const toTable = Math.atan2(seat.tableX - seat.x, seat.tableZ - seat.z);
    expect(Math.cos(seat.yaw - toTable)).toBeCloseTo(1, 5);
  }
});

test("room layout: the entrance is the middle of the south wall", () => {
  const c = roomCentre(4),
    e = entrance(4);
  expect(e.inside.x).toBeCloseTo(c.x);
  expect(e.outside.x).toBeCloseTo(c.x);
  expect(roomAt(e.inside.x, e.inside.z)).toBe(4);
  expect(roomAt(e.outside.x, e.outside.z)).toBe(null);
  expect(e.outside.z).toBeGreaterThan(ROOM_SIDE / 2);
});

test("room layout: routes stay on the floor", () => {
  const room = 2;
  const placements = Array.from({ length: 15 }, (_, p) =>
    spotPlacement(room, p),
  );
  const ends: Point[] = [
    entrance(room).inside,
    ...seatSpots(room),
    ...placements.flatMap((p) =>
      [0, QUEUE_DRAW_MAX - 1].map((n) => toHall(p, ...queueSpot(n))),
    ),
  ];
  fc.assert(
    fc.property(
      fc.constantFrom(...ends),
      fc.constantFrom(...ends),
      (from, to) => {
        const route = routeWithin(room, from, to);
        expect(route[0]).toEqual({ x: from.x, z: from.z });
        expect(route[route.length - 1]).toEqual({ x: to.x, z: to.z });
        // Sample every 0.25 along the route, leaving out the first and last metre.
        const length = routeLength(route);
        for (let m = 1; m < length - 1; m += 0.25) {
          const at = routeAt(route, m);
          expect(roomAt(at.x, at.z)).toBe(room);
          expect(placements.some((p) => stallBlocks(p, at.x, at.z))).toBe(
            false,
          );
          for (const table of tableSpots(room))
            expect(Math.hypot(table.x - at.x, table.z - at.z)).toBeGreaterThan(
              0.62,
            );
        }
        expect(length).toBeLessThan(4 * ROOM_SIDE);
      },
    ),
  );
});

test("room layout: routeAt runs from the first point to the last", () => {
  const route = [
    { x: 0, z: 0 },
    { x: 3, z: 0 },
    { x: 3, z: 4 },
  ];
  expect(routeLength(route)).toBeCloseTo(7);
  expect(routeAt(route, 0)).toMatchObject({ x: 0, z: 0 });
  expect(routeAt(route, 5)).toMatchObject({ x: 3, z: 2 });
  expect(routeAt(route, 99)).toMatchObject({ x: 3, z: 4 });
  expect(routeAt(route, 1).yaw).toBeCloseTo(Math.PI / 2);
});
