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

test("owner can look out from each stall and recover the hall viewpoint", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await expect(
    page.getByRole("button", { name: "Inside my stall" }),
  ).toHaveCount(0);
  await createGuest(page, "Counter viewpoint owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "viewpoint-owner", principal },
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
  await page.getByLabel("Restaurant name").fill("Viewpoint counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Viewpoint counter", exact: true }),
  ).toBeVisible();
  await page.getByText("Lease another location", { exact: true }).click();
  const expansion = page
    .locator("details")
    .filter({ has: page.getByText("Lease another location", { exact: true }) });
  await expansion
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(locations[1].stall_id);
  await expansion.getByRole("radio", { name: "Mexican", exact: true }).check();
  await expansion.getByRole("button", { name: "Confirm lease" }).click();
  await expect
    .poll(async () => (await state(page)).profile.restaurant.stalls.length)
    .toBe(2);

  // Freeze the presentation at a busy counter. No simulated service is awarded.
  const snapshot: View = await state(page);
  const owned = snapshot.profile!.restaurant!.stalls.map((stall) => stall.id);
  for (const stall of snapshot.hall.stalls) {
    if (!owned.includes(stall.stall_id)) continue;
    stall["open?"] = true;
    stall.activity = {
      waiting: 3,
      cooking: 0,
      handover: false,
      staffed: true,
      workers: 2,
      staging: false,
      paused: false,
    };
  }
  await page.route("**/api/state", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  const canvas = host.locator("canvas");
  await expect(canvas).toBeVisible();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(owned[0]);
  await page.getByLabel("Reduced detail").check();
  await expect(
    page.getByRole("button", { name: "Inside my stall" }),
  ).toBeEnabled();
  await page.evaluate(() => document.fonts.ready);
  await canvas.screenshot();
  const overview = await canvas.screenshot();
  await page.getByRole("button", { name: "Inside my stall" }).click();
  await expect(host).toHaveAttribute("data-hall-view", owned[0]);
  const interior = await canvas.screenshot();
  expect(interior.equals(overview)).toBe(false);
  await page.getByRole("button", { name: "Look up", exact: true }).click();
  await page.getByRole("button", { name: "Look left", exact: true }).click();
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  await page
    .getByRole("button", { name: "Return to hall", exact: true })
    .click();
  await expect(host).toHaveAttribute("data-hall-view", "hall");
  await expect
    .poll(async () => (await canvas.screenshot()).equals(overview))
    .toBe(true);
  await page.getByRole("button", { name: "Inside my stall" }).click();
  await page
    .getByRole("combobox", { name: "Your stall", exact: true })
    .selectOption(owned[1]);
  await expect(host).toHaveAttribute("data-hall-view", owned[1]);
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-view", owned[1]);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-view", "hall");
  await page.getByRole("button", { name: "Inside my stall" }).click();
  snapshot.hall.stalls.find((stall) => stall.stall_id === owned[0])!["open?"] =
    false;
  await page
    .getByRole("combobox", { name: "Your stall", exact: true })
    .selectOption(owned[0]);
  await expect(
    page.getByText(/This stall is closed. The shutter will rise/),
  ).toBeVisible();
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByRole("button", { name: "ホールの視点に戻る" }),
  ).toBeVisible();
  await page.setViewportSize({ width: 360, height: 780 });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(360);
  snapshot.profile!.restaurant = null;
  await expect(host).toHaveAttribute("data-hall-view", "hall");
  await expect(
    page.getByRole("group", { name: "店主の視点", exact: true }),
  ).toHaveCount(0);
});
