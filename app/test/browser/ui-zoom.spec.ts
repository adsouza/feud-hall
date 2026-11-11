import { readFileSync } from "node:fs";
import { test, expect, type BrowserContext, type Page } from "@playwright/test";

const source = readFileSync(
  new URL("../../src-tauri/src/zoom.js", import.meta.url),
  "utf8",
);
const key = "feud-hall.ui-zoom.v1";
type Probe = Window & {
  zoomRequested: number[];
  zoomApplied: number[];
  zoomPaused: boolean;
  zoomRejectNext: boolean;
  zoomRelease: (() => void)[];
  cameraWheels: number;
};
const driver = `
  window.zoomRequested = []; window.zoomApplied = []; window.zoomRelease = [];
  window.zoomPaused = false; window.zoomRejectNext = false; window.cameraWheels = 0;
  window.__TAURI_INTERNALS__ = { invoke(command, {value}) {
    if (command !== "plugin:webview|set_webview_zoom") throw new Error("Unexpected native command");
    window.zoomRequested.push(value);
    if (window.zoomRejectNext) { window.zoomRejectNext = false; return Promise.reject(new Error("Native refusal")); }
    return new Promise(resolve => {
      const complete = () => { window.zoomApplied.push(value); resolve(); };
      if (window.zoomPaused) window.zoomRelease.push(complete); else complete();
    });
  }};
`;

async function install(
  context: BrowserContext,
  os: string,
  blockedStorage = false,
) {
  await context.route("http://feud-zoom.test/**", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<meta charset="UTF-8"><label>Draft <input value="日本語"></label><div id="camera">Hall camera</div>
      <script>document.querySelector('#camera').addEventListener('wheel', () => window.cameraWheels++);</script>`,
    }),
  );
  await context.addInitScript({
    content:
      driver +
      (blockedStorage
        ? `Object.defineProperty(window, 'localStorage', {get() {throw new Error('Storage blocked');}});`
        : "") +
      source.replaceAll("__FEUD_OS__", os),
  });
}
async function saved(page: Page, percent: string) {
  await expect
    .poll(() => page.evaluate((key) => localStorage.getItem(key), key))
    .toBe(percent);
}

for (const [os, modifier] of [
  ["macos", "Meta"],
  ["linux", "Control"],
]) {
  test(`${os} zoom survives a browser-process restart and subsequent shortcuts use the restored scale`, async ({
    playwright,
  }, info) => {
    const profile = info.outputPath("zoom-profile");
    async function launch() {
      const context =
        await playwright.chromium.launchPersistentContext(profile);
      await install(context, os);
      const page = context.pages()[0];
      await page.goto("http://feud-zoom.test/");
      await expect
        .poll(() =>
          page.evaluate(() => (window as unknown as Probe).zoomApplied.length),
        )
        .toBe(1);
      return { context, page };
    }
    let { context, page } = await launch();
    try {
      await page.keyboard.press(`${modifier}+=`);
      await page.keyboard.press(`${modifier}+=`);
      await saved(page, "140");
      await context.close();
      ({ context, page } = await launch());
      expect(
        await page.evaluate(() => (window as unknown as Probe).zoomApplied),
      ).toEqual([1.4]);
      await page.getByRole("textbox", { name: "Draft" }).focus();
      await page.keyboard.press(`${modifier}+-`);
      await saved(page, "120");
      await expect(page.getByRole("textbox", { name: "Draft" })).toHaveValue(
        "日本語",
      );
      await expect(page.getByRole("textbox", { name: "Draft" })).toBeFocused();
      await page.keyboard.press(`${modifier}+0`);
      await saved(page, "100");
      await context.close();
      ({ context, page } = await launch());
      expect(
        await page.evaluate(() => (window as unknown as Probe).zoomApplied),
      ).toEqual([1]);
    } finally {
      await context.close();
    }
  });
}

test("rapid zoom requests persist the final acknowledged scale and a refusal does not save a false result", async ({
  page,
}) => {
  await install(page.context(), "macos");
  await page.goto("http://feud-zoom.test/");
  await saved(page, "100");
  await page.evaluate(() => {
    (window as unknown as Probe).zoomPaused = true;
  });
  for (let i = 0; i < 3; i++) await page.keyboard.press("Meta+=");
  expect(
    await page.evaluate(() => (window as unknown as Probe).zoomRequested),
  ).toEqual([1, 1.2]);
  await page.evaluate(() =>
    (window as unknown as Probe).zoomRelease.shift()!(),
  );
  await saved(page, "120");
  await expect
    .poll(() => page.evaluate(() => (window as unknown as Probe).zoomRequested))
    .toEqual([1, 1.2, 1.6]);
  await page.evaluate(() => {
    (window as unknown as Probe).zoomPaused = false;
    (window as unknown as Probe).zoomRelease.shift()!();
  });
  await saved(page, "160");
  await page.evaluate(() => {
    (window as unknown as Probe).zoomRejectNext = true;
  });
  await page.keyboard.press("Meta+=");
  await expect
    .poll(() =>
      page.evaluate(() => (window as unknown as Probe).zoomRequested.at(-1)),
    )
    .toBe(1.8);
  await saved(page, "160");
  await page.keyboard.press("Meta+=");
  await saved(page, "180");
});

test("invalid preferences, limits, IME input and modified wheel input preserve usable controls", async ({
  page,
}) => {
  await install(page.context(), "macos");
  await page.goto("http://feud-zoom.test/");
  for (const raw of ["NaN", "0", "1001", "-20", "100.5", "not-json"]) {
    await page.evaluate(({ key, raw }) => localStorage.setItem(key, raw), {
      key,
      raw,
    });
    await page.reload();
    await saved(page, "100");
    expect(
      await page.evaluate(() => (window as unknown as Probe).zoomApplied),
    ).toEqual([1]);
  }
  for (const [percent, shortcut, scale] of [
    ["20", "Meta+-", 0.2],
    ["1000", "Meta+=", 10],
  ] as const) {
    await page.evaluate(
      ({ key, percent }) => localStorage.setItem(key, percent),
      { key, percent },
    );
    await page.reload();
    await saved(page, percent);
    await page.keyboard.press(shortcut);
    expect(
      await page.evaluate(() => (window as unknown as Probe).zoomApplied),
    ).toEqual([scale]);
  }
  await page.keyboard.press("Meta+0");
  await saved(page, "100");
  await page
    .getByRole("textbox")
    .dispatchEvent("keydown", { key: "+", metaKey: true, isComposing: true });
  await saved(page, "100");
  await page.locator("#camera").dispatchEvent("wheel", {
    deltaY: -120,
    ctrlKey: true,
    bubbles: true,
    cancelable: true,
  });
  await saved(page, "120");
  expect(
    await page.evaluate(() => (window as unknown as Probe).cameraWheels),
  ).toBe(0);
  await page
    .locator("#camera")
    .dispatchEvent("wheel", { deltaY: 120, bubbles: true });
  expect(
    await page.evaluate(() => (window as unknown as Probe).cameraWheels),
  ).toBe(1);
});

test("unavailable preference storage does not disable live zoom", async ({
  page,
}) => {
  await install(page.context(), "linux", true);
  await page.goto("http://feud-zoom.test/");
  await expect
    .poll(() => page.evaluate(() => (window as unknown as Probe).zoomApplied))
    .toEqual([1]);
  await page.keyboard.press("Control+=");
  await expect
    .poll(() => page.evaluate(() => (window as unknown as Probe).zoomApplied))
    .toEqual([1, 1.2]);
});
