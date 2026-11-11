import fc from "fast-check";
import type { Application, View } from "../../src/api";
import { createGuest, expect, state, test } from "./hall";

const applicants = ["Ari", "Bo", "Chika"];
const queue: Application[] = applicants.map((name) => ({
  application_id: "application-" + name,
  name,
  status: "pending",
  proof: { shift_id: "shift-" + name, stall_id: "s001", tasks: 1 },
}));
const trace = fc.record({
  order: fc.shuffledSubarray(applicants, { minLength: 3, maxLength: 3 }),
  notes: fc.tuple(
    fc.constantFrom("Try another shift first.", "もう一度勤務してください。"),
    fc.constantFrom(
      "Please add more detail.",
      "理由をもう少し詳しく書いてください。",
    ),
  ),
  visitAnotherPage: fc.boolean(),
});

test("generated review edits keep each applicant's decision separate", async ({
  browser,
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  await createGuest(page, "Model reviewer");
  const initial: View = await state(page);
  if (!initial.profile) throw new Error("Expected a reviewer profile fixture");
  initial.profile.account["owner?"] = true;
  initial.profile.account["reviewer?"] = true;
  initial.profile.reviewer_queue = queue;

  await fc.assert(
    fc.asyncProperty(trace, async ({ order, notes, visitAnotherPage }) => {
      const context = await browser.newContext({ locale: "en-US" });
      try {
        const reviewer = await context.newPage();
        const snapshot = structuredClone(initial);
        await reviewer.route("**/api/state", (route) =>
          route.fulfill({ json: snapshot }),
        );
        await reviewer.goto(hall.origin);
        const review = reviewer.getByRole("button", {
          name: "Review",
          exact: true,
        });
        await review.click();

        const [target, other, third] = order;
        const card = (name: string) =>
          reviewer.getByRole("article").filter({
            has: reviewer.getByRole("heading", { name, exact: true }),
          });
        const reason = (name: string) =>
          card(name).getByRole("textbox", { name: "Decision reason" });
        const reject = (name: string) =>
          card(name).getByRole("button", { name: "Reject", exact: true });
        const expected = new Map<string, string>();
        const checkDrafts = async (visible: string[]) => {
          for (const name of visible) {
            const draft = expected.get(name) ?? "";
            await expect(reason(name)).toHaveValue(draft, { timeout: 750 });
            if (draft) await expect(reject(name)).toBeEnabled();
            else await expect(reject(name)).toBeDisabled({ timeout: 750 });
          }
        };

        for (const [name, note] of [
          [other, notes[0]],
          [target, notes[1]],
        ]) {
          await reason(name).fill(note);
          expected.set(name, note);
          await checkDrafts(order);
        }

        // Another reviewer completes the untouched application while this
        // reviewer still has two independent drafts.
        snapshot.profile!.reviewer_queue = [target, other].map((name) =>
          queue.find((app) => app.name === name)!,
        );
        snapshot.hall.position++;
        await expect(card(third)).toHaveCount(0);
        if (visitAnotherPage) {
          await reviewer
            .getByRole("button", { name: "Hall", exact: true })
            .click();
          await review.click();
        }
        await checkDrafts([target, other]);

        await reviewer.route("**/api/commands", async (route) => {
          snapshot.profile!.reviewer_queue =
            snapshot.profile!.reviewer_queue.filter(
              (app) => app.name !== target,
            );
          snapshot.hall.position++;
          await route.fulfill({ json: { accepted: true } });
        });
        const command = reviewer.waitForRequest("**/api/commands");
        await reject(target).click();
        expect((await command).postDataJSON()).toMatchObject({
          kind: "review_license_application",
          payload: {
            application_id: "application-" + target,
            decision: "rejected",
            reason: expected.get(target),
          },
        });
        await expect(card(target)).toHaveCount(0);
        await checkDrafts([other]);
      } finally {
        await context.close();
      }
    }),
    {
      numRuns: 6,
      seed: Number(
        process.env.FEUD_HALL_BROWSER_SEED ??
          process.env.GITHUB_RUN_ID ??
          923_114,
      ),
      path: process.env.FEUD_HALL_BROWSER_PATH,
    },
  );
});
