import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./test/browser",
  workers: 1,
  timeout: 45_000,
  forbidOnly: !!process.env.CI,
  // Per-test durations in CI logs show whether the shards stay balanced.
  reporter: process.env.CI ? [["list"], ["github"]] : "list",
  use: {
    browserName: "chromium",
    trace: "retain-on-failure",
  },
});
