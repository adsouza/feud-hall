# Supply Market Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make buying supplies something an owner sees and touches: a 3D market of seven vendor stalls on the Business page where clicking a container adds a crate to a cart, the order is sent on request and fills at the next clearing, and rival owners are seen shopping.

**Architecture:** The server keeps a small projection of recent market clearings, folded from committed events beside the existing counter-service projection. From it the owner's private view gains their own pending requests and recent outcomes, and the public view gains, per restaurant, which products filled and a coarse cart size. Each product's crate size and stock level are derived from the catalog and the market and sent with its price. On the client, presentation data maps every product to a vendor, a shape and a colour; a pure cart model turns clicks into `submit_purchase_request` payloads; a Three.js scene draws the market and emits intents; and a Svelte panel holds the scene, a synchronized accessible list and the cart, and submits through the existing use case.

**Tech Stack:** Elixir / Phoenix (view and one projection; no rule, event or command change), Svelte 5, TypeScript, Three.js 0.187, Bun 1.4.4, Playwright with fast-check.

**Spec:** [docs/superpowers/specs/2026-11-13-livelier-hall-design.md](../specs/2026-11-13-livelier-hall-design.md), section "Project 5: Supply market", plus its Goals, Non-goals, Anti-goals and "Existing contracts" sections. Read those and [AGENTS.md](../../../AGENTS.md) before starting any task.

## Global Constraints

- **Nothing is bought until "Send order".** A click adds to a draft cart. The scene and the list emit intents only; `App.svelte`'s existing `submit(kind, payload)` is the one submitting path. No second path for purchases.
- **What is drawn is the real market.** Container fill follows the server's stock level; the tag shows the server's published price; a crate, a filled line or a rival's trip appears only for something the server committed. Animation never implies a purchase that has not been committed.
- **A rival's cart has no labels, quantities or prices.** Pointing at a rival shows the restaurant's name and nothing else. Only the owner's own cart has labels and amounts.
- **What becomes public**, and nothing more: for recent clearings, per restaurant, the product IDs that filled and one of three cart-size buckets. Quantities, costs, prices paid, price limits, pending requests, unfilled amounts and reasons stay private to the owner.
- **No server rule changes.** No event, command, catalog version or stored state is added. New view fields are derived from committed events and state; a query writes nothing.
- Money crosses the wire as canonical decimal integer strings and is never turned into a JavaScript number for arithmetic that is sent back: use `BigInt` or string arithmetic.
- The price limit on a cart line defaults to the published price plus 10%, rounded up to a whole minor unit, and is editable. It is a willingness-to-pay limit, as today.
- One crate size per product, sent by the server and shown on the tag; the client never computes it.
- The existing text purchase form, starter stock, restock automation and pricing policy controls stay as they are. The market is added beside them.
- The market is on the Business page's Supply section. It is not part of the hall's 3D world, and no delivery animation is added to the hall scene.
- The list is the market wherever the scene cannot be: no WebGL, a narrow layout, or a scene failure. Every action in the scene exists in the list and by keyboard.
- The scene renders only while the Supply section is visible.
- The first-visit note about stars is announced politely to assistive technology, never takes focus, fades, and is remembered per device (browser storage, wrapped in try/catch). The star's meaning stays available: on pointing at or focusing a star, and in a legend under the shelves.
- Every new string exists in English and Japanese with a stable key in `app/src/i18n.ts`.
- Looks stay deterministic: a rival shopper's figure is `personLook(serialFor("owner:" + restaurant_id), "owner")`, the same person as at their stall.
- Never run `tsc`. Never run a whole test suite without a file name; run test files one at a time. Cap Node with `NODE_OPTIONS=--max-old-space-size=1536`. Server commands run from `server/`, client commands from `app/`. Check `df -m /System/Volumes/Data | tail -1` before each browser run and stop if under 1000 MB free. Never run two heavy commands at once.
- Never start a server against the database `feud_hall_management`. Do not push.
- Format with `mix format` and Prettier. Commit messages end, after a blank line, with the Co-Authored-By line for the model that wrote the commit.

## Review Focus

Each line names a condition the spec implies and the behaviour a person would expect. The test that pins it is in the task named.

1. **The server restarts, or the owner reconnects, between sending and clearing.** Pending requests come from committed state and are still shown; an outcome the projection no longer has is shown as settled with a pointer to stock, never as still on its way for ever, and never as filled without evidence. (Tasks 1 and 3)
2. **Sending a line for a product that already has a pending request.** The server replaces the pending request; the cart says so before sending and "On its way" shows one line, not two. (Tasks 3 and 6)
3. **A send whose outcome is uncertain** (the response is lost). The line stays pending under its command ID and is resolved by that ID, never sent again under a new one. (Task 6)
4. **A product in the catalog with no presentation entry, and an entry for a product the catalog no longer has.** The first is drawn as a plain crate at the pantry and is buyable; the second is ignored; a check fails for the first so it is noticed. (Task 2)
5. **Prices move between adding a line and sending it.** The line keeps the limit the owner saw (or edited); a published price above it is shown as such before sending, and after sending it comes back as a rejection for price, not a silent non-event. (Tasks 3 and 6)

---

## File Structure

Server (new): `server/lib/feud_hall/application/projections/market_activity.ex`, `server/test/feud_hall/application/market_activity_test.exs`.

Server (modified): `server/lib/feud_hall/application/command_workflow.ex` (fold and carry the projection, as `counter_services`), `server/lib/feud_hall/application/management.ex` (view fields), `server/lib/feud_hall/domain/market.ex` (`crate_size/2`, `level_permille/3`), `server/test/feud_hall/application/management_test.exs`, `server/test/feud_hall/domain/market_test.exs`.

Client (new):
- `app/src/market-goods.json` — per product ID: vendor, shape, colour, variant. Presentation data only.
- `app/src/market-goods.ts` — typed access, the fallback, vendor order.
- `app/src/market-cart.ts` — the cart draft and its requests. Pure.
- `app/src/market-layout.ts` — where vendors, containers, the cart and shoppers stand. Pure.
- `app/src/market-scene.ts` — the Three.js scene.
- `app/src/MarketPanel.svelte` — scene, list, cart, note and legend.
- `app/test/browser/market-goods.spec.ts`, `market-cart.spec.ts`, `market-layout.spec.ts`, `market.spec.ts`.
- `server/test/feud_hall/application/market_goods_coverage_test.exs` — every catalog product has an entry.

Client (modified): `app/src/people.ts` (pushing pose), `app/src/api.ts`, `app/src/App.svelte` (Supply section hosts the panel; the hall's Stock panel links to it), `app/src/i18n.ts`, `app/src/refusals.ts` if a reason code is new to the client.

Docs: `docs/GAME_DESIGN.md` §8 and §15, `docs/ARCHITECTURE.md` (commands and authorization; presentation data), `docs/TESTING.md`, `docs/superpowers/reports/2026-11-15-supply-market.md`.

Names used throughout:
- **vendor IDs**, in display order: `greengrocer`, `butcher`, `fishmonger`, `dairy`, `grains`, `spices`, `pantry`.
- **shape IDs**: `round`, `leafy`, `root`, `cut`, `fish`, `shellfish`, `sack`, `jar`, `bottle`, `loaf`, `block`, `carton`.
- **variant IDs**: `plain`, `frozen`, `value`, `shelf`.
- **size buckets**: `small`, `medium`, `large`.

---

### Task 1: Market facts in the views

**Files:**
- Create: `server/lib/feud_hall/application/projections/market_activity.ex`, `server/test/feud_hall/application/market_activity_test.exs`
- Modify: `server/lib/feud_hall/domain/market.ex`, `server/lib/feud_hall/application/command_workflow.ex`, `server/lib/feud_hall/application/management.ex`, `app/src/api.ts`
- Test: `server/test/feud_hall/domain/market_test.exs`, `server/test/feud_hall/application/management_test.exs`

**Interfaces (produced):**

```elixir
# Domain, pure.
Market.crate_size(catalog, product_id) :: pos_integer
# About ten servings of the recipe line that uses the most of the product, rounded UP to a round number:
# largest = max line quantity over every recipe line whose product is this one, or whose substitute is this one
#           (converted: div(line.qty * sub.num + sub.den - 1, sub.den)); 100 if no recipe uses the product.
# raw = largest * 10; rounded up to the next value in the series 1, 2, 5 x a power of ten
# (so 1,450 -> 2,000; 550 -> 1,000; 2,000 -> 2,000; 90 -> 100).
Market.level_permille(catalog, market, product_id) :: 0..1000
# min(1000, div(stock * 1000, target at the demand floor)), using the same target Market.price/3 uses; 0 when stock is 0.

# Application projection, folded from committed events like Projections.CounterService.
alias FeudHall.Application.Projections.MarketActivity
MarketActivity.new() :: activity
MarketActivity.fold(events, state_before, activity) :: activity
# Keeps the last 6 clearings that settled at least one request, newest first.
MarketActivity.outcomes(activity, restaurant_id) :: [outcome]      # that restaurant's, newest first
#   outcome = %{request_id, batch, at, product, requested, filled, cost, short, reason}
#   requested: the request's qty; filled: units filled (0 if none); cost: minor units paid (0 if none);
#   short: requested - filled; reason: nil | :stock_exhausted | :price_above_limit | :insufficient_cash | :storage_full
#   (use the reason atoms Market.clear/1 really produces; when a request has more than one shortfall, the first by the event's order).
MarketActivity.trips(activity) :: [trip]                             # public, newest first
#   trip = %{batch, at, restaurant_id, products: [product_id sorted], size: :small | :medium | :large}
#   one per restaurant per clearing with at least one fill;
#   size from the number of crates filled across its products (units filled / that product's crate size, summed, rounded up):
#   1..3 small, 4..9 medium, 10 or more large.
```

`fold/3` handles each `market_cleared` event in `events`. It must read each settled request's restaurant, product, quantity from `state_before.market.requests` (the event's `unfilled` entries carry only `request_id`, `qty`, `reason`), so the workflow passes the state as it was before the batch. A request submitted and cleared inside one batch does not occur (clearing happens in clock advances).

JSON view additions (all derived; money as the view's existing "cents" strings):
- Owner's private restaurant view, each `market[product]` entry gains `crate: integer` and `level: integer` (0..1000) beside `price` and `stock`.
- Owner's private restaurant view gains `purchases: %{pending: [%{request_id, product, qty, max_price_per_kunit, submitted_at, automated}], recent: [outcome]}`. `pending` is this restaurant's entries of `state.market.requests`, sorted by product. `recent` is `MarketActivity.outcomes/2` with `cost` as a cents string and `reason` as a string or null.
- Public hall view gains `market_trips: [%{batch, at, restaurant_id, products, size}]` from `MarketActivity.trips/1`, with `size` as a string.
- `app/src/api.ts`: matching optional types (`crate?`, `level?`, `purchases?`, `market_trips?`).

- [ ] **Step 1: Write the failing tests.**

`market_test.exs`:

```elixir
test "crate size is about ten servings of the largest line, rounded up to 1, 2 or 5 times a power of ten" do
  catalog = LaunchCatalog.catalog()
  # roasted_salmon uses 145 of salmon; nothing uses more.
  assert Market.crate_size(catalog, "salmon") == 2_000
  # A substitute counts at its converted quantity.
  assert Market.crate_size(catalog, "salmon_frozen") == 2_000
  for {id, _} <- catalog.products do
    size = Market.crate_size(catalog, id)
    assert size > 0
    assert size in for(p <- 0..7, m <- [1, 2, 5], do: m * Integer.pow(10, p))
  end
end

test "level is stock against the target at the demand floor, capped at 1000" do
  # stock 0 -> 0; stock = half the floor target -> 500; stock above it -> 1000.
end
```

Compute the salmon expectation from the catalog in the test if the recipe quantity differs from 145; the rule, not the literal, is the requirement.

`market_activity_test.exs` (build a hall with two restaurants and pending requests the way `server/test/feud_hall/domain/market_flow_test.exs` does):

```elixir
test "a clearing yields one outcome per settled request with what filled and what fell short" do
  # A: requested 3_000 of rice, filled 3_000, cost as the event's fill cost, short 0, reason nil.
  # B: requested 2_000 of salmon with stock 500 -> filled 500, short 1_500, reason :stock_exhausted.
  # C: a request whose limit is below the price -> filled 0, cost 0, short = requested, reason :price_above_limit.
end

test "trips say which products filled and a size bucket, and nothing else" do
  # Keys of every trip are exactly [:at, :batch, :products, :restaurant_id, :size].
  # 3 crates -> :small; 4 -> :medium; 9 -> :medium; 10 -> :large (drive with quantities that are multiples of the crate size).
  # A restaurant with no fill in a clearing has no trip for it.
end

test "only the last six clearings with outcomes are kept, newest first" do
end

test "a clearing with no requests changes nothing" do
end
```

`management_test.exs`:

```elixir
test "the owner's view carries their pending requests and recent outcomes" do
  # Submit a request as an owner: profile.restaurant.purchases.pending has it (product, qty, max_price_per_kunit as sent).
  # Advance past a clearing: pending is empty; recent has the outcome with filled, short, cost (a cents string) and reason.
  # market[product] has integer crate and level.
end

test "a rival's view carries the trip and nothing private" do
  # After the same clearing, another principal's view: hall.market_trips has restaurant_id, products, size, batch, at;
  # the whole encoded hall view contains no "qty", "cost", "max_price_per_kunit", "request_id", "short" or "reason" for that purchase;
  # their own profile.restaurant.purchases holds none of the first owner's entries.
  # A guest with no account sees the same market_trips.
end

test "after a restart the projection is empty and pending requests are still shown" do
  # Recover the runtime from the store: pending for a not-yet-cleared request is present; recent and market_trips are [].
end
```

- [ ] **Step 2: Run** each file — Expected: FAIL (undefined functions, missing keys).
- [ ] **Step 3: Implement.** Fold the projection in `command_workflow.ex` exactly where `counter_services` is folded and carried (pass `runtime.state`, the state before the batch), and start it empty wherever a runtime is built or recovered. Document in the projection's moduledoc that it is rebuilt from nothing after a restart and why that is acceptable (outcomes are also visible as stock; pending requests come from state). Update the `PublicView`/management moduledoc sentence on what is public about purchases.
- [ ] **Step 4: Run**, one at a time: the three files above, `test/feud_hall/application/command_workflow_test.exs`, `test/feud_hall/application/recovery_test.exs`, `test/feud_hall/domain/market_flow_test.exs`; then `mix format --check-formatted`. Expected: PASS. Then show sensitivity: make `trips/1` include `qty`, confirm the rival-view test fails, and restore.
- [ ] **Step 5: Commit** — `Show an owner's purchase outcomes and rivals' market trips`

---

### Task 2: What each product looks like and who sells it

**Files:**
- Create: `app/src/market-goods.json`, `app/src/market-goods.ts`, `app/test/browser/market-goods.spec.ts`, `server/test/feud_hall/application/market_goods_coverage_test.exs`
- Modify: `app/src/i18n.ts`

**Interfaces (produced):**

```ts
export type VendorId = "greengrocer" | "butcher" | "fishmonger" | "dairy" | "grains" | "spices" | "pantry";
export type ShapeId = "round" | "leafy" | "root" | "cut" | "fish" | "shellfish" | "sack" | "jar" | "bottle" | "loaf" | "block" | "carton";
export type VariantId = "plain" | "frozen" | "value" | "shelf";
export type Good = { vendor: VendorId; shape: ShapeId; colour: number; variant: VariantId; beside?: string };
export const VENDORS: readonly VendorId[];              // the display order above
/** The entry for a product, or the fallback: a plain carton at the pantry. */
export function goodFor(productId: string): Good;
export function hasGood(productId: string): boolean;
/** Products grouped by vendor in display order; a substitute directly after its primary. */
export function shelves(productIds: string[]): { vendor: VendorId; products: string[] }[];
```

`market-goods.json` is an object keyed by product ID: `{"vendor": ..., "shape": ..., "colour": "#rrggbb", "variant": ..., "beside": "<primary product ID>"?}`. `beside` is present exactly for a product that is some recipe line's substitute and names that line's primary product; such a product has the same vendor and shape as its primary and a variant other than `plain`.

i18n keys (English and Japanese): `vendor_greengrocer` "Greengrocer", `vendor_butcher` "Butcher", `vendor_fishmonger` "Fishmonger", `vendor_dairy` "Dairy and eggs", `vendor_grains` "Grains and nuts", `vendor_spices` "Spices and tea", `vendor_pantry` "Bakery and pantry".

- [ ] **Step 1: Write the failing tests.**

`market_goods_coverage_test.exs` (reads `../app/src/market-goods.json` relative to the server directory):

```elixir
test "every catalog product has a vendor and a shape" do
  goods = JSON.decode!(File.read!(Path.expand("../../../../app/src/market-goods.json", __DIR__)))
  catalog = LaunchCatalog.catalog()
  missing = Map.keys(catalog.products) -- Map.keys(goods)
  assert missing == []
  for {id, good} <- goods, Map.has_key?(catalog.products, id) do
    assert good["vendor"] in ~w(greengrocer butcher fishmonger dairy grains spices pantry)
    assert good["shape"] in ~w(round leafy root cut fish shellfish sack jar bottle loaf block carton)
    assert good["variant"] in ~w(plain frozen value shelf)
    assert good["colour"] =~ ~r/^#[0-9a-f]{6}$/
  end
end

test "a substitute sits beside its primary at the same vendor and looks different" do
  # For every recipe line with a substitute: goods[sub]["beside"] == line.product,
  # same vendor and shape as the primary, and variant != "plain".
end

test "meat, fish and dairy are at their vendors" do
  # Every product whose origins include :meat is at the butcher; :fish at the fishmonger; :dairy or :egg at dairy,
  # except products the test lists by ID with a reason (for example a sauce that contains fish).
end
```

`market-goods.spec.ts`:

```ts
test("goods: an unknown product is a plain carton at the pantry", () => {
  expect(hasGood("no_such_product")).toBe(false);
  expect(goodFor("no_such_product")).toEqual({ vendor: "pantry", shape: "carton", colour: 0xb89a6a, variant: "plain" });
});
test("goods: shelves follow the vendor order and put a substitute after its primary", () => {
  // shelves(all product IDs in the JSON): vendors in VENDORS order, none empty skipped silently (an empty vendor is absent);
  // for every entry with `beside`, its index is its primary's index + 1 or follows other substitutes of the same primary.
});
test("goods: every vendor has an English and a Japanese name", () => { /* i18n keys exist in both catalogs */ });
```

- [ ] **Step 2: Run** `mix test test/feud_hall/application/market_goods_coverage_test.exs` (from `server/`) and `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser market-goods.spec.ts` (from `app/`) — Expected: FAIL (file missing).
- [ ] **Step 3: Implement.** Generate the JSON from the catalog with a throwaway script (not committed), then correct it by hand: vendor from origins and what the product is; shape from what it is (rice in a sack, oil in a bottle, tofu a block, yogurt a carton, herbs leafy, onions and carrots root or round, pastes and sauces in a jar, breads a loaf); a colour close to the food's own. List the product IDs and names you were unsure of in your report.
- [ ] **Step 4: Run** both test files again, then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.
- [ ] **Step 5: Commit** — `Map every product to a vendor, a shape and a colour`

---

### Task 3: The cart

**Files:**
- Create: `app/src/market-cart.ts`, `app/test/browser/market-cart.spec.ts`

**Interfaces:**
- Consumes: Task 1's view types in `api.ts`.
- Produces:

```ts
export type CartLine = { product: string; crates: number; limit: string; limitEdited: boolean };
export type Cart = { lines: CartLine[] };
export type Offer = { price: string; stock: number; crate: number; level: number };       // one market entry
export type Pending = { request_id: string; product: string; qty: number; max_price_per_kunit: string };
export type Outcome = { request_id: string; product: string; requested: number; filled: number; cost: string; short: number; reason: string | null };

export const MAX_CRATES = 99;
export const emptyCart: Cart;
/** Published price plus 10%, rounded up to a whole minor unit. Decimal strings in and out. */
export function defaultLimit(price: string): string;
/** One more crate of the product; a new line takes the default limit from the offer. */
export function addCrate(cart: Cart, product: string, offer: Offer): Cart;
export function setCrates(cart: Cart, product: string, crates: number): Cart;   // 0 removes the line; clamps to 0..MAX_CRATES
export function setLimit(cart: Cart, product: string, limit: string): Cart;     // ignored unless /^[1-9][0-9]*$/
/** Keeps unedited limits at the default for the current price; drops lines whose product left the market. */
export function reprice(cart: Cart, market: Record<string, Offer>): Cart;
/** The payloads "Send order" submits, one per line, in cart order. */
export function requests(cart: Cart, market: Record<string, Offer>, restaurantId: string):
  { restaurant_id: string; product: string; qty: number; max_price_per_kunit: string }[];
/** What a line would cost at the published price: ceil(qty * price / 1000). Decimal string. */
export function lineEstimate(line: CartLine, offer: Offer): string;
export type LineNote = "replaces_pending" | "price_above_limit" | "more_than_stock";
/** Things to tell the owner about a line before sending. */
export function lineNotes(line: CartLine, offer: Offer, pending: Pending[]): LineNote[];
export type Tracked = { product: string; state: "pending" | "filled" | "short" | "rejected" | "settled"; filled: number; short: number; reason: string | null; requestId: string };
/** "On its way": what became of the request IDs this device sent, newest first. */
export function track(sent: { requestId: string; product: string }[], pending: Pending[], recent: Outcome[]): Tracked[];
```

`track` rules: a sent ID found in `pending` is `pending`; found in `recent` with `short == 0` is `filled`; with `filled > 0` and `short > 0` is `short`; with `filled == 0` is `rejected` (reason from the outcome); found in neither is `settled` (the server no longer has the outcome). A `submit_purchase_request` command's ID is its request ID.

- [ ] **Step 1: Write the failing tests** in `market-cart.spec.ts`:

```ts
test("cart: the default limit is the price plus ten per cent, rounded up, as a decimal string", () => {
  expect(defaultLimit("1000")).toBe("1100");
  expect(defaultLimit("1001")).toBe("1102");          // 1101.1 rounds up
  expect(defaultLimit("1")).toBe("2");
  expect(defaultLimit("123456789012345678901234567890")).toBe("135802467913580246791358024679");
});
test("cart: one click is one crate", () => { /* addCrate twice on the same product: one line, crates 2, limit from the first offer */ });
test("cart: requests carry whole crates and exact strings", () => {
  // crates 3, crate 2000, limit "1234" -> { restaurant_id, product, qty: 6000, max_price_per_kunit: "1234" }; nothing else on the object.
});
test("cart: an unedited limit follows the price and an edited one does not", () => { /* reprice */ });
test("cart: invalid limits and crate counts are refused", () => { /* "0", "", "1.5", "-3", "abc" leave the limit; crates -1 -> 0 removes; 500 -> 99 */ });
test("cart: notes", () => {
  // price "1300" against limit "1200" -> price_above_limit; a pending request for the product -> replaces_pending;
  // crates * crate above stock -> more_than_stock; none -> [].
});
test("cart: the estimate rounds up like the server", () => { /* qty 1500, price "333" -> "500" (499.5 up) */ });
test("cart: tracking", () => { /* one ID in each of the five states, with exact filled/short/reason */ });
test("cart: arithmetic never passes through a float", () => {
  fc.assert(fc.property(fc.bigInt({ min: 1n, max: 10n ** 40n }), (p) => {
    const limit = BigInt(defaultLimit(p.toString()));
    expect(limit).toBe((p * 110n + 99n) / 100n);
  }));
});
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser market-cart.spec.ts` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement** with `BigInt` for every money value. All functions return new objects; none mutates its input.
- [ ] **Step 4: Run** the file, then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.
- [ ] **Step 5: Commit** — `Add the market cart draft and its requests`

---

### Task 4: A figure pushing a cart

**Files:**
- Modify: `app/src/people.ts`
- Test: `app/test/browser/people.spec.ts`

**Interfaces:**
- Produces: `Pose` gains `pushing: boolean`. Every existing `Pose` literal in `app/src` and `app/test` gains `pushing: false`.
- Produces: `cartHandlePoint(look: Look): { y: number; forward: number }` — where both hands meet the cart's handle, in the units of `carryPoint`. `CART_HANDLE_HEIGHT = 0.9` (world units) is exported.

- [ ] **Step 1: Write the failing tests** in `people.spec.ts`, with the file's existing `parts` helper and standing pose:

```ts
test("people: a figure pushing a cart holds the handle with both hands at handle height", () => {
  for (const serial of [1, 2, 3, 99, 4096]) {
    const look = personLook(serial, "owner");
    const pushing = parts(look, { ...stand, pushing: true, walking: true, stride: 0.5 }, "full");
    const hands = pushing.filter((p) => p.kind === "hand");
    expect(hands).toHaveLength(2);
    for (const hand of hands) expect(handHeight(hand)).toBeCloseTo(CART_HANDLE_HEIGHT, 2);
    // Arms do not swing while pushing, legs do.
    expect(armAngles(pushing)).toEqual(armAngles(parts(look, { ...stand, pushing: true, walking: true, stride: -0.5 }, "full")));
    expect(legAngles(pushing)).not.toEqual(legAngles(parts(look, { ...stand, pushing: true, walking: true, stride: -0.5 }, "full")));
  }
});
test("people: pushing and carrying are exclusive, pushing wins", () => { /* carrying: true, pushing: true equals pushing alone */ });
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser people.spec.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** in `poseParts`: both arms reach forward and slightly down to the handle; hands at `CART_HANDLE_HEIGHT` whatever the figure's height; the simple detail level keeps single-piece arms. Keep `posePerson` allocation-free.
- [ ] **Step 4: Run** the file, then `people-scene.spec.ts` (after `bun run --bun build`), then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.
- [ ] **Step 5: Commit** — `Add a cart-pushing pose for figures`

---

### Task 5: The market scene

**Files:**
- Create: `app/src/market-layout.ts`, `app/src/market-scene.ts`, `app/test/browser/market-layout.spec.ts`
- (The scene is exercised through the panel's browser tests in Task 6.)

**Interfaces:**
- Consumes: Task 2's `goodFor`, `shelves`, `VENDORS`; Task 4's pushing pose and `cartHandlePoint`; `createPeople` from `people-mesh.ts`; `personLook`, `serialFor`.
- Produces (`market-layout.ts`, pure):

```ts
export const CONTAINERS_PER_ROW = 6;
export type Placed = { product: string; vendor: VendorId; x: number; y: number; z: number };
/** Where each vendor's stall stands (a row along x, centred on 0) and where each product's container sits on its shelves. */
export function marketLayout(productIds: string[]): { stalls: { vendor: VendorId; x: number; width: number }[]; containers: Placed[] };
/** Camera poses: the whole row, and close on one vendor. */
export function overviewPose(stallCount: number): { position: [number, number, number]; target: [number, number, number] };
export function vendorPose(stall: { x: number; width: number }): { position: [number, number, number]; target: [number, number, number] };
/** Where a shopper walks for a trip: in from one end, stopping in front of each vendor that sells one of the products, out the other end. */
export function tripRoute(products: string[], layout: ReturnType<typeof marketLayout>): { x: number; z: number; pause: boolean }[];
/** How full a container is drawn, 0..1, from the server's level (0..1000): 0 -> 0, 1000 -> 1, never empty-looking above 0 (min 0.12). */
export function fillFor(level: number): number;
/** How many goods a cart shows for a size bucket: small 2, medium 5, large 9. */
export function cartGoods(size: "small" | "medium" | "large"): number;
```

- Produces (`market-scene.ts`):

```ts
export type MarketAppearance = {
  market: Record<string, { price: string; stock: number; crate: number; level: number }>;
  starred: string[];                       // products the owner's menu uses
  cart: { product: string; crates: number }[];
  focusedVendor: VendorId | null;          // null: the row
  selected: string;                        // product highlighted from the list, or ""
  trips: { batch: number; restaurant_id: string; products: string[]; size: "small" | "medium" | "large" }[];
  ownRestaurant: string;
  restaurantName: (id: string) => string;
  priceLabel: (price: string) => string;
  crateLabel: (crate: number) => string;
  motion: boolean;
};
export type MarketActions = {
  add(product: string): void;              // a container was clicked
  focusVendor(vendor: VendorId | null): void;
  hover(product: string): void;            // "" when nothing
  hoverShopper(name: string): void;        // "" when nothing; the restaurant's name only
  fail(): void;
};
export function createMarketScene(host: HTMLElement, actions: MarketActions): {
  update(next: MarketAppearance): void;
  setVisible(visible: boolean): void;      // stops drawing while the Supply section is hidden
  dispose(): void;
};
```

The host element gets `data-market-containers` (containers drawn), `data-market-shoppers` (rival shoppers present), `data-market-cart` (crates on the owner's cart) and `data-market-vendor` (the focused vendor or "").

**What the scene shows:**
- A row of vendor stalls, one per vendor that has products, each with an awning in its own colour and its name on a sign (canvas texture; the name is passed in through `restaurantName`-style callbacks only for rivals, vendor names come from `i18n` via the panel as part of labels on the tag textures: add `vendorLabel: (vendor: VendorId) => string` to `MarketAppearance`).
- On each stall's shelves, one container per product, instanced by shape. Its goods are drawn to `fillFor(level)` of the container. A price tag in front shows `priceLabel(price)` and `crateLabel(crate)`. A star above containers in `starred`. A container whose `level` is below 300 carries a "low" marker. Variants: `frozen` goods are paler and frosted, `value` is a plain sack look, `shelf` a box look.
- The owner's cart at the front, holding `min(crates, 12)` crates per line as small boxes in the product's colour.
- For each trip in `trips` whose `restaurant_id` is not `ownRestaurant` and whose batch the scene has not staged yet: one figure, the restaurant's owner look, pushing a cart holding `cartGoods(size)` unlabelled goods in the products' shapes and colours, walking `tripRoute`. A trip seen on the first `update` after creation is not staged (no burst on load). With `motion` false the shopper stands at the first vendor it would stop at for 20 seconds and then goes.
- Clicking a container calls `actions.add(product)`; clicking a stall's sign or awning calls `actions.focusVendor(vendor)`; pointing at a shopper calls `actions.hoverShopper(name)`.
- It draws on demand: after an `update`, while a shopper walks or the camera eases, and not otherwise. `setVisible(false)` cancels the frame loop.

- [ ] **Step 1: Write the failing tests** in `market-layout.spec.ts`:

```ts
test("market layout: every product has one container at its vendor, none overlapping", () => {
  // With all product IDs of market-goods.json: containers.length equals the product count;
  // each container's vendor is goodFor(product).vendor and its x lies within that vendor's stall;
  // no two containers closer than 0.5; stalls do not overlap and are in VENDORS order by x.
});
test("market layout: a substitute's container is next to its primary's", () => { /* same row, adjacent index */ });
test("market layout: a trip stops at each vendor it buys from, in row order, once", () => {
  // tripRoute(["salmon", "rice_long", "onion"]): pause points in front of fishmonger, grains and greengrocer stalls, sorted by x; starts and ends beyond the row's ends.
});
test("market layout: fill and cart goods", () => {
  expect(fillFor(0)).toBe(0); expect(fillFor(1)).toBeCloseTo(0.12); expect(fillFor(1000)).toBe(1);
  expect(fillFor(500)).toBeGreaterThan(fillFor(200));
  expect([cartGoods("small"), cartGoods("medium"), cartGoods("large")]).toEqual([2, 5, 9]);
});
test("market layout: the camera poses look at what they name", () => { /* overview target x is 0; vendorPose target x equals the stall's x */ });
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run test:browser market-layout.spec.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** both modules. Read `app/src/hall-scene.ts` for how this codebase sets up a renderer, draws on demand, handles context loss (`actions.fail()`), disposes, and uses `createPeople`; follow it. Keep draw calls low: instanced meshes per shape, one canvas texture atlas for tags.
- [ ] **Step 4: Run** the layout spec, then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS.
- [ ] **Step 5: Commit** — `Draw the supply market`

---

### Task 6: The market on the Business page

**Files:**
- Create: `app/src/MarketPanel.svelte`, `app/test/browser/market.spec.ts`
- Modify: `app/src/App.svelte`, `app/src/i18n.ts`, `app/src/refusals.ts` (only if an outcome reason has no message yet)

**Interfaces:**
- Consumes: everything above; `App.svelte`'s `submit(kind, payload)`, its pending-command state and its `title(productId)`, `cash(amount)` helpers.
- Produces: `MarketPanel.svelte` props: `restaurant` (the owner's private restaurant view), `trips` (`view.hall.market_trips ?? []`), `stalls` (for restaurant names), `visible` (the Supply section is shown), `disabled`, `motion`, `submit` (the app's function), `pendingIds` (command IDs the app still treats as uncertain), `title`, `cash`, `t`.

**Behaviour:**
- The panel sits at the top of the Supply section, above the existing text form, which stays unchanged.
- It shows the scene when WebGL is available and the panel is at least 720 CSS pixels wide; otherwise the list alone. A scene failure switches to the list alone and says so once.
- The list (always present, synchronized with the scene): a tab or button per vendor; under the chosen vendor, each product with its name, tag (price per thousand units and crate size), a stock meter from `level`, a star if the menu uses it, a "low" label when `level < 300`, and an "Add a crate" button. Choosing a vendor in the list focuses it in the scene and the reverse. Focusing a product in the list highlights its container.
- The cart: each line with the product name, crate count with − and + buttons, quantity (crates × crate size), the limit as an editable field, the estimate, and its notes (`replaces_pending`, `price_above_limit`, `more_than_stock`) as text. "Send order" calls `submit("submit_purchase_request", payload)` once per line in order, awaiting each, and removes a line from the cart when its submit was accepted or is uncertain; a refused line stays with the refusal shown. "Empty cart" clears the draft.
- "On its way": from `track(sent, restaurant.purchases.pending, restaurant.purchases.recent)`: pending lines say they fill at the next clearing; filled lines say how many units arrived and the cost; short lines say how many arrived and how many did not, with the reason; rejected lines give the reason; settled lines say the order was settled and to check stock. A line leaves the list 60 seconds after it stops being pending, or when dismissed. The sent IDs are kept in memory for the session; an ID the app reports as uncertain stays pending until resolved.
- The first time the panel is shown on a device, a note explains the star ("Starred supplies are used by your menu.") in a `role="status"` region; it fades after 8 seconds or on dismissal and is not shown again (`localStorage`, key `feudhall.market.starNote`, wrapped in try/catch). A legend under the shelves always shows the star and the "low" marker with their meaning; a star in the list has the same text as its accessible description and title.
- Pointing at a rival in the scene shows the restaurant's name near the pointer and in a polite live region; nothing else about them is shown anywhere.
- The hall's Stock panel (the hall interaction with target "supply") keeps its content and gains a link, "Open the market", that goes to the Business page's Supply section.
- Drafts survive live updates: a view refresh does not reset the cart, the chosen vendor, an edited limit or keyboard focus.

i18n keys to add in English and Japanese (use these keys; write natural, short text): `market`, `marketListOnly`, `marketSceneFailed`, `addCrate`, `crateOf` (parameter: quantity), `perThousand`, `stockLevel`, `lowStock`, `starredSupply`, `starNote`, `dismiss`, `cart`, `cartEmpty`, `crates`, `priceLimit`, `estimate`, `sendOrder`, `emptyCart`, `onItsWay`, `fillsAtNextClearing`, `orderFilled` (units, cost), `orderShort` (arrived, missing, reason), `orderRejected` (reason), `orderSettled`, `noteReplacesPending`, `notePriceAboveLimit`, `noteMoreThanStock`, `openMarket`, `rivalShopping` (name), `legend`.

- [ ] **Step 1: Write the failing browser tests** in `market.spec.ts`. Follow `people-scene.spec.ts` and `visible-diners.spec.ts`: seed an owner with a stall, capture a `View`, serve edited copies from `page.route("**/api/state", …)` with a new `hall.position` each time; install `page.clock` before `page.goto`. Use the list for clicks where a canvas position would be fragile, and one test that clicks the canvas at a container's projected position if the scene exposes one through a test hook (`data-market-hit="<product>:<x>,<y>"` on the host for the selected product is acceptable).

```ts
test("market: add a crate, send, see it pending, then filled", async ({ page, hall }) => {
  // Business > Supply. Choose a vendor, "Add a crate" on a starred product twice: cart line shows 2 crates, qty 2 x crate, limit = price + 10%.
  // "Send order": exactly one POST of submit_purchase_request with product, qty and max_price_per_kunit as strings/integers expected; cart is empty;
  // "On its way" shows the line as pending. Serve a view whose purchases.pending is empty and purchases.recent has the outcome (filled, short 0):
  // the line says filled with units and cost. data-market-cart went 2 -> 0.
});
test("market: a short fill says how much arrived and why", async ({ page, hall }) => { /* recent outcome filled 500 short 1500 reason stock_exhausted */ });
test("market: a price above the limit is noted before sending and comes back rejected", async ({ page, hall }) => {});
test("market: a rival's fill appears as an unlabelled shopper", async ({ page, hall }) => {
  // Serve hall.market_trips with a rival's trip: data-market-shoppers becomes 1; the page text contains no quantity or price for it;
  // hovering (or the test hook) shows only the restaurant's name; the owner's own trip does not add a shopper.
});
test("market: the list works with the scene unavailable", async ({ page, hall }) => {
  // Launch with WebGL disabled (as the hall's no-WebGL test does): no canvas; the same add, send, pending, filled flow passes through the list.
});
test("market: the star note shows once, fades, and the legend stays", async ({ page, hall }) => {});
test("market: a refresh keeps the cart and an edited limit", async ({ page, hall }) => {});
test("market: every market string exists in Japanese", async ({ page, hall }) => { /* switch language; the panel shows no English key fallbacks; check the i18n catalogs directly for each key */ });
```

- [ ] **Step 2: Run** `NODE_OPTIONS=--max-old-space-size=1536 bun run --bun build` then `bun run test:browser market.spec.ts` — Expected: FAIL (no market).
- [ ] **Step 3: Implement** the panel and the wiring. `App.svelte` passes the panel its existing `submit`; do not add a fetch.
- [ ] **Step 4: Run**, one file at a time (rebuilding after source changes): `market.spec.ts`, `owner-view.spec.ts`, `journeys.spec.ts`, `phone-layout.spec.ts`, `hall-interactions.spec.ts`; then `bun check`, `bun run lint`, `bun run format:check`. Expected: PASS, with no existing assertion weakened.
- [ ] **Step 5: Commit** — `Put the supply market on the Business page`

---

### Task 7: Documentation and report

**Files:**
- Modify: `docs/GAME_DESIGN.md` (§8: what is public about purchases; §15: the market view and its visual language), `docs/ARCHITECTURE.md` (commands and authorization: the two view additions and what stays private; the market-activity projection; presentation data keyed by product ID), `docs/TESTING.md` (new spec files and the coverage test), `AGENTS.md` only if an entry point it lists changed
- Create: `docs/superpowers/reports/2026-11-15-supply-market.md`

- [ ] **Step 1:** Write the documentation changes. Gameplay in the game design, contracts in the architecture document; link rather than copy. Mark tuning values (crate rounding, bucket boundaries, six clearings kept, the 300 "low" level, the 10% default limit) as proposed defaults.
- [ ] **Step 2:** Write the report: what was built; each builder's call with its reason; the products whose vendor or shape was a judgement; which checks ran with results; what is not verified (full suites, a real hall, the packaged app, frame rate of the market scene, Japanese text reviewed by a fluent reader).
- [ ] **Step 3:** Check every relative link you added with `ls`.
- [ ] **Step 4: Commit** — `Document the supply market and report the work`
