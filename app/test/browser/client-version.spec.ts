import type { Page } from "@playwright/test";
import { expect, test } from "./hall";

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

function servedPages(page: Page) {
  const fetches: string[] = [];
  page.on("request", (request) => {
    if (
      request.resourceType() === "fetch" &&
      new URL(request.url()).pathname === "/"
    )
      fetches.push(request.url());
  });
  return fetches;
}

// Serves the real page with another entry script, as after a deploy that
// changed the client code.
async function serveNewerClient(page: Page, origin: string) {
  await page.route(new URL("/", origin).href, async (route) => {
    const response = await route.fetch();
    const original = await response.text();
    const body = original.replace(
      /src="\/assets\/index-[^"]+\.js"/,
      'src="/assets/index-newer.js"',
    );
    expect(body).not.toBe(original);
    await route.fulfill({ response, body });
  });
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
  expect(fetches).toHaveLength(1);

  // A notice already showing needs no second look at the served page.
  const polled = page.waitForResponse(
    (response) => new URL(response.url()).pathname === "/api/state",
  );
  await becomeVisible(page);
  await polled;
  expect(fetches).toHaveLength(1);

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
    page.waitForEvent("load"),
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

  await becomeVisible(page);
  await expect.poll(() => fetches.length).toBe(1);
  await expect(notice).toHaveCount(0);

  // A host's error page during a deploy, and a page with no client at all.
  const home = new URL("/", hall.origin).href;
  const unusable = [
    {
      status: 503,
      contentType: "text/html",
      body: '<script type="module" src="/assets/maintenance.js"></script>',
    },
    { status: 200, contentType: "text/plain", body: "Not a client page." },
  ];
  for (const [index, answer] of unusable.entries()) {
    await page.route(home, (route) => route.fulfill(answer));
    await becomeVisible(page);
    await expect.poll(() => fetches.length).toBe(index + 2);
    await expect(notice).toHaveCount(0);
    await page.unroute(home);
  }

  // This check runs only if none of the earlier ones raised the notice.
  await serveNewerClient(page, hall.origin);
  await becomeVisible(page);
  await expect(notice).toBeVisible();
  expect(fetches).toHaveLength(4);
  expect(errors).toEqual([]);
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
  expect(fetches).toHaveLength(1);
});
