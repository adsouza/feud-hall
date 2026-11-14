import type { Locator, Page } from "@playwright/test";
import type { View } from "../../src/api";
import { CLEAR_MS, EAT_MS } from "../../src/diner-floor";
import { createGuest, expect, state, test } from "./hall";

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

/** One clock step: the page polls every 850 ms, so each step polls once. */
const STEP = 1000;

type Snapshot = {
  waiting: number;
  service: string;
  today?: { arrivals: number; admitted: number; left: number };
  queueLimit?: number;
  access?: string;
};

/**
 * An owner with one open stall in Hall 1. The page's clock is installed before
 * it loads, so the poll and the scene's frames run on the test's time once
 * paused; until then time flows as usual.
 */
async function ownStall(page: Page, hall: { origin: string; secret: string }) {
  await page.clock.install();
  await page.goto(hall.origin);
  await createGuest(page, "Floor owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "floor-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await page.getByRole("button", { name: "Business", exact: true }).click();
  const locations = (await state(page)).profile.slots;
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(locations[0].stall_id);
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("Floor counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Floor counter", exact: true }),
  ).toBeVisible();
  const base: View = await state(page);
  const stall = base.profile!.restaurant!.stalls[0].id;
  // Every count below is for Hall 1, the only open room, where the stall is.
  expect(base.hall.rooms?.open).toBe(1);
  expect(base.hall.stalls.find((s) => s.stall_id === stall)?.room).toBe(1);

  let current = base;
  let served = 0;
  let views = 0;
  let paused = false;
  await page.route("**/api/state**", (route) => {
    served++;
    return route.fulfill({ json: current });
  });
  /** Serves a copy of the captured view: only the owned stall is open and busy. */
  async function serve(snapshot: Snapshot) {
    const view: View = structuredClone(base);
    // Each call is a new server view: its position rises, as a real server's
    // does when events commit. The scene re-applies no counts from a view
    // whose position it has already seen.
    view.hall.position = base.hall.position + ++views;
    view.hall.access = snapshot.access ?? "open";
    view.hall.today = snapshot.today;
    if (snapshot.queueLimit === undefined) delete view.hall.queue_limit;
    else view.hall.queue_limit = snapshot.queueLimit;
    for (const s of view.hall.stalls) {
      const mine = s.stall_id === stall;
      s["open?"] = mine;
      s.last_service = mine ? snapshot.service : null;
      s.activity = {
        waiting: mine ? snapshot.waiting : 0,
        cooking: 0,
        handover: false,
        staffed: mine,
        workers: mine ? 2 : 0,
        staging: false,
        paused: false,
      };
    }
    current = view;
    // While the clock runs, let a poll fetch it before the caller goes on;
    // once paused, the caller's next step polls.
    if (paused) return;
    const after = served;
    await expect.poll(() => served).toBeGreaterThan(after + 1);
  }
  /** Stops the page's clock: from here on time moves only by `step`. */
  async function pause() {
    const now = await page.evaluate(() => Date.now());
    await page.clock.pauseAt(now + 500);
    await page.waitForTimeout(300); // let the poll that pausing fired finish
    paused = true;
  }
  return { stall, serve, pause };
}

async function openHall(page: Page) {
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  return host;
}

async function step(page: Page) {
  await page.clock.fastForward(STEP);
  await page.waitForTimeout(40); // the poll's response arrives in real time
}

/** A drawn count from the scene host; null while the scene does not report it. */
async function drawn(host: Locator, name: "walking" | "seated" | "people") {
  const value = await host.getAttribute("data-hall-" + name);
  return value === null ? null : Number(value);
}

/**
 * Steps the clock until `done` holds, at most `limit` ms of clock time; returns
 * the clock time taken, or Infinity. `each` runs after every step.
 */
async function stepUntil(
  page: Page,
  done: () => Promise<boolean>,
  limit: number,
  each?: () => Promise<void>,
) {
  for (let elapsed = STEP; elapsed <= limit; elapsed += STEP) {
    await step(page);
    await each?.();
    if (await done()) return elapsed;
  }
  return Infinity;
}

test("visible diners: a served diner sits, eats and leaves", async ({
  page,
  hall,
}) => {
  test.setTimeout(300_000);
  const { serve, pause } = await ownStall(page, hall);
  const today = { arrivals: 1, admitted: 1, left: 0 };
  await serve({ waiting: 1, service: "order-a", today });
  const host = await openHall(page);
  await expect.poll(() => drawn(host, "walking")).toBe(0);
  await expect.poll(() => drawn(host, "seated")).toBe(0);
  await pause();

  await serve({ waiting: 0, service: "order-b", today });
  const sat = await stepUntil(
    page,
    async () => (await drawn(host, "seated")) === 1,
    30_000,
  );
  expect(sat).toBeLessThanOrEqual(30_000);
  // Still at the table 50 s after sitting down.
  for (let elapsed = 0; elapsed < 50_000; elapsed += STEP) {
    await step(page);
    expect(await drawn(host, "seated")).toBe(1);
  }
  const left = await stepUntil(
    page,
    async () => (await drawn(host, "seated")) === 0,
    EAT_MS + 30_000 - sat - 50_000,
  );
  expect(left).toBeLessThan(Infinity);
  const out = await stepUntil(
    page,
    async () => (await drawn(host, "walking")) === 0,
    40_000,
  );
  expect(out).toBeLessThan(Infinity);
});

test("visible diners: a diner who leaves without buying is shown leaving", async ({
  page,
  hall,
}) => {
  test.setTimeout(240_000);
  const { serve, pause } = await ownStall(page, hall);
  await serve({
    waiting: 1,
    service: "order-a",
    today: { arrivals: 5, admitted: 4, left: 0 },
  });
  const host = await openHall(page);
  await expect.poll(() => drawn(host, "walking")).toBe(0);
  await pause();
  const before = await drawn(host, "people");
  expect(before).toBeGreaterThan(0);

  await serve({
    waiting: 1,
    service: "order-a",
    today: { arrivals: 6, admitted: 4, left: 0 },
  });
  const entered = await stepUntil(
    page,
    async () => (await drawn(host, "walking")) === 1,
    10_000,
  );
  expect(entered).toBeLessThan(Infinity);
  expect(await drawn(host, "people")).toBe(before! + 1);
  const gone = await stepUntil(
    page,
    async () => (await drawn(host, "walking")) === 0,
    120_000,
  );
  expect(gone).toBeLessThan(Infinity);
  expect(await drawn(host, "people")).toBe(before);
});

test("visible diners: at the room overview a joiner stays drawn in the queue", async ({
  page,
  hall,
}) => {
  test.setTimeout(240_000);
  const { serve, pause } = await ownStall(page, hall);
  await serve({
    waiting: 1,
    service: "order-a",
    today: { arrivals: 1, admitted: 1, left: 0 },
  });
  const host = await openHall(page);
  // No stall is selected, and from the room overview every stall is beyond
  // the detail distance, so the owned stall is drawn simply.
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-room", "1");
  await expect.poll(() => drawn(host, "walking")).toBe(0);
  // 1 owner + 1 worker (reduced detail) + 1 queued diner.
  await expect.poll(() => drawn(host, "people")).toBe(3);
  await pause();
  const before = await drawn(host, "people");

  await serve({
    waiting: 2,
    service: "order-a",
    today: { arrivals: 2, admitted: 2, left: 0 },
  });
  const entered = await stepUntil(
    page,
    async () => (await drawn(host, "walking")) === 1,
    10_000,
  );
  expect(entered).toBeLessThan(Infinity);
  const arrived = await stepUntil(
    page,
    async () => (await drawn(host, "walking")) === 0,
    60_000,
  );
  expect(arrived).toBeLessThan(Infinity);
  // The joiner stands at the second queue spot, still drawn.
  expect(await drawn(host, "people")).toBe(before! + 1);
  expect(await drawn(host, "walking")).toBe(0);
});

test("visible diners: the floor is empty during cleaning", async ({
  page,
  hall,
}) => {
  test.setTimeout(240_000);
  const { serve, pause } = await ownStall(page, hall);
  await serve({
    waiting: 3,
    service: "order-a",
    today: { arrivals: 3, admitted: 3, left: 0 },
  });
  const host = await openHall(page);
  await expect.poll(() => drawn(host, "walking")).toBe(0);
  await pause();
  await serve({
    waiting: 2,
    service: "order-b",
    today: { arrivals: 3, admitted: 3, left: 0 },
  });
  const sat = await stepUntil(
    page,
    async () => (await drawn(host, "seated")) === 1,
    30_000,
  );
  expect(sat).toBeLessThanOrEqual(30_000);

  // The server's access value while the hall is being cleaned.
  await serve({
    waiting: 0,
    service: "order-b",
    today: { arrivals: 3, admitted: 3, left: 0 },
    access: "cleaning",
  });
  const cleared = await stepUntil(
    page,
    async () =>
      (await drawn(host, "seated")) === 0 &&
      (await drawn(host, "walking")) === 0,
    CLEAR_MS + 2_000,
  );
  expect(cleared).toBeLessThanOrEqual(CLEAR_MS + 2_000);
});

test("visible diners: the queue is drawn to the server's queue limit", async ({
  page,
  hall,
}) => {
  const { stall, serve } = await ownStall(page, hall);
  const today = { arrivals: 6, admitted: 6, left: 0 };
  // An older server sends no limit: four are drawn, as before.
  await serve({ waiting: 6, service: "order-a", today });
  const host = await openHall(page);
  // Focusing the stall draws it in full: 1 owner + 2 workers + the queue.
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(stall);
  await expect.poll(() => drawn(host, "people")).toBe(3 + 4);
  await serve({ waiting: 6, service: "order-a", today, queueLimit: 6 });
  await expect.poll(() => drawn(host, "people")).toBe(3 + 6);
  expect(await drawn(host, "walking")).toBe(0);
});

test("visible diners: reduced motion shows no walking", async ({
  page,
  hall,
}) => {
  test.setTimeout(240_000);
  await page.emulateMedia({ reducedMotion: "reduce" });
  const { serve, pause } = await ownStall(page, hall);
  const today = { arrivals: 1, admitted: 1, left: 0 };
  await serve({ waiting: 1, service: "order-a", today });
  const host = await openHall(page);
  await expect.poll(() => drawn(host, "walking")).toBe(0);
  await pause();

  await serve({ waiting: 0, service: "order-b", today });
  const walking = async () => {
    expect(await drawn(host, "walking")).toBe(0);
  };
  const sat = await stepUntil(
    page,
    async () => (await drawn(host, "seated")) === 1,
    10_000,
    walking,
  );
  expect(sat).toBeLessThan(Infinity);
  // Eating, and leaving after the meal, are never drawn as walking either.
  const left = await stepUntil(
    page,
    async () => (await drawn(host, "seated")) === 0,
    EAT_MS + 10_000,
    walking,
  );
  expect(left).toBeLessThan(Infinity);
});
