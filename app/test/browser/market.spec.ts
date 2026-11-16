import type { Locator, Page, Route } from "@playwright/test";
import type { PurchaseOutcome, View } from "../../src/api";
import { contentLabel, label, type Key } from "../../src/i18n";
import { defaultLimit } from "../../src/market-cart";
import { goodFor } from "../../src/market-goods";
import { refusalMessage } from "../../src/refusals";
import { createGuest, expect, state, test } from "./hall";

test.use({
  launch: true,
  viewport: { width: 1440, height: 1000 },
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});

type Command = {
  command_id: string;
  kind: string;
  payload: Record<string, unknown>;
};
type Answer = "accept" | "refuse" | "abort";

const en = (key: Key) => label("en", key);
const name = (id: string) => contentLabel("en", id);
const fill = (text: string, values: Record<string, string | number>) =>
  Object.entries(values).reduce(
    (out, [k, v]) => out.replaceAll(`{${k}}`, String(v)),
    text,
  );

/** Makes WebGL unavailable to the page, as on a machine without it. */
async function withoutWebGL(page: Page) {
  await page.addInitScript(() => {
    const original = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (
      this: HTMLCanvasElement,
      type: string,
      ...rest: unknown[]
    ) {
      if (/webgl/i.test(type)) return null;
      return (original as (...a: unknown[]) => unknown).call(
        this,
        type,
        ...rest,
      );
    } as typeof HTMLCanvasElement.prototype.getContext;
  });
}

/**
 * An owner with one stall, on the Business page. From here on the page's
 * views are served from `current`; every `serve` is a new view with a higher
 * position. Market purchase commands are answered by the test.
 */
async function marketOwner(
  page: Page,
  hall: { origin: string; secret: string },
  options: { route?: boolean } = {},
) {
  await page.clock.install();
  await page.goto(hall.origin);
  await createGuest(page, "Market owner");
  const principal = (await state(page)).profile.account.id;
  const seeded = await page.request.post(hall.origin + "/api/operator/seed", {
    headers: { authorization: "Bearer " + hall.secret },
    data: { command_id: "market-owner", principal },
  });
  expect((await seeded.json()).accepted).toBe(true);
  await page.getByRole("button", { name: "Business", exact: true }).click();
  const locations = (await state(page)).profile.slots;
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(locations[0].stall_id);
  await page
    .getByRole("button", { name: "Reserve stall for ten minutes" })
    .click();
  await page.getByRole("radio", { name: "Tamil", exact: true }).check();
  await page.getByLabel("Restaurant name").fill("Market counter");
  await page.getByRole("button", { name: "Confirm lease" }).click();
  await expect(
    page.getByRole("heading", { name: "Market counter", exact: true }),
  ).toBeVisible();
  const base: View = await state(page);
  const restaurant = base.profile!.restaurant!;
  const starred = restaurant.menu_products ?? [];
  expect(starred.length).toBeGreaterThan(0);
  // A starred product the market sells, with a crate size, at a level above low.
  const products = starred.filter(
    (id) =>
      restaurant.market[id]?.crate && (restaurant.market[id].level ?? 0) >= 300,
  );
  expect(products.length).toBeGreaterThan(1);

  let current = base;
  let views = 0;
  let served = 0;
  const commands: Command[] = [];
  const answers: Answer[] = [];
  /** What the next view says after an accepted purchase request. */
  let onAccepted: (command: Command, view: View) => void = (command, view) => {
    const p = command.payload;
    view.profile!.restaurant!.purchases!.pending = [
      ...view.profile!.restaurant!.purchases!.pending.filter(
        (r) => r.product !== p.product,
      ),
      {
        request_id: "PR:" + command.command_id,
        product: String(p.product),
        qty: Number(p.qty),
        max_price_per_kunit: String(p.max_price_per_kunit),
        submitted_at: view.hall.now,
        automated: false,
      },
    ];
  };

  function next(edit?: (view: View) => void): View {
    const view: View = structuredClone(current);
    view.hall.position = base.hall.position + ++views;
    edit?.(view);
    current = view;
    return view;
  }
  if (options.route !== false) {
    await page.route("**/api/state**", (route) => {
      served++;
      return route.fulfill({ json: current });
    });
    await page.route("**/api/commands", async (route: Route) => {
      const body = route.request().postDataJSON() as Command;
      if (body.kind !== "submit_purchase_request") return route.continue();
      commands.push(body);
      const answer = answers.shift() ?? "accept";
      if (answer === "abort") return route.abort("failed");
      if (answer === "refuse")
        return route.fulfill({
          json: { accepted: false, reason: "insufficient_cash" },
        });
      next((view) => onAccepted(body, view));
      return route.fulfill({ json: { accepted: true } });
    });
  }
  /** Serves a new view and waits until a poll has fetched it. */
  async function serve(edit: (view: View) => void) {
    next(edit);
    const after = served;
    await expect.poll(() => served).toBeGreaterThan(after + 1);
  }
  return {
    base,
    restaurant,
    products,
    commands,
    answers,
    serve,
    setOnAccepted(fn: typeof onAccepted) {
      onAccepted = fn;
    },
  };
}

function panelOf(page: Page) {
  return page.locator("[data-market-panel]");
}
async function chooseVendorOf(panel: Locator, product: string) {
  await panel
    .getByRole("group", { name: en("marketVendors"), exact: true })
    .getByRole("button", {
      name: en(`vendor_${goodFor(product).vendor}` as Key),
      exact: true,
    })
    .click();
}
const addButton = (panel: Locator, product: string) =>
  panel.getByRole("button", {
    name: fill(en("addCrateOf"), { name: name(product) }),
    exact: true,
  });
const cartLine = (panel: Locator, product: string) =>
  panel.locator(`[data-cart-line="${product}"]`);
const wayList = (panel: Locator) =>
  panel.getByRole("list", { name: en("onItsWay"), exact: true });
const limitField = (panel: Locator, product: string) =>
  panel.getByRole("textbox", {
    name: fill(en("priceLimitOf"), { name: name(product) }),
    exact: true,
  });

function outcome(
  command: Command,
  view: View,
  fields: Partial<PurchaseOutcome>,
): PurchaseOutcome {
  return {
    request_id: "PR:" + command.command_id,
    batch: 1,
    at: view.hall.now,
    product: String(command.payload.product),
    requested: Number(command.payload.qty),
    filled: Number(command.payload.qty),
    cost: "0",
    short: 0,
    reason: null,
    ...fields,
  };
}
/** The next view: the request has cleared with this outcome. */
function cleared(command: Command, fields: Partial<PurchaseOutcome>) {
  return (view: View) => {
    const purchases = view.profile!.restaurant!.purchases!;
    purchases.pending = purchases.pending.filter(
      (r) => r.request_id !== "PR:" + command.command_id,
    );
    purchases.recent = [outcome(command, view, fields)];
  };
}

/** Two crates of the product through the list, then "Send order". */
async function sendTwoCrates(
  page: Page,
  owner: Awaited<ReturnType<typeof marketOwner>>,
  product: string,
) {
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  await addButton(panel, product).click();
  await expect(
    cartLine(panel, product).locator("[data-cart-crates]"),
  ).toHaveText("2");
  const before = owner.commands.length;
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(before + 1);
  await expect(panel.getByText(en("cartEmpty"))).toBeVisible();
  return owner.commands[before];
}

test("market: add a crate, send, see it pending, then filled", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const offer = owner.restaurant.market[product];
  const crate = offer.crate!;
  const panel = panelOf(page);
  const host = panel.locator("[data-market-scene]");
  // The scene is drawn only while on screen (Business page lands at the top).
  await host.scrollIntoViewIfNeeded();
  await expect(host.locator("canvas")).toBeVisible();
  await chooseVendorOf(panel, product);
  await expect(host).toHaveAttribute(
    "data-market-vendor",
    goodFor(product).vendor,
  );
  // Starred: the menu uses it.
  await expect(
    panel
      .locator(`[data-market-product="${product}"]`)
      .getByRole("img", { name: en("starredSupply") }),
  ).toBeVisible();
  await addButton(panel, product).click();
  await addButton(panel, product).click();
  const line = cartLine(panel, product);
  await expect(line.locator("[data-cart-crates]")).toHaveText("2");
  await expect(line.locator("[data-cart-qty]")).toHaveText(String(2 * crate));
  const limit = defaultLimit(offer.price);
  await expect(limitField(panel, product)).toHaveValue(limit);
  await expect(host).toHaveAttribute("data-market-cart", "2");

  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  const [sent] = owner.commands;
  expect(sent.payload).toEqual({
    restaurant_id: owner.restaurant.id,
    product,
    qty: 2 * crate,
    max_price_per_kunit: limit,
  });
  await expect(panel.getByText(en("cartEmpty"))).toBeVisible();
  await expect(host).toHaveAttribute("data-market-cart", "0");
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveCount(1);
  await expect(way).toHaveAttribute("data-way-state", "pending");
  await expect(way).toContainText(en("fillsAtNextClearing"));

  await owner.serve(cleared(sent, { cost: "1234" }));
  await expect(way).toHaveAttribute("data-way-state", "filled");
  await expect(way).toContainText(
    fill(en("orderFilled"), { units: 2 * crate, cost: "$12.34" }),
  );
  // The filled crates arrive on the cart, apart from the (empty) draft.
  await expect(host).toHaveAttribute("data-market-arrived", "2");
  await expect(host).toHaveAttribute("data-market-cart", "0");
  // It leaves a minute after it stopped being pending, and so do its crates.
  await page.clock.fastForward(61_000);
  await expect(way).toHaveCount(0);
  await expect(host).toHaveAttribute("data-market-arrived", "0");
  expect(owner.commands).toHaveLength(1);
});

test("market: a short fill says how much arrived and why", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const crate = owner.restaurant.market[product].crate!;
  const host = panelOf(page).locator("[data-market-scene]");
  const sent = await sendTwoCrates(page, owner, product);
  // One crate and one unit of the next arrived; the rest did not.
  const filled = crate + 1;
  await owner.serve(
    cleared(sent, {
      requested: 2 * crate,
      filled,
      short: 2 * crate - filled,
      cost: "300",
      reason: "stock_exhausted",
    }),
  );
  const way = wayList(panelOf(page)).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "short");
  await expect(way).toContainText(
    fill(en("orderShort"), {
      arrived: filled,
      missing: 2 * crate - filled,
      reason: refusalMessage("en", "stock_exhausted"),
    }),
  );
  await expect(host).toHaveAttribute(
    "data-market-arrived",
    String(Math.ceil(filled / crate)),
  );
});

test("market: a price above the limit is noted before sending and comes back rejected", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const price = owner.restaurant.market[product].price;
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  const field = limitField(panel, product);
  await field.fill(price);
  const note = cartLine(panel, product).locator(
    '[data-cart-note="price_above_limit"]',
  );
  await expect(note).toHaveCount(0);
  // The published price moves above the limit the owner set.
  const risen = String(BigInt(price) + 50n);
  await owner.serve((view) => {
    view.profile!.restaurant!.market[product].price = risen;
  });
  await expect(note).toHaveText(en("notePriceAboveLimit"));
  await expect(field).toHaveValue(price);
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  const [sent] = owner.commands;
  expect(sent.payload.max_price_per_kunit).toBe(price);
  await owner.serve(
    cleared(sent, {
      filled: 0,
      short: Number(sent.payload.qty),
      reason: "price_above_limit",
    }),
  );
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "rejected");
  await expect(way).toContainText(
    fill(en("orderRejected"), {
      reason: refusalMessage("en", "price_above_limit"),
    }),
  );
  await expect(panel.locator("[data-market-scene]")).toHaveAttribute(
    "data-market-arrived",
    "0",
  );
});

test("market: a rival's fill appears as an unlabelled shopper", async ({
  page,
  hall,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  const host = panel.locator("[data-market-scene]");
  // The scene is drawn only while on screen (Business page lands at the top).
  await host.scrollIntoViewIfNeeded();
  await expect(host.locator("canvas")).toBeVisible();
  await owner.serve((view) => {
    view.hall.market_trips = [];
  });
  await expect(host).toHaveAttribute("data-market-shoppers", "0");
  const rivalName = "Rival Noodle Bar";
  const template = owner.base.hall.stalls[0];
  await owner.serve((view) => {
    view.hall.stalls.push({
      ...template,
      stall_id: "rival-stall",
      restaurant_id: "rival-r",
      name: rivalName,
    });
    view.hall.market_trips = [
      {
        batch: 9001,
        restaurant_id: "rival-r",
        products: [product],
        size: "large",
      },
      {
        batch: 9001,
        restaurant_id: owner.restaurant.id,
        products: [product],
        size: "small",
      },
    ];
  });
  // The owner's own trip adds no shopper.
  await expect(host).toHaveAttribute("data-market-shoppers", "1");
  const text = await panel.innerText();
  expect(text).not.toContain(rivalName);
  expect(text).not.toMatch(/large/i);
  // Point across the picture until a shopper is under the pointer.
  const found = await host.evaluate(async (element) => {
    const canvas = element.querySelector("canvas")!;
    const region = document.querySelector(".market-rival")!;
    const box = canvas.getBoundingClientRect();
    for (let y = 8; y < box.height; y += 10)
      for (let x = 8; x < box.width; x += 10) {
        canvas.dispatchEvent(
          new PointerEvent("pointermove", {
            clientX: box.left + x,
            clientY: box.top + y,
            buttons: 0,
            bubbles: true,
          }),
        );
        await new Promise<void>((resolve) => queueMicrotask(resolve));
        if (region.textContent?.trim()) return region.textContent.trim();
      }
    return "";
  });
  expect(found).toBe(fill(en("rivalShopping"), { name: rivalName }));
  await expect(panel.locator(".market-rival")).toHaveAttribute(
    "aria-live",
    "polite",
  );
  // Nothing else about the rival appears anywhere.
  const after = await panel.innerText();
  expect(after.split(rivalName)).toHaveLength(2);
  expect(after).not.toMatch(/large/i);
});

test("market: the list works with the scene unavailable", async ({
  page,
  hall,
}) => {
  await withoutWebGL(page);
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  await expect(panel.getByText(en("marketListOnly"))).toBeVisible();
  await expect(panel.locator("canvas")).toHaveCount(0);
  await expect(panel.locator("[data-market-scene]")).toHaveCount(0);
  // No cart picture, so no green-lid entry in the legend.
  await expect(panel.locator(".market-legend")).toContainText(en("legendLow"));
  await expect(panel.locator(".market-legend")).not.toContainText(
    en("legendArrived"),
  );
  const sent = await sendTwoCrates(page, owner, product);
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "pending");
  await owner.serve(cleared(sent, { cost: "999" }));
  await expect(way).toHaveAttribute("data-way-state", "filled");
});

test("market: a scene failure switches to the list and says so", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const panel = panelOf(page);
  const canvas = panel.locator("[data-market-scene] canvas");
  await panel.locator("[data-market-scene]").scrollIntoViewIfNeeded();
  await expect(canvas).toBeVisible();
  await canvas.dispatchEvent("webglcontextlost", { cancelable: true });
  await expect(panel.locator("[data-market-scene]")).toHaveCount(0);
  await expect(panel.getByText(en("marketSceneFailed"))).toHaveCount(1);
  await chooseVendorOf(panel, owner.products[0]);
  await expect(addButton(panel, owner.products[0])).toBeEnabled();
});

test("market: the star note shows once, fades, and the legend stays", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const panel = panelOf(page);
  const note = panel.getByRole("status").filter({ hasText: en("starNote") });
  await expect(note).toHaveCount(1);
  // The note never takes focus.
  expect(
    await page.evaluate(() => document.activeElement?.closest(".market-note")),
  ).toBeNull();
  expect(
    await page.evaluate(() => localStorage.getItem("feudhall.market.starNote")),
  ).toBe("1");
  await page.clock.fastForward(9000);
  await expect(panel.getByText(en("starNote"))).toHaveCount(0);
  const legend = panel.locator(".market-legend");
  for (const key of [
    "starredSupply",
    "legendArrived",
    "legendLow",
    "legendEmpty",
    "legendFrozen",
    "legendValue",
    "legendShelf",
  ] as Key[])
    await expect(legend).toContainText(en(key));
  // The star in the list says the same, as its name and its title.
  await chooseVendorOf(panel, owner.products[0]);
  const star = panel
    .locator(`[data-market-product="${owner.products[0]}"]`)
    .getByRole("img", { name: en("starredSupply"), exact: true });
  await expect(star).toHaveAttribute("title", en("starredSupply"));
  // Not shown again on this device.
  await page.reload();
  await expect(panelOf(page)).toBeVisible();
  await expect(panelOf(page).locator(".market-legend")).toBeVisible();
  await page.waitForTimeout(500);
  await expect(panelOf(page).getByText(en("starNote"))).toHaveCount(0);
});

test("market: a refresh keeps the cart and an edited limit", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product, other] = owner.products;
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  const field = limitField(panel, product);
  await field.fill("");
  await field.pressSequentially("123");
  await field.dispatchEvent("compositionstart");
  for (let i = 1; i <= 2; i++)
    await owner.serve((view) => {
      const market = view.profile!.restaurant!.market;
      market[product].price = String(BigInt(market[product].price) + 7n);
    });
  await expect(field).toBeFocused();
  await expect(field).toHaveValue("123");
  await field.dispatchEvent("compositionend");
  await expect(
    cartLine(panel, product).locator("[data-cart-crates]"),
  ).toHaveText("1");
  await expect(
    panel
      .getByRole("group", { name: en("marketVendors") })
      .getByRole("button", { pressed: true }),
  ).toHaveText(en(`vendor_${goodFor(product).vendor}` as Key));
  // Another product's unedited limit follows the price.
  await chooseVendorOf(panel, other);
  await addButton(panel, other).click();
  const risen = String(BigInt(owner.restaurant.market[other].price) * 2n);
  await owner.serve((view) => {
    view.profile!.restaurant!.market[other].price = risen;
  });
  await expect(limitField(panel, other)).toHaveValue(defaultLimit(risen));
  await expect(field).toHaveValue("123");
});

test("market: leaving the Supply section and coming back keeps the cart", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  await addButton(panel, product).click();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(panel).toHaveCount(0);
  await page.getByRole("button", { name: "Business", exact: true }).click();
  await expect(
    cartLine(panel, product).locator("[data-cart-crates]"),
  ).toHaveText("2");
  await expect(addButton(panel, product)).toBeVisible();
});

test("market: an uncertain send stays unconfirmed under its command ID until the retry", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [first, second] = owner.products;
  const panel = panelOf(page);
  await chooseVendorOf(panel, first);
  await addButton(panel, first).click();
  await chooseVendorOf(panel, second);
  await addButton(panel, second).click();
  owner.answers.push("abort");
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveCount(1);
  await expect(way).toHaveAttribute("data-way-state", "unconfirmed");
  await expect(way).toContainText(en("orderUnconfirmed"));
  await expect(way).toContainText(name(first));
  // Sending stopped: the other line stays in the cart, the first left it.
  await expect(cartLine(panel, second)).toBeVisible();
  await expect(cartLine(panel, first)).toHaveCount(0);
  const retry = page.getByRole("button", { name: en("retry"), exact: true });
  await expect(retry).toBeEnabled({ timeout: 10_000 });
  expect(owner.commands).toHaveLength(1);
  await retry.click();
  await expect.poll(() => owner.commands.length).toBe(2);
  expect(owner.commands[1].command_id).toBe(owner.commands[0].command_id);
  expect(owner.commands[1].payload).toEqual(owner.commands[0].payload);
  await expect(way).toHaveAttribute("data-way-state", "pending");
  await expect(way).toContainText(en("fillsAtNextClearing"));
  await expect(cartLine(panel, second)).toBeVisible();
  await page.waitForTimeout(1500);
  expect(owner.commands).toHaveLength(2);
});

test("market: a product with a pending request says it replaces it, and shows one line", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  await owner.serve((view) => {
    view.profile!.restaurant!.purchases!.pending = [
      {
        request_id: "PR:earlier",
        product,
        qty: 100,
        max_price_per_kunit: owner.restaurant.market[product].price,
        submitted_at: view.hall.now,
        automated: false,
      },
    ];
  });
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  await expect(
    cartLine(panel, product).locator('[data-cart-note="replaces_pending"]'),
  ).toHaveText(en("noteReplacesPending"));
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveCount(1);
  await expect(way).toHaveAttribute("data-way-state", "pending");
});

test("market: a click on a container in the picture adds a crate", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  const host = panel.locator("[data-market-scene]");
  // The scene is drawn only while on screen (Business page lands at the top).
  await host.scrollIntoViewIfNeeded();
  await expect(host.locator("canvas")).toBeVisible();
  await chooseVendorOf(panel, product);
  await addButton(panel, product).focus();
  // Focusing the row scrolls the list; the picture draws only on screen.
  await host.scrollIntoViewIfNeeded();
  await expect(host).toHaveAttribute(
    "data-market-hit",
    new RegExp(`^${product}:\\d+,\\d+$`),
    { timeout: 15_000 },
  );
  const hit = (await host.getAttribute("data-market-hit"))!;
  const [x, y] = hit.split(":")[1].split(",").map(Number);
  // Focusing the row scrolled the page; the point is relative to the canvas.
  await host.scrollIntoViewIfNeeded();
  const box = (await host.locator("canvas").boundingBox())!;
  expect(box.y + y).toBeGreaterThan(0);
  expect(box.y + y).toBeLessThan(1000);
  await page.mouse.click(box.x + x, box.y + y);
  await expect(
    cartLine(panel, product).locator("[data-cart-crates]"),
  ).toHaveText("1");
  await expect(host).toHaveAttribute("data-market-cart", "1");
  expect(owner.commands).toHaveLength(0);
});

test("market: the hall's Stock panel opens the market", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall, { route: false });
  const stall = owner.restaurant.stalls[0].id;
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Location", exact: true })
    .selectOption(stall);
  await page
    .getByRole("button", { name: "Focus on the hall", exact: true })
    .click();
  await page
    .locator(".hall-scene-pane")
    .getByRole("group", { name: "Stall actions", exact: true })
    .getByRole("button", { name: "Stock", exact: true })
    .click();
  const workbench = page.getByRole("region", {
    name: "Stall actions",
    exact: true,
  });
  // The text panel keeps its controls and gains the link.
  await expect(
    workbench.getByRole("button", { name: "Request purchase", exact: true }),
  ).toBeVisible();
  await workbench
    .getByRole("button", { name: en("openMarket"), exact: true })
    .click();
  const panel = panelOf(page);
  await expect(panel).toBeVisible();
  await expect(
    page.locator('[data-business-section="supply"]'),
  ).toBeInViewport();
  await expect(panel.locator("[data-market-scene] canvas")).toBeVisible();
  await expect(
    panel.getByRole("heading", { name: en("market"), exact: true }),
  ).toBeFocused();
});

test("market: every market string exists in Japanese", async ({
  page,
  hall,
}) => {
  const keys: Key[] = [
    "market",
    "marketVendors",
    "marketListOnly",
    "marketSceneFailed",
    "wholeMarket",
    "pickVendor",
    "addCrate",
    "crateOf",
    "perThousand",
    "priceUnavailable",
    "stockLevel",
    "lowStock",
    "outOfStock",
    "starredSupply",
    "starNote",
    "marketDismiss",
    "variant_frozen",
    "variant_value",
    "variant_shelf",
    "cart",
    "cartEmpty",
    "crates",
    "oneMoreCrate",
    "oneFewerCrate",
    "priceLimit",
    "estimate",
    "sendOrder",
    "emptyCart",
    "onItsWay",
    "fillsAtNextClearing",
    "orderUnconfirmed",
    "orderFilled",
    "orderShort",
    "orderRejected",
    "orderSettled",
    "orderSent",
    "noteReplacesPending",
    "notePriceAboveLimit",
    "noteMoreThanStock",
    "openMarket",
    "rivalShopping",
    "legend",
    "legendArrived",
    "legendLow",
    "legendEmpty",
    "legendFrozen",
    "legendValue",
    "legendShelf",
    "addCrateOf",
    "priceLimitOf",
    "dismissLineOf",
    "removeLineOf",
    "removeLine",
    "cartLineUnavailable",
    "limitInvalid",
    "marketAutomatic",
  ];
  const placeholders = (text: string) =>
    [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
  const problems: string[] = [];
  for (const key of keys) {
    const ja = label("ja", key);
    if (!ja || ja === label("en", key)) problems.push(key);
    if (placeholders(ja).join() !== placeholders(label("en", key)).join())
      problems.push(key + " placeholders");
  }
  for (const code of [
    "price_above_limit",
    "insufficient_cash",
    "insufficient_storage",
    "stock_exhausted",
  ])
    if (
      refusalMessage("ja", code) === refusalMessage("ja", "unknown_rejection")
    )
      problems.push(code);
  expect(problems).toEqual([]);

  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  await page.getByLabel("Language / 言語").selectOption("ja");
  const panel = panelOf(page);
  await expect(
    panel.getByRole("heading", { name: label("ja", "market"), exact: true }),
  ).toBeVisible();
  await panel
    .getByRole("group", { name: label("ja", "marketVendors"), exact: true })
    .getByRole("button", {
      name: label("ja", `vendor_${goodFor(product).vendor}` as Key),
      exact: true,
    })
    .click();
  await panel
    .getByRole("button", {
      name: fill(label("ja", "addCrateOf"), {
        name: contentLabel("ja", product),
      }),
      exact: true,
    })
    .click();
  const text = await panel.innerText();
  const english = keys
    .map((key) => label("en", key))
    .filter((value) => !value.includes("{"))
    .filter((value) => text.includes(value));
  expect(english).toEqual([]);
  await expect(panel).toContainText(label("ja", "cart"));
  await expect(panel).toContainText(label("ja", "legendShelf"));
});

test("market: a malformed price or a missing crate cannot be added, and nothing breaks", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [broken, older] = owner.products;
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const panel = panelOf(page);
  await chooseVendorOf(panel, broken);
  await addButton(panel, broken).click();
  await expect(cartLine(panel, broken)).toBeVisible();
  await owner.serve((view) => {
    const market = view.profile!.restaurant!.market;
    market[broken].price = "12.5";
    delete market[older].crate;
    delete market[older].level;
    delete view.profile!.restaurant!.purchases;
  });
  const row = panel.locator(`[data-market-product="${broken}"]`);
  await expect(row).toContainText(en("priceUnavailable"));
  await expect(addButton(panel, broken)).toBeDisabled();
  // The line whose price became unusable stays in the cart, shown as unavailable.
  await expect(cartLine(panel, broken)).toHaveAttribute(
    "data-cart-unavailable",
    "",
  );
  await expect(cartLine(panel, broken)).toContainText(
    en("cartLineUnavailable"),
  );
  await chooseVendorOf(panel, older);
  const olderRow = panel.locator(`[data-market-product="${older}"]`);
  await expect(olderRow).toContainText(name(older));
  await expect(addButton(panel, older)).toBeDisabled();
  await expect(olderRow.getByRole("meter")).toHaveCount(0);

  // Without purchases the panel cannot know the outcome: it says only "sent",
  // and the line leaves a minute later.
  const usable = owner.products[2];
  expect(usable).toBeDefined();
  owner.setOnAccepted(() => {});
  await chooseVendorOf(panel, usable);
  await addButton(panel, usable).click();
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  // The unavailable line was skipped and is still in the cart.
  expect(owner.commands[0].payload.product).toBe(usable);
  await expect(cartLine(panel, broken)).toBeVisible();
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveCount(1);
  await expect(way).toHaveAttribute("data-way-state", "sent");
  await expect(way).toContainText(en("orderSent"));
  await expect(way).not.toContainText(en("fillsAtNextClearing"));
  await page.clock.fastForward(61_000);
  await expect(way).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("market: after a reload a pending request is still on its way", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const sent = await sendTwoCrates(page, owner, product);
  const way = wayList(panelOf(page)).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "pending");
  await page.reload();
  const after = wayList(panelOf(page)).getByRole("listitem");
  await expect(after).toHaveCount(1);
  await expect(after).toHaveAttribute("data-way-state", "pending");
  await expect(after).toHaveAttribute(
    "data-way-request",
    "PR:" + sent.command_id,
  );
  await expect(after).toContainText(name(product));
  // Its outcome is shown when it clears, though this page never sent it.
  await owner.serve(
    cleared(sent, { filled: 0, short: 10, reason: "insufficient_cash" }),
  );
  await expect(after).toHaveAttribute("data-way-state", "rejected");
});

test("market: a price rejection and an automatic order sent elsewhere are shown", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product, other] = owner.products;
  await owner.serve((view) => {
    const purchases = view.profile!.restaurant!.purchases!;
    purchases.pending = [
      {
        request_id: "PR:restock",
        product: other,
        qty: 500,
        max_price_per_kunit: owner.restaurant.market[other].price,
        submitted_at: view.hall.now,
        automated: true,
      },
    ];
    purchases.recent = [
      {
        request_id: "PR:other-device",
        batch: 3,
        at: view.hall.now,
        product,
        requested: 400,
        filled: 0,
        cost: "0",
        short: 400,
        reason: "price_above_limit",
        automated: false,
      },
    ];
  });
  const way = wayList(panelOf(page));
  const rejected = way.locator('[data-way-request="PR:other-device"]');
  await expect(rejected).toHaveAttribute("data-way-state", "rejected");
  await expect(rejected).toContainText(
    fill(en("orderRejected"), {
      reason: refusalMessage("en", "price_above_limit"),
    }),
  );
  await expect(rejected).not.toHaveAttribute("data-way-automated");
  const automatic = way.locator('[data-way-request="PR:restock"]');
  await expect(automatic).toHaveAttribute("data-way-state", "pending");
  await expect(automatic).toHaveAttribute("data-way-automated", "");
  await expect(automatic).toContainText(en("marketAutomatic"));
  expect(owner.commands).toHaveLength(0);
});

test("market: an order from the text form appears under On its way", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const form = page
    .locator('[data-business-section="supply"] form')
    .filter({ has: page.getByRole("combobox", { name: "Product" }) });
  await form
    .getByRole("combobox", { name: "Product", exact: true })
    .selectOption(product);
  await form.getByRole("spinbutton", { name: "Quantity" }).fill("120");
  await form
    .getByRole("textbox", { name: "Maximum price per 1,000 units (cents)" })
    .fill("99999");
  await form
    .getByRole("button", { name: "Request purchase", exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  const line = wayList(panelOf(page)).getByRole("listitem");
  await expect(line).toHaveCount(1);
  await expect(line).toHaveAttribute("data-way-state", "pending");
  await expect(line).toHaveAttribute(
    "data-way-request",
    "PR:" + owner.commands[0].command_id,
  );
});

test("market: two sends of one product show one line and never 'settled'", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  // Record every state the list shows, between polls too.
  await page.evaluate(() => {
    const seen: string[] = [];
    (window as unknown as { wayStates: string[] }).wayStates = seen;
    const record = () => {
      const items = document.querySelectorAll(
        "[data-market-panel] .market-way li",
      );
      seen.push(
        [...items]
          .map((li) => {
            const data = (li as HTMLElement).dataset;
            return `${data.wayRequest}=${data.wayState}`;
          })
          .join(","),
      );
    };
    new MutationObserver(record).observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["data-way-state", "data-way-request"],
    });
  });
  const first = await sendTwoCrates(page, owner, product);
  const way = wayList(panel).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "pending");
  const second = await sendTwoCrates(page, owner, product);
  expect(second.command_id).not.toBe(first.command_id);
  await expect(way).toHaveCount(1);
  await expect(way).toHaveAttribute(
    "data-way-request",
    "PR:" + second.command_id,
  );
  await expect(way).toHaveAttribute("data-way-state", "pending");
  // A few more polls: still one line.
  await owner.serve(() => {});
  await expect(way).toHaveCount(1);
  const states = await page.evaluate(
    () => (window as unknown as { wayStates: string[] }).wayStates,
  );
  expect(states.filter((s) => s.includes(","))).toEqual([]);
  expect(states.filter((s) => s.includes("settled"))).toEqual([]);
  expect(states.length).toBeGreaterThan(0);
});

test("market: a mistyped price limit is kept, marked, and blocks sending", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  const field = limitField(panel, product);
  await field.fill("2.50");
  const send = panel.getByRole("button", {
    name: en("sendOrder"),
    exact: true,
  });
  // Clicking Send blurs the field first: the text stays, nothing is sent.
  await field.blur();
  await send.click({ force: true });
  await expect(field).toHaveValue("2.50");
  await expect(field).toHaveAttribute("aria-invalid", "true");
  await expect(
    cartLine(panel, product).locator("[data-cart-limit-invalid]"),
  ).toHaveText(en("limitInvalid"));
  await expect(send).toBeDisabled();
  await page.waitForTimeout(500);
  expect(owner.commands).toHaveLength(0);
  await field.fill("250");
  await expect(field).toHaveAttribute("aria-invalid", "false");
  await expect(
    cartLine(panel, product).locator("[data-cart-limit-invalid]"),
  ).toHaveCount(0);
  await send.click();
  await expect.poll(() => owner.commands.length).toBe(1);
  expect(owner.commands[0].payload.max_price_per_kunit).toBe("250");
});

test("market: a line whose offer becomes unusable stays, keeps its limit, and is skipped", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product, other] = owner.products;
  const panel = panelOf(page);
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  await limitField(panel, product).fill("4321");
  await chooseVendorOf(panel, other);
  await addButton(panel, other).click();
  const price = owner.restaurant.market[product].price;
  // The product is gone from one view.
  await owner.serve((view) => {
    delete view.profile!.restaurant!.market[product];
  });
  const line = cartLine(panel, product);
  await expect(line).toHaveAttribute("data-cart-unavailable", "");
  await expect(line).toContainText(en("cartLineUnavailable"));
  // Send skips it: only the other line goes, and it stays in the cart.
  await panel
    .getByRole("button", { name: en("sendOrder"), exact: true })
    .click();
  await expect.poll(() => owner.commands.length).toBe(1);
  expect(owner.commands[0].payload.product).toBe(other);
  await expect(cartLine(panel, other)).toHaveCount(0);
  await expect(line).toBeVisible();
  // Back in the market: usable again with the edited limit.
  await owner.serve((view) => {
    view.profile!.restaurant!.market[product] = {
      ...owner.restaurant.market[product],
      price,
    };
  });
  await expect(line).not.toHaveAttribute("data-cart-unavailable");
  await expect(limitField(panel, product)).toHaveValue("4321");
  // Only the owner removes it.
  await owner.serve((view) => {
    view.profile!.restaurant!.market[product].price = "bad";
  });
  await line
    .getByRole("button", {
      name: fill(en("removeLineOf"), { name: name(product) }),
      exact: true,
    })
    .click();
  await expect(line).toHaveCount(0);
});

test("market: the scene is created only when the Supply section comes on screen", async ({
  page,
  hall,
}) => {
  await marketOwner(page, hall);
  // A fresh load lands on the Business page at the top.
  await page.goto(hall.origin);
  const host = panelOf(page).locator("[data-market-scene]");
  await expect(host).toHaveCount(1);
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  await expect(host).not.toBeInViewport();
  await page.waitForTimeout(1000);
  await expect(host).not.toHaveAttribute("data-market-containers");
  await expect(host.locator("canvas")).toHaveCount(0);
  await host.scrollIntoViewIfNeeded();
  await expect(host).toHaveAttribute("data-market-containers", /^[1-9]\d*$/);
  await expect(host.locator("canvas")).toBeVisible();
});

test("market: the cart reports the crates it draws, up to its cap", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const panel = panelOf(page);
  const host = panel.locator("[data-market-scene]");
  // The scene is drawn only while on screen (Business page lands at the top).
  await host.scrollIntoViewIfNeeded();
  await expect(host.locator("canvas")).toBeVisible();
  await chooseVendorOf(panel, product);
  await addButton(panel, product).click();
  const crates = cartLine(panel, product).locator("[data-cart-crates]");
  // One line draws at most CART_CRATES_PER_LINE (12) crates.
  for (let i = 0; i < 14; i++)
    await cartLine(panel, product)
      .getByRole("button", {
        name: fill(en("oneMoreCrate"), { name: name(product) }),
      })
      .click();
  await expect(crates).toHaveText("15");
  await expect(host).toHaveAttribute("data-market-cart-total", "15");
  await expect(host).toHaveAttribute("data-market-cart", "12");
});
