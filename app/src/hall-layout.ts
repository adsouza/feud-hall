export type StallSlot =
  { ring: "perimeter"; perimeter: number } | { ring: "island"; order: number };
export type StallPlacement = StallSlot & {
  perimeter: number;
  island: number | null;
  centerX: number;
  centerZ: number;
  x: number;
  z: number;
  yaw: number;
};
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
 * down the centre line at the tray) passes no one.
 */
export const QUEUE_SPOTS: readonly (readonly [number, number])[] = [
  [-1.45, 1.55],
  [-0.55, 1.55],
  [-1.45, 2.45],
  [-0.55, 2.45],
];
const corners = [0, 0.25, 0.5, 0.75];
const islandPositions = [...corners, 0.125, 0.375, 0.625, 0.875];
const ISLAND_SIDE = 9.4;
const AISLE = 9;

/** Corners first, then bisect the longest physical gap; ties go clockwise from NW. */
export function nextPerimeter(
  occupied: number[],
  width = 1,
  depth = 1,
): number {
  const corner = corners.find((at) => !occupied.includes(at));
  if (corner !== undefined) return corner;
  const sorted = [...occupied].sort((a, b) => a - b);
  let candidate = 0;
  let largest = 0;
  sorted.forEach((at, i) => {
    const end = sorted[i + 1] ?? sorted[0] + 1;
    const gap = (end - at) * (Math.floor(at * 4) % 2 ? depth : width);
    if (gap > largest) {
      candidate = (at + end) / 2;
      largest = gap;
    }
  });
  return candidate;
}

export function nextStallSlot(occupied: StallSlot[]): StallSlot {
  const outer = occupied.filter((slot) => slot.ring === "perimeter");
  if (outer.length < 16) {
    const { width, depth } = layoutStalls(occupied);
    return {
      ring: "perimeter",
      perimeter: nextPerimeter(
        outer.map((slot) => slot.perimeter),
        width,
        depth,
      ),
    };
  }
  const taken = new Set(
    occupied.filter((slot) => slot.ring === "island").map((slot) => slot.order),
  );
  let order = 0;
  while (taken.has(order)) order++;
  return { ring: "island", order };
}

export function hallLayout(count: number) {
  const slots: StallSlot[] = [];
  while (slots.length < count) slots.push(nextStallSlot(slots));
  return layoutStalls(slots);
}

function edgePoint(perimeter: number, width: number, depth: number) {
  const edge = Math.floor(perimeter * 4),
    fraction = perimeter * 4 - edge;
  const [x, z] = [
    [-width / 2 + fraction * width, -depth / 2],
    [width / 2, -depth / 2 + fraction * depth],
    [width / 2 - fraction * width, depth / 2],
    [-width / 2, depth / 2 - fraction * depth],
  ][edge];
  return { x, z };
}

/** Cosmetic geometry only; balancing islands never changes logical location IDs. */
export function layoutStalls(slots: StallSlot[]) {
  const members: {
    slot: Extract<StallSlot, { ring: "island" }>;
    index: number;
  }[] = [];
  slots.forEach((slot, index) => {
    if (slot.ring === "island") members.push({ slot, index });
  });
  members.sort((a, b) => a.slot.order - b.slot.order);
  const count = Math.ceil(members.length / 8),
    columns = Math.ceil(Math.sqrt(count)),
    rows = Math.ceil(count / (columns || 1));
  const islands = Array.from({ length: count }, (_, id) => {
    const row = Math.floor(id / columns),
      inRow = Math.min(columns, count - row * columns);
    return {
      id,
      x: ((id % columns) - (inRow - 1) / 2) * (ISLAND_SIDE + AISLE),
      z: (row - (rows - 1) / 2) * (ISLAND_SIDE + AISLE),
      side: ISLAND_SIDE,
      count:
        Math.floor(members.length / count) +
        (id < members.length % count ? 1 : 0),
    };
  });
  const outer = slots
    .filter((slot) => slot.ring === "perimeter")
    .map((slot) => slot.perimeter)
    .sort((a, b) => a - b);
  const minGap = Math.min(
    ...outer.map((at, i) => (outer[i + 1] ?? outer[0] + 1) - at),
  );
  const minimum = Math.max(14, 4.7 / (4 * minGap));
  const width = Math.max(
    minimum,
    ...islands.map(
      (island) => Math.abs(island.x) * 2 + ISLAND_SIDE + AISLE * 2,
    ),
  );
  const depth = Math.max(
    minimum,
    ...islands.map(
      (island) => Math.abs(island.z) * 2 + ISLAND_SIDE + AISLE * 2,
    ),
  );
  const placements: StallPlacement[] = slots.map((slot) => {
    if (slot.ring === "island")
      return {
        ...slot,
        perimeter: 0,
        island: null,
        centerX: 0,
        centerZ: 0,
        x: 0,
        z: 0,
        yaw: 0,
      };
    const point = edgePoint(slot.perimeter, width, depth);
    return {
      ...slot,
      ...point,
      island: null,
      centerX: 0,
      centerZ: 0,
      // Only corner booths turn diagonally; wall booths face perpendicular to their wall.
      yaw: corners.includes(slot.perimeter)
        ? Math.atan2(-point.x, -point.z)
        : [0, -Math.PI / 2, Math.PI, Math.PI / 2][
            Math.floor(slot.perimeter * 4)
          ],
    };
  });
  let offset = 0;
  for (const island of islands) {
    for (let i = 0; i < island.count; i++) {
      const member = members[offset++],
        perimeter = islandPositions[i];
      const local = edgePoint(perimeter, ISLAND_SIDE, ISLAND_SIDE);
      placements[member.index] = {
        ...member.slot,
        perimeter,
        island: island.id,
        centerX: island.x,
        centerZ: island.z,
        x: island.x + local.x,
        z: island.z + local.z,
        yaw: Math.atan2(local.x, local.z),
      };
    }
  }
  return {
    width,
    depth,
    floorWidth: width + 6,
    floorDepth: depth + 6,
    islands,
    placements,
  };
}

type Frame = Pick<StallPlacement, "x" | "z" | "yaw">;
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

/** Enter walking at eye level in a clear aisle, with an open counter ahead. */
export function walkingEntrance(
  stalls: { id: string; open: boolean; placement: StallPlacement }[],
  selected: string,
  floorWidth: number,
  floorDepth: number,
) {
  const open = stalls.filter((stall) => stall.open);
  const candidates = open.length ? open : stalls;
  const preferred = candidates.find((stall) => stall.id === selected);
  const ordered = preferred
    ? [preferred, ...candidates.filter((stall) => stall !== preferred)]
    : candidates;
  for (const stall of ordered)
    for (const distance of [4.6, 5.2, 6])
      for (const offset of [0, -0.8, 0.8]) {
        const position = toHall(stall.placement, offset, distance);
        if (
          Math.abs(position.x) > floorWidth / 2 - 0.3 ||
          Math.abs(position.z) > floorDepth / 2 - 0.3 ||
          stalls.some((other) =>
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
  return { stall: "", position: { x: 0, z: 0 }, target: { x: 0, z: -6 } };
}
