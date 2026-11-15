import { expect, test } from "./hall";

test("web requests send the client protocol and a refused protocol asks for a reload", async ({
  page,
  hall,
}) => {
  const first = page.waitForRequest(
    (request) => new URL(request.url()).pathname === "/api/state",
  );
  await page.goto(hall.origin);
  expect((await first).headers()["x-feud-protocol"]).toBe("1");

  await page.route("**/api/state**", (route) =>
    route.fulfill({ status: 426, json: { error: "client_update_required" } }),
  );
  const notice = page
    .getByRole("status")
    .filter({ hasText: "This page is out of date. Reload to continue." });
  await expect(notice).toBeVisible();
  await expect(notice.getByRole("button", { name: "Reload" })).toBeVisible();
  await expect(
    page.getByText("This desktop app and hall use different versions."),
  ).toHaveCount(0);
});
