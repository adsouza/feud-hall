import { createGuest, expect, state, test } from "./hall";

test("release boundary checks protocol, origin, and a copied revoked cookie", async ({
  page,
  hall,
  playwright,
}) => {
  const ready = await page.request.get(hall.origin + "/healthz");
  expect(await ready.json()).toEqual({ ready: true });

  const mismatch = await page.request.get(hall.origin + "/api/state", {
    headers: { "x-feud-protocol": "999" },
  });
  expect(mismatch.status()).toBe(426);
  expect(await mismatch.json()).toEqual({ error: "client_update_required" });

  await page.goto(hall.origin);
  await createGuest(page, "Release check");
  const original = await state(page);
  const cookie = (await page.context().cookies()).find(
    (entry) => entry.name === "_feud_device",
  );
  expect(cookie?.httpOnly).toBe(true);
  expect(cookie?.sameSite).toBe("Lax");
  const command = {
    command_id: "release-allowance",
    kind: "request_allowance",
    payload: {},
  };

  const invalidHeaders: Record<string, string>[] = [
    { origin: "https://wrong.example", "x-feud-command": "1" },
    { origin: hall.origin },
  ];
  for (const headers of invalidHeaders) {
    const refused = await page.request.post(hall.origin + "/api/commands", {
      headers,
      data: command,
    });
    expect(refused.status()).toBe(403);
  }
  expect((await state(page)).profile.balance).toBe(original.profile.balance);

  const originHeaders = {
    origin: hall.origin,
    "x-feud-command": "1",
    "x-feud-protocol": "1",
  };
  const accepted = await page.request.post(hall.origin + "/api/commands", {
    headers: originHeaders,
    data: command,
  });
  expect(await accepted.json()).toMatchObject({ accepted: true });
  expect(accepted.headers()["x-feud-protocol"]).toBe("1");

  const revoked = await page.request.post(hall.origin + "/api/commands", {
    headers: originHeaders,
    data: { command_id: "release-revoke", kind: "revoke_device", payload: {} },
  });
  expect(await revoked.json()).toMatchObject({ accepted: true });

  const stale = await playwright.request.newContext({
    extraHTTPHeaders: { Cookie: `_feud_device=${cookie?.value}` },
  });
  try {
    expect(
      (await (await stale.get(hall.origin + "/api/state")).json()).profile,
    ).toBeNull();
    expect((await stale.get(hall.origin + "/api/dining-history")).ok()).toBe(
      false,
    );
    const retried = await stale.post(hall.origin + "/api/commands", {
      headers: originHeaders,
      data: command,
    });
    expect(await retried.json()).toEqual({ error: "unauthenticated" });
  } finally {
    await stale.dispose();
  }

  await page.getByLabel("Language / 言語").selectOption("ja");
  await expect(page.locator("html")).toHaveAttribute("lang", "ja");
  const loadedFaces = await page.evaluate(async () => {
    const faces = await document.fonts.load(
      '400 16px "Noto Sans JP"',
      "日本語",
    );
    return faces.filter((font) => font.status === "loaded").length;
  });
  expect(loadedFaces).toBeGreaterThan(0);
});
