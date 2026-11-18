import { cash, type Slot } from "../../src/api";
import { createGuest, expect, state, test } from "./hall";

test.use({
  launch: true,
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});

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

  const locations: Slot[] = (await state(page)).profile.slots;
  const [first, second] = locations;
  await page.setViewportSize({ width: 390, height: 844 });
  const plan = page.getByRole("group", { name: "Stall floor plan · Hall 1" });
  await expect(plan.getByRole("button")).toHaveCount(locations.length);
  await expect(
    page.getByText(
      "Most foot traffic, with the highest rent and holding fees.",
    ),
  ).toBeVisible();
  const reserve = page.getByRole("button", {
    name: "Reserve stall for ten minutes",
  });
  await expect(reserve).toBeDisabled();
  const list = page.getByRole("combobox", { name: "Location", exact: true });
  const firstBay = plan.getByRole("button", {
    name: new RegExp("^" + first.stall_id + " · "),
  });
  const secondBay = plan.getByRole("button", {
    name: new RegExp("^" + second.stall_id + " · "),
  });
  await firstBay.click();
  await expect(list).toHaveValue(first.stall_id);
  await expect(firstBay).toHaveAttribute("aria-pressed", "true");
  await expect(
    page.getByText(`Daily open rent ${cash(first.rent)}`, { exact: false }),
  ).toBeVisible();
  await expect(
    page.getByText(`Daily holding fee ${cash(first.holding)}`, {
      exact: false,
    }),
  ).toBeVisible();
  await expect(
    page.getByText(`Setup fee ${cash(first.setup_fee)}`, { exact: false }),
  ).toBeVisible();
  expect((await state(page)).profile.draft).toBeNull();
  await list.selectOption(second.stall_id);
  await expect(secondBay).toHaveAttribute("aria-pressed", "true");
  await firstBay.press("Enter");
  await expect(list).toHaveValue(first.stall_id);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(390);
  await reserve.click();
  await expect(page.getByLabel("Restaurant name")).toBeVisible();
  expect((await state(page)).profile.draft.stall_id).toBe(first.stall_id);
  await page.setViewportSize({ width: 1440, height: 900 });
  await expect(page.getByRole("radio")).toHaveCount(25);
  await expect(page.locator("svg .region")).toHaveCount(25);
  await expect(
    page.getByText("Select a cuisine to see its recipes."),
  ).toBeVisible();
  await page.getByRole("button", { name: "Tamil", exact: true }).press("Enter");
  await expect(
    page.getByRole("radio", { name: "Tamil", exact: true }),
  ).toBeChecked();
  const preview = page.locator(".recipe-preview");
  await expect(
    preview.getByRole("heading", { name: "Tamil recipes" }),
  ).toBeVisible();
  await expect(preview.getByRole("listitem")).toHaveText([
    "Idli with sambar · Main",
    "Masala dosa · Main",
    "Vegetable uttapam · Main",
    "Filter coffee · Drink",
    "Paal payasam · Dessert",
  ]);
  await expect(
    preview.getByRole("heading", { name: "Available at setup" }).locator(".."),
  ).toContainText("Idli with sambar");
  await expect(
    preview.getByRole("heading", { name: "Unlock later" }).locator(".."),
  ).toContainText("Masala dosa");
  await page.getByRole("radio", { name: "Mexican", exact: true }).check();
  await expect(
    preview.getByRole("heading", { name: "Mexican recipes" }),
  ).toBeVisible();
  await expect(preview).toContainText("Bean tacos");
  await expect(preview).not.toContainText("Masala dosa");
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
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
    expansion.getByRole("heading", { name: "Mexican recipes" }),
  ).toBeVisible();
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

test("Maori is selectable on the map in both languages and has its own complete artwork", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Maori owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "maori-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await page.getByRole("button", { name: "Business", exact: true }).click();
  const slots = (await state(page)).profile.slots;
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(slots[0].stall_id);
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  const region = page.getByRole("button", { name: "Māori", exact: true });
  await expect(region).toBeVisible();
  await region.press("Enter");
  await expect(
    page.getByRole("radio", { name: "Māori", exact: true }),
  ).toBeChecked();
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByRole("radio", { name: "マオリ", exact: true }),
  ).toBeChecked();
  await expect(
    page.getByRole("button", { name: "マオリ", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await expect(
    page.getByRole("heading", { name: "マオリのレシピ" }),
  ).toBeVisible();
  await expect(page.locator(".recipe-preview")).toContainText(
    "豚肉とプーハーのボイルアップ",
  );
  await page.getByLabel("Language / 言語").selectOption("en");
  await page.getByLabel("Restaurant name").fill("Māori kitchen");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Māori kitchen", exact: true }),
  ).toBeVisible();
  const snapshot = await state(page);
  expect(snapshot.profile.restaurant.cuisine).toBe("maori");
  expect(Object.keys(snapshot.profile.restaurant.menu)).toEqual([
    "pork_puha_boil_up",
  ]);
  const maoriTexture = page.waitForResponse(
    (response) =>
      response.url().includes("maori-") && response.url().endsWith(".webp"),
  );
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(slots[0].stall_id);
  await expect(
    page.getByRole("button", { name: "Inside my stall", exact: true }),
  ).toBeEnabled();
  expect((await maoriTexture).ok()).toBe(true);
  await (await maoriTexture).finished();
  await page
    .locator("[data-hall-canvas] canvas")
    .screenshot({ path: testInfo.outputPath("maori-stall.png") });
  // Inspect the cuisine as a separate diner; owners cannot buy from their own stall.
  await page.context().clearCookies();
  await page.reload();
  await createGuest(page, "Maori diner");
  const dinerSnapshot = await state(page);
  // A display-only open stall fixture exercises the standalone image crop.
  dinerSnapshot.hall.stalls.find(
    (stall: any) => stall.stall_id === slots[0].stall_id,
  )["open?"] = true;
  await page.route(/\/api\/state(?:\?|$)/, (route) =>
    route.fulfill({ json: dinerSnapshot }),
  );
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(slots[0].stall_id);
  const art = page.locator(".cuisine-artwork");
  await expect(art).toBeVisible();
  await expect(art.locator("figcaption")).toHaveText("Māori");
  await expect
    .poll(() =>
      art
        .locator("img")
        .evaluate(
          (img: HTMLImageElement) => img.complete && img.naturalWidth === 512,
        ),
    )
    .toBe(true);
  const crop = await art.locator(".illustration").boundingBox();
  const image = await art.locator("img").boundingBox();
  expect(image!.width).toBeCloseTo(crop!.width, 0);
  expect(image!.height).toBeCloseTo(crop!.height, 0);
  await page.screenshot({ path: testInfo.outputPath("maori-visit.png") });
});
