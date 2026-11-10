import { createGuest, expect, state, test } from "./hall";

const hour = 3_600_000;
const dismiss = "Dismiss notification";

test("visitor can dine and sees why ordering is unavailable", async ({
  page,
  hall,
}) => {
  const home = await page.goto(hall.origin);
  expect(home?.headers()["content-security-policy"]).toContain(
    "default-src 'self'",
  );
  await expect
    .poll(() =>
      page
        .locator("header img")
        .evaluate(
          (img: HTMLImageElement) => img.complete && img.naturalWidth > 0,
        ),
    )
    .toBe(true);

  await createGuest(page, "Diner");
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await page.clock.install();
  const claim = page.getByRole("button", { name: "Claim daily allowance" });
  await claim.click();
  await expect(page.getByText("$12.00", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: dismiss })).toBeVisible();
  await page.clock.runFor(4300);
  await expect(page.getByRole("button", { name: dismiss })).toHaveCount(0);

  await claim.click();
  const refusal = page.getByText(
    "You’ve already claimed your dining allowance for this game day.",
  );
  await expect(refusal).toBeVisible();
  await page.getByRole("button", { name: dismiss }).press("Enter");
  await expect(refusal).toHaveCount(0);

  const location = page.getByRole("combobox", {
    name: "Location",
    exact: true,
  });
  await expect(location.locator("option")).toHaveText([
    "—",
    "NPC budget",
    "NPC premium",
  ]);
  await location.selectOption({ label: "NPC budget" });
  const dietaryProfile = page.getByRole("combobox", {
    name: "Dietary profile",
  });
  await expect(dietaryProfile.locator("option")).toHaveText([
    "—",
    "Unrestricted",
    "Carb conscious",
    "Vegan",
    "Vegetarian",
  ]);
  await dietaryProfile.selectOption("vegan");
  await page
    .getByRole("combobox", { name: "Main", exact: true })
    .selectOption("falafel_wrap");
  const quoteResponse = page.waitForResponse((response) =>
    response.url().includes("/api/quote?"),
  );
  await page.getByRole("button", { name: "Review order" }).click();
  const quote = await (await quoteResponse).json();
  expect(BigInt(quote.total)).toBeGreaterThan(0n);

  const commandIds: string[] = [];
  await page.route("**/api/commands", async (route) => {
    const command = route.request().postDataJSON();
    if (command.kind !== "admit_visit") return route.continue();
    commandIds.push(command.command_id);
    const result = await route.fetch();
    expect((await result.json()).accepted).toBe(true);
    if (commandIds.length === 1) {
      await route.fulfill({ status: 503, json: { error: "unknown_outcome" } });
    } else {
      await route.fulfill({ response: result });
    }
  });
  await page.getByRole("button", { name: "Confirm order" }).click();
  await page.getByRole("button", { name: "Retry same command" }).click();
  await expect(
    page.getByText("Preparing your tray", { exact: false }),
  ).toBeVisible();
  expect(commandIds).toHaveLength(2);
  expect(commandIds[0]).toBe(commandIds[1]);
  await hall.control({ advance_to: quote.earliest_completion });
  await expect.poll(async () => (await state(page)).profile.visit).toBeNull();
  expect((await state(page)).profile.balance).toBe(
    (1200n - BigInt(quote.total)).toString(),
  );

  const closed = await state(page);
  for (const stall of closed.hall.stalls) stall["open?"] = false;
  const serveClosed = (route: import("@playwright/test").Route) =>
    route.fulfill({ json: closed });
  await page.route("**/api/state", serveClosed);
  await expect(
    page.getByText("No stalls are open for orders right now.", {
      exact: false,
    }),
  ).toBeVisible();
  await expect(location).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(
    page.getByText("現在、注文を受け付けている店舗はありません。", {
      exact: false,
    }),
  ).toBeVisible();
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(390);
  await page.getByLabel("Language / 言語").selectOption("en");
  await page.unroute("**/api/state", serveClosed);

  await hall.control({ advance_to: 27 * hour });
  await expect(
    page.getByRole("status").filter({ hasText: "service resumes at 05:00" }),
  ).toBeVisible();
  await expect(location).toHaveCount(0);
  await hall.control({ advance_to: 29 * hour });
  await expect(location.locator('option[value="s001"]')).toHaveText(
    "NPC budget",
  );
});

test("helper sees selection, automatic handover, and the missed-window explanation", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Helper");
  await page.getByRole("button", { name: "Work", exact: true }).click();
  await expect(
    page.getByText("Shift length 5:00 (real time)", { exact: false }),
  ).toBeVisible();
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
  await expect(
    page.getByRole("timer").filter({ hasText: "Time left 5:00" }),
  ).toBeVisible();

  const { deadline } = await hall.control<{ deadline: number }>({
    ready_order: "first",
  });
  const tray = page.getByRole("button", { name: "Falafel wrap", exact: true });
  await expect(tray).toBeVisible();
  await expect(page.getByRole("timer")).toHaveCount(2);

  const stale = await state(page);
  const keepOldView = (route: import("@playwright/test").Route) =>
    route.fulfill({ json: stale });
  await page.route("**/api/state", keepOldView);
  await tray.click();
  await expect(
    page.getByRole("status").filter({
      hasText: "Selected: Falafel wrap. The handover will start automatically.",
    }),
  ).toBeVisible();
  await expect(tray).toHaveCount(0);
  await expect(page.getByRole("button", { name: dismiss })).toHaveCount(0);
  await page.unroute("**/api/state", keepOldView);

  await hall.control({ advance_to: deadline });
  const inProgress = page
    .getByRole("status")
    .filter({ hasText: "Handing over Falafel wrap." });
  await expect(inProgress).toBeVisible();
  const active = (await state(page)).profile.work.active;
  expect(active.tasks).toBe(0);
  const heartbeat = async (commandId: string) => {
    const response = await page.request.post(hall.origin + "/api/commands", {
      headers: { origin: hall.origin, "x-feud-command": "1" },
      data: {
        command_id: commandId,
        kind: "report_helper_presence",
        payload: { shift_id: active.shift_id },
      },
    });
    expect((await response.json()).accepted).toBe(true);
  };
  await heartbeat("browser-handover-heartbeat");
  await page.reload();
  await page.getByRole("button", { name: "Work", exact: true }).click();
  await expect(inProgress).toBeVisible();
  await hall.control({ advance_to: active.handover.done_at });
  await expect(page.getByText(/Completed handovers\s+1/)).toBeVisible();
  await expect(inProgress).toHaveCount(0);

  const missed = await hall.control<{ deadline: number }>({
    ready_order: "second",
  });
  await expect(tray).toBeVisible();
  await heartbeat("browser-second-selection-heartbeat");
  await hall.control({ advance_to: missed.deadline });
  await expect(
    page.getByText("Selection window ended", { exact: false }).first(),
  ).toBeVisible();
  const help = page
    .locator("summary")
    .filter({ hasText: "What does “Selection window ended” mean?" });
  await help.focus();
  await page.keyboard.press("Enter");
  await expect(
    page.getByText(
      "A tray was ready, but the game did not receive your choice in time.",
      { exact: false },
    ),
  ).toBeVisible();
});

test("an invited owner can preview a cuisine on the map before selecting it", async ({
  browser,
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Invitation issuer");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "browser-seed", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await page.getByRole("button", { name: "Issue invitation" }).click();
  const invitation = page.locator("code").filter({ hasText: /^invite\./ });
  await expect(invitation).toBeVisible();

  const other = await browser.newContext();
  try {
    const owner = await other.newPage();
    await owner.goto(hall.origin);
    await createGuest(
      owner,
      "Invited owner",
      (await invitation.innerText()).trim(),
    );
    await expect(
      owner.getByRole("heading", { name: "Set up your first stall" }),
    ).toBeVisible();
    await owner
      .getByRole("combobox", { name: "Location", exact: true })
      .selectOption("s002");
    await owner
      .getByRole("button", { name: "Reserve stall for ten minutes" })
      .click();
    const radio = owner.getByRole("radio", { name: "Levantine" });
    const region = owner.getByRole("button", {
      name: "Levantine",
      exact: true,
    });
    const label = owner.locator("label").filter({ has: radio });
    const initialColor = await label.evaluate(
      (element) => getComputedStyle(element).color,
    );
    await region.hover();
    await expect(label).not.toHaveCSS("color", initialColor);
    await expect(radio).not.toBeChecked();
    await region.press("Enter");
    await expect(radio).toBeChecked();
  } finally {
    await other.close();
  }
});

test.describe("startup recovery", () => {
  test.use({ restore: true });

  test("the due NPC plan records its refusal and the HTTP hall stays available", async ({
    page,
    hall,
  }) => {
    await page.goto(hall.origin);
    await expect(
      page.getByRole("heading", { name: "NPC budget" }),
    ).toBeVisible();
    const before = (await state(page)).hall;
    const plan = await hall.control<{ position: number; outcomes: unknown[] }>({
      restart_plan: true,
    });
    expect(plan.position).toBeLessThanOrEqual(before.position);
    expect(plan.outcomes).toContainEqual({
      action: "open_stall",
      result: "rejected",
      reason: "staff_off_duty",
    });

    await createGuest(page, "Recovered hall visitor");
    await page.getByRole("button", { name: "My visit", exact: true }).click();
    await page.getByRole("button", { name: "Claim daily allowance" }).click();
    await expect(page.getByText("$12.00", { exact: true })).toBeVisible();
    await expect.poll(hall.logs).toContain('"kind":"request_allowance"');
    await hall.control({ advance_to: before.now + 24_000 });
    expect((await state(page)).hall.now).toBeGreaterThan(before.now);
    const malformed = await page.request.post(hall.origin + "/api/commands", {
      headers: { "content-type": "application/json" },
      data: Buffer.from("{"),
    });
    expect(malformed.status()).toBe(400);
    expect(await malformed.json()).toEqual({ error: "invalid_command" });
  });
});
