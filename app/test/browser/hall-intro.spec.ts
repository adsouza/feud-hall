import type { Page, Route } from "@playwright/test";
import { expect, test } from "./hall";

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

const starting = "Waiting for the hall to respond.";
const intro = (page: Page) => page.locator("[data-hall-intro]");
// The positioned container exists from the moment the intro starts, before
// its module has loaded; while it is absent the intro has not started.
const stage = (page: Page) => page.locator("[data-intro-stage]");
const hallHeading = (page: Page) =>
  page.getByRole("heading", { name: "Hall", exact: true });

type Answer = (route: Route) => Promise<void>;

/**
 * Opens the hall with the page's clock installed and paused before it loads,
 * so the page's timers and frames run only on `page.clock.runFor`. Every
 * `/api/state` request waits until `release`, then gets `answer` (the real
 * hall's reply by default).
 */
async function openHeld(page: Page, origin: string) {
  await installPausedClock(page);
  const held = await holdState(page);
  await page.goto(origin);
  return held;
}

async function installPausedClock(page: Page) {
  const start = Date.now();
  await page.clock.install({ time: start });
  await page.clock.pauseAt(start + 1000);
}

async function holdState(page: Page) {
  let answer: Answer = (route) => route.fallback();
  let open = () => {};
  const gate = new Promise<void>((resolve) => (open = resolve));
  await page.route("**/api/state**", async (route) => {
    await gate;
    await answer(route);
  });
  return {
    release(next?: Answer) {
      if (next) answer = next;
      open();
    },
  };
}

async function startIntro(page: Page) {
  await page.clock.runFor(1501);
  await expect(intro(page)).toBeVisible();
}

test("intro: an answer just before the threshold never mounts it", async ({
  page,
  hall,
}) => {
  const held = await openHeld(page, hall.origin);
  await page.clock.runFor(1400);
  held.release();
  await expect(hallHeading(page)).toBeVisible();
  await page.clock.runFor(3000);
  await expect(stage(page)).toHaveCount(0);
  await expect(intro(page)).toHaveCount(0);
});

test("intro: a slow first load plays it after 1.5 s", async ({
  page,
  hall,
}) => {
  await openHeld(page, hall.origin);
  await expect(page.getByText("Opening the hall…")).toBeVisible();
  await page.clock.runFor(1499);
  await expect(stage(page)).toHaveCount(0);
  await expect(intro(page)).toHaveCount(0);
  await page.clock.runFor(2);
  await expect(intro(page)).toBeVisible();
  await expect(intro(page)).toHaveAttribute("data-intro-beat", "outside");
});

test("intro: the waiting status stays visible during it", async ({
  page,
  hall,
}) => {
  await openHeld(page, hall.origin);
  await startIntro(page);
  const status = page.getByRole("status").filter({ hasText: starting });
  await expect(status).toBeVisible();
  // Drawn above the intro, not merely present beneath it.
  const onTop = await status.evaluate((element) => {
    const box = element.getBoundingClientRect();
    const hit = document.elementFromPoint(
      box.left + box.width / 2,
      box.top + box.height / 2,
    );
    return !!hit && element.contains(hit);
  });
  expect(onTop).toBe(true);
});

test("intro: the answer shows the page at once and dissolves it", async ({
  page,
  hall,
}) => {
  const held = await openHeld(page, hall.origin);
  await startIntro(page);
  held.release();
  await expect(hallHeading(page)).toBeVisible();
  // The clock has not moved: the intro is still dissolving over the page, and
  // the page's hall controls already take clicks.
  await expect(intro(page)).toHaveCount(1);
  const list = page.getByRole("button", { name: "Stall list", exact: true });
  await expect(list).toHaveAttribute("aria-pressed", "false");
  // Click where the intro covers the control, without the scrolling that a
  // locator click may use to move it out from under the intro.
  const button = (await list.boundingBox())!;
  const cover = (await intro(page).boundingBox())!;
  const x = button.x + button.width / 2;
  const y = button.y + button.height / 2;
  expect(x > cover.x && x < cover.x + cover.width).toBe(true);
  expect(y > cover.y && y < cover.y + cover.height).toBe(true);
  await page.mouse.click(x, y);
  await expect(list).toHaveAttribute("aria-pressed", "true");
  await expect(intro(page)).toHaveCount(1);
  await page.clock.runFor(600);
  await expect(intro(page)).toHaveCount(0);
  await expect(stage(page)).toHaveCount(0);
});

test("intro: a skip jumps to the hold", async ({ page, hall }) => {
  await openHeld(page, hall.origin);
  await startIntro(page);
  await expect(intro(page)).toHaveAttribute("data-intro-beat", "outside");
  await page.keyboard.press("Space");
  await expect(intro(page)).toHaveAttribute("data-intro-beat", "hold");
});

test("intro: quick 503 answers still play it", async ({ page, hall }) => {
  await installPausedClock(page);
  await page.route("**/api/state**", (route) =>
    route.fulfill({ status: 503, json: { error: "unavailable" } }),
  );
  await page.goto(hall.origin);
  await expect(
    page.getByRole("status").filter({ hasText: starting }),
  ).toBeVisible();
  await page.clock.runFor(1600);
  await expect(intro(page)).toBeVisible();
});

test("intro: an update-required answer ends it", async ({ page, hall }) => {
  const held = await openHeld(page, hall.origin);
  await startIntro(page);
  held.release((route) =>
    route.fulfill({ status: 426, json: { error: "client_update_required" } }),
  );
  const notice = page
    .getByRole("status")
    .filter({ hasText: "This page is out of date. Reload to continue." });
  await expect(notice).toBeVisible();
  await page.clock.runFor(600);
  await expect(intro(page)).toHaveCount(0);
  await expect(stage(page)).toHaveCount(0);
  await expect(notice.getByRole("button", { name: "Reload" })).toBeVisible();
});

test("intro: switching language updates caption and hint", async ({
  page,
  hall,
}) => {
  await openHeld(page, hall.origin);
  await startIntro(page);
  await expect(intro(page)).toContainText("Click or press any key to skip");
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(intro(page)).toContainText(
    "クリックするか、いずれかのキーを押すとスキップします",
  );
  await expect(
    page
      .getByRole("status")
      .filter({ hasText: "ホールの応答を待っています。" }),
  ).toBeVisible();
  await expect(page.getByText(starting)).toHaveCount(0);
});

test("intro: reduced motion or no WebGL keeps the text screen", async ({
  page,
  hall,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openHeld(page, hall.origin);
  await page.clock.runFor(2000);
  await expect(page.getByText("Opening the hall…")).toBeVisible();
  await expect(stage(page)).toHaveCount(0);
  await expect(intro(page)).toHaveCount(0);

  // Motion allowed, but no WebGL context of any kind; 2D canvases still work.
  // Record whether the intro's container ever appears: "never mounts" must be
  // told apart from "mounts, then fails".
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.addInitScript(() => {
    (window as unknown as { introSeen: boolean }).introSeen = false;
    new MutationObserver(() => {
      if (document.querySelector("[data-intro-stage], [data-hall-intro]"))
        (window as unknown as { introSeen: boolean }).introSeen = true;
    }).observe(document, { childList: true, subtree: true });
    const getContext = HTMLCanvasElement.prototype.getContext;
    const webgl = ["webgl", "webgl2", "experimental-webgl"];
    HTMLCanvasElement.prototype.getContext = function (
      this: HTMLCanvasElement,
      kind: string,
      ...rest: unknown[]
    ) {
      if (webgl.includes(kind)) return null;
      return (getContext as (...args: unknown[]) => unknown).call(
        this,
        kind,
        ...rest,
      );
    } as typeof getContext;
  });
  await page.reload();
  expect(
    await page.evaluate(() => [
      !!document.createElement("canvas").getContext("2d"),
      !!document.createElement("canvas").getContext("webgl2"),
    ]),
  ).toEqual([true, false]);
  await page.clock.runFor(2000);
  await expect(page.getByText("Opening the hall…")).toBeVisible();
  await expect(stage(page)).toHaveCount(0);
  await expect(intro(page)).toHaveCount(0);
  expect(
    await page.evaluate(
      () => (window as unknown as { introSeen: boolean }).introSeen,
    ),
  ).toBe(false);
});

test("intro: losing WebGL returns to the text screen for good", async ({
  page,
  hall,
}) => {
  await openHeld(page, hall.origin);
  await startIntro(page);
  const lost = await page.evaluate(() => {
    const canvas = document.querySelector("[data-hall-intro] canvas");
    const gl = (canvas as HTMLCanvasElement | null)?.getContext("webgl2");
    const extension = gl?.getExtension("WEBGL_lose_context");
    extension?.loseContext();
    return !!extension;
  });
  expect(lost).toBe(true);
  await page.clock.runFor(100);
  await expect(intro(page)).toHaveCount(0);
  await expect(stage(page)).toHaveCount(0);
  await expect(page.getByText("Opening the hall…")).toBeVisible();
  await page.clock.runFor(3000);
  await expect(intro(page)).toHaveCount(0);
  await expect(stage(page)).toHaveCount(0);
  await expect(page.getByText("Opening the hall…")).toBeVisible();
});

test("intro: a second slow load plays it again", async ({ page, hall }) => {
  const first = await openHeld(page, hall.origin);
  await startIntro(page);
  await expect(intro(page)).toHaveAttribute("data-intro-beat", "outside");
  first.release();
  await expect(hallHeading(page)).toBeVisible();
  await page.clock.runFor(600);
  await expect(intro(page)).toHaveCount(0);

  await page.unroute("**/api/state**");
  await holdState(page);
  await page.reload();
  await expect(page.getByText("Opening the hall…")).toBeVisible();
  await startIntro(page);
  await expect(intro(page)).toHaveAttribute("data-intro-beat", "outside");
});
