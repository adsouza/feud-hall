// Runs one CI shard of the browser suite: `bun run ./test/browser/run-shard.ts 3/6`.
// Playwright's --shard takes contiguous runs of tests, which keeps each slow hall
// file in one shard. This deals test locations round-robin instead, so every
// shard gets a share of each file. Extra arguments go to `playwright test`.
import { spawnSync } from "node:child_process";
import { join, relative } from "node:path";
import type { JSONReport, JSONReportSuite } from "@playwright/test/reporter";

const [current, total] = (process.argv[2] ?? "").split("/").map(Number);
if (
  !Number.isInteger(current) ||
  !Number.isInteger(total) ||
  total < 1 ||
  current < 1 ||
  current > total
) {
  console.error("usage: bun run ./test/browser/run-shard.ts <current>/<total>");
  process.exit(2);
}
const extra = process.argv.slice(3);
const playwright = join(process.cwd(), "node_modules", ".bin", "playwright");

const listed = spawnSync(playwright, ["test", "--list", "--reporter=json"], {
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
  stdio: ["ignore", "pipe", "inherit"],
});
if (listed.status !== 0) process.exit(listed.status ?? 1);
const report = JSON.parse(listed.stdout) as JSONReport;

// Tests declared on one line (a loop) share a location and stay together.
const locations: string[] = [];
const visit = (suite: JSONReportSuite) => {
  for (const spec of suite.specs) {
    const file = relative(
      process.cwd(),
      join(report.config.rootDir, spec.file),
    );
    const location = `${file}:${spec.line}`;
    if (!locations.includes(location)) locations.push(location);
  }
  suite.suites?.forEach(visit);
};
report.suites.forEach(visit);

const mine = locations.filter((_, i) => i % total === current - 1);
console.log(
  `shard ${current}/${total}: ${mine.length} of ${locations.length} test locations`,
);
if (mine.length === 0) process.exit(0);

const run = spawnSync(playwright, ["test", ...mine, ...extra], {
  stdio: "inherit",
});
process.exit(run.status ?? 1);
