import type { Page } from "@playwright/test";
import type { View } from "../../src/api";
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

// Opens the hall with one leased stall, then serves the same view with that
// stall closed at the next position, so the live scene sees it close.
async function closeOwnedStall(
  page: Page,
  hall: { origin: string; secret: string },
  name: string,
) {
  await page.goto(hall.origin);
  await createGuest(page, name);
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "shutter-owner-" + name, principal },
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
  await page.getByLabel("Restaurant name").fill("Shutter stall");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Shutter stall", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-room", "1");

  // Record every value the host attribute takes: a roll lasts about a second
  // and a poll could step over it.
  await host.evaluate((element) => {
    const log: string[] = [];
    (window as unknown as { shutterLog: string[] }).shutterLog = log;
    new MutationObserver(() =>
      log.push(element.getAttribute("data-hall-shutters-moving") ?? ""),
    ).observe(element, {
      attributes: true,
      attributeFilter: ["data-hall-shutters-moving"],
    });
  });
  const readings = () =>
    page.evaluate(
      () => (window as unknown as { shutterLog: string[] }).shutterLog,
    );

  // Serve the stall open and staffed until the scene has drawn it open.
  const snapshot: View = await state(page);
  const owned = snapshot.profile!.restaurant!.stalls.map((stall) => stall.id);
  const mine = (stall: View["hall"]["stalls"][number]) =>
    owned.includes(stall.stall_id);
  for (const stall of snapshot.hall.stalls) {
    if (mine(stall)) stall["open?"] = true;
    stall.activity = {
      waiting: mine(stall) ? 3 : 0,
      cooking: 0,
      handover: false,
      staffed: mine(stall),
      workers: mine(stall) ? 2 : 0,
      staging: false,
      paused: false,
    };
  }
  snapshot.hall.position += 1;
  await page.route("**/api/state", (route) =>
    route.fulfill({ json: snapshot }),
  );
  const people = async () =>
    Number(await host.getAttribute("data-hall-people"));
  const before = await people();
  await expect.poll(people).toBeGreaterThan(before);
  const drawnOpen = await people();
  // Its shutter rolls up on opening; let that finish before it closes.
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "0");
  await page.evaluate(() => {
    (window as unknown as { shutterLog: string[] }).shutterLog.length = 0;
  });
  // Then the same stall closes: a newer view, as the server would serve it.
  for (const stall of snapshot.hall.stalls)
    if (mine(stall)) {
      stall["open?"] = false;
      stall.activity = {
        waiting: 0,
        cooking: 0,
        handover: false,
        staffed: false,
        workers: 0,
        staging: false,
        paused: false,
      };
    }
  snapshot.hall.position += 1;
  return { host, readings, people, drawnOpen };
}

test("hall shutters: a stall that closes rolls its shutter down", async ({
  page,
  hall,
}) => {
  const { host, readings } = await closeOwnedStall(
    page,
    hall,
    "Shutter roller",
  );
  await expect.poll(readings).toContain("1");
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "0");
});

test("hall shutters: reduced motion snaps without rolling", async ({
  page,
  hall,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const { host, readings, people, drawnOpen } = await closeOwnedStall(
    page,
    hall,
    "Shutter snapper",
  );
  // The closed view has been drawn (its workers are gone), and from then on
  // nothing was ever mid-roll.
  await expect.poll(people).toBeLessThan(drawnOpen);
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "0");
  await page.waitForTimeout(1500);
  expect((await readings()).filter((value) => value !== "0")).toEqual([]);
  await expect(host).toHaveAttribute("data-hall-shutters-moving", "0");
});
