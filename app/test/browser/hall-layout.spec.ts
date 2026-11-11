import { test, expect, state } from "./hall";
import {
  hallLayout,
  nextPerimeter,
  nextStallSlot,
  layoutStalls,
  toHall,
  toStall,
  type StallSlot,
} from "../../src/hall-layout";
import fc from "fast-check";

test.use({
  launch: true,
  viewport: { width: 1440, height: 1000 },
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});

test("outer corners and gaps fill first, then an outward island, with separated booths through 150", () => {
  const full = hallLayout(150);
  expect(full.placements.slice(0, 4).map((p) => p.perimeter)).toEqual([
    0, 0.25, 0.5, 0.75,
  ]);
  expect(full.placements.slice(4, 8).map((p) => p.perimeter)).toEqual([
    0.125, 0.375, 0.625, 0.875,
  ]);
  expect(full.placements.filter((p) => p.ring === "perimeter")).toHaveLength(
    16,
  );
  expect(full.placements.slice(16, 20).map((p) => p.perimeter)).toEqual([
    0, 0.25, 0.5, 0.75,
  ]);
  expect(full.islands).toHaveLength(17);
  expect(hallLayout(24).islands.map((island) => island.count)).toEqual([8]);
  expect(hallLayout(25).islands.map((island) => island.count)).toEqual([5, 4]);
  expect(hallLayout(33).islands.map((island) => island.count)).toEqual([
    6, 6, 5,
  ]);
  const failures: string[] = [];
  for (let count = 1; count <= 150; count++) {
    const layout = hallLayout(count);
    if (layout.islands.length !== Math.ceil(Math.max(0, count - 16) / 8))
      failures.push("wrong island count");
    for (const island of layout.islands) {
      if (island.count > 8 || (layout.islands.length > 1 && island.count < 4))
        failures.push("bad island size");
      if (
        layout.width / 2 - Math.abs(island.x) - island.side / 2 < 9 - 1e-8 ||
        layout.depth / 2 - Math.abs(island.z) - island.side / 2 < 9 - 1e-8
      )
        failures.push("narrow outer aisle");
      for (const other of layout.islands)
        if (
          other.id < island.id &&
          Math.abs(other.x - island.x) < island.side + 9 - 1e-8 &&
          Math.abs(other.z - island.z) < island.side + 9 - 1e-8
        )
          failures.push("narrow island aisle");
    }
    for (const [i, pose] of layout.placements.entries()) {
      const before = full.placements[i];
      if (
        pose.ring !== before.ring ||
        (pose.ring === "perimeter" && pose.perimeter !== before.perimeter) ||
        (pose.ring === "island" &&
          before.ring === "island" &&
          pose.order !== before.order)
      )
        failures.push("changed identity");
      const localX = pose.x - pose.centerX,
        localZ = pose.z - pose.centerZ;
      const front = toHall(pose, 0, 1),
        direction = pose.ring === "island" ? 1 : -1;
      if (
        pose.ring === "perimeter" &&
        ![0, 0.25, 0.5, 0.75].includes(pose.perimeter)
      ) {
        const dx = front.x - pose.x,
          dz = front.z - pose.z;
        const expected =
          Math.abs(pose.z + layout.depth / 2) < 1e-8
            ? [0, 1]
            : Math.abs(pose.z - layout.depth / 2) < 1e-8
              ? [0, -1]
              : Math.abs(pose.x - layout.width / 2) < 1e-8
                ? [-1, 0]
                : [1, 0];
        if (
          Math.abs(dx - expected[0]) > 1e-8 ||
          Math.abs(dz - expected[1]) > 1e-8
        )
          failures.push("angled wall stall");
      } else if (
        Math.abs(
          Math.hypot(front.x - pose.centerX, front.z - pose.centerZ) -
            Math.hypot(localX, localZ) -
            direction,
        ) > 1e-8
      )
        failures.push("wrong facing");
      for (const x of [-1.8, 1.8])
        for (const z of [-1.25, 1.25]) {
          const corner = toHall(pose, x, z);
          if (
            Math.abs(corner.x) >= layout.floorWidth / 2 ||
            Math.abs(corner.z) >= layout.floorDepth / 2
          )
            failures.push("outside wall");
        }
    }
    const boxes = layout.placements.map((pose) =>
      [
        [-1.8, -1.25],
        [1.8, -1.25],
        [1.8, 1.25],
        [-1.8, 1.25],
      ].map(([x, z]) => toHall(pose, x, z)),
    );
    for (let i = 0; i < boxes.length; i++)
      for (let j = 0; j < i; j++) {
        const a = boxes[i],
          b = boxes[j];
        const separate = [a, b].some((box) =>
          [0, 1].some((edge) => {
            const dx = box[edge + 1].x - box[edge].x,
              dz = box[edge + 1].z - box[edge].z;
            const pa = a.map((p) => p.x * -dz + p.z * dx),
              pb = b.map((p) => p.x * -dz + p.z * dx);
            return (
              Math.max(...pa) < Math.min(...pb) ||
              Math.max(...pb) < Math.min(...pa)
            );
          }),
        );
        if (!separate) failures.push(`overlap at ${count}: ${i}, ${j}`);
      }
  }
  expect(failures).toEqual([]);
});

test("vacancies fill actual largest gaps and rotated coordinates round trip", () => {
  const all = hallLayout(16).placements.map((pose) => pose.perimeter);
  fc.assert(
    fc.property(
      fc.subarray(all.slice(4)),
      fc.subarray(Array.from({ length: 40 }, (_, i) => i)),
      fc.double({ min: -2, max: 2, noNaN: true }),
      fc.double({ min: -2, max: 2, noNaN: true }),
      (rest, orders, x, z) => {
        const occupied = [0, 0.25, 0.5, 0.75, ...rest];
        const sorted = [...occupied].sort((a, b) => a - b),
          candidate = nextPerimeter(occupied);
        if (occupied.includes(candidate)) throw Error("occupied gap");
        const distance = (at: number) =>
          Math.min(
            ...occupied.map((p) =>
              Math.min(Math.abs(at - p), 1 - Math.abs(at - p)),
            ),
          );
        if (
          sorted.some(
            (at, i) =>
              distance(candidate) + 1e-10 <
              distance((at + (sorted[i + 1] ?? 1)) / 2),
          )
        )
          throw Error("not largest gap");
        const slots: StallSlot[] = occupied.map((perimeter) => ({
          ring: "perimeter",
          perimeter,
        }));
        const withHoles: StallSlot[] = [
          ...hallLayout(16).placements,
          ...orders.map((order) => ({ ring: "island" as const, order })),
        ];
        const replacement = nextStallSlot(withHoles);
        if (replacement.ring !== "island" || orders.includes(replacement.order))
          throw Error("occupied island slot");
        const balanced = layoutStalls(withHoles);
        if (balanced.islands.some((island) => island.count > 8))
          throw Error("oversized island");
        for (const pose of [
          ...layoutStalls(slots).placements,
          ...balanced.placements,
        ]) {
          const world = toHall(pose, x, z),
            local = toStall(pose, world.x, world.z);
          if (Math.abs(local.x - x) > 1e-8 || Math.abs(local.z - z) > 1e-8)
            throw Error("bad frame");
        }
      },
    ),
    { seed: 110611, numRuns: 40 },
  );
  const sixteen = hallLayout(16).placements;
  expect(nextStallSlot(sixteen)).toEqual({ ring: "island", order: 0 });
  const thirty = hallLayout(30).placements;
  const hole = thirty.filter(
    (pose) => pose.ring !== "island" || pose.order !== 5,
  );
  expect(nextStallSlot(hole)).toEqual({ ring: "island", order: 5 });
  expect(layoutStalls(hole).islands.every((island) => island.count <= 8)).toBe(
    true,
  );
  expect(nextPerimeter([0, 0.25, 0.5, 0.75, 0.125], 2, 1)).toBe(0.625);
  expect(nextStallSlot(sixteen.slice(1))).toEqual({
    ring: "perimeter",
    perimeter: 0,
  });
});

test("renders an outer ring, splits small islands after eight and supports 150 stalls", async ({
  page,
  hall,
}, info) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(hall.origin);
  const snapshot = await state(page),
    original = snapshot.hall.stalls[0];
  const populate = (count: number) => {
    snapshot.hall.stalls = Array.from({ length: count }, (_, i) => ({
      ...original,
      stall_id: `ring-${i}`,
      name: `Counter ${i + 1}`,
      activity: { ...original.activity, waiting: 2, workers: 1 },
    }));
  };
  populate(16);
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.reload();
  const canvas = page.locator("[data-hall-canvas] canvas");
  await expect(canvas).toBeVisible();
  await page.getByLabel("Reduced detail").check();
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await canvas.screenshot({ path: info.outputPath("perimeter-hall.png") });
  populate(24);
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(25);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await canvas.screenshot({ path: info.outputPath("island-hall.png") });
  // A newly added outward-facing island tablet must be readable and pickable too.
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption("ring-21");
  await page
    .getByRole("button", { name: "Focus on the hall", exact: true })
    .click();
  await page
    .locator(".hall-scene-pane")
    .getByRole("button", { name: "Menu", exact: true })
    .click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-tablet", "ring-21");
  await canvas.screenshot({ path: info.outputPath("island-tablet.png") });
  // The selected stall changes both island and heading at the split. Its screen
  // must stay readable and pickable without closing the tablet or losing drafts.
  const split = page.waitForResponse(
    async (response) =>
      response.url().includes("/api/state") &&
      (await response.json()).hall?.stalls.length === 25,
  );
  populate(25);
  await split;
  await canvas.screenshot({ path: info.outputPath("tablet-after-split.png") });
  const box = (await canvas.boundingBox())!;
  const scale = Math.min(box.height / 1.08, box.width / 0.7344);
  await page.mouse.click(
    box.x + box.width / 2,
    box.y + box.height / 2 + (240 / 1080 - 0.5) * 0.93 * scale,
  );
  await expect
    .poll(async () => (await state(page)).profile?.account.name)
    .toBe("Visitor");
  await host.press("Escape");
  // The responsive snapshot deliberately has no account: only presentation changes here.
  await page
    .getByRole("button", { name: "Restore hall layout", exact: true })
    .click();
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(26);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await canvas.screenshot({ path: info.outputPath("split-islands-hall.png") });
  populate(40);
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(41);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await canvas.screenshot({ path: info.outputPath("small-islands-hall.png") });
  populate(150);
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(151);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  expect(errors).toEqual([]);
  const rendered = await canvas.screenshot({
    path: info.outputPath("perimeter-150.png"),
  });
  const visibleFraction = await page.evaluate(async (bytes) => {
    const image = await createImageBitmap(
      new Blob([Uint8Array.from(bytes)], { type: "image/png" }),
    );
    const probe = document.createElement("canvas");
    probe.width = image.width;
    probe.height = image.height;
    const context = probe.getContext("2d")!;
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, image.width, image.height).data;
    let visible = 0;
    for (let i = 0; i < pixels.length; i += 4)
      if (
        Math.abs(pixels[i] - 17) +
          Math.abs(pixels[i + 1] - 21) +
          Math.abs(pixels[i + 2] - 38) >
        25
      )
        visible++;
    image.close();
    return visible / (probe.width * probe.height);
  }, Array.from(rendered));
  expect(visibleFraction).toBeGreaterThan(0.15);
  await expect(canvas).toBeVisible();
});
