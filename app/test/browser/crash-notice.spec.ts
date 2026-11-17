import type { Page } from "@playwright/test";
import { expect, test } from "./hall";

type Native = Window & {
  nativeCalls: string[];
  crashReports: { id: string; path: string }[];
  revealFails: boolean;
};

const newest =
  "/home/ria/.var/app/io.github.adsouza.FeudHall/data/io.github.adsouza.FeudHall/logs/crash-20261117T121130.000Z-2.txt";
const reports = [
  { id: "20261117T121130.000Z-2", path: newest },
  {
    id: "20261116T080000.000Z-2",
    path: "/home/ria/.var/app/io.github.adsouza.FeudHall/data/io.github.adsouza.FeudHall/logs/crash-20261116T080000.000Z-2.txt",
  },
];

// Runs the shared client in desktop mode: hall requests go to the test hall
// as the native transport would send them, and the crash commands are scripted.
async function asDesktop(
  page: Page,
  scripted: { id: string; path: string }[],
  revealFails = false,
) {
  await page.addInitScript(
    ({ scripted, revealFails }) => {
      const native = window as unknown as Native & {
        isTauri: boolean;
        __TAURI_INTERNALS__: unknown;
      };
      native.nativeCalls = [];
      // Acknowledged reports stay acknowledged across a reload, as the
      // native side's .seen files do.
      native.crashReports = sessionStorage.getItem("crash-acknowledged")
        ? []
        : scripted;
      native.revealFails = revealFails;
      native.isTauri = true;
      native.__TAURI_INTERNALS__ = {
        async invoke(command: string, args: Record<string, unknown>) {
          if (command !== "hall_request") native.nativeCalls.push(command);
          if (command === "hall_request") {
            const { path, method, body } = args.request as {
              path: string;
              method: string;
              body?: unknown;
            };
            const reply = await fetch(path, {
              method,
              headers: {
                "x-feud-protocol": "1",
                accept: "application/json",
                ...(body === undefined || body === null
                  ? {}
                  : {
                      "x-feud-command": "1",
                      "content-type": "application/json",
                    }),
              },
              body:
                body === undefined || body === null
                  ? undefined
                  : JSON.stringify(body),
            });
            return { status: reply.status, body: await reply.text() };
          }
          if (command === "crash_reports") return native.crashReports;
          if (command === "acknowledge_crash_reports") {
            native.crashReports = [];
            sessionStorage.setItem("crash-acknowledged", "1");
            return null;
          }
          if (command === "reveal_crash_report") {
            if (native.revealFails) throw "reveal_unavailable";
            return null;
          }
          throw new Error("Unexpected native command " + command);
        },
      };
    },
    { scripted, revealFails },
  );
}
const calls = (page: Page) =>
  page.evaluate(() => (window as unknown as Native).nativeCalls);
const notice = (page: Page) =>
  page.getByRole("region", {
    name: "Feud Hall closed unexpectedly last time.",
  });

test("crash notice shows the newest report's path, with no copy button", async ({
  page,
  hall,
}) => {
  await asDesktop(page, reports);
  await page.goto(hall.origin);
  await expect(notice(page)).toBeVisible();
  await expect(notice(page).locator("code")).toHaveText(newest);
  await expect(
    notice(page).getByText(
      "A diagnostic report was saved. It contains no passwords or game text. Please send it to the developers:",
    ),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: /copy/i })).toHaveCount(0);
  await notice(page).getByRole("button", { name: "Show in folder" }).click();
  await expect.poll(() => calls(page)).toContain("reveal_crash_report");
  await expect(notice(page)).toBeVisible();
});

test("crash notice dismiss acknowledges the reports", async ({
  page,
  hall,
}) => {
  await asDesktop(page, reports);
  await page.goto(hall.origin);
  await notice(page)
    .getByRole("button", { name: "Dismiss notification" })
    .click();
  await expect(notice(page)).toHaveCount(0);
  expect(
    (await calls(page)).filter((call) => call === "acknowledge_crash_reports"),
  ).toHaveLength(1);
  await page.reload();
  await expect(page.getByRole("navigation")).toBeVisible();
  await expect(notice(page)).toHaveCount(0);
});

test("crash notice explains when the folder cannot be shown", async ({
  page,
  hall,
}) => {
  await asDesktop(page, reports, true);
  await page.goto(hall.origin);
  await notice(page).getByRole("button", { name: "Show in folder" }).click();
  await expect(
    notice(page).getByText(
      "The folder could not be opened. The report's location is shown above.",
    ),
  ).toBeVisible();
  await expect(notice(page).locator("code")).toHaveText(newest);
});

test("crash notice stays away without reports", async ({ page, hall }) => {
  await asDesktop(page, []);
  await page.goto(hall.origin);
  await expect.poll(() => calls(page)).toContain("crash_reports");
  await expect(page.getByRole("navigation")).toBeVisible();
  await expect(page.getByText("closed unexpectedly")).toHaveCount(0);
});

test("crash notice follows the Japanese locale", async ({ page, hall }) => {
  await asDesktop(page, reports);
  await page.goto(hall.origin);
  await expect(notice(page)).toBeVisible();
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByRole("region", {
      name: "前回、Feud Hallが予期せず終了しました。",
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "フォルダーで表示" }),
  ).toBeVisible();
});

test("crash notice is not covered by the opening intro while the hall is starting", async ({
  page,
  hall,
}) => {
  await asDesktop(page, reports);
  // No hall reply: the client keeps waiting and plays the opening intro.
  await page.route("**/api/state**", (route) => route.abort("timedout"));
  await page.goto(hall.origin);
  await expect(notice(page)).toBeVisible();
  await expect(page.locator("[data-intro-stage]")).toBeVisible();
  await expect
    .poll(() =>
      notice(page).evaluate((element) => {
        const box = element.getBoundingClientRect();
        const points = [
          [box.left + 8, box.top + 8],
          [box.right - 8, box.bottom - 8],
          [box.left + box.width / 2, box.top + box.height / 2],
        ];
        return points.every(([x, y]) =>
          element.contains(document.elementFromPoint(x, y)),
        );
      }),
    )
    .toBe(true);
});
