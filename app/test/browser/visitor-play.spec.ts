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

test("M5 diner keeps a live visit and can compare and order after WebGL loss", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  const canvas = page.locator("[data-hall-canvas] canvas");
  await expect(canvas).toBeVisible();
  const reset = page.getByRole("button", { name: "Reset camera" });
  await expect(reset).toBeEnabled();
  await page.getByRole("button", { name: "Orbit left" }).click();
  await reset.click();
  const host = page.locator("[data-hall-canvas]");
  await host.focus();
  await host.press("ArrowUp");
  const location = page.getByRole("combobox", {
    name: "Location",
    exact: true,
  });
  await expect(location).not.toHaveValue("");
  await location.selectOption("");
  const scene = await canvas.boundingBox();
  expect(scene).not.toBeNull();
  await canvas.click({
    position: { x: scene!.width * 0.5, y: scene!.height * 0.6 },
  });
  await expect(
    page.getByRole("combobox", { name: "Location" }),
  ).not.toHaveValue("");
  await page.getByRole("button", { name: "Hall audio" }).click();
  await expect(page.getByRole("slider", { name: "Ambience" })).toBeVisible();
  await expect(page.getByRole("slider", { name: "Effects" })).toBeVisible();
  await page.getByRole("button", { name: "Hall audio" }).click();

  await createGuest(page, "Tasting diner");
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await page.getByRole("button", { name: "Claim daily allowance" }).click();
  await expect
    .poll(async () => (await state(page)).profile.balance)
    .toBe("1200");
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(canvas).toBeVisible();
  await canvas.dispatchEvent("webglcontextlost", { cancelable: true });
  await expect(
    page.getByText("The 3D view is unavailable. The stall list is open."),
  ).toBeVisible();

  await page.getByText("Compare meals", { exact: true }).click();
  const budget = page.getByLabel("Budget in dollars (optional)");
  await budget.fill("0.01");
  await page.getByRole("button", { name: "Find meals" }).click();
  await expect(
    page.getByText("No meals currently match these filters."),
  ).toBeVisible();
  await budget.fill("12.00");
  await page.getByRole("button", { name: "Find meals" }).click();
  const meal = page.getByRole("button", { name: "Choose meal" }).first();
  await expect(meal).toBeVisible();
  await meal.click();

  const quoted = page.waitForResponse((r) => r.url().includes("/api/quote?"));
  await page.getByRole("button", { name: "Review order" }).click();
  const quote = await (await quoted).json();
  await page.getByRole("button", { name: "Confirm order" }).click();
  await expect
    .poll(async () => (await state(page)).profile.visit)
    .not.toBeNull();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(page.locator(".visit-tracker")).toHaveCount(0);
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await expect(
    page.getByRole("status").filter({
      hasText: /Preparing your tray|Order queued|At the counter/,
    }),
  ).toBeVisible();
  await hall.control({ advance_to: quote.earliest_completion });
  await expect(
    page.getByRole("heading", { name: "Dining receipts" }),
  ).toBeVisible();
  await expect(
    page.locator("details").filter({ hasText: "Charged" }),
  ).toHaveCount(1);

  await page.setViewportSize({ width: 360, height: 780 });
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(page.getByRole("button", { name: "店舗一覧" })).toBeVisible();
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(360);
});

test("M5 helper can stage pickup supplies and yield to the ready tray", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Counter helper");
  await page.getByRole("button", { name: "Work", exact: true }).click();
  await page
    .locator("article")
    .filter({
      has: page.getByRole("heading", {
        name: "s001 · Counter helper",
        exact: true,
      }),
    })
    .getByRole("button", { name: "Accept shift" })
    .click();
  await expect(page.getByRole("timer")).toBeVisible();

  await hall.control({ incoming_order: "staging" });
  await expect(page.getByText("Coming up", { exact: true })).toBeVisible();
  const active = (await state(page)).profile.work.active;
  const readyAt = active.approaching[0].ready_at as number;
  await hall.control({ advance_to: readyAt - 24_000 });
  await page.getByRole("button", { name: "Stage pickup supplies" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Staging pickup supplies" }),
  ).toBeVisible();

  await hall.control({ advance_to: readyAt });
  await page.getByRole("button", { name: "Yield to service" }).click();
  const choice = page.locator(".counter-options button").first();
  await expect(choice).toBeVisible();
  await expect(page.getByText(/Automatic next choice/)).toBeVisible();
  await choice.click();
  const shift = (await state(page)).profile.work.active;
  await hall.control({ advance_to: shift.selection.deadline });
  await expect(
    page.getByRole("status").filter({ hasText: "Handing over " }),
  ).toBeVisible();
});
