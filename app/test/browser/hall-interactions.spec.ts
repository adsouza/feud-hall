import { createGuest, expect, state, test } from "./hall";
import type { Page } from "@playwright/test";

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

const workbench = (page: Page) =>
  page.getByRole("region", { name: "Stall actions", exact: true });
const stationControl = (page: Page, target: string) => {
  const labels: Record<string, string> = {
    menu: "Menu",
    counter: "Counter",
    staff: "Staff",
    supply: "Stock",
  };
  return page
    .locator(".hall-scene-pane")
    .getByRole("group", { name: "Stall actions", exact: true })
    .getByRole("button", { name: labels[target], exact: true });
};

async function focusStall(page: Page, id: string) {
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(id);
  await page
    .getByRole("button", { name: "Focus on the hall", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Restore hall layout", exact: true }),
  ).toBeVisible();
}

async function tapTablet(page: Page, kind: string, id?: string) {
  const host = page.locator("[data-hall-canvas]");
  const rows = page.locator(".tablet-text-controls");
  const button = rows
    .locator(
      `[data-tablet-kind="${kind}"]${id === undefined ? "" : `[data-tablet-id="${id}"]`}`,
    )
    .first();
  await expect(button).toBeAttached();
  await expect(button).toBeEnabled();
  const index = Number(await button.getAttribute("data-tablet-row"));
  await host.focus();
  await host.press("Home");
  const box = (await host.locator("canvas").boundingBox())!;
  const scale = Math.min(box.height / 1.08, box.width / 0.7344);
  const point = async (u: number, v: number) => {
    await page.mouse.click(
      box.x + box.width / 2 + (u - 0.5) * 0.62 * scale,
      box.y + box.height / 2 + (v - 0.5) * 0.93 * scale,
    );
  };
  for (let i = 0; i < Math.floor(index / 6); i++) await point(0.83, 0.92);
  await point(0.5, (180 + (index % 6) * 120 + 60) / 1080);
}

test("a diner orders and follows service at the 3D counter without leaving the hall", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Hall diner");
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await focusStall(page, "s001");
  await expect(page.locator(".hall-scene-pane .scene button")).toHaveCount(0);
  const canvas = await page
    .locator("[data-hall-canvas] canvas")
    .elementHandle();
  await stationControl(page, "menu").click();
  await expect(workbench(page)).toHaveCount(0);
  const host = page.locator("[data-hall-canvas]");
  await expect(host).toHaveAttribute("data-hall-tablet", "s001");
  // Read the accessible mirror, but act through real ray/UV picks on the mesh.
  const rows = page.locator(".tablet-text-controls");
  const tap = (kind: string) => tapTablet(page, kind);
  await tap("allowance");
  await expect(rows.locator('[data-tablet-kind="allowance"]')).toHaveCount(0);
  await tap("diets");
  await tap("diet");
  await tap("main");
  const quoteResponse = page.waitForResponse((response) =>
    response.url().includes("/api/quote?"),
  );
  await tap("review");
  const quoted = await (await quoteResponse).json();
  await expect(rows.locator('[data-tablet-kind="confirm"]')).toBeAttached();
  await page.screenshot({
    path: testInfo.outputPath("hall-tablet-checkout.png"),
  });
  let attempts: { command_id: string; kind: string }[] = [];
  await page.route("**/api/commands", async (route) => {
    const data = route.request().postDataJSON();
    if (data.kind !== "admit_visit") return route.continue();
    attempts.push(data);
    const response = await route.fetch();
    if (attempts.length === 1) return route.abort("failed");
    await route.fulfill({ response });
  });
  await tap("confirm");
  await expect(rows.locator('[data-tablet-kind="retry"]')).toBeAttached();
  await tap("retry");
  await expect(rows.locator('[data-tablet-kind="retry"]')).toHaveCount(0);
  expect(attempts).toHaveLength(2);
  expect(attempts[0].command_id).toBe(attempts[1].command_id);
  await expect
    .poll(async () => (await state(page)).profile.visit?.stall)
    .toBe("s001");
  const view = await state(page);
  await host.focus();
  await host.press("Escape");
  await page
    .getByRole("button", { name: "Restore hall layout", exact: true })
    .click();
  await focusStall(page, "s041");
  await stationControl(page, "menu").click();
  await expect(rows.locator('[data-tablet-kind="visit"]')).toBeAttached();
  await expect(rows.locator('[data-tablet-kind="dessert"]')).toHaveCount(0);
  await tap("visit");
  await expect(host).toHaveAttribute("data-hall-tablet", "s001");
  await hall.control({ advance_to: view.profile.visit.estimate });
  await expect(rows).toContainText(/Meal served|Tray served/);
  expect((await state(page)).profile.balance).toBe(
    (1200n - BigInt(quoted.total)).toString(),
  );
  const history = await (
    await page.request.get(hall.origin + "/api/dining-history")
  ).json();
  expect(history.receipts).toHaveLength(1);
  expect(await canvas!.evaluate((node) => node.isConnected)).toBe(true);
  await host.focus();
  await host.press("Escape");
  await expect(host).toHaveAttribute("data-hall-tablet", "");
  await host.press("e");
  await expect(host).toHaveAttribute("data-hall-tablet", "s001");
  await page.setViewportSize({ width: 375, height: 780 });
  await page.getByLabel("Language / 言語").selectOption("ja");
  await page.screenshot({
    path: testInfo.outputPath("hall-tablet-phone-ja.png"),
  });
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(375);
  await host
    .locator("canvas")
    .dispatchEvent("webglcontextlost", { cancelable: true });
  await expect(host).toHaveCount(0);
  await expect(
    page.getByRole("region", { name: "店舗での操作", exact: true }),
  ).toBeVisible();
});

test("a helper accepts, stages and selects a tray entirely in the 3D hall", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Hall helper");
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await focusStall(page, "s001");
  await stationControl(page, "staff").click();
  const panel = workbench(page);
  await panel.getByRole("button", { name: "Accept shift" }).click();
  await expect(panel.getByRole("timer")).toBeVisible();
  await hall.control({ incoming_order: "staging" });
  await expect(panel.getByText("Coming up", { exact: true })).toBeVisible();
  const ready = (await state(page)).profile.work.active.approaching[0].ready_at;
  await hall.control({ advance_to: ready - 24_000 });
  await panel.getByRole("button", { name: "Stage pickup supplies" }).click();
  await expect(
    panel.getByRole("status").filter({ hasText: "Staging pickup supplies" }),
  ).toBeVisible();
  await hall.control({ advance_to: ready });
  await panel.getByRole("button", { name: "Yield to service" }).click();
  await panel.locator(".counter-options button").first().click();
  const shift = (await state(page)).profile.work.active;
  await hall.control({ advance_to: shift.selection.deadline });
  await expect(
    panel.getByRole("status").filter({ hasText: "Handing over" }),
  ).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("hall-helper.png") });
  await page.getByRole("button", { name: "Work", exact: true }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Handing over" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(workbench(page)).toBeVisible();
  await workbench(page).getByRole("button", { name: "Leave shift" }).click();
  await expect
    .poll(async () => (await state(page)).profile.work.active)
    .toBeNull();
});

test("an owner runs the stall from the hall and shared drafts survive a narrow Japanese layout", async ({
  page,
  hall,
}, testInfo) => {
  await page.goto(hall.origin);
  await createGuest(page, "Hall owner");
  const principal = (await state(page)).profile.account.id;
  expect(
    (
      await (
        await page.request.post(hall.origin + "/api/operator/seed", {
          headers: { authorization: "Bearer " + hall.secret },
          data: { command_id: "hall-owner", principal },
        })
      ).json()
    ).accepted,
  ).toBe(true);
  async function command(kind: string, payload: object) {
    const response = await page.request.post(hall.origin + "/api/commands", {
      headers: { origin: hall.origin, "x-feud-command": "1" },
      data: { command_id: crypto.randomUUID(), kind, payload },
    });
    expect((await response.json()).accepted).toBe(true);
  }
  const id = (await state(page)).profile.slots[0].stall_id;
  await command("reserve_stall", { stall_id: id });
  await command("create_restaurant", {
    restaurant_id: "hall-kitchen",
    stall_id: id,
    name: "Hall kitchen",
    cuisine: "levantine",
  });
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await focusStall(page, id);
  await stationControl(page, "supply").click();
  const panel = workbench(page);
  await panel.getByText(/Suggested starter ingredients/).click();
  await panel
    .getByRole("button", { name: "Request purchase", exact: true })
    .first()
    .click();
  await hall.control({
    advance_to: (await state(page)).hall.now + 20 * 60_000,
  });
  await panel
    .getByRole("group", { name: "Stall station" })
    .getByRole("button", { name: "Menu", exact: true })
    .click();
  await panel
    .getByRole("combobox", { name: "Menu", exact: true })
    .selectOption("falafel_wrap");
  await panel
    .getByRole("textbox", { name: "Price (cents)", exact: true })
    .fill("725");
  await panel.getByRole("button", { name: "Set price", exact: true }).click();
  await expect
    .poll(
      async () =>
        (await state(page)).profile.restaurant.stalls.find(
          (stall: any) => stall.id === id,
        ).menu.falafel_wrap,
    )
    .toBe("725");
  await page
    .getByRole("button", { name: "Inside my stall", exact: true })
    .click();
  await page.locator("[data-hall-canvas]").focus();
  await page.locator("[data-hall-canvas]").press("e");
  await panel.getByRole("button", { name: "Open stall", exact: true }).click();
  await expect
    .poll(async () => (await state(page)).profile.restaurant.stalls[0].mode)
    .toBe("open");
  await expect(page.locator("[data-hall-canvas]")).toHaveAttribute(
    "data-hall-view",
    id,
  );
  await expect(panel.getByRole("button", { name: "Review order" })).toHaveCount(
    0,
  );
  await expect(panel.getByRole("button", { name: "Accept shift" })).toHaveCount(
    0,
  );
  await panel
    .getByRole("group", { name: "Stall station" })
    .getByRole("button", { name: "Menu", exact: true })
    .click();
  const price = panel.getByRole("textbox", {
    name: "Price (cents)",
    exact: true,
  });
  await price.fill("831");
  await price.press("e");
  await expect(
    panel
      .getByRole("group", { name: "Stall station" })
      .getByRole("button", { name: "Menu", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await price.fill("831");
  await page.getByRole("button", { name: "Business", exact: true }).click();
  await expect(
    page.getByRole("textbox", { name: "Price (cents)", exact: true }),
  ).toHaveValue("831");
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(
    workbench(page).getByRole("textbox", {
      name: "Price (cents)",
      exact: true,
    }),
  ).toHaveValue("831");
  await page.setViewportSize({ width: 320, height: 780 });
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByRole("textbox", { name: "価格（セント）", exact: true }),
  ).toHaveValue("831");
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(320);
  await page
    .getByRole("textbox", { name: "価格（セント）", exact: true })
    .scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath("hall-owner-phone-ja.png"),
  });
  const japanesePrice = page.getByRole("textbox", {
    name: "価格（セント）",
    exact: true,
  });
  await japanesePrice.focus();
  const input = await japanesePrice.elementHandle();
  await page
    .locator("[data-hall-canvas] canvas")
    .dispatchEvent("webglcontextlost", { cancelable: true });
  await expect(page.locator("[data-hall-canvas]")).toHaveCount(0);
  await expect(japanesePrice).toHaveValue("831");
  await expect(japanesePrice).toBeFocused();
  expect(await input!.evaluate((node) => node.isConnected)).toBe(true);
});

test("a tablet supports visitor signup, dietary availability and the cleaning cutoff", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await focusStall(page, "s001");
  await stationControl(page, "menu").click();
  const host = page.locator("[data-hall-canvas]");
  const rows = page.locator(".tablet-text-controls");
  await expect(rows.locator('[data-tablet-kind="guest"]')).toBeAttached();
  // Home/Enter activates the first screen row without a pointer or HTML form.
  await host.focus();
  await host.press("Home");
  await host.press("Enter");
  await expect
    .poll(async () => (await state(page)).profile?.account.name)
    .toBe("Visitor");
  await tapTablet(page, "allowance");
  await expect(rows.locator('[data-tablet-kind="main"]')).toBeAttached();
  await tapTablet(page, "diets");
  await tapTablet(page, "diet", "keto_style");
  await expect(rows.locator('[data-tablet-kind="main"]')).toHaveCount(0);
  await expect(rows.locator('[data-tablet-kind="review"]')).toBeDisabled();
  await tapTablet(page, "diets");
  await tapTablet(page, "diet", "unrestricted");
  await expect(rows.locator('[data-tablet-kind="main"]')).toBeAttached();
  await hall.control({ advance_to: 27 * 60 * 60_000 });
  await expect(rows).toContainText("Cleaning");
  await expect(rows.locator('[data-tablet-kind="main"]')).toHaveCount(0);
  await expect(rows.locator('[data-tablet-kind="review"]')).toHaveCount(0);
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await expect(host).toHaveAttribute("data-hall-tablet", "");
});
