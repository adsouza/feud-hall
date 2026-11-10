import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./test/browser",
  workers: 1,
  timeout: 45_000,
  forbidOnly: !!process.env.CI,
  use: {
    browserName: "chromium",
    trace: "retain-on-failure",
  },
});
