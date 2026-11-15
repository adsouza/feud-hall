import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { expect, test as base } from "@playwright/test";
import type { Page } from "@playwright/test";

const server = fileURLToPath(new URL("../../../server/", import.meta.url));
const run = promisify(execFile);
const script = "test/support/browser_hall.exs";
const replyPrefix = "BROWSER_HALL ";

type Hall = {
  origin: string;
  secret: string;
  control: <T>(message: object) => Promise<T>;
  logs: () => string;
};

export const test = base.extend<{
  hall: Hall;
  restore: boolean;
  launch: boolean;
}>({
  restore: [false, { option: true }],
  launch: [false, { option: true }],
  hall: async ({ restore, launch }, use, testInfo) => {
    const host = process.env.PGHOST ?? "localhost";
    if (host !== "localhost" && host !== "127.0.0.1")
      throw new Error("The browser suite requires local PostgreSQL");

    const secret = randomUUID();
    const database = "feud_hall_browser_" + randomUUID().replaceAll("-", "");
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      MIX_ENV: "test",
      PGHOST: host,
      FEUD_HALL_SERVE: "0",
      FEUD_HALL_TEST_DB: database,
      FEUD_HALL_BROWSER_SECRET: secret,
      FEUD_HALL_BROWSER_LAUNCH: launch ? "1" : "0",
    };
    delete env.DATABASE_URL;
    const mix = (args: string[]) =>
      run("mix", args, { cwd: server, env, timeout: 30_000 });

    let output = "";
    try {
      await mix(["ecto.create", "--quiet"]);
      await mix(["ecto.migrate", "--quiet"]);
      if (restore) await mix(["run", "--no-start", script, "seed-restart"]);

      const process = spawn("mix", ["run", "--no-start", script], {
        cwd: server,
        env,
        stdio: ["pipe", "pipe", "pipe"],
      });
      const exited = once(process, "close");
      // Observe a spawn failure even if it happens before cleanup starts.
      void exited.catch(() => {});
      const capture = (data: Buffer) => {
        output = (output + data.toString()).slice(-32_000);
      };
      process.stdout.on("data", capture);
      process.stderr.on("data", capture);
      process.stdin.on("error", (error) => capture(Buffer.from(error.message)));
      const reader = createInterface({ input: process.stdout });
      const lines = reader[Symbol.asyncIterator]();

      async function read<T>(): Promise<T> {
        for (;;) {
          const line = await lines.next();
          if (line.done)
            throw new Error("Browser hall exited before replying\n" + output);
          if (line.value.startsWith(replyPrefix))
            return JSON.parse(line.value.slice(replyPrefix.length)) as T;
        }
      }

      try {
        const { origin } = await read<{ origin: string }>();
        await use({
          origin,
          secret,
          async control<T>(message: object): Promise<T> {
            process.stdin.write(JSON.stringify(message) + "\n");
            return read<T>();
          },
          logs: () => output,
        });
      } finally {
        reader.close();
        process.stdin.end();
        const stop = setTimeout(() => process.kill("SIGKILL"), 3000);
        try {
          await exited;
        } finally {
          clearTimeout(stop);
        }
      }
    } finally {
      try {
        if (testInfo.status !== testInfo.expectedStatus)
          await testInfo.attach("hall-log", {
            body: output,
            contentType: "text/plain",
          });
      } finally {
        await mix(["ecto.drop", "--quiet"]);
      }
    }
  },
});

export async function createGuest(
  page: Page,
  name: string,
  invitation?: string,
) {
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await page.getByLabel("Display name").fill(name);
  if (invitation)
    await page.getByLabel("Invitation code (optional)").fill(invitation);
  await page.getByRole("button", { name: "Create visitor profile" }).click();
  await expect(
    page
      .getByRole("heading", { name, exact: true })
      .or(page.getByRole("button", { name: "Business", exact: true })),
  ).toBeVisible();
}

export async function state(page: Page) {
  const response = await page.request.get(
    new URL("/api/state", page.url()).href,
  );
  expect(response.ok()).toBe(true);
  return response.json();
}

// Serves the real page with another entry script, as after a deploy that
// changed the client code.
export async function serveNewerClient(page: Page, origin: string) {
  await page.route(new URL("/", origin).href, async (route) => {
    const response = await route.fetch();
    const original = await response.text();
    const body = original.replace(
      /src="\/assets\/index-[^"]+\.js"/,
      'src="/assets/index-newer.js"',
    );
    expect(body).not.toBe(original);
    await route.fulfill({ response, body });
  });
}

export { expect };
