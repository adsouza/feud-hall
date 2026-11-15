import type { Page, Request, Route } from "@playwright/test";
import { createGuest, expect, serveNewerClient, test } from "./hall";

test("web requests send the client protocol and a refused protocol asks for a reload", async ({
  page,
  hall,
}) => {
  const first = page.waitForRequest(
    (request) => new URL(request.url()).pathname === "/api/state",
  );
  await page.goto(hall.origin);
  expect((await first).headers()["x-feud-protocol"]).toBe("1");

  await page.route("**/api/state**", (route) =>
    route.fulfill({ status: 426, json: { error: "client_update_required" } }),
  );
  const notice = page
    .getByRole("status")
    .filter({ hasText: "This page is out of date. Reload to continue." });
  await expect(notice).toBeVisible();
  await expect(notice.getByRole("button", { name: "Reload" })).toBeVisible();
  await expect(
    page.getByText("This desktop app and hall use different versions."),
  ).toHaveCount(0);
});

const newVersion = "A new version of Feud Hall is available.";

// Counts the tab's fetches of the page at "/", sent and answered.
function servedPages(page: Page) {
  const fetches = { sent: 0, answered: 0 };
  const served = (request: Request) =>
    request.resourceType() === "fetch" &&
    new URL(request.url()).pathname === "/";
  page.on("request", (request) => {
    if (served(request)) fetches.sent += 1;
  });
  const answered = (request: Request) => {
    if (served(request)) fetches.answered += 1;
  };
  page.on("requestfinished", answered);
  page.on("requestfailed", answered);
  return fetches;
}

async function openHall(page: Page, origin: string) {
  const connected = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === "/api/state" && response.ok(),
  );
  await page.goto(origin);
  await connected;
}

const becomeVisible = (page: Page) =>
  page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));

test("an open tab offers a reload once the hall serves a newer client", async ({
  page,
  hall,
}) => {
  await openHall(page, hall.origin);
  const fetches = servedPages(page);
  await serveNewerClient(page, hall.origin);

  await becomeVisible(page);
  const notice = page.getByRole("status").filter({ hasText: newVersion });
  await expect(notice).toBeVisible();
  await expect(notice.getByRole("button", { name: "Reload" })).toBeVisible();
  expect(fetches.sent).toBe(1);

  // A notice already showing needs no second look at the served page.
  const polled = page.waitForResponse(
    (response) => new URL(response.url()).pathname === "/api/state",
  );
  await becomeVisible(page);
  await polled;
  expect(fetches.sent).toBe(1);

  await page.getByLabel("Language / 言語").selectOption("ja");
  const japanese = page
    .getByRole("status")
    .filter({ hasText: "新しいバージョンのFeud Hallが利用できます。" });
  await expect(japanese).toBeVisible();
  await expect(
    japanese.getByRole("button", { name: "再読み込み" }),
  ).toBeVisible();

  await page.unroute(new URL("/", hall.origin).href);
  await Promise.all([
    page.waitForEvent("load", { timeout: 10_000 }),
    japanese.getByRole("button", { name: "再読み込み" }).click(),
  ]);
  await expect(page.getByText(newVersion)).toHaveCount(0);
  await expect(
    page.getByText("新しいバージョンのFeud Hallが利用できます。"),
  ).toHaveCount(0);
});

test("no reload is offered while the hall serves the same client or cannot serve it", async ({
  page,
  hall,
}) => {
  const errors: Error[] = [];
  page.on("pageerror", (error) => errors.push(error));
  await openHall(page, hall.origin);
  const fetches = servedPages(page);
  const notice = page.getByRole("status").filter({ hasText: newVersion });

  // The same client, a host's error page during a deploy, and a page with no
  // client at all. Each answer is late, as a trigger that arrives while a check
  // is still running is skipped.
  const home = new URL("/", hall.origin).href;
  const answers: ((route: Route) => Promise<void>)[] = [
    (route) => route.fallback(),
    (route) =>
      route.fulfill({
        status: 503,
        contentType: "text/html",
        body: '<script type="module" src="/assets/maintenance.js"></script>',
      }),
    (route) =>
      route.fulfill({
        status: 200,
        contentType: "text/plain",
        body: "Not a client page.",
      }),
  ];
  for (const [index, answer] of answers.entries()) {
    await page.route(home, async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 250));
      await answer(route);
    });
    await becomeVisible(page);
    await expect.poll(() => fetches.answered).toBe(index + 1);
    await expect(notice).toHaveCount(0);
    await page.unroute(home);
  }

  // This check runs only if none of the earlier ones raised the notice.
  await serveNewerClient(page, hall.origin);
  await becomeVisible(page);
  await expect(notice).toBeVisible();
  expect(fetches.sent).toBe(4);
  expect(errors).toEqual([]);
});

test("a reload is not offered over a command whose outcome is uncertain", async ({
  page,
  hall,
}) => {
  await openHall(page, hall.origin);
  await createGuest(page, "Uncertain diner");
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await page.route(
    "**/api/commands",
    (route) =>
      route.fulfill({ status: 503, json: { error: "unknown_outcome" } }),
    { times: 1 },
  );
  await page
    .getByRole("button", { name: "Claim daily allowance", exact: true })
    .click();
  const retry = page.getByRole("button", { name: "Retry same command" });
  await expect(retry).toBeVisible();

  await serveNewerClient(page, hall.origin);
  await becomeVisible(page);
  const notice = page.getByRole("status").filter({ hasText: newVersion });
  await expect(notice).toBeVisible();
  const reload = notice.getByRole("button", { name: "Reload" });
  await expect(reload).toBeDisabled();

  await retry.click();
  await expect(retry).toHaveCount(0);
  await expect(reload).toBeEnabled();
});

test("a tab checks for a newer client when its connection returns", async ({
  page,
  hall,
}) => {
  await openHall(page, hall.origin);
  const fetches = servedPages(page);
  await serveNewerClient(page, hall.origin);
  await page.route("**/api/state**", (route) => route.abort(), { times: 1 });

  await expect(
    page.getByRole("status").filter({ hasText: newVersion }),
  ).toBeVisible();
  expect(fetches.sent).toBe(1);
});
