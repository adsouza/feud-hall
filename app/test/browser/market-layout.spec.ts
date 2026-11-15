import { readFileSync } from "node:fs";
import { expect, test } from "./hall";
import { VENDORS, goodFor, shelves } from "../../src/market-goods";
import {
  AISLE_Z,
  MIN_COLUMNS,
  PITCH_X,
  cartGoods,
  clickOutcome,
  columnsFor,
  fillFor,
  hoveredProduct,
  marketLayout,
  overviewPose,
  tripRoute,
  vendorPose,
} from "../../src/market-layout";

const goodsJson: Record<string, unknown> = JSON.parse(
  readFileSync(new URL("../../src/market-goods.json", import.meta.url), "utf8"),
);
const ids = Object.keys(goodsJson).sort();

test("market layout: column count grows with the square root of the product count", () => {
  expect(MIN_COLUMNS).toBe(3);
  expect(columnsFor(0)).toBe(3);
  expect(columnsFor(1)).toBe(3);
  expect(columnsFor(10)).toBe(4); // ceil(sqrt(15))
  expect(columnsFor(22)).toBe(6); // ceil(sqrt(33))
  expect(columnsFor(96)).toBe(12); // sqrt(144) exactly
  expect(columnsFor(97)).toBe(13);
});

test("market layout: every product has one container at its vendor, none overlapping", () => {
  const layout = marketLayout(ids);
  expect(layout.containers.length).toBe(ids.length);
  expect(new Set(layout.containers.map((c) => c.product)).size).toBe(
    ids.length,
  );

  const problems: string[] = [];
  const stallOf = new Map(layout.stalls.map((s) => [s.vendor, s]));
  for (const c of layout.containers) {
    const vendor = goodFor(c.product).vendor;
    if (c.vendor !== vendor) problems.push(`${c.product} at ${c.vendor}`);
    const stall = stallOf.get(vendor);
    if (!stall) {
      problems.push(`${c.product}: no ${vendor} stall`);
      continue;
    }
    if (Math.abs(c.x - stall.x) > stall.width / 2)
      problems.push(`${c.product} outside its stall`);
    if (c.column < 0 || c.column >= stall.columns)
      problems.push(`${c.product} column ${c.column}`);
    if (c.tier < 0 || c.tier >= stall.tiers)
      problems.push(`${c.product} tier ${c.tier}`);
  }
  let closest = Infinity;
  for (let i = 0; i < layout.containers.length; i++)
    for (let j = i + 1; j < layout.containers.length; j++) {
      const a = layout.containers[i];
      const b = layout.containers[j];
      closest = Math.min(closest, Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z));
    }
  expect(problems).toEqual([]);
  expect(closest).toBeGreaterThanOrEqual(0.5);

  // Stalls in VENDORS order by x, not overlapping, the row centred on 0.
  expect(layout.stalls.map((s) => s.vendor)).toEqual(
    VENDORS.filter((v) => ids.some((id) => goodFor(id).vendor === v)),
  );
  for (let i = 1; i < layout.stalls.length; i++) {
    const left = layout.stalls[i - 1];
    const right = layout.stalls[i];
    expect(right.x - right.width / 2).toBeGreaterThan(left.x + left.width / 2);
  }
  const first = layout.stalls[0];
  const last = layout.stalls[layout.stalls.length - 1];
  expect(first.x - first.width / 2 + (last.x + last.width / 2)).toBeCloseTo(
    0,
    6,
  );
  // Each stall's shelf face is sized from its own product count.
  for (const stall of layout.stalls) {
    const count = layout.containers.filter(
      (c) => c.vendor === stall.vendor,
    ).length;
    expect(stall.columns).toBe(columnsFor(count));
  }
});

test("market layout: every container is visible from the front, tiers step up and back", () => {
  const layout = marketLayout(ids);
  const problems: string[] = [];
  for (const a of layout.containers)
    for (const b of layout.containers) {
      if (a.vendor !== b.vendor || b.tier !== a.tier + 1) continue;
      if (!(b.y > a.y && b.z < a.z)) problems.push(`${a.product}/${b.product}`);
    }
  expect(problems).toEqual([]);
  // Within a tier, a container's height and depth do not depend on its column.
  const tiers = new Map<string, { y: number; z: number }>();
  for (const c of layout.containers) {
    const key = `${c.vendor}:${c.tier}`;
    const seen = tiers.get(key);
    if (!seen) tiers.set(key, { y: c.y, z: c.z });
    else if (seen.y !== c.y || seen.z !== c.z) problems.push(key);
  }
  expect(problems).toEqual([]);
});

test("market layout: a substitute's container is next to its primary's", () => {
  const layout = marketLayout(ids);
  const at = new Map(layout.containers.map((c) => [c.product, c]));
  const problems: string[] = [];
  let pairs = 0;
  for (const { products } of shelves(ids))
    for (let i = 1; i < products.length; i++) {
      const id = products[i];
      if (goodFor(id).beside !== products[i - 1]) continue;
      pairs++;
      const primary = at.get(products[i - 1]);
      const sub = at.get(id);
      if (!primary || !sub) {
        problems.push(`${id}: missing`);
        continue;
      }
      if (
        sub.tier !== primary.tier ||
        sub.y !== primary.y ||
        sub.z !== primary.z
      )
        problems.push(`${id}: not on its primary's tier`);
      if (sub.column !== primary.column + 1)
        problems.push(`${id}: column ${sub.column} after ${primary.column}`);
      if (Math.abs(sub.x - primary.x - PITCH_X) > 1e-9)
        problems.push(`${id}: not one pitch to the right`);
    }
  expect(problems).toEqual([]);
  // The catalog really has substitutes, so this checked something.
  expect(pairs).toBeGreaterThan(100);
});

test("market layout: a group that does not fit moves whole to the next tier", () => {
  // Four products give three columns. Clams and its substitute fill columns
  // 0 and 1; halibut's pair would straddle the tier end, so it starts tier 1
  // and column 2 of tier 0 stays empty.
  const layout = marketLayout([
    "halibut_frozen",
    "clams",
    "halibut",
    "clams_frozen",
  ]);
  expect(layout.stalls).toHaveLength(1);
  expect(layout.stalls[0]).toMatchObject({ columns: 3, tiers: 2 });
  const at = new Map(layout.containers.map((c) => [c.product, c]));
  expect(at.get("clams")).toMatchObject({ tier: 0, column: 0 });
  expect(at.get("clams_frozen")).toMatchObject({ tier: 0, column: 1 });
  expect(at.get("halibut")).toMatchObject({ tier: 1, column: 0 });
  expect(at.get("halibut_frozen")).toMatchObject({ tier: 1, column: 1 });
  // A lone product does fill the last column.
  const fits = marketLayout(["clams", "clams_frozen", "salmon"]);
  expect(fits.containers.find((c) => c.product === "salmon")).toMatchObject({
    tier: 0,
    column: 2,
  });
});

test("market layout: a trip stops at each vendor it buys from, in row order, once", () => {
  const layout = marketLayout(ids);
  const route = tripRoute(["salmon", "rice_long", "onion", "salmon"], layout);
  const stall = (vendor: string) =>
    layout.stalls.find((s) => s.vendor === vendor) as { x: number };
  const pauses = route.filter((point) => point.pause);
  expect(pauses.map((p) => p.x)).toEqual(
    ["greengrocer", "fishmonger", "grains"].map((v) => stall(v).x),
  );
  for (const point of route) expect(point.z).toBe(AISLE_Z);
  const first = layout.stalls[0];
  const last = layout.stalls[layout.stalls.length - 1];
  expect(route[0].pause).toBe(false);
  expect(route[route.length - 1].pause).toBe(false);
  expect(route[0].x).toBeLessThan(first.x - first.width / 2);
  expect(route[route.length - 1].x).toBeGreaterThan(last.x + last.width / 2);
  // A product the catalog does not describe is bought from the pantry.
  const unknown = tripRoute(["no_such_product"], layout).filter((p) => p.pause);
  expect(unknown.map((p) => p.x)).toEqual([stall("pantry").x]);
  // A vendor without a stall is passed by.
  const fishOnly = marketLayout(["salmon"]);
  expect(tripRoute(["onion"], fishOnly).filter((p) => p.pause)).toEqual([]);
});

test("market layout: fill and cart goods", () => {
  expect(fillFor(0)).toBe(0);
  expect(fillFor(-5)).toBe(0);
  expect(fillFor(1)).toBeCloseTo(0.12);
  expect(fillFor(119)).toBeCloseTo(0.12);
  expect(fillFor(1000)).toBe(1);
  expect(fillFor(5000)).toBe(1);
  expect(fillFor(500)).toBeGreaterThan(fillFor(200));
  expect(fillFor(500)).toBeCloseTo(0.5);
  expect([cartGoods("small"), cartGoods("medium"), cartGoods("large")]).toEqual(
    [2, 5, 9],
  );
});

test("market layout: the camera poses look at what they name", () => {
  const layout = marketLayout(ids);
  const overview = overviewPose(layout.stalls);
  expect(overview.target[0]).toBeCloseTo(0, 6);
  expect(overview.position[0]).toBeCloseTo(0, 6);
  expect(overview.position[2]).toBeGreaterThan(overview.target[2]);
  expect(overview.position[1]).toBeGreaterThan(overview.target[1]);
  for (const stall of layout.stalls) {
    const pose = vendorPose(stall);
    expect(pose.target[0]).toBeCloseTo(stall.x, 6);
    expect(pose.position[0]).toBeCloseTo(stall.x, 6);
    // Closer than the overview, and a wider stall needs a farther camera.
    const distance = Math.hypot(
      pose.position[1] - pose.target[1],
      pose.position[2] - pose.target[2],
    );
    expect(distance).toBeLessThan(
      Math.hypot(
        overview.position[1] - overview.target[1],
        overview.position[2] - overview.target[2],
      ),
    );
  }
  const narrow = vendorPose(
    layout.stalls.find(
      (s) => s.vendor === "fishmonger",
    ) as (typeof layout.stalls)[number],
  );
  const wide = vendorPose(
    layout.stalls.find(
      (s) => s.vendor === "pantry",
    ) as (typeof layout.stalls)[number],
  );
  expect(wide.position[2] - wide.target[2]).toBeGreaterThan(
    narrow.position[2] - narrow.target[2],
  );
});

test("market layout: a click adds only at the focused stall, elsewhere it focuses", () => {
  const salmon = {
    kind: "container",
    product: "salmon",
    vendor: "fishmonger",
  } as const;
  const onion = {
    kind: "container",
    product: "onion",
    vendor: "greengrocer",
  } as const;
  const butcher = { kind: "stall", vendor: "butcher" } as const;
  // The whole row: every part of a stall focuses it; nothing is added.
  expect(clickOutcome(salmon, null)).toEqual({
    action: "focus",
    vendor: "fishmonger",
  });
  expect(clickOutcome(butcher, null)).toEqual({
    action: "focus",
    vendor: "butcher",
  });
  // A close-up: the focused vendor's containers add, other stalls focus.
  expect(clickOutcome(salmon, "fishmonger")).toEqual({
    action: "add",
    product: "salmon",
  });
  expect(clickOutcome(onion, "fishmonger")).toEqual({
    action: "focus",
    vendor: "greengrocer",
  });
  expect(clickOutcome(butcher, "fishmonger")).toEqual({
    action: "focus",
    vendor: "butcher",
  });
  // The focused stall's own structure, and empty ground, do nothing.
  expect(
    clickOutcome({ kind: "stall", vendor: "fishmonger" }, "fishmonger"),
  ).toEqual({ action: "none" });
  expect(clickOutcome(null, "fishmonger")).toEqual({ action: "none" });
  expect(clickOutcome(null, null)).toEqual({ action: "none" });
  // Hover names a product only where a click would add it.
  expect(hoveredProduct(salmon, "fishmonger")).toBe("salmon");
  expect(hoveredProduct(salmon, null)).toBe("");
  expect(hoveredProduct(onion, "fishmonger")).toBe("");
  expect(hoveredProduct(butcher, "butcher")).toBe("");
  expect(hoveredProduct(null, "butcher")).toBe("");
});
