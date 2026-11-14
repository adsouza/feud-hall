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

test("people: the hall draws the owner, workers and queue of each open stall", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Figure count owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "figure-count-owner", principal },
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
  await page.getByLabel("Restaurant name").fill("Figure counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Figure counter", exact: true }),
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

  // Freeze the presentation: only the two owned stalls are open and busy.
  const snapshot: View = await state(page);
  const owned = snapshot.profile!.restaurant!.stalls.map((stall) => stall.id);
  // Every count below is for Hall 1: both owned stalls are in it, with the
  // launch hall's own stalls, and no other room is open.
  expect(snapshot.hall.rooms?.open).toBe(1);
  expect(
    snapshot.hall.stalls
      .filter((stall) => owned.includes(stall.stall_id))
      .map((stall) => stall.room),
  ).toEqual([1, 1]);
  for (const stall of snapshot.hall.stalls) {
    const mine = owned.includes(stall.stall_id);
    stall["open?"] = mine;
    stall.activity = {
      waiting: mine ? 3 : 0,
      cooking: 0,
      handover: false,
      staffed: mine,
      workers: mine ? 2 : 0,
      staging: false,
      paused: false,
    };
  }
  await page.route("**/api/state", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  const people = async () =>
    Number(await host.getAttribute("data-hall-people"));
  // Returning to the hall keeps the camera where it was last shown. Reset it
  // to Hall 1's overview and zoom all the way out: there both stalls are beyond
  // the detail distance, so each draws at reduced detail: 1 owner + 1 worker
  // + 1 queued diner.
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-room", "1");
  const zoomOut = page.getByRole("button", { name: "Zoom out", exact: true });
  for (let step = 0; step < 12; step++) await zoomOut.click();
  await expect.poll(people).toBe(6);
  // Selecting a stall focuses the camera on it, which brings both owned stalls
  // within detail distance. Each: 1 owner + 2 workers + 3 queued diners.
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(owned[0]);
  await expect.poll(people).toBe(12);
});
