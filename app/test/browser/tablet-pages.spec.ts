import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect } from "@playwright/test";

test("long tablet views reveal new errors without repeatedly resetting pagination", async ({
  page,
}, info) => {
  // Bundle the real screen renderer; this presentation-only test needs no hall or database.
  const bundle = info.outputPath("tablet-screen.js");
  mkdirSync(dirname(bundle), { recursive: true });
  execFileSync(
    "bun",
    [
      "build",
      fileURLToPath(new URL("../../src/hall-tablet.ts", import.meta.url)),
      "--target=browser",
      "--format=esm",
      `--outfile=${bundle}`,
    ],
    { timeout: 10000, stdio: "pipe" },
  );
  const source = readFileSync(bundle, "utf8");
  await page.route("http://tablet.test/**", (route) =>
    route.fulfill({
      contentType: route.request().url().endsWith(".js")
        ? "text/javascript"
        : "text/html",
      body: route.request().url().endsWith(".js")
        ? source
        : "<html><body></body></html>",
    }),
  );
  await page.goto("http://tablet.test/");
  const result = await page.evaluate(async () => {
    const moduleUrl = "http://tablet.test/screen.js";
    const { createTabletScreen } = await import(moduleUrl);
    const screen = createTabletScreen(() => {});
    const view = {
      stall: "counter",
      title: "Counter",
      subtitle: "Review order",
      notice: "Balance $12.00",
      rows: Array.from({ length: 12 }, (_, i) => ({
        text: `Item ${i}`,
        action: { kind: "main", id: String(i) },
      })),
      previous: "Previous",
      next: "Next",
      close: "Step back",
    };
    const pick = () => screen.hit(0.5, 240 / 1080);
    screen.update(view);
    screen.key("End", false);
    const lastPage = pick();
    const error = {
      text: "The order could not be accepted. Please try again.",
      error: true,
    };
    const failed = {
      ...view,
      notice: "Please check the message below",
      noticeError: true,
      rows: [error, ...view.rows],
    };
    screen.update(failed);
    const revealed = pick() === undefined;
    screen.key("ArrowRight", false);
    const browsed = pick();
    screen.update({ ...failed, notice: "Updated balance" });
    const afterUpdate = pick();
    screen.update(view);
    screen.update(failed);
    const repeated = pick() === undefined;
    document.body.replaceChildren(screen.material.map.image);
    screen.dispose();
    return { lastPage, revealed, browsed, afterUpdate, repeated };
  });
  expect(result.lastPage).toEqual({ kind: "main", id: "6" });
  expect(result.revealed).toBe(true);
  expect(result.browsed).toEqual({ kind: "main", id: "5" });
  expect(result.afterUpdate).toEqual(result.browsed);
  expect(result.repeated).toBe(true);
});
