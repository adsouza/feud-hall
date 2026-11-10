import type { Page, Route } from "@playwright/test";
import fc from "fast-check";
import type { View } from "../../src/api";
import { createGuest, expect, state, test } from "./hall";

type Edit = "location" | "main" | "drink" | "diet" | "same" | "restore";
type AccessChange = "none" | "cleaning" | "visit" | "sign-out" | "menu";
type Reply = { total: string; earliest_completion: number; terms: object };

const edits: Edit[] = ["location", "main", "drink", "diet", "same", "restore"];
const changes: AccessChange[] = [
  "none",
  "cleaning",
  "visit",
  "sign-out",
  "menu",
];
const timing = {
  latestFirst: false,
  staleRefusal: false,
  latestRefusal: false,
  invalidateEarly: false,
};
type Scenario = { edit: Edit; access: AccessChange } & typeof timing;
const scenario: fc.Arbitrary<Scenario> = fc.record({
  edit: fc.constantFrom(...edits),
  access: fc.constantFrom(...changes),
  latestFirst: fc.boolean(),
  staleRefusal: fc.boolean(),
  latestRefusal: fc.boolean(),
  invalidateEarly: fc.boolean(),
});
function example(
  edit: Edit,
  access: AccessChange,
  overrides: Partial<typeof timing> = {},
): [Scenario] {
  return [{ edit, access, ...timing, ...overrides }];
}
const main = "falafel_wrap";
const otherMain = "chicken_shawarma_wrap";
const drink = "mint_lemonade";

function withMenus(view: View): View {
  const stalls = view.hall.stalls.slice(0, 2).map((stall) => ({
    ...stall,
    "open?": true,
    menu: { [main]: "500", [otherMain]: "600", [drink]: "200" },
  }));
  return { ...view, hall: { ...view.hall, stalls } };
}

async function beginQuote(page: Page, routes: Route[]) {
  const previous = routes.length;
  await page.getByRole("button", { name: "Review order" }).click();
  await expect.poll(() => routes.length).toBe(previous + 1);
  return routes[previous];
}

async function replyToQuote(page: Page, route: Route, reply: Reply | null) {
  const received = page.waitForResponse(
    (response) => response.url() === route.request().url(),
  );
  await route.fulfill(
    reply
      ? { json: reply }
      : { status: 409, json: { error: "profile_not_enabled" } },
  );
  await (await received).finished();
  // Let the fetch continuation and Svelte's render flush finish before checking
  // the absence of an invalid confirmation or refusal.
  await page.evaluate(
    () =>
      new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done())),
      ),
  );
}

test("generated dining edits keep replies attached to their own draft", async ({
  browser,
  page,
  hall,
}) => {
  test.setTimeout(90_000);
  await page.goto(hall.origin);
  await createGuest(page, "Model diner");
  const initial = withMenus(await state(page));
  const [first, second] = initial.hall.stalls.map((stall) => stall.stall_id);
  expect(second).toBeTruthy();
  expect(initial.profile).toBeTruthy();

  await fc.assert(
    fc.asyncProperty(
      scenario,
      async ({
        edit,
        access,
        latestFirst,
        staleRefusal,
        latestRefusal,
        invalidateEarly,
      }) => {
        const context = await browser.newContext({ locale: "en-US" });
        try {
          const diner = await context.newPage();
          let snapshot = structuredClone(initial);
          const quotes: Route[] = [];
          await diner.route("**/api/state", (route) =>
            route.fulfill({ json: snapshot }),
          );
          await diner.route("**/api/quote?*", (route) => {
            quotes.push(route);
          });
          await diner.goto(hall.origin);
          await diner
            .getByRole("button", { name: "My visit", exact: true })
            .click();

          const select = (name: string, value: string) =>
            diner
              .getByRole("combobox", { name, exact: true })
              .selectOption(value);
          await select("Location", first);
          await select("Main", main);
          const old = await beginQuote(diner, quotes);

          const original = {
            stall_id: first,
            main,
            profile_id: "unrestricted",
          };
          const draft: Record<string, string> = { ...original };
          switch (edit) {
            case "location":
              await select("Location", second);
              await select("Main", main);
              draft.stall_id = second;
              break;
            case "main":
              await select("Main", otherMain);
              draft.main = otherMain;
              break;
            case "drink":
              await select("Drink", drink);
              draft.drink = drink;
              break;
            case "diet":
              await select("Dietary profile", "vegetarian");
              draft.profile_id = "vegetarian";
              break;
            case "restore":
              await select("Main", otherMain);
              await select("Main", main);
              break;
            case "same":
              break;
          }
          const latest = await beginQuote(diner, quotes);
          expect(
            Object.fromEntries(new URL(old.request().url()).searchParams),
          ).toEqual(original);
          expect(
            Object.fromEntries(new URL(latest.request().url()).searchParams),
          ).toEqual(draft);

          async function invalidate() {
            snapshot.hall.position++;
            snapshot.hall.now = 3 * 3_600_000;
            switch (access) {
              case "cleaning":
                snapshot.hall.access = "cleaning";
                break;
              case "visit":
                snapshot.profile!.visit = {
                  id: "V:other",
                  stall: second,
                  tray_status: "accepted",
                  dessert: "none",
                };
                break;
              case "sign-out":
                snapshot.profile = null;
                break;
              case "menu":
                delete snapshot.hall.stalls.find(
                  (stall) => stall.stall_id === draft.stall_id,
                )!.menu[draft.main];
                break;
            }
            await expect(diner.locator("header .clock b")).toHaveText("03:00");
          }

          const oldReply = staleRefusal
            ? null
            : {
                total: "701",
                earliest_completion: 360_000,
                terms: { draft: original },
              };
          const newReply = latestRefusal
            ? null
            : { total: "902", earliest_completion: 720_000, terms: { draft } };
          const confirm = diner.getByRole("button", { name: "Confirm order" });
          const settled = expect.configure({ timeout: 750 });
          const check = async (current: boolean) => {
            await settled(
              diner.getByText("$7.01", { exact: true }),
            ).toHaveCount(0);
            await settled(diner.locator(".refusal-notice")).toHaveCount(
              current && latestRefusal ? 1 : 0,
            );
            if (current && newReply) {
              await expect(confirm).toBeEnabled();
              await expect(
                diner.getByText("$9.02", { exact: true }),
              ).toBeVisible();
            } else {
              await settled(confirm).toHaveCount(0);
            }
          };
          const invalidBeforeReply =
            access !== "none" && (invalidateEarly || latestRefusal);
          if (invalidBeforeReply) await invalidate();
          if (latestFirst) {
            await replyToQuote(diner, latest, newReply);
            await check(!invalidBeforeReply);
            await replyToQuote(diner, old, oldReply);
          } else {
            await replyToQuote(diner, old, oldReply);
            await check(false);
            await replyToQuote(diner, latest, newReply);
          }
          await check(!invalidBeforeReply);
          if (access !== "none" && !invalidBeforeReply) {
            await invalidate();
            await check(false);
          }

          if (access === "none" && newReply) {
            const command = diner.waitForRequest("**/api/commands");
            await diner.route("**/api/commands", (route) =>
              route.fulfill({ json: { accepted: true } }),
            );
            await confirm.click();
            expect((await command).postDataJSON()).toMatchObject({
              kind: "admit_visit",
              payload: {
                ...draft,
                drink: draft.drink ?? null,
                confirmed: newReply.terms,
              },
            });
          }
        } finally {
          await context.close();
        }
      },
    ),
    {
      seed: Number(
        process.env.FEUD_HALL_BROWSER_SEED ??
          process.env.GITHUB_RUN_ID ??
          518_431,
      ),
      path: process.env.FEUD_HALL_BROWSER_PATH,
      numRuns: 12,
      examples: [
        example("main", "none", { latestFirst: true }),
        example("drink", "none", { staleRefusal: true }),
        example("diet", "cleaning", {
          invalidateEarly: true,
          latestRefusal: true,
        }),
        example("location", "visit", {
          latestFirst: true,
          invalidateEarly: true,
        }),
        example("main", "sign-out", { invalidateEarly: true }),
        example("drink", "menu", { latestFirst: true }),
        example("same", "none", { latestFirst: true, latestRefusal: true }),
        example("restore", "none"),
      ],
    },
  );
});
