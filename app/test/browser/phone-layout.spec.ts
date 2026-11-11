import { createGuest, expect, state, test } from "./hall";

test.use({
  launch: true,
  viewport: { width: 390, height: 844 },
  hasTouch: true,
  isMobile: true,
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});

test("phone business navigation preserves drafts and composition across sections and the 400px boundary", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Phone owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "phone-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  const nav = page.getByRole("navigation", { name: "Main navigation" });
  await nav.getByRole("button", { name: "Business", exact: true }).click();
  const locations = (await state(page)).profile.slots;
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(locations[0].stall_id);
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("Phone counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  const sections = page.getByRole("combobox", {
    name: "Business section",
    exact: true,
  });
  await expect(sections).toBeVisible();
  const price = page.getByRole("textbox", {
    name: "Price (cents)",
    exact: true,
  });
  await price.fill("1234");
  await page.screenshot({ path: testInfo.outputPath("phone-business-en.png") });
  await sections.selectOption("performance");
  await expect(
    page.getByRole("heading", { name: "Performance", exact: true }),
  ).toBeVisible();
  await expect(price).toBeHidden();
  await page.goBack();
  await expect(price).toHaveValue("1234");
  await sections.selectOption("supply");
  const maxPrice = page.getByRole("textbox", {
    name: "Maximum price per 1,000 units (cents)",
    exact: true,
  });
  await maxPrice.fill("567");
  await page.setViewportSize({ width: 400, height: 844 });
  await expect(sections).toBeHidden();
  await expect(price).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Staff and hours", exact: true }),
  ).toBeVisible();
  await maxPrice.focus();
  await maxPrice.dispatchEvent("compositionstart");
  await page.setViewportSize({ width: 399, height: 844 });
  await expect(sections).toHaveValue("supply");
  await expect(maxPrice).toBeFocused();
  await expect(maxPrice).toHaveValue("567");
  await maxPrice.dispatchEvent("compositionend");
  await sections.selectOption("menu");
  await expect(price).toHaveValue("1234");
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByRole("combobox", { name: "運営メニュー", exact: true }),
  ).toBeVisible();
  await expect(price).toHaveCount(0);
  await expect(
    page.getByRole("textbox", { name: "価格（セント）", exact: true }),
  ).toHaveValue("1234");
  await page.setViewportSize({ width: 320, height: 720 });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(320);
  expect((await page.locator("header").boundingBox())!.height).toBeLessThan(
    110,
  );
  const bottom = await page
    .getByRole("navigation", { name: "メインナビゲーション" })
    .boundingBox();
  expect(Math.round(bottom!.y + bottom!.height)).toBe(720);
  await page.screenshot({ path: testInfo.outputPath("phone-business-ja.png") });
});

test("phone stall details support Back, preserve comparison drafts and keep the hall separate", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Phone diner");
  const nav = page.getByRole("navigation", { name: "Main navigation" });
  await nav.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("phone-hall.png") });
  const picker = page.getByRole("combobox", { name: "Location", exact: true });
  const stalls = (await state(page)).hall.stalls;
  await picker.selectOption(stalls[0].stall_id);
  const inspector = page.getByRole("region", { name: "Menu", exact: true });
  await expect(inspector).toBeFocused();
  await expect(page.locator("[data-hall-canvas]")).toHaveCount(0);
  const compare = page.getByText("Compare meals", { exact: true });
  await compare.click();
  const budget = page.getByRole("textbox", {
    name: "Budget in dollars (optional)",
    exact: true,
  });
  await budget.fill("11.50");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({
    path: testInfo.outputPath("phone-stall-detail.png"),
  });
  await page.goBack();
  await expect(
    page.getByRole("button", { name: "Back to hall", exact: true }),
  ).toBeHidden();
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  await expect(picker).toHaveValue(stalls[0].stall_id);
  await page.goForward();
  await expect(budget).toHaveValue("11.50");
  await expect(page.locator("[data-hall-canvas]")).toHaveCount(0);
  await page.setViewportSize({ width: 400, height: 844 });
  await expect(
    page.getByRole("button", { name: "Back to hall", exact: true }),
  ).toBeHidden();
  await expect(page.locator("[data-hall-canvas] canvas")).toBeVisible();
  await expect(budget).toHaveValue("11.50");
  await budget.focus();
  await budget.dispatchEvent("compositionstart");
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(budget).toBeFocused();
  await expect(page.locator("[data-hall-canvas]")).toHaveCount(0);
  await budget.dispatchEvent("compositionend");
  await page.getByLabel("Language / 言語").selectOption("ja");
  await page.getByRole("button", { name: "ホールに戻る", exact: true }).click();
  await expect(
    page.getByRole("combobox", { name: "区画", exact: true }),
  ).toBeFocused();
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(390);
});
