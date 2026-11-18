import * as T from "three";
import { createGuest, expect, state, test } from "./hall";
import type { View } from "../../src/api";

test.use({
  launch: true,
  viewport: { width: 1280, height: 900 },
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});
type Probe = Window & {
  __THREE_DEVTOOLS__: EventTarget;
  hallScene: T.Scene;
  hallCamera: T.Camera;
  pickupPhases: string[];
  counterStall?: string;
  trayFrames: { atCounter: number; stationary: boolean; carried: number }[];
};

async function probe(page: import("@playwright/test").Page) {
  await page.addInitScript(() => {
    const view = window as unknown as Probe;
    view.__THREE_DEVTOOLS__ = new EventTarget();
    view.pickupPhases = [];
    view.trayFrames = [];
    view.__THREE_DEVTOOLS__.addEventListener("observe", (event) => {
      const renderer = (event as CustomEvent).detail as T.WebGLRenderer & {
        isWebGLRenderer?: boolean;
      };
      if (!renderer?.isWebGLRenderer) return;
      const draw = renderer.render;
      renderer.render = function (scene, camera) {
        draw.call(this, scene, camera);
        view.hallScene = scene as T.Scene;
        view.hallCamera = camera;
        const hands = scene.getObjectByName("player-pickup-hands");
        if (hands?.visible) view.pickupPhases.push(hands.userData.phase);
        if (!view.counterStall) return;
        const counter = scene.children
          .flatMap((group) => group.children)
          .flatMap((stall) => stall.children)
          .find(
            (object) =>
              object.userData.stall === view.counterStall &&
              (object.name === "counter-tray" ||
                object.name.startsWith("personal-pickup:")),
          );
        const carried = scene.getObjectByName(
          "diner-carried-trays",
        ) as T.InstancedMesh;
        if (!counter || !carried) return;
        const origin = counter.getWorldPosition(counter.position.clone());
        const matrix = carried.matrix.clone();
        const point = origin.clone();
        let atCounter = Number(counter.visible);
        for (let i = 0; i < carried.count; i++) {
          carried.getMatrixAt(i, matrix);
          if (
            point.setFromMatrixPosition(matrix).distanceToSquared(origin) < 1e-6
          )
            atCounter++;
        }
        view.trayFrames.push({
          atCounter,
          stationary: counter.visible,
          carried: carried.count,
        });
      };
    });
  });
}
async function trayCount(page: import("@playwright/test").Page) {
  return page.evaluate(() => {
    let count = 0;
    (window as unknown as Probe).hallScene?.traverse((object) => {
      if (object.visible && object.name.startsWith("personal-pickup:")) count++;
    });
    return count;
  });
}

test("only tablet screen clicks open the tablet; counters and other trays only select the stall", async ({
  page,
  hall,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await probe(page);
  await page.goto(hall.origin);
  const snapshot = await state(page);
  // Render a public handover belonging to another diner, never a private pickup.
  snapshot.hall.stalls[0].activity.handover = true;
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.reload();
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("tabindex", "0");
  const stall = snapshot.hall.stalls[0].stall_id;
  const selection = page.locator(".stall-inspector").getByRole("combobox", {
    name: "Location",
    exact: true,
    includeHidden: true,
  });
  await selection.selectOption(stall);
  await page
    .getByRole("button", { name: "Focus on the hall", exact: true })
    .click();
  async function clickAt(point: number[]) {
    const position = await page.evaluate(
      ({ stall, point }) => {
        const view = window as unknown as Probe;
        let tablet: T.Object3D | undefined;
        view.hallScene.traverse((object) => {
          if (
            object.userData.stall === stall &&
            (object as T.Mesh).geometry?.type === "PlaneGeometry"
          )
            tablet = object;
        });
        const root = tablet!.parent!;
        const tray = root.children.find(
          (object) =>
            object.position.x === 0 &&
            object.position.y === 0.93 &&
            object.position.z === 0.88,
        );
        if (!tray?.visible)
          throw new Error("The other diner's public tray must be visible");
        const p = root
          .localToWorld(root.position.clone().set(point[0], point[1], point[2]))
          .project(view.hallCamera);
        const canvas = document.querySelector("[data-hall-canvas] canvas")!;
        return {
          x: ((p.x + 1) / 2) * canvas.clientWidth,
          y: ((1 - p.y) / 2) * canvas.clientHeight,
        };
      },
      { stall, point },
    );
    await host.locator("canvas").click({ position });
  }
  for (const point of [
    [-0.6, 0.88, 1.08],
    [0, 1.01, 0.88],
    [0, 1.94, 1.035],
  ]) {
    await clickAt(point);
    await expect(host).toHaveAttribute("data-hall-tablet", "");
    await expect(selection).toHaveValue(stall);
  }
  await clickAt([1.04, 1.43, 1.207]);
  await expect(host).toHaveAttribute("data-hall-tablet", stall);
});

test("the next diner takes the sole counter tray even when a new handover has started", async ({
  page,
  hall,
}) => {
  await probe(page);
  await page.goto(hall.origin);
  await createGuest(page, "Counter diner");
  const snapshot: View = await state(page);
  const stall = snapshot.hall.stalls[0];
  for (const entry of snapshot.hall.stalls) {
    entry.last_service = null;
    entry.activity!.waiting = entry === stall ? 3 : 0;
    entry.activity!.handover = false;
  }
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.reload();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(stall.stall_id);
  const take = page.getByRole("button", { name: "Take tray", exact: true });
  const frames = () =>
    page.evaluate(() => (window as unknown as Probe).trayFrames);
  await page.evaluate((id) => {
    (window as unknown as Probe).counterStall = id;
  }, stall.stall_id);

  snapshot.hall.position++;
  stall.last_service = "own-meal";
  stall.activity!.waiting--;
  snapshot.profile!.counter_pickups = [
    { id: "own-meal", stall: stall.stall_id },
  ];
  await expect(take).toBeVisible();
  await expect.poll(() => trayCount(page)).toBe(1);
  await expect
    .poll(async () => (await frames()).at(-1))
    .toMatchObject({
      atCounter: 1,
      stationary: true,
      carried: 0,
    });

  // Move on without collecting the private tray. The next handover replaces
  // it, and the receipt from the previous meal no longer controls the counter.
  snapshot.profile!.counter_pickups = [];
  stall.activity!.handover = true;
  snapshot.hall.position++;
  await expect(take).toHaveCount(0);
  await expect.poll(() => trayCount(page)).toBe(0);
  await expect
    .poll(async () => (await frames()).at(-1))
    .toMatchObject({
      atCounter: 1,
      stationary: true,
      carried: 0,
    });

  // The next completed handover and another active counter job can arrive in
  // the same snapshot. The departing diner lifts the old tray first.
  stall.last_service = "next-meal";
  stall.activity!.waiting--;
  snapshot.hall.position++;
  await expect
    .poll(async () =>
      (await frames()).some(
        (frame) => !frame.stationary && frame.carried === 1,
      ),
    )
    .toBe(true);
  await expect
    .poll(async () => (await frames()).at(-1))
    .toMatchObject({
      atCounter: 1,
      stationary: true,
      carried: 1,
    });
  expect((await frames()).every((frame) => frame.atCounter <= 1)).toBe(true);
});

for (const reduced of [false, true])
  test(`a served tray can be taken ${reduced ? "without motion" : "with reaching arms"} without gameplay writes`, async ({
    page,
    hall,
  }, info) => {
    if (reduced) await page.emulateMedia({ reducedMotion: "reduce" });
    await probe(page);
    const commands: string[] = [];
    page.on("request", (request) => {
      if (request.url().endsWith("/api/commands"))
        commands.push(request.postDataJSON().kind);
    });
    await page.goto(hall.origin);
    await createGuest(page, "Tray diner");
    await page.getByRole("button", { name: "My visit", exact: true }).click();
    await page.getByRole("button", { name: "Claim daily allowance" }).click();
    await page
      .getByRole("combobox", { name: "Location", exact: true })
      .selectOption("s001");
    await page
      .getByRole("combobox", { name: "Main", exact: true })
      .selectOption({ index: 1 });
    await page
      .getByRole("button", { name: "Review order", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Confirm order", exact: true })
      .click();
    await expect
      .poll(async () => (await state(page)).profile.visit?.estimate)
      .toBeTruthy();
    const estimate = (await state(page)).profile.visit.estimate;
    await page.getByRole("button", { name: "Hall", exact: true }).click();
    const host = page.locator("[data-hall-canvas]");
    await expect(host).toHaveAttribute("tabindex", "0");
    await page
      .getByRole("combobox", { name: "Location", exact: true })
      .selectOption("s001");
    await expect(
      page.getByRole("button", { name: "Take tray", exact: true }),
    ).toHaveCount(0);
    await expect.poll(() => trayCount(page)).toBe(0);
    await hall.control({ advance_to: estimate });
    await expect(
      page.getByRole("button", { name: "Take tray", exact: true }),
    ).toBeVisible();
    await expect.poll(() => trayCount(page)).toBe(1);
    const before = await state(page),
      count = commands.length;
    if (reduced) {
      await host.focus();
      await host.press("f");
    } else {
      const point = await page.evaluate(() => {
        const view = window as unknown as Probe;
        let tray: T.Object3D | undefined;
        view.hallScene.traverse((object) => {
          if (object.visible && object.name.startsWith("personal-pickup:"))
            tray = object;
        });
        const position = tray!.getWorldPosition(tray!.position.clone());
        position.y += 0.025;
        position.project(view.hallCamera);
        const canvas = document.querySelector("[data-hall-canvas] canvas")!;
        return {
          x: ((position.x + 1) / 2) * canvas.clientWidth,
          y: ((1 - position.y) / 2) * canvas.clientHeight,
        };
      });
      await host.locator("canvas").click({ position: point });
      await host.press("f");
      await expect
        .poll(() =>
          page.evaluate(() =>
            (window as unknown as Probe).pickupPhases.includes("taking"),
          ),
        )
        .toBe(true);
      await host
        .locator("canvas")
        .screenshot({ path: info.outputPath("taking-tray.png") });
    }
    await expect
      .poll(() =>
        page.evaluate(
          () =>
            (window as unknown as Probe).hallScene.getObjectByName(
              "player-pickup-hands",
            )?.visible,
        ),
      )
      .toBe(false);
    await expect(
      page.getByRole("button", { name: "Take tray", exact: true }),
    ).toHaveCount(0);
    await expect.poll(() => trayCount(page)).toBe(0);
    if (reduced)
      expect(
        await page.evaluate(() => (window as unknown as Probe).pickupPhases),
      ).toEqual([]);
    const after = await state(page);
    expect(after.profile.balance).toBe(before.profile.balance);
    expect(after.hall.position).toBe(before.hall.position);
    expect(commands.length).toBe(count);
    // A live refresh and a remount must not make an already taken tray reappear.
    await page.getByRole("button", { name: "My visit", exact: true }).click();
    await expect(
      page.getByRole("heading", { name: "Dining receipts", exact: true }),
    ).toBeVisible();
    await expect(
      page.locator("details").filter({ hasText: "Charged" }),
    ).toHaveCount(1);
    await page.getByRole("button", { name: "Hall", exact: true }).click();
    await expect(host).toHaveAttribute("tabindex", "0");
    await expect.poll(() => trayCount(page)).toBe(0);
    await expect(
      page.getByRole("button", { name: "Take tray", exact: true }),
    ).toHaveCount(0);
  });
