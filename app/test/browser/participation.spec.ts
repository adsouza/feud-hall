import { createGuest, expect, state, test } from "./hall";

test.use({ launch: true });

test("owners keep competitor dining but lose helper access when licensed", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Future owner");
  await page.getByRole("button", { name: "Work", exact: true }).click();
  await page.getByRole("button", { name: "Accept shift" }).first().click();
  await expect(page.getByRole("timer")).toBeVisible();
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "license-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  const navigation = page.getByRole("navigation", { name: "Main navigation" });
  await expect(
    navigation.getByRole("button", { name: "Work", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByText("Restaurant owners cannot take helper shifts."),
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Accept shift" })).toHaveCount(
    0,
  );
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Work history" }),
  ).toBeVisible();
  await expect(
    page.getByText(/Restaurant license granted; helper shift ended/),
  ).toBeVisible();

  async function command(kind: string, payload: object = {}) {
    const response = await page.request.post(hall.origin + "/api/commands", {
      headers: { origin: hall.origin, "x-feud-command": "1" },
      data: { command_id: crypto.randomUUID(), kind, payload },
    });
    const result = await response.json();
    expect(result.accepted, JSON.stringify(result)).toBe(true);
  }
  const slot = (await state(page)).profile.slots[0].stall_id;
  await command("reserve_stall", { stall_id: slot });
  await command("create_restaurant", {
    restaurant_id: "owner-kitchen",
    stall_id: slot,
    name: "Own kitchen",
    cuisine: "levantine",
  });
  const budget = (await state(page)).profile.restaurant.starter_stock.budget;
  await command("request_starter_stock", {
    restaurant_id: "owner-kitchen",
    budget,
  });
  await hall.control({
    advance_to: (await state(page)).hall.now + 20 * 60_000,
  });
  await command("report_owner_presence", { present: true });
  await command("open_stall", { stall_id: slot });
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(slot);
  await expect(
    page.getByText("You cannot buy food or drinks from your own restaurant."),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Order here", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  const locations = page.getByRole("combobox", {
    name: "Location",
    exact: true,
  });
  await expect(locations.locator(`option[value="${slot}"]`)).toHaveCount(0);
  expect(await locations.locator("option").count()).toBeGreaterThan(1);
  await page.getByRole("button", { name: "Claim daily allowance" }).click();
  const rival = (await state(page)).hall.stalls.find(
    (stall: any) => stall["open?"] && stall.restaurant_id !== "owner-kitchen",
  );
  await locations.selectOption(rival.stall_id);
  await page
    .getByRole("combobox", { name: "Main", exact: true })
    .selectOption(
      Object.keys(rival.menu).find((id) => id === "falafel_wrap") ??
        Object.keys(rival.menu)[0],
    );
  await expect(
    page.getByRole("button", { name: "Review order" }),
  ).toBeEnabled();
  await page.getByRole("button", { name: "Review order" }).click();
  await page.getByRole("button", { name: "Confirm order" }).click();
  await expect
    .poll(async () => (await state(page)).profile.visit?.stall)
    .toBe(rival.stall_id);
});
