import { createGuest, expect, state, test } from "./hall";

test.use({ launch: true });

test("launch owner selects from all cuisines, equips a recipe and expands", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Launch owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "launch-owner-seed", principal },
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
  await expect(page.getByRole("radio")).toHaveCount(24);
  await expect(page.locator("svg .region")).toHaveCount(24);
  await page.getByRole("button", { name: "Tamil", exact: true }).press("Enter");
  await expect(
    page.getByRole("radio", { name: "Tamil", exact: true }),
  ).toBeChecked();
  await page.getByLabel("Restaurant name").fill("Test counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Test counter", exact: true }),
  ).toBeVisible();

  const dosa = page.locator("li").filter({ hasText: "Masala dosa" });
  await expect(dosa).toContainText("Equipment Griddle · $120.00");
  await dosa.getByRole("button", { name: "Unlock · $380.00" }).click();
  await expect
    .poll(async () => (await state(page)).profile.restaurant.ledger.capex)
    .toBe("38000");

  await page.getByText("Lease another location", { exact: true }).click();
  const expansion = page.locator("details").filter({
    has: page.getByText("Lease another location", { exact: true }),
  });
  await expansion
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(locations[1].stall_id);
  await page.waitForResponse((response) =>
    response.url().endsWith("/api/state"),
  );
  await expansion.getByRole("radio", { name: "Mexican", exact: true }).check();
  await expect(
    expansion.getByText(/Estimated break-even at starter prices/),
  ).toBeVisible();
  await expansion.getByRole("button", { name: "Confirm lease" }).click();
  await expect
    .poll(async () =>
      (await state(page)).profile.restaurant.stalls.map(
        (stall: { cuisine: string }) => stall.cuisine,
      ),
    )
    .toEqual(["tamil", "mexican"]);
  expect((await state(page)).profile.restaurant.ledger.capital).toBe("500000");
});
