import * as T from "three";
import { createGuest, expect, state, test } from "./hall";
import { servedTrays } from "../../src/diner-pickup";
import type { DiningHistory, Profile } from "../../src/api";

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
};

async function probe(page: import("@playwright/test").Page) {
  await page.addInitScript(() => {
    const view = window as unknown as Probe;
    view.__THREE_DEVTOOLS__ = new EventTarget();
    view.pickupPhases = [];
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

test("only committed served courses create personal trays", () => {
  const account = {
    id: "diner",
    name: "Diner",
    "owner?": false,
    "reviewer?": false,
    proof: null,
    quota: 0,
    progress: 0,
  };
  const profile: Pick<Profile, "account" | "visit"> = {
    account,
    visit: {
      id: "visit",
      stall: "stall",
      tray_status: "preparing",
      stage: "counter",
      dessert: "none",
    },
  };
  expect(servedTrays(profile, null, 1000)).toEqual([]);
  profile.visit!.tray_status = "served";
  profile.visit!.stage = "served";
  profile.visit!.dessert = "offered";
  const main = servedTrays(profile, null, 1000);
  expect(main).toEqual([{ id: "diner:visit:main", stall: "stall" }]);
  profile.visit!.dessert = "accepted";
  profile.visit!.stage = "preparing";
  expect(servedTrays(profile, null, 1000)).toEqual(main);
  profile.visit!.stage = "served";
  expect(servedTrays(profile, null, 1000)).toHaveLength(2);
  const history: DiningHistory = {
    before: null,
    receipts: [
      {
        visit_id: "visit",
        stall_id: "stall",
        restaurant_id: "r",
        at: 1000,
        reason: "completed",
        total: "800",
        courses: [
          {
            kind: "main",
            recipe_id: "meal",
            outcome: "served",
            price: "600",
            charged: "600",
          },
          {
            kind: "dessert",
            recipe_id: "sweet",
            outcome: "served",
            price: "200",
            charged: "200",
          },
        ],
      },
    ],
  };
  expect(servedTrays(profile, history, 1000)).toHaveLength(2);
  profile.visit = null;
  expect(servedTrays(profile, history, 1000)).toHaveLength(2);
  expect(servedTrays(profile, history, 721001)).toEqual([]);
  expect(servedTrays(null, history, 1000)).toEqual([]);
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
