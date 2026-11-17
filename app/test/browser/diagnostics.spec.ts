import { readFileSync } from "node:fs";
import { test, expect, type Page } from "@playwright/test";

const source = readFileSync(
  new URL("../../src-tauri/src/diagnostics.js", import.meta.url),
  "utf8",
);
type Crumb = { kind: string; [field: string]: unknown };
type Probe = Window & {
  crumbs: Crumb[];
  calls: number;
  rejectAll: boolean;
};
const driver = `
  window.crumbs = []; window.calls = 0; window.rejectAll = false;
  window.__TAURI_INTERNALS__ = { invoke(command, args) {
    if (command !== "diagnostic_breadcrumb") throw new Error("Unexpected native command");
    window.calls++;
    if (window.rejectAll) return Promise.reject(new Error("IPC down"));
    window.crumbs.push(args.crumb);
    return Promise.resolve();
  }};
`;

async function open(page: Page) {
  await page.context().route("http://feud-diagnostics.test/**", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<meta charset="UTF-8"><label>Draft <input value="日本語秘密テキスト"></label><p id="text">Plain words to select here</p>`,
    }),
  );
  await page.context().addInitScript({ content: driver + source });
  await page.goto("http://feud-diagnostics.test/");
}
const crumbs = (page: Page) =>
  page.evaluate(() => (window as unknown as Probe).crumbs);
const ofKind = async (page: Page, kind: string) =>
  (await crumbs(page)).filter((crumb) => crumb.kind === kind);

test("diagnostics: copy sends kind only, never the copied text", async ({
  page,
}) => {
  await open(page);
  await page.getByRole("textbox", { name: "Draft" }).selectText();
  await page.evaluate(() =>
    document.dispatchEvent(new ClipboardEvent("copy", { bubbles: true })),
  );
  await expect.poll(async () => (await ofKind(page, "copy")).length).toBe(1);
  expect((await ofKind(page, "copy"))[0]).toEqual({ kind: "copy" });
  expect(JSON.stringify(await crumbs(page))).not.toContain("秘密");
});

test("diagnostics: selection sends its length once per new selection", async ({
  page,
}) => {
  await open(page);
  const select = (from: number, to: number) =>
    page.evaluate(
      ([from, to]) => {
        const text = document.querySelector("#text")!.firstChild!;
        const range = document.createRange();
        range.setStart(text, from);
        range.setEnd(text, to);
        getSelection()!.removeAllRanges();
        getSelection()!.addRange(range);
      },
      [from, to],
    );
  await select(0, 5);
  await expect
    .poll(() => ofKind(page, "selection"))
    .toEqual([{ kind: "selection", length: 5 }]);
  await select(0, 11);
  await page.waitForTimeout(200);
  expect(await ofKind(page, "selection")).toHaveLength(1);
  await page.evaluate(() => getSelection()!.removeAllRanges());
  await page.waitForTimeout(100);
  await select(6, 11);
  await expect
    .poll(() => ofKind(page, "selection"))
    .toEqual([
      { kind: "selection", length: 5 },
      { kind: "selection", length: 5 },
    ]);
  expect(JSON.stringify(await crumbs(page))).not.toContain("Plain");
});

test("diagnostics: uncaught errors are reported truncated", async ({
  page,
}) => {
  await open(page);
  await page.evaluate(() =>
    setTimeout(() => {
      throw new Error("x".repeat(1000));
    }),
  );
  await expect.poll(async () => (await ofKind(page, "error")).length).toBe(1);
  const [error] = await ofKind(page, "error");
  expect(typeof error.message).toBe("string");
  expect((error.message as string).length).toBeLessThanOrEqual(300);
  expect(typeof error.line).toBe("number");
  expect(typeof error.file).toBe("string");
});

test("diagnostics: its own failed invoke does not loop", async ({ page }) => {
  await open(page);
  await page.waitForTimeout(1500);
  await page.evaluate(() => {
    const probe = window as unknown as Probe;
    probe.rejectAll = true;
    probe.calls = 0;
  });
  await page.evaluate(() =>
    document.dispatchEvent(new ClipboardEvent("copy", { bubbles: true })),
  );
  await page.waitForTimeout(500);
  expect(await page.evaluate(() => (window as unknown as Probe).calls)).toBe(1);
  expect(await ofKind(page, "rejection")).toEqual([]);
});

test("diagnostics: the GPU is reported at most once", async ({ page }) => {
  await open(page);
  const webgl = await page.evaluate(
    () =>
      !!document
        .createElement("canvas")
        .getContext("webgl")
        ?.getExtension("WEBGL_debug_renderer_info"),
  );
  if (webgl)
    await expect.poll(async () => (await ofKind(page, "gpu")).length).toBe(1);
  await page.waitForTimeout(1000);
  const gpu = await ofKind(page, "gpu");
  expect(gpu.length).toBe(webgl ? 1 : 0);
  for (const crumb of gpu) {
    expect(Object.keys(crumb).sort()).toEqual(["kind", "renderer", "vendor"]);
  }
});
