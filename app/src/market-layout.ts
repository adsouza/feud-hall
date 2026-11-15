import { goodFor, shelves, type VendorId } from "./market-goods";

// The market is a row of stalls along x, centred on 0, fronts at z = 0 facing
// +z (towards the camera). Each stall is a stepped display stand: tier 0 is the
// lowest and nearest, each higher tier stands TIER_RISE higher and TIER_DEPTH
// further back, so every container shows from the front.

/** Distance between neighbouring containers' centres along a tier. */
export const PITCH_X = 0.66;
/** Height of each step of a display stand. */
export const TIER_RISE = 0.42;
/** Depth of each step of a display stand. */
export const TIER_DEPTH = 0.56;
/** Height of the lowest step's top. */
export const BASE_Y = 0.55;
/** Bare stand at each end of a stall's shelves. */
export const STALL_MARGIN = 0.3;
/** Space between neighbouring stalls (room for a parked cart). */
export const STALL_GAP = 1.5;
/** Fewest columns a stall's shelves have. */
export const MIN_COLUMNS = 3;
/** Where shoppers walk: just in front of the stalls, so a close-up shows them. */
export const AISLE_Z = 1.2;
/** How far beyond the row's ends a shopper enters and leaves. */
const OFFSTAGE = 3;

export type Stall = {
  vendor: VendorId;
  x: number; // centre
  width: number;
  columns: number;
  tiers: number;
  height: number; // top of the highest step
  depth: number; // the stand reaches from z = 0 back to z = -depth
};
export type Placed = {
  product: string;
  vendor: VendorId;
  x: number;
  y: number; // top of the step the container stands on
  z: number; // centre of that step
  tier: number;
  column: number;
};
export type MarketLayout = { stalls: Stall[]; containers: Placed[] };
export type CameraPose = {
  position: [number, number, number];
  target: [number, number, number];
};

/** Columns of a stall that sells `count` products: about sqrt(1.5 count), at least MIN_COLUMNS. */
export function columnsFor(count: number): number {
  return Math.max(MIN_COLUMNS, Math.ceil(Math.sqrt(1.5 * Math.max(0, count))));
}

/** Where each vendor's stall stands (a row along x, centred on 0) and where each product's container sits on its shelves. */
export function marketLayout(productIds: string[]): MarketLayout {
  const stalls: Stall[] = [];
  const containers: Placed[] = [];
  let left = 0;
  for (const { vendor, products } of shelves(productIds)) {
    const columns = columnsFor(products.length);
    // A primary and the substitutes that follow it stay together on a tier.
    const groups: string[][] = [];
    for (const id of products) {
      const last = groups[groups.length - 1];
      if (last && goodFor(id).beside === last[0]) last.push(id);
      else groups.push([id]);
    }
    const width = columns * PITCH_X + 2 * STALL_MARGIN;
    const placed: Omit<Placed, "x">[] = [];
    let tier = 0;
    let column = 0;
    for (const group of groups) {
      if (column > 0 && column + group.length > columns) {
        tier++;
        column = 0;
      }
      for (const product of group) {
        if (column >= columns) {
          tier++;
          column = 0;
        }
        placed.push({
          product,
          vendor,
          y: BASE_Y + tier * TIER_RISE,
          z: -(tier + 0.5) * TIER_DEPTH,
          tier,
          column,
        });
        column++;
      }
    }
    const tiers = tier + 1;
    for (const item of placed)
      containers.push({
        ...item,
        x: left + STALL_MARGIN + (item.column + 0.5) * PITCH_X,
      });
    stalls.push({
      vendor,
      x: left + width / 2,
      width,
      columns,
      tiers,
      height: BASE_Y + (tiers - 1) * TIER_RISE,
      depth: tiers * TIER_DEPTH,
    });
    left += width + STALL_GAP;
  }
  // Centre the row on x = 0.
  const shift = stalls.length ? (left - STALL_GAP) / 2 : 0;
  for (const stall of stalls) stall.x -= shift;
  for (const container of containers) container.x -= shift;
  return { stalls, containers };
}

/** A stall's sign hangs this far above its top step, so the top tags show beneath it. */
export const SIGN_BOTTOM = 0.8;
/** Tallest a stall's sign is. */
export const SIGN_MAX_H = 0.72;

const FOV = 40; // degrees, vertical; the scene's camera uses the same
const ELEVATION = 0.38; // radians the camera looks down
const TAN = Math.tan(((FOV / 2) * Math.PI) / 180);

/** The camera's field of view in degrees (vertical). */
export const CAMERA_FOV = FOV;

// A camera that frames a box of `width` x `height` (seen from the front)
// centred on `target`, looking down at ELEVATION.
function frame(
  target: [number, number, number],
  width: number,
  height: number,
  aspect: number,
): CameraPose {
  const distance =
    Math.max(height / 2 / TAN, width / 2 / (TAN * Math.max(aspect, 0.1))) *
    1.06;
  return {
    target,
    position: [
      target[0],
      target[1] + Math.sin(ELEVATION) * distance,
      target[2] + Math.cos(ELEVATION) * distance,
    ],
  };
}

// How tall a stall looks from the camera: its steps, the containers and tags
// on the top step, and the canopy and sign above, foreshortened.
function apparentHeight(stall: Pick<Stall, "height" | "depth">): number {
  return (
    (stall.height + SIGN_BOTTOM + SIGN_MAX_H + 0.3) * Math.cos(ELEVATION) +
    stall.depth * Math.sin(ELEVATION)
  );
}

/** Camera pose that shows the whole row. */
export function overviewPose(
  stalls: readonly Pick<Stall, "x" | "width" | "height" | "depth">[],
  aspect = 16 / 9,
): CameraPose {
  if (stalls.length === 0) return frame([0, 1, 0], 8, 3, aspect);
  const first = stalls[0];
  const last = stalls[stalls.length - 1];
  const leftEdge = first.x - first.width / 2;
  const rightEdge = last.x + last.width / 2;
  const tallest = stalls.reduce((a, b) => (b.height > a.height ? b : a));
  const deepest = Math.max(...stalls.map((s) => s.depth));
  return frame(
    [(leftEdge + rightEdge) / 2, (tallest.height + 1.2) / 2, -deepest / 3],
    rightEdge - leftEdge + 1,
    apparentHeight(tallest),
    aspect,
  );
}

/** Camera pose close on one vendor's stall, framing all of it. */
export function vendorPose(
  stall: Pick<Stall, "x" | "width" | "height" | "depth">,
  aspect = 16 / 9,
): CameraPose {
  // Down to the aisle in front, and wide enough for the cart parked beside.
  return frame(
    [stall.x, (stall.height + 1.4) / 2 - 0.35, -stall.depth / 2 + 0.3],
    stall.width + 2 * STALL_GAP,
    apparentHeight(stall) + 0.7,
    aspect,
  );
}

/** Where a shopper walks for a trip: in from one end, stopping in front of each vendor that sells one of the products, out the other end. */
export function tripRoute(
  products: string[],
  layout: MarketLayout,
): { x: number; z: number; pause: boolean }[] {
  const { stalls } = layout;
  if (stalls.length === 0) return [];
  const buying = new Set(products.map((id) => goodFor(id).vendor));
  const first = stalls[0];
  const last = stalls[stalls.length - 1];
  return [
    { x: first.x - first.width / 2 - OFFSTAGE, z: AISLE_Z, pause: false },
    ...stalls
      .filter((stall) => buying.has(stall.vendor))
      .map((stall) => ({ x: stall.x, z: AISLE_Z, pause: true })),
    { x: last.x + last.width / 2 + OFFSTAGE, z: AISLE_Z, pause: false },
  ];
}

/** How full a container is drawn, 0..1, from the server's level (0..1000): 0 -> 0, 1000 -> 1, never empty-looking above 0 (min 0.12). */
export function fillFor(level: number): number {
  if (!(level > 0)) return 0;
  return Math.min(1, Math.max(0.12, level / 1000));
}

/** How many goods a cart shows for a size bucket: small 2, medium 5, large 9. */
export function cartGoods(size: "small" | "medium" | "large"): number {
  return size === "large" ? 9 : size === "medium" ? 5 : 2;
}

/** What the pointer is over, ignoring shoppers: a container, another part of a stall, or nothing. */
export type PointerTarget =
  | { kind: "container"; product: string; vendor: VendorId }
  | { kind: "stall"; vendor: VendorId }
  | null;
export type ClickOutcome =
  | { action: "add"; product: string }
  | { action: "focus"; vendor: VendorId }
  | { action: "none" };

/**
 * What a click does: a container of the focused vendor adds its product; any
 * part of another stall (or of any stall, on the whole row) focuses that
 * vendor; the focused stall's structure and empty ground do nothing.
 */
export function clickOutcome(
  target: PointerTarget,
  focused: VendorId | null,
): ClickOutcome {
  if (!target) return { action: "none" };
  if (target.vendor !== focused)
    return { action: "focus", vendor: target.vendor };
  return target.kind === "container"
    ? { action: "add", product: target.product }
    : { action: "none" };
}

/** The product a pointer names: only one a click would add, otherwise "". */
export function hoveredProduct(
  target: PointerTarget,
  focused: VendorId | null,
): string {
  const outcome = clickOutcome(target, focused);
  return outcome.action === "add" ? outcome.product : "";
}
