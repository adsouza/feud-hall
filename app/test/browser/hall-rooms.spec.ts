import * as T from "three";
import type { Page } from "@playwright/test";
import type { Stall, View } from "../../src/api";
import { ROOM_SIDE, roomCentre } from "../../src/room-layout";
import { test, expect, state } from "./hall";

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

type Probe = Window & {
  __THREE_DEVTOOLS__: EventTarget;
  hallScene?: T.Scene;
  hallCamera?: T.Camera;
};

// Keep the scene and camera of the last drawn frame, through Three's devtools hook.
function observeScene(page: Page) {
  return page.addInitScript(() => {
    const probe = window as unknown as Probe;
    probe.__THREE_DEVTOOLS__ = new EventTarget();
    probe.__THREE_DEVTOOLS__.addEventListener("observe", (event) => {
      const renderer = (event as CustomEvent).detail as T.WebGLRenderer & {
        isWebGLRenderer?: boolean;
      };
      if (!renderer?.isWebGLRenderer) return;
      const draw = renderer.render;
      renderer.render = function (scene, camera) {
        draw.call(this, scene, camera);
        probe.hallScene = scene as T.Scene;
        probe.hallCamera = camera;
      };
    });
  });
}

type Spot = [room: number, position: number, activity?: Partial<Activity>];
type Activity = NonNullable<Stall["activity"]>;

function stallsAt(template: Stall, spots: Spot[]): Stall[] {
  return spots.map(([room, position, activity]) => ({
    ...template,
    stall_id: `room-${room}-${position}`,
    restaurant_id: `restaurant-${room}-${position}`,
    name: `Counter ${room}.${position}`,
    room,
    position,
    "open?": true,
    last_service: null,
    activity: {
      waiting: 1,
      cooking: 0,
      handover: false,
      staffed: true,
      workers: 1,
      staging: false,
      paused: false,
      ...activity,
    },
  }));
}

/** Serve a synthetic hall built from the real one; edits to it are served on the next poll. */
async function routed(
  page: Page,
  origin: string,
  spots: Spot[],
  open: number,
): Promise<View> {
  await page.goto(origin);
  const snapshot: View = await state(page);
  const template = snapshot.hall.stalls[0];
  snapshot.hall.stalls = stallsAt(template, spots);
  snapshot.hall.rooms = { count: 10, open };
  snapshot.hall.vacancies = [];
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.reload();
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  return snapshot;
}

/** Wait until the app has fetched the state after an edit. */
async function nextPoll(page: Page) {
  await page.waitForResponse((response) =>
    response.url().includes("/api/state"),
  );
  await page.waitForResponse((response) =>
    response.url().includes("/api/state"),
  );
}

async function visibleFraction(page: Page) {
  const rendered = await page.locator("[data-hall-canvas] canvas").screenshot();
  return page.evaluate(async (bytes) => {
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
}

/** Where a stall's booth appears on screen in the last drawn frame. */
function screenPosition(page: Page, id: string) {
  return page.evaluate((id) => {
    const probe = window as unknown as Probe;
    let root: T.Object3D | undefined;
    probe.hallScene!.traverse((object) => {
      if (object.userData.stall === id) root = object.parent!;
    });
    if (!root) return null;
    const at = root.getWorldPosition(
      new (root.position.constructor as typeof T.Vector3)(),
    );
    at.project(probe.hallCamera!);
    return [at.x, at.y, at.z];
  }, id);
}

/** Stalls of a room that the pointer can select: drawn, with a hit box. */
function drawnStalls(page: Page, room: number) {
  return page.evaluate((room) => {
    const probe = window as unknown as Probe;
    const ids = new Set<string>();
    probe.hallScene!.traverse((object) => {
      const id = object.userData.stall as string | undefined;
      if (!id || !id.startsWith(`room-${room}-`)) return;
      let shown = true;
      for (let at: T.Object3D | null = object; at; at = at.parent)
        shown &&= at.visible;
      if (shown) ids.add(id);
    });
    return ids.size;
  }, room);
}

test("a new hall shows Hall 1 with its three stalls and twelve to-let bays", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  const snapshot: View = await state(page);
  expect(snapshot.hall.rooms).toEqual({ count: 10, open: 1 });
  expect(snapshot.hall.stalls.map((stall) => stall.room)).toEqual([1, 1, 1]);
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await expect(host).toHaveAttribute("data-hall-bays", "12");
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveText([
    "—",
    ...snapshot.hall.stalls.map((s) => `${s.name} · ${s.stall_id}`),
  ]);
});

test("only the current room and open neighbours are drawn", async ({
  page,
  hall,
}) => {
  const busy = { waiting: 3, workers: 2 };
  await routed(
    page,
    hall.origin,
    [
      [1, 3, busy],
      [2, 3, busy],
      [2, 7, busy],
      [3, 3],
      [3, 5],
      [3, 7],
    ],
    3,
  );
  const host = page.locator("[data-hall-canvas]");
  const people = async () =>
    Number(await host.getAttribute("data-hall-people"));
  // Selected, room 1's stall is drawn in full: 1 owner + 2 workers + 3 diners.
  // Room 2, next door, is drawn simply: 1 owner + 1 worker + 1 diner each.
  // Room 3 is not drawn.
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption("room-1-3");
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await expect.poll(people).toBe(6 + 3 * 2);
  await host.focus();
  await host.press("]");
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await host.press("]");
  await expect(host).toHaveAttribute("data-hall-room", "3");
  // Room 2 simply, room 3's three quiet stalls (1 + 1 + 1 each); room 1 not at all.
  await expect.poll(people).toBe(3 * 2 + 3 * 3);
  // There is no room 4 to go to.
  await host.press("]");
  await expect(host).toHaveAttribute("data-hall-room", "3");
});

test("a closed room is not entered", async ({ page, hall }) => {
  test.setTimeout(120_000);
  await observeScene(page);
  const snapshot = await routed(page, hall.origin, [], 1);
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-room", "1");
  const eye = () =>
    page.evaluate(() => {
      const probe = window as unknown as Probe;
      const position = probe.hallCamera!.position;
      return [position.x, position.y, position.z];
    });
  // With no stall to stand before, walking starts at the room's centre facing
  // north; Shift+Right steps due east toward room 2.
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await host.focus();
  await page.keyboard.down("Shift");
  await page.keyboard.down("ArrowRight");
  let last = -Infinity;
  await expect
    .poll(
      async () => {
        const [x] = await eye();
        const stopped = x > 10 && Math.abs(x - last) < 1e-6;
        last = x;
        return stopped;
      },
      { timeout: 60_000, intervals: [700] },
    )
    .toBe(true);
  await page.keyboard.up("ArrowRight");
  await page.keyboard.up("Shift");
  const [x, y, z] = await eye();
  expect(x).toBeLessThan(17);
  expect(y).toBeCloseTo(1.55, 4);
  expect(Math.abs(z)).toBeLessThan(0.01);
  await expect(host).toHaveAttribute("data-hall-room", "1");

  snapshot.hall.rooms = { count: 10, open: 2 };
  await nextPoll(page);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await host.focus();
  await page.keyboard.down("Shift");
  await page.keyboard.down("ArrowRight");
  await expect(host).toHaveAttribute("data-hall-room", "2", {
    timeout: 60_000,
  });
  await page.keyboard.up("ArrowRight");
  await page.keyboard.up("Shift");
});

test("the camera leaves a room that closes", async ({ page, hall }) => {
  await observeScene(page);
  const snapshot = await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [2, 3],
      [3, 3],
      [3, 4],
    ],
    3,
  );
  const host = page.locator("[data-hall-canvas]");
  await host.focus();
  await host.press("]");
  await host.press("]");
  await expect(host).toHaveAttribute("data-hall-room", "3");
  snapshot.hall.stalls = snapshot.hall.stalls.filter(
    (stall) => stall.room !== 3,
  );
  snapshot.hall.rooms = { count: 10, open: 2 };
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await nextPoll(page);
  // The camera itself moved: it is over room 2, not left over room 3.
  const centre = roomCentre(2).x;
  const x = await page.evaluate(
    () => (window as unknown as Probe).hallCamera!.position.x,
  );
  expect(Math.abs(x - centre)).toBeLessThan(ROOM_SIDE / 2);
  expect(await visibleFraction(page)).toBeGreaterThan(0.15);
});

test("selecting a stall in another room moves there", async ({
  page,
  hall,
}) => {
  await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [2, 5],
    ],
    2,
  );
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption("room-2-5");
  await expect(host).toHaveAttribute("data-hall-room", "2");
});

test("a stall never moves", async ({ page, hall }) => {
  await observeScene(page);
  const snapshot = await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [1, 5],
      [1, 9],
    ],
    1,
  );
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect.poll(() => screenPosition(page, "room-1-3")).not.toBeNull();
  const before = (await screenPosition(page, "room-1-3"))!;
  const template = snapshot.hall.stalls[0];
  snapshot.hall.stalls = [
    ...stallsAt(
      template,
      [0, 1, 2, 4, 6, 7, 8, 10, 11, 12, 13, 14].map((position): Spot => [
        1,
        position,
      ]),
    ),
    ...snapshot.hall.stalls.filter((stall) => stall.stall_id === "room-1-3"),
  ];
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(14);
  await nextPoll(page);
  const after = (await screenPosition(page, "room-1-3"))!;
  for (let i = 0; i < 3; i++) expect(after[i]).toBeCloseTo(before[i], 9);
});

test("150 stalls across ten rooms render", async ({ page, hall }) => {
  test.setTimeout(180_000);
  await observeScene(page);
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const spots: Spot[] = [];
  for (let room = 1; room <= 10; room++)
    for (let position = 0; position < 15; position++)
      spots.push([room, position]);
  await routed(page, hall.origin, spots, 10);
  await expect(
    page
      .getByRole("combobox", { name: "Location", exact: true })
      .locator("option"),
  ).toHaveCount(151);
  const host = page.locator("[data-hall-canvas]");
  const location = page.getByRole("combobox", {
    name: "Location",
    exact: true,
  });
  for (let room = 1; room <= 10; room++) {
    if (room > 1) {
      await host.focus();
      await host.press("]");
    }
    await expect(host).toHaveAttribute("data-hall-room", String(room));
    await expect.poll(() => drawnStalls(page, room)).toBe(15);
    expect(await visibleFraction(page), `room ${room}`).toBeGreaterThan(0.15);
    // A pointer selects a stall of this room: the middle of the north wall.
    const target = `room-${room}-3`;
    const at = (await screenPosition(page, target))!;
    const box = (await host.locator("canvas").boundingBox())!;
    await page.mouse.click(
      box.x + ((at[0] + 1) / 2) * box.width,
      box.y + ((1 - at[1]) / 2) * box.height,
    );
    await expect(location).toHaveValue(target);
    await expect(host).toHaveAttribute("data-hall-room", String(room));
  }
  expect(errors).toEqual([]);
});
