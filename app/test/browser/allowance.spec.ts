import { createGuest, expect, state, test } from "./hall";

const hour = 3_600_000;

test("daily allowance action follows the principal's claim across reloads and midnight", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Allowance diner");
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  const claim = page.getByRole("button", {
    name: "Claim daily allowance",
    exact: true,
  });
  await expect(claim).toBeVisible();
  await claim.click();
  await expect(claim).toHaveCount(0);
  await expect
    .poll(async () => (await state(page)).profile.allowance_claimed)
    .toBe(true);

  await page.reload();
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  await expect(claim).toHaveCount(0);
  await page.getByLabel("Language / 言語").selectOption("ja");
  const japaneseClaim = page.getByRole("button", {
    name: "本日の食事補助を受け取る",
    exact: true,
  });
  await expect(japaneseClaim).toHaveCount(0);
  await hall.control({ advance_to: 24 * hour - 24 });
  await expect
    .poll(async () => (await state(page)).hall.now)
    .toBe(24 * hour - 24);
  await expect(japaneseClaim).toHaveCount(0);
  await hall.control({ advance_to: 24 * hour });
  await expect(japaneseClaim).toBeVisible();
  await japaneseClaim.click();
  await expect(japaneseClaim).toHaveCount(0);
});

test("a stale allowance action is refused and the resulting notice can be dismissed", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Stale allowance diner");
  await page.getByRole("button", { name: "My visit", exact: true }).click();
  const stale = await state(page);
  await page.route(/\/api\/state(?:\?|$)/, (route) =>
    route.fulfill({ json: stale }),
  );
  const claimed = await page.request.post(hall.origin + "/api/commands", {
    headers: { origin: hall.origin, "x-feud-command": "1" },
    data: {
      command_id: "allowance-from-another-session",
      kind: "request_allowance",
      payload: {},
    },
  });
  expect((await claimed.json()).accepted).toBe(true);
  await page
    .getByRole("button", { name: "Claim daily allowance", exact: true })
    .click();
  const refusal = page.getByText(
    "You’ve already claimed your dining allowance for this game day.",
    { exact: true },
  );
  await expect(refusal).toBeVisible();
  await page
    .locator(".refusal-notice")
    .getByRole("button", { name: "Dismiss notification", exact: true })
    .press("Enter");
  await expect(refusal).toHaveCount(0);
  await page.unroute(/\/api\/state(?:\?|$)/);
  await expect(
    page.getByRole("button", { name: "Claim daily allowance", exact: true }),
  ).toHaveCount(0);
});
