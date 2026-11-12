import { readFileSync } from "node:fs";
import { expect, test } from "./hall";
import { layoutTabletText, splitTabletMessage } from "../../src/tablet-text";

const source = `export const layoutTabletText = ${layoutTabletText.toString()};
export const splitTabletMessage = ${splitTabletMessage.toString()};`;
const cuisines = JSON.parse(
  readFileSync(
    new URL("../../../server/priv/content/launch_menus.json", import.meta.url),
    "utf8",
  ),
);
const labels: string[] = cuisines.flatMap((cuisine: any[]) =>
  cuisine[3].flatMap((recipe: any[]) => [recipe[1], recipe[2]]),
);

test("tablet labels wrap complete dish words and prices with real English/Japanese font metrics", async ({
  page,
  hall,
}) => {
  await page.goto(hall.origin);
  const url = hall.origin + "/__tablet-layout-probe.js";
  await page.route(url, (route) =>
    route.fulfill({ contentType: "text/javascript", body: source }),
  );
  const result = await page.evaluate(
    async ({ url, labels }) => {
      const { layoutTabletText, splitTabletMessage } = await import(url);
      await document.fonts.load('400 36px "Noto Sans JP"', labels.join(""));
      const context = document.createElement("canvas").getContext("2d")!;
      const measure = (text: string, size: number) => {
        context.font = `400 ${size}px "Noto Sans JP", system-ui, sans-serif`;
        return context.measureText(text).width;
      };
      const failure: string[] = [];
      const prices = ["$7.73", "$12.34", "$1,234.56"];
      for (const label of labels)
        for (const price of prices) {
          const text = label + " · " + price;
          const layout = layoutTabletText(text, 648, 36, 2, measure);
          if (
            layout.lines.length > 2 ||
            layout.size < 30 ||
            layout.lines.some(
              (line: string) => measure(line, layout.size) > 648,
            )
          )
            failure.push("overflow: " + text);
          if (!layout.lines.at(-1).endsWith(price))
            failure.push("split price: " + text);
          if (
            layout.lines.join("").replaceAll(/\s/gu, "") !==
            text.replaceAll(/\s/gu, "")
          )
            failure.push("lost text: " + text);
          if (
            !/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(
              label,
            ) &&
            layout.lines.join(" ") !== text
          )
            failure.push("split word: " + text);
        }
      for (const message of [
        "The stall doesn’t have enough of the ingredients allowed for this order.",
        "The server may have committed this command. Retry with its original ID.",
        "This restaurant cannot accept the requested order because another player has already reserved the remaining ingredients. Please choose a different dish.",
        "An ingredient in this order doesn’t meet your selected dietary requirements.",
        "この注文に使用できる食材の在庫が足りません。",
        "この注文には、選択した食事条件に合わない食材が含まれています。",
      ]) {
        const rows: string[] = splitTabletMessage(message);
        const lines: string[] = rows.flatMap(
          (row) => layoutTabletText(row, 648, 36, 2, measure).lines,
        );
        if (
          lines.join("").replaceAll(/\s/gu, "") !==
          message.replaceAll(/\s/gu, "")
        )
          failure.push("lost error text");
        if (
          !/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(
            message,
          ) &&
          lines.join(" ") !== message
        )
          failure.push("split error word");
      }
      const regression = "Vegetable couscous · $12.34";
      const width = measure("Vegetable couscous · $12.", 36);
      const layout = layoutTabletText(regression, width, 36, 2, measure);
      // Draw the same fitted lines used by the screen for a visual regression artifact.
      const canvas = document.createElement("canvas");
      canvas.width = 720;
      canvas.height = 200;
      const output = canvas.getContext("2d")!;
      output.fillStyle = "#253145";
      output.fillRect(0, 0, 720, 200);
      output.fillStyle = "white";
      output.font = `400 ${layout.size}px "Noto Sans JP", system-ui, sans-serif`;
      layout.lines.forEach((line: string, index: number) =>
        output.fillText(line, 36, 55 + index * (layout.size + 5)),
      );
      document.body.replaceChildren(canvas);
      return { failure, lines: layout.lines, size: layout.size };
    },
    { url, labels },
  );
  expect(result.failure).toEqual([]);
  expect(result.lines).toEqual(["Vegetable couscous ·", "$12.34"]);
  expect(result.size).toBe(36);
  await page.screenshot({
    path: test.info().outputPath("tablet-word-wrap.png"),
  });
});
