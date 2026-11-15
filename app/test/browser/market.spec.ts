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
    name: `${en("addCrate")}: ${name(product)}`,
    exact: true,
  });
const cartLine = (panel: Locator, product: string) =>
  panel.locator(`[data-cart-line="${product}"]`);
const wayList = (panel: Locator) =>
  panel.getByRole("list", { name: en("onItsWay"), exact: true });
const limitField = (panel: Locator, product: string) =>
  panel.getByRole("textbox", {
    name: `${en("priceLimit")}: ${name(product)}`,
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
  // It leaves a minute after it stopped being pending.
  await page.clock.fastForward(61_000);
  await expect(way).toHaveCount(0);
  expect(owner.commands).toHaveLength(1);
});

test("market: a short fill says how much arrived and why", async ({
  page,
  hall,
}) => {
  const owner = await marketOwner(page, hall);
  const [product] = owner.products;
  const sent = await sendTwoCrates(page, owner, product);
  await owner.serve(
    cleared(sent, {
      requested: 2000,
      filled: 500,
      short: 1500,
      cost: "300",
      reason: "stock_exhausted",
    }),
  );
  const way = wayList(panelOf(page)).getByRole("listitem");
  await expect(way).toHaveAttribute("data-way-state", "short");
  await expect(way).toContainText(
    fill(en("orderShort"), {
      arrived: 500,
      missing: 1500,
      reason: refusalMessage("en", "stock_exhausted"),
    }),
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
        at: view.hall.now,
        restaurant_id: "rival-r",
        products: [product],
        size: "large",
      },
      {
        batch: 9001,
        at: view.hall.now,
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
  await expect(host.locator("canvas")).toBeVisible();
  await chooseVendorOf(panel, product);
  await addButton(panel, product).focus();
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
    "noteReplacesPending",
    "notePriceAboveLimit",
    "noteMoreThanStock",
    "openMarket",
    "rivalShopping",
    "legend",
    "legendLow",
    "legendEmpty",
    "legendFrozen",
    "legendValue",
    "legendShelf",
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
      name: `${label("ja", "addCrate")}: ${contentLabel("ja", product)}`,
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
  // The line whose price became unusable leaves the cart.
  await expect(cartLine(panel, broken)).toHaveCount(0);
  await chooseVendorOf(panel, older);
  const olderRow = panel.locator(`[data-market-product="${older}"]`);
  await expect(olderRow).toContainText(name(older));
  await expect(addButton(panel, older)).toBeDisabled();
  await expect(olderRow.getByRole("meter")).toHaveCount(0);
  expect(errors).toEqual([]);
});
