import * as T from "three";
import type { Page } from "@playwright/test";
import type { Stall, Vacancy, View } from "../../src/api";
import { cash, clock } from "../../src/api";
import { ROOM_SIDE, positionKind, roomCentre } from "../../src/room-layout";
import { createGuest, test, expect, state } from "./hall";

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

/** Vacant spots "spot-<room>-<position>" with rent 1000 + 100 × position. */
function vacanciesAt(spots: [room: number, position: number][]): Vacancy[] {
  return spots.map(([room, position]) => ({
    stall_id: `spot-${room}-${position}`,
    tier: positionKind(room, position),
    room,
    position,
    exposure: 1000,
    rent: String(1000 + 100 * position),
    holding: "500",
    setup_fee: "2000",
    base_rent: "1000",
    class_leased: 0,
    class_total: 4,
  }));
}

/** Serve a synthetic hall built from the real one; edits to it are served on the next poll. */
async function routed(
  page: Page,
  origin: string,
  spots: Spot[],
  open: number,
  vacant: [room: number, position: number][] = [],
  goto = true,
): Promise<View> {
  if (goto) await page.goto(origin);
  const snapshot: View = await state(page);
  const template = snapshot.hall.stalls[0];
  snapshot.hall.stalls = stallsAt(template, spots);
  snapshot.hall.rooms = { count: 10, open };
  snapshot.hall.vacancies = vacanciesAt(vacant);
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
  // With every hall open there is no closed hall to explain.
  await expect(page.locator("#hall-room-closed")).toHaveCount(0);
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

const hallsGroup = (page: Page, name = "Halls") =>
  page.getByRole("group", { name, exact: true });
const hallButton = (page: Page, room: number) =>
  hallsGroup(page).getByRole("button", { name: `Hall ${room}`, exact: true });
const locationPicker = (page: Page) =>
  page.getByRole("combobox", { name: "Location", exact: true });
/** A vacant spot's card in the grouped list. */
const spotCard = (page: Page, id: string) =>
  page.locator("article").filter({ hasText: id });

/**
 * A point in the frame of the object carrying `userData[key] === id` (a
 * stall's or bay's root), in world coordinates and on screen.
 */
function pointOf(
  page: Page,
  key: "stall" | "vacancy",
  id: string,
  local: [number, number, number] = [0, 1.06, 0.07],
) {
  return page.evaluate(
    ({ key, id, local }) => {
      const probe = window as unknown as Probe;
      let root: T.Object3D | undefined;
      probe.hallScene!.traverse((object) => {
        if (object.userData[key] === id) root = object.parent!;
      });
      if (!root) return null;
      const at = root.localToWorld(
        new (root.position.constructor as typeof T.Vector3)(...local),
      );
      const world = [at.x, at.y, at.z];
      at.project(probe.hallCamera!);
      return { world, screen: [at.x, at.y, at.z] };
    },
    { key, id, local },
  );
}

async function clickScreen(page: Page, screen: number[]) {
  for (const value of screen.slice(0, 2)) {
    expect(value).toBeGreaterThan(-0.95);
    expect(value).toBeLessThan(0.95);
  }
  const box = (await page.locator("[data-hall-canvas] canvas").boundingBox())!;
  await page.mouse.click(
    box.x + ((screen[0] + 1) / 2) * box.width,
    box.y + ((1 - screen[1]) / 2) * box.height,
  );
}

test("the Halls control lists every room and enables the open ones", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  const buttons = hallsGroup(page).getByRole("button");
  await expect(buttons).toHaveText(
    Array.from({ length: 10 }, (_, i) => `Hall ${i + 1}`),
  );
  await expect(
    hallsGroup(page).getByRole("button", { pressed: true }),
  ).toHaveText(["Hall 1"]);
  await expect(hallsGroup(page).locator("button:disabled")).toHaveCount(9);
  await expect(hallButton(page, 1)).toBeEnabled();
  await expect(hallButton(page, 1)).toHaveAccessibleDescription("");
  for (let room = 2; room <= 10; room++) {
    await expect(hallButton(page, room)).toBeDisabled();
    await expect(hallButton(page, room)).toHaveAccessibleDescription(
      "Closed halls open when a class of spots is full",
    );
  }
  // The reason is also shown, as a line under the control.
  const reason = page.locator("#hall-room-closed");
  await expect(reason).toBeVisible();
  await expect(reason).toHaveText(
    "Closed halls open when a class of spots is full",
  );
  await page.getByLabel("Language / 言語").selectOption("ja");
  const japanese = hallsGroup(page, "ホールの切り替え");
  await expect(
    japanese.getByRole("button", { name: "ホール1", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await expect(
    japanese.getByRole("button", { name: "ホール2", exact: true }),
  ).toHaveAccessibleDescription(
    "閉じているホールは、同じ区分の区画がすべて埋まると開きます",
  );
  await expect(page.locator("#hall-room-closed")).toHaveText(
    "閉じているホールは、同じ区分の区画がすべて埋まると開きます",
  );
});

test("the Halls control and the bracket keys move between open rooms", async ({
  page,
  hall,
}) => {
  await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [2, 3],
      [3, 3],
    ],
    3,
  );
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await expect(hallButton(page, 1)).toHaveAttribute("aria-pressed", "true");
  await expect(hallButton(page, 4)).toBeDisabled();
  await hallButton(page, 2).click();
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await expect(hallButton(page, 2)).toHaveAttribute("aria-pressed", "true");
  await expect(hallButton(page, 1)).toHaveAttribute("aria-pressed", "false");
  await host.focus();
  await host.press("]");
  await expect(host).toHaveAttribute("data-hall-room", "3");
  await expect(hallButton(page, 3)).toHaveAttribute("aria-pressed", "true");
  await expect(hallButton(page, 2)).toHaveAttribute("aria-pressed", "false");
  await host.press("[");
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await expect(hallButton(page, 2)).toHaveAttribute("aria-pressed", "true");
});

test("the list and the picker group stalls and vacant spots by open room", async ({
  page,
  hall,
}) => {
  await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [1, 5],
      [2, 1],
      [2, 3],
      [2, 5],
      [2, 7],
    ],
    2,
    [
      [1, 0],
      [1, 9],
      [2, 10],
      [2, 11],
    ],
  );
  const picker = locationPicker(page);
  await expect(picker.locator("optgroup")).toHaveCount(2);
  await expect(picker.locator('optgroup[label="Hall 1"] option')).toHaveText([
    "Counter 1.3 · room-1-3",
    "Counter 1.5 · room-1-5",
  ]);
  await expect(picker.locator('optgroup[label="Hall 2"] option')).toHaveCount(
    4,
  );
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await expect(
    page.getByRole("heading", { level: 2, name: /^Hall \d+ ·/ }),
  ).toHaveText(["Hall 1 · 2 stalls", "Hall 2 · 4 stalls"]);
  const contents = {
    "Hall 1 · 2 stalls": {
      stalls: ["Counter 1.3", "Counter 1.5"],
      spots: ["spot-1-0", "spot-1-9"],
    },
    "Hall 2 · 4 stalls": {
      stalls: ["Counter 2.1", "Counter 2.3", "Counter 2.5", "Counter 2.7"],
      spots: ["spot-2-10", "spot-2-11"],
    },
  };
  for (const [name, { stalls, spots }] of Object.entries(contents)) {
    const room = page.getByRole("region", { name, exact: true });
    await expect(room.getByRole("heading", { level: 3 })).toHaveText([
      ...stalls,
      ...spots.map(() => "To let"),
    ]);
    await expect(room.getByRole("button", { name: "View spot" })).toHaveCount(
      spots.length,
    );
  }
  await expect(spotCard(page, "spot-1-9")).toContainText("spot-1-9 · Quiet");
  await expect(spotCard(page, "spot-1-9")).toContainText(
    "Daily open rent $19.00",
  );
  await expect(spotCard(page, "spot-2-10")).toContainText("Prime");
  for (const id of ["spot-1-0", "spot-1-9", "spot-2-10", "spot-2-11"]) {
    await spotCard(page, id).getByRole("button", { name: "View spot" }).click();
    await expect(spotCard(page, id)).toHaveAttribute("aria-current", "true");
    await expect(page.locator('[aria-current="true"]')).toHaveCount(1);
  }
  // Selecting a stall clears the viewed spot.
  await page
    .getByRole("region", { name: "Hall 1 · 2 stalls", exact: true })
    .locator("article")
    .filter({ hasText: "Counter 1.3" })
    .getByRole("button", { name: "Menu", exact: true })
    .click();
  await expect(page.locator('[aria-current="true"]')).toHaveCount(0);
});

test("clicking a to-let bay in the scene views that spot", async ({
  page,
  hall,
}) => {
  await observeScene(page);
  await routed(page, hall.origin, [[1, 0]], 1, [[1, 3]]);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect.poll(() => pointOf(page, "vacancy", "spot-1-3")).not.toBeNull();
  const bay = (await pointOf(page, "vacancy", "spot-1-3"))!;
  await clickScreen(page, bay.screen);
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await expect(spotCard(page, "spot-1-3")).toHaveAttribute(
    "aria-current",
    "true",
  );
});

test("without WebGL the grouped list offers the same spots", async ({
  page,
  hall,
}) => {
  await routed(
    page,
    hall.origin,
    [
      [1, 3],
      [1, 5],
      [2, 3],
    ],
    2,
    [[1, 9]],
  );
  await page
    .locator("[data-hall-canvas] canvas")
    .dispatchEvent("webglcontextlost", { cancelable: true });
  await expect(page.locator("[data-hall-canvas]")).toHaveCount(0);
  // One stall reads in the singular.
  await expect(
    page.getByRole("heading", { level: 2, name: /^Hall \d+ ·/ }),
  ).toHaveText(["Hall 1 · 2 stalls", "Hall 2 · 1 stall"]);
  const room = page.getByRole("region", {
    name: "Hall 1 · 2 stalls",
    exact: true,
  });
  await room.getByRole("button", { name: "View spot" }).click();
  await expect(spotCard(page, "spot-1-9")).toHaveAttribute(
    "aria-current",
    "true",
  );
});

test("returning to the hall page restores the room last viewed", async ({
  page,
  hall,
}) => {
  await routed(
    page,
    hall.origin,
    [
      [2, 3],
      [2, 5],
    ],
    2,
  );
  const host = page.locator("[data-hall-canvas]");
  // A visitor's first view is Hall 1, even when it has no stalls.
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await hallButton(page, 2).click();
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await expect(host).toHaveCount(0);
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(host.locator("canvas")).toBeVisible();
  await expect(host).toHaveAttribute("data-hall-room", "2");
  await expect(hallButton(page, 2)).toHaveAttribute("aria-pressed", "true");
});

test("an owner's first view frames the room of their first stall", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Room owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "room-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await page.getByRole("button", { name: "Business", exact: true }).click();
  const locations = (await state(page)).profile.slots;
  await locationPicker(page).selectOption(locations[0].stall_id);
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("Room counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Room counter", exact: true }),
  ).toBeVisible();
  // Serve the owner's stall from Hall 3.
  const snapshot: View = await state(page);
  const own = snapshot.profile!.restaurant!.stalls[0].id;
  const stall = snapshot.hall.stalls.find((s) => s.stall_id === own)!;
  stall.room = 3;
  stall.position = 5;
  snapshot.hall.rooms = { count: 10, open: 3 };
  snapshot.hall.vacancies = [];
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  // Owners land on their business; the reload leaves no saved camera.
  await page.reload();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  await expect(host).toHaveAttribute("data-hall-room", "3");
  await expect(hallButton(page, 3)).toHaveAttribute("aria-pressed", "true");
});

test("a wall stops a click; an open doorway does not", async ({
  page,
  hall,
}) => {
  test.setTimeout(120_000);
  await observeScene(page);
  // Hall 1 is empty, so walking starts at its centre facing north.
  await routed(
    page,
    hall.origin,
    [
      [2, 8],
      [2, 14],
    ],
    2,
  );
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await host.focus();
  // Turn on the spot until facing east, toward the wall shared with Hall 2.
  const heading = () =>
    page.evaluate(() => {
      const camera = (window as unknown as Probe).hallCamera!;
      const d = camera.getWorldDirection(
        new (camera.position.constructor as typeof T.Vector3)(),
      );
      return Math.atan2(d.z, d.x);
    });
  await host.press("ArrowRight");
  for (let step = 0; step < 120; step++) {
    const error = await heading();
    if (Math.abs(error) < 0.1) break;
    await host.press(error < 0 ? "ArrowRight" : "ArrowLeft");
  }
  expect(Math.abs(await heading())).toBeLessThan(0.1);
  const eye = await page.evaluate(() => {
    const p = (window as unknown as Probe).hallCamera!.position;
    return [p.x, p.y, p.z];
  });
  expect(eye[0]).toBeCloseTo(0, 6);
  expect(eye[1]).toBeCloseTo(1.55, 4);
  expect(eye[2]).toBeCloseTo(0, 6);
  const location = locationPicker(page);
  await expect(location).toHaveValue("");

  // Hall 2's west-wall stall is behind the wall, well clear of the doorway.
  const behind = (await pointOf(page, "stall", "room-2-14"))!;
  const crossing = (behind.world[2] * 17) / behind.world[0];
  expect(Math.abs(crossing)).toBeGreaterThan(4);
  await clickScreen(page, behind.screen);
  await page.waitForTimeout(500);
  await expect(location).toHaveValue("");
  await expect(host).toHaveAttribute("data-hall-room", "1");

  // Hall 2's east-wall stall shows through the doorway: its doorway-side edge.
  const edges = await Promise.all(
    ([-1.5, 1.5] as const).map(
      async (x) => (await pointOf(page, "stall", "room-2-8", [x, 1.06, 0.07]))!,
    ),
  );
  const through = edges.sort(
    (a, b) => Math.abs(a.world[2]) - Math.abs(b.world[2]),
  )[0];
  expect(Math.abs((through.world[2] * 17.2) / through.world[0])).toBeLessThan(
    1.9,
  );
  await clickScreen(page, through.screen);
  await expect(location).toHaveValue("room-2-8");
  await expect(host).toHaveAttribute("data-hall-room", "2");
});

test("a personal tray in a room that is not drawn cannot be taken", async ({
  page,
  hall,
}) => {
  test.setTimeout(120_000);
  await observeScene(page);
  await page.goto(hall.origin);
  await createGuest(page, "Far diner");
  const snapshot = await routed(
    page,
    hall.origin,
    [
      [2, 3],
      [3, 3],
      [4, 3],
    ],
    4,
    [],
    false,
  );
  // A served private tray waits at Hall 4's counter.
  snapshot.profile!.visit = {
    id: "far-visit",
    stall: "room-4-3",
    tray_status: "served",
    stage: "served",
    dessert: "none",
  };
  snapshot.hall.access = "open";
  await nextPoll(page);
  const host = page.locator("[data-hall-canvas]");
  await hallButton(page, 2).click();
  await expect(host).toHaveAttribute("data-hall-room", "2");
  // Look east from far above Hall 2's west side: Hall 4 lies ahead, undrawn,
  // and the view passes over the walls between.
  for (let turn = 0; turn < 4; turn++)
    await page
      .getByRole("button", { name: "Orbit right", exact: true })
      .click();
  for (let zoom = 0; zoom < 4; zoom++)
    await page.getByRole("button", { name: "Zoom out", exact: true }).click();
  const tray = await page.evaluate(() => {
    const probe = window as unknown as Probe;
    let item: T.Object3D | undefined;
    probe.hallScene!.traverse((object) => {
      if (object.name.startsWith("personal-pickup:")) item = object;
    });
    if (!item) return null;
    let shown = true;
    for (let at: T.Object3D | null = item; at; at = at.parent)
      shown &&= at.visible;
    const at = item.getWorldPosition(
      new (item.position.constructor as typeof T.Vector3)(),
    );
    at.y += 0.025;
    const world = [at.x, at.y, at.z];
    at.project(probe.hallCamera!);
    return { shown, world, screen: [at.x, at.y, at.z] };
  });
  expect(tray).not.toBeNull();
  expect(tray!.shown).toBe(false);
  expect(tray!.world[0]).toBeGreaterThan(roomCentre(4).x - ROOM_SIDE / 2);
  await clickScreen(page, tray!.screen);
  await page.waitForTimeout(500);
  await expect(page.getByText("Taking your tray")).toHaveCount(0);
  await expect(page.getByText("Tray taken")).toHaveCount(0);
});

/** The panel for the vacant spot being viewed. */
const spotPanel = (page: Page) =>
  page.getByRole("region", { name: "Vacant spot", exact: true });

/** A visitor admitted as an owner, with no business yet, on the hall page. */
async function seededOwner(
  page: Page,
  hall: { origin: string; secret: string },
  name: string,
) {
  await page.goto(hall.origin);
  await createGuest(page, name);
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "seed-" + principal, principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await expect(
    page.getByRole("button", { name: "Business", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
}

/** Click a to-let bay in the scene, from the reset camera. */
async function clickBay(page: Page, id: string) {
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect.poll(() => pointOf(page, "vacancy", id)).not.toBeNull();
  await clickScreen(page, (await pointOf(page, "vacancy", id))!.screen);
}

const s043Scarcity =
  "2 of 6 standard spots are taken, so rent is 20% above the usual $100.00.";

test("the setup floor plan follows open rooms and live spot availability", async ({
  page,
  hall,
}) => {
  await seededOwner(page, hall, "Floor plan owner");
  const snapshot: View = await state(page);
  const [first, second] = vacanciesAt([
    [1, 3],
    [2, 10],
  ]);
  snapshot.hall.rooms = { count: 10, open: 2 };
  snapshot.profile!.slots = [first, second];
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.getByRole("button", { name: "Business", exact: true }).click();

  const list = page.getByRole("combobox", { name: "Location", exact: true });
  await list.selectOption(second.stall_id);
  const hallTwo = page.getByRole("group", {
    name: "Stall floor plan · Hall 2",
  });
  await expect(
    hallTwo.getByRole("button", { name: "spot-2-10 · Prime" }),
  ).toHaveAttribute("aria-pressed", "true");
  await expect(list.locator("optgroup")).toHaveCount(2);
  const rooms = page.getByRole("navigation", { name: "Halls", exact: true });
  await expect(rooms.getByRole("button")).toHaveCount(2);

  await rooms.getByRole("button", { name: "Hall 1" }).click();
  await expect(list).toHaveValue(second.stall_id);
  await expect(
    page
      .getByRole("group", { name: "Stall floor plan · Hall 1" })
      .getByRole("button", { name: "spot-1-3 · Standard" }),
  ).toBeVisible();

  snapshot.profile!.slots = [first];
  await expect(
    list.locator("option", { hasText: second.stall_id }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Reserve stall for ten minutes" }),
  ).toBeDisabled();
  await rooms.getByRole("button", { name: "Hall 2" }).click();
  await expect(hallTwo.getByRole("button")).toHaveCount(0);
});

test("leasing from a to-let bay", async ({ page, hall }) => {
  await observeScene(page);
  await seededOwner(page, hall, "Bay owner");
  const s043 = (await state(page)).hall.vacancies.find(
    (spot: Vacancy) => spot.stall_id === "s043",
  );
  expect(s043).toMatchObject({
    tier: "standard",
    rent: "12000",
    base_rent: "10000",
    class_leased: 2,
    class_total: 6,
  });
  await clickBay(page, "s043");
  const panel = spotPanel(page);
  await expect(panel).toContainText("s043");
  await expect(panel).toContainText("Standard");
  await expect(panel.locator(".spot-rent")).toHaveText(
    "Daily open rent $120.00",
  );
  await expect(panel.locator(".rent-explanation")).toHaveText(s043Scarcity);
  await expect(panel).toContainText(`Daily holding fee ${cash(s043.holding)}`);
  await expect(panel).toContainText(`Setup fee ${cash(s043.setup_fee)}`);

  // The first answer is lost; the form's own retry resends the same command.
  const commands: { kind: string; command_id: string }[] = [];
  await page.route("**/api/commands", async (route) => {
    const command = route.request().postDataJSON();
    commands.push(command);
    if (command.kind !== "reserve_stall") return route.continue();
    const result = await route.fetch();
    if (commands.filter((c) => c.kind === "reserve_stall").length === 1)
      await route.fulfill({ status: 503, json: { error: "unknown_outcome" } });
    else await route.fulfill({ response: result });
  });
  await panel.getByRole("button", { name: "Reserve this spot" }).click();
  await expect(
    page.getByRole("heading", { name: "Set up your first stall" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Retry same command" }).click();
  await expect(page.getByLabel("Restaurant name")).toBeVisible();
  const draft = (await state(page)).profile.draft;
  expect(draft).toMatchObject({ stall_id: "s043", rent: "12000" });
  const form = page.locator("form").filter({ hasText: "s043" });
  await expect(form).toContainText("Daily open rent $120.00");
  await expect(form.locator(".rent-explanation")).toHaveText(
    `Held at this rent until ${clock(draft.expires_at)}.`,
  );
  const reserves = commands.filter((c) => c.kind === "reserve_stall");
  expect(reserves).toHaveLength(2);
  expect(new Set(reserves.map((c) => c.command_id)).size).toBe(1);
  // Nothing else was submitted: presence reports are the owner's heartbeat.
  expect(
    commands
      .map((c) => c.kind)
      .filter((kind) => kind !== "report_owner_presence"),
  ).toEqual(["reserve_stall", "reserve_stall"]);
});

test("the lease list and the bay agree", async ({ page, hall }) => {
  await page.goto(hall.origin);
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  const vacancies: Vacancy[] = (await state(page)).hall.vacancies;
  expect(vacancies).toHaveLength(12);
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  const panel = spotPanel(page);
  for (const spot of vacancies) {
    const card = spotCard(page, spot.stall_id);
    const view = card.getByRole("button", {
      name: "View spot " + spot.stall_id,
      exact: true,
    });
    await expect(view).toHaveText("View spot");
    await view.click();
    await expect(panel).toContainText(spot.stall_id);
    const rent = `Daily open rent ${cash(spot.rent)}`;
    await expect(card.locator(".spot-rent")).toHaveText(rent);
    await expect(panel.locator(".spot-rent")).toHaveText(rent);
    const line = await card.locator(".rent-explanation").innerText();
    expect(line).toMatch(/^(The usual rent|\d+ of \d+ )/);
    await expect(panel.locator(".rent-explanation")).toHaveText(line);
  }
  await panel.getByRole("button", { name: "Close spot details" }).click();
  await expect(panel).toHaveCount(0);
  await expect(page.locator('[aria-current="true"]')).toHaveCount(0);
});

test("a visitor sees the bay but cannot reserve it", async ({ page, hall }) => {
  await observeScene(page);
  await page.goto(hall.origin);
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  await clickBay(page, "s043");
  const panel = spotPanel(page);
  await expect(panel).toContainText("Standard");
  await expect(panel.locator(".spot-rent")).toHaveText(
    "Daily open rent $120.00",
  );
  await expect(panel.locator(".rent-explanation")).toHaveText(s043Scarcity);
  await expect(panel).toContainText(
    "You can look around now. Create a profile when you’re ready to eat or work.",
  );
  await expect(panel.getByRole("button")).toHaveText(["Close spot details"]);
});

test("the expansion estimate explains its rent", async ({ page, hall }) => {
  await seededOwner(page, hall, "Second spot");
  await page.getByRole("button", { name: "Business", exact: true }).click();
  await locationPicker(page).selectOption("s043");
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("First counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "First counter", exact: true }),
  ).toBeVisible();

  const current: View = await state(page);
  const slot = current.profile!.slots.find((s) => s.stall_id === "s044")!;
  expect(slot).toMatchObject({ tier: "standard", class_leased: 3 });
  expect(BigInt(slot.rent)).toBeGreaterThan(BigInt(slot.base_rent!));
  const percent =
    ((BigInt(slot.rent) - BigInt(slot.base_rent!)) * 100n) /
    BigInt(slot.base_rent!);
  const line = `3 of 6 standard spots are taken, so rent is ${percent}% above the usual ${cash(slot.base_rent!)}.`;

  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await spotCard(page, "s044")
    .getByRole("button", { name: "View spot s044", exact: true })
    .click();
  await expect(spotPanel(page).locator(".rent-explanation")).toHaveText(line);
  await spotPanel(page)
    .getByRole("button", { name: "Lease this spot" })
    .click();

  const form = page.locator("form").filter({ hasText: "s044" });
  await expect(form).toBeVisible();
  await expect(form.getByRole("combobox", { name: "Location" })).toHaveValue(
    "s044",
  );
  await form.getByRole("radio", { name: "Levantine", exact: true }).check();
  const estimate = form.locator(".lease-estimate");
  await expect(estimate.locator(".rent-explanation")).toHaveText(line);
  const forecast = current.hall.lease_forecast!;
  const open = BigInt(forecast.trading_hours);
  const overhead =
    (BigInt(slot.rent) * open + BigInt(slot.holding) * (24n - open)) / 24n +
    BigInt(forecast.wages);
  const margin = BigInt(forecast.starter_margins.levantine);
  expect(margin).toBeGreaterThan(0n);
  await expect(estimate).toContainText(
    `Estimated daily rent and wages ${cash(overhead.toString())}`,
  );
  await expect(estimate).toContainText(
    `Estimated break-even at starter prices: ${(overhead + margin - 1n) / margin} meals per game day.`,
  );
});

test("an expansion sends the rent it showed and keeps the form open when it changed", async ({
  page,
  hall,
}) => {
  await seededOwner(page, hall, "Expected rent");
  await page.getByRole("button", { name: "Business", exact: true }).click();
  await locationPicker(page).selectOption("s043");
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("First counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "First counter", exact: true }),
  ).toBeVisible();

  const slot = (await state(page)).profile!.slots.find(
    (s: { stall_id: string }) => s.stall_id === "s044",
  )!;
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await spotCard(page, "s044")
    .getByRole("button", { name: "View spot s044", exact: true })
    .click();
  await spotPanel(page)
    .getByRole("button", { name: "Lease this spot" })
    .click();
  const form = page.locator("form").filter({ hasText: "s044" });
  const expansion = page.locator("details").filter({ has: form });
  const picker = form.getByRole("combobox", { name: "Location" });
  await expect(picker).toHaveValue("s044");
  await expect(form).toContainText(`Daily open rent ${cash(slot.rent)}`);
  await form.getByRole("radio", { name: "Levantine", exact: true }).check();

  const leases: Record<string, unknown>[] = [];
  await page.route("**/api/commands", async (route) => {
    const command = route.request().postDataJSON();
    if (command.kind !== "lease_location") return route.continue();
    leases.push(command.payload);
    await route.fulfill({ json: { accepted: false, reason: "quote_changed" } });
  });
  await form.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByText(
      "The rent for that spot has changed. Check the new rent and confirm again.",
    ),
  ).toBeVisible();
  expect(leases).toEqual([
    {
      restaurant_id: expect.any(String),
      stall_id: "s044",
      cuisine: "levantine",
      expected_rent: slot.rent,
    },
  ]);
  await expect(expansion).toHaveAttribute("open", "");
  await expect(form).toContainText(`Daily open rent ${cash(slot.rent)}`);
  await expect(picker).toHaveValue("s044");
  // Nothing was resubmitted.
  await page.waitForTimeout(500);
  expect(leases).toHaveLength(1);
});

test("Japanese shows the same numbers", async ({ page, hall }) => {
  await page.goto(hall.origin);
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await spotCard(page, "s043")
    .getByRole("button", { name: "View spot s043", exact: true })
    .click();
  await page.getByLabel("Language / 言語").selectOption("ja");
  const panel = page.getByRole("region", { name: "空き区画", exact: true });
  await expect(panel).toContainText("標準");
  await expect(panel.locator(".spot-rent")).toHaveText(
    "営業時の日額賃料 $120.00",
  );
  await expect(panel.locator(".rent-explanation")).toHaveText(
    "標準区画は6区画中2区画が埋まっているため、賃料は通常の$100.00より20%高くなっています。",
  );
  await expect(
    spotCard(page, "s043").getByRole("button", {
      name: "区画s043を見る",
      exact: true,
    }),
  ).toHaveText("区画を見る");
});

test("a spot taken while the panel is open", async ({ page, hall }) => {
  const snapshot = await routed(page, hall.origin, [[1, 0]], 1, [[1, 3]]);
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await spotCard(page, "spot-1-3")
    .getByRole("button", { name: "View spot spot-1-3", exact: true })
    .click();
  const panel = spotPanel(page);
  await expect(panel.locator(".spot-rent")).toHaveText(
    "Daily open rent $13.00",
  );
  snapshot.hall.vacancies = [];
  await nextPoll(page);
  await expect(panel).toContainText("spot-1-3");
  await expect(panel).toContainText(
    "This stall can’t be reserved or leased right now. Check your current reservation or choose another stall.",
  );
  await expect(panel.locator(".spot-rent")).toHaveCount(0);
  await expect(panel.getByRole("button")).toHaveText(["Close spot details"]);
  await panel.getByRole("button", { name: "Close spot details" }).click();
  await expect(panel).toHaveCount(0);
});

test("a spot the viewer reserves is not reported as taken", async ({
  page,
  hall,
}) => {
  await seededOwner(page, hall, "Own reservation");
  await page.getByRole("button", { name: "Stall list", exact: true }).click();
  await spotCard(page, "s043")
    .getByRole("button", { name: "View spot s043", exact: true })
    .click();
  const panel = spotPanel(page);
  await expect(panel).toContainText("s043");

  // Reserve the viewed spot elsewhere while its panel is still open.
  await page.getByRole("button", { name: "Business", exact: true }).click();
  await locationPicker(page).selectOption("s043");
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await expect(page.getByLabel("Restaurant name")).toBeVisible();
  expect((await state(page)).profile.draft).toMatchObject({
    stall_id: "s043",
  });
  await nextPoll(page);

  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(spotCard(page, "s044")).toBeVisible();
  await expect(panel).toHaveCount(0);
  await expect(
    page.getByText(
      "This stall can’t be reserved or leased right now. Check your current reservation or choose another stall.",
    ),
  ).toHaveCount(0);
});

test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true });

  test("viewing a spot opens it as the detail view", async ({ page, hall }) => {
    await page.goto(hall.origin);
    await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
    await page.getByRole("button", { name: "Stall list", exact: true }).click();
    await spotCard(page, "s043")
      .getByRole("button", { name: "View spot s043", exact: true })
      .click();
    await expect(
      page.getByRole("heading", { level: 1, name: "Vacant spot" }),
    ).toBeVisible();
    const panel = spotPanel(page);
    await expect(panel.locator(".rent-explanation")).toHaveText(s043Scarcity);
    await expect(panel.locator(".rent-explanation")).toBeVisible();
    await expect(spotCard(page, "s043")).toBeHidden();
    await page.getByRole("button", { name: "Back to hall" }).click();
    await expect(spotCard(page, "s043")).toBeVisible();
  });
});
