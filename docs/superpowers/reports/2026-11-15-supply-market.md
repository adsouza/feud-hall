# Supply market: what was built, the calls made, and what is unchecked

## What to decide

1. **Whether to accept the product looks.** Every one of the 274 products was
   given a vendor and a shape by judgement, and about 25 were close calls. See
   [Product looks that were judgement calls](#product-looks-that-were-judgement-calls).
2. **Whether the arrived-crates mark reads well.** Filled crates now arrive on
   the owner's cart, closed with a green lid. At the close-up camera distance
   the cart is small, so the draft and arrived crates are both only a few
   pixels. See [What was built](#what-was-built).
3. **Whether the tuning values stand.** Crate size, the three cart sizes, six
   clearings kept, the "low" level, the 10% price limit and the 60 seconds a
   settled line stays are proposed defaults, not measured. See
   [Tuning values](#tuning-values).
4. **Whether to act on the limitations** in [Known limitations](#known-limitations).
5. **Whether to merge.** Nothing is pushed. The whole-branch review is still to
   come ([Final review](#final-review)), and the full test suites have not been
   run (see [What is not verified](#what-is-not-verified)).

Evidence for Project 5 of the
[livelier hall design](../specs/2026-11-13-livelier-hall-design.md#project-5-supply-market),
built from the [plan](../plans/2026-11-15-supply-market.md) in seven tasks on
the branch `supply-market`. The rules now live in the
[game design](../../GAME_DESIGN.md#the-supply-market), the contracts in the
[architecture](../../ARCHITECTURE.md#the-supply-market-view) and the checks in
[Testing](../../TESTING.md#supply-market-checks).

## What was built

- **A 3D market on the owner's Business page.** Seven vendor stalls in a row
  (greengrocer, butcher, fishmonger, dairy and eggs, grains and nuts, spices and
  tea, bakery and pantry). Clicking a stall brings it into close-up; each
  container shows how much stock is left and its published price and crate size.
  A click on a container adds one crate to a draft cart. Nothing is bought until
  "Send order", which sends one purchase request per line through the same path
  the text form uses. Sent lines sit under "On its way" until the clearing
  reports what happened to them.
- **Filled crates arrive on the owner's cart.** While a filled or short line is
  listed, its crates (filled units divided by the crate size, rounded up) stand
  on the cart under the draft, closed with a green lid, and leave with the line;
  the legend explains the lid. This was added after the documentation task,
  because the plan had left out this part of the design.
- **Stars, markers and a legend.** Supplies the owner's menu uses are starred.
  Low stock has a red tag, empty has a grey tag, and frozen, value and preserved
  substitutes look different. A one-time note explains the stars and fades; a
  legend stays under the shelves.
- **Rivals shopping.** When another restaurant's purchase fills, a figure
  (the same person as at their stall) pushes an unlabelled cart of the goods
  bought past the stalls. Pointing at one shows only the restaurant's name.
- **The list.** A synchronized list with the same cart is the market whenever
  the picture is not available: no WebGL, a panel under 720 px, or a failed
  scene. The existing text form, starter stock, restock automation and pricing
  controls are untouched; the hall's Stock panel gains an "Open the market" link.
- **Server fields.** The owner's view gains each product's crate size and stock
  level, the owner's own pending requests and recent outcomes, and the supplies
  the menu uses. The public hall view gains recent rivals' trips (below). No
  rule, event, command or stored state changed.
- **Presentation data and a check.** `market-goods.json` maps every product to
  its vendor, shape, colour and variant, and a server test fails if a catalog
  product has no entry.
- **A cart-pushing pose** for figures, used for the shoppers.
- Both languages: every new string exists in English and Japanese.

## What became public, and what did not

The public view used to carry no orders at all. It now carries, for the six most
recent clearings that settled a request, per restaurant that had a fill: the
product IDs that filled, one of three cart sizes (small, medium, large), and the
clearing's number and scheduled time (clearing times were already public).
Guests see the same.

Still private to the owner: quantities, costs, prices paid, price limits,
pending requests, unfilled amounts, reasons, request IDs, and the supplies the
menu uses. A test encodes the public hall and a guest's view and checks that none
of those key names appear. As the owner accepted in the design, an attentive
player can infer a rival's menu plans from the shapes of what they buy.

## Rulings

Each line gives the ruling, the reason, and what it costs if wrong. They are
grouped by when they were made. Nothing is left out.

### Errors found in the plan, before or while building

These are mistakes in the plan, not choices. The plan was not reviewed by the
owner before execution, and a check of it against the code before building found
the first two; the third was found by the Task 6 builder.

1. **The request ID form.** The plan said a command's ID is its request ID. In
   the code the request ID is `"PR:"` plus the command ID (`decider.ex:250`).
   Ruling: the client derives `"PR:" + command ID` and a server test pins the
   form through the owner's view. Cost if wrong: if the prefix ever changes,
   sent lines fall to "settled, check your stock" instead of tracking, and the
   server test fails first.
2. **Automated restocks are requested and cleared in the same batch.** The plan
   said a request is always created before the batch that clears it. Restock
   automation can request and clear inside one clock-advance batch, so the state
   before the batch does not hold the request. Ruling: the projection folds each
   event against the state immediately before that event, in the one pass that
   already evolves the batch; a test covers it through the real advance.
   Cost if wrong: only a slightly larger change to `command_workflow.ex` than
   planned; unneeded care at worst. A mutation that used the state before the
   batch made that test fail.
3. **No source for the stars.** The plan assumed the client could tell which
   supplies the menu uses. Nothing it receives carried recipe lines. Ruling: the
   owner's private view gains a derived `menu_products` list, with its own test
   and commit. Cost if wrong: one more private view field; to undo, remove it
   and the stars with it.

Smaller plan inconsistencies, each settled by reading the code:

4. **Containers per row.** The plan's six containers per
   row cannot hold 96 products at the pantry. Each stall's shelf is sized from
   its own count (columns about the square root of 1.5 times the count, at least
   three), and a primary and its substitutes never split across a tier's end.
   Cost if wrong: the market reads as crowded and the layout constants change.
5. **Reason name.** The plan listed `:storage_full`; the code uses
   `:insufficient_storage`. The code won.
6. **`MarketAppearance`.** The plan's interface block left out `vendorLabel`,
   its prose included it. The later, more specific statement won.
7. **Pose literals.** The plan's file list for the pose task was incomplete (the
   pose appears in more files, and three test helpers it named did not exist).
   The task edited every file that needed it and wrote the helpers.
8. **Comment-only test bodies.** Some tests in the plan were comments. Each was
   treated as a specification and became real assertions: a test that asserts
   nothing is a defect.
9. **`submit` returned nothing.** The panel needs the outcome and command ID of
   a send, which the function did not return. Ruling: `submit` and `deliver`
   resolve to `{outcome: accepted | refused | uncertain | skipped, commandId,
   reason}` with no change for existing callers; they stay the one submitting
   path. After an uncertain result, sending stops and the remaining lines stay in
   the cart (the app holds one uncertain command at a time). Cost if wrong: an
   owner with a lost response must resolve it with the existing Retry before the
   rest of the cart goes.
10. **A product that substitutes for two primaries.** The plan's `beside` was
    ambiguous there. Ruling: the lowest ID wins. This turned out moot: no
    launch product substitutes for two primaries.
11. **Empty vendors and money formats.** `shelves()` omits a vendor with no
    products, and a pending request's price limit is a cents string like the
    view's other money.

### Design decisions made in the plan

1. **The recent-outcomes store is an application projection, not hall state.**
   It is folded from committed events beside the existing counter-service
   projection, which avoids changing the event-sourced state and every snapshot.
   Cost if wrong: the projection is empty after a restart, so an outcome settled
   just before a restart shows as "settled, check stock" and rivals' recent trips
   start from nothing.
2. **The server computes crate size and stock level** and sends them with each
   price, so the picture, list, cart and tests share one definition. Cost if
   wrong: the client could compute them, but two definitions would drift.
3. **Crate size is ten servings** of the largest recipe line using the product,
   rounded up to 1, 2 or 5 times a power of ten. Cost if wrong: crates are a
   little larger than ten servings for some products.
4. **Cart sizes and window.** One to three crates is small, four to nine medium,
   ten or more large; six clearings (about a minute) are kept; a container is
   "low" below 30% of its target. The spec left these to the builder. Tuning
   only.
5. **The mapping lives in `app/src/market-goods.json`** and a server test checks
   it against the launch catalog, because the client has no catalog at test time
   and the spec requires a failing check for a missing product. Cost if wrong:
   move the check to a browser test against a live hall.
6. **No frame-rate bench** for the market scene; the spec asks for none. The
   report says so under [What is not verified](#what-is-not-verified).

### Decisions made during building

Task 1 (server):

- **Trip fields `batch` and `at` are public.** They identify the clearing, not
  the purchase, and clearing times are public already. The reviewer could not
  confirm this against "nothing more"; the spec says "for recent clearings, per
  restaurant". Cost if wrong: drop `at` and keep `batch`, which is all staging
  needs.
- **Trip size sums exact crate fractions and rounds up once** (1.5 and 1.5 crates
  is 3, small, not 2 plus 2). The spec says "roughly how much". Tuning only.
- **`fold/3` became `observe/3`** (the consequence of plan error 2). No
  standalone batch fold exists on purpose, so the market fold cannot drift from
  the real evolve pass.
- **A trip's time is the clearing's scheduled instant,** not the state's current
  time. Where a request has several shortfalls its `reason` is the first.

Task 2 (data):

- **The coverage test pins no product count.** The reviewer could not verify the
  counts from the diff, but `AGENTS.md` forbids hardcoding a roster count; the
  test derives both sides from the catalog. No cost.
- The JSON import uses `with { type: "json" }` because the browser test runner
  cannot load a bare JSON import.

Task 3 (cart):

- **`setCrates` with NaN or an absent product changes nothing**; the brief was
  silent. At the 99-crate maximum, adding a crate returns an equal cart.

Task 4 (pose):

- **`cartHandlePoint` takes an optional stride** (default 0 matches the brief),
  because walking bob moves the hand slightly.

Task 5 (scene):

- **A shopper never blocks a purchase click.** Clicks pick containers and stalls
  only; hovering a shopper still names the restaurant. A rival walking past must
  not eat the owner's click. No cost.
- **A container adds only when its vendor is in focus; in the whole-row view any
  click on a stall focuses it.** Containers in the row view are about 10 pixels
  wide, so a click there is as likely an accident as an order. This deviates
  from the brief's "clicking a container adds". Cost if wrong: one extra click to
  buy from the row view is restored by removing the rule.
- **`data-market-hit` is a test-only attribute** giving the screen position of
  the selected container, so a browser test can click a real container.
- **A seen clearing is never staged again.** After the first update sets a
  high-water mark, only newer clearings stage rivals, so a reconnect cannot
  replay old clearings as a burst of shoppers.
- **With motion off, shoppers stand in the aisle in front of the first stall**,
  not beside it, so they are inside the close-up.
- **The scene was checked by eye** with a temporary harness and headless
  screenshots, because a scene judged only by data attributes can be unreadable.
  Cost: builder time. (The review also found, and the fix stopped, a timer that
  re-armed every 20 ms in a hidden tab.)

Task 6 (panel):

- **Drafts live above the panel** (`market-state.svelte.ts`), so the cart, chosen
  vendor and "On its way" list survive leaving the Supply section and coming
  back in a session. Only the star note flag is kept across a reload.
- **Uncertain sends are resolved inside `deliver`,** not by a "latest result"
  value as first ruled. A retry can happen while the panel is unmounted, and a
  single latest value could be overwritten before the panel saw it. Better than
  the ruling; no cost.
- **The legend also explains the frozen, value and preserved looks and the empty
  tag,** and the `shelf` variant is worded "preserved" because it includes
  chilled products. More strings than the plan listed, all in both languages.
- **The market is on the Business page only;** the hall's Stock panel gets an
  "Open the market" link and keeps its text panel, as the spec says.
- **`menu_products` follows each stall's menu as the kitchen cooks it** (priced,
  right cuisine, equipment ready; per-stall overrides included), not the raw
  restaurant menu. A star means "your stalls sell something that uses this", so a
  recipe a stall cannot cook yet draws no star. Cost if wrong: switch the source
  to the restaurant menu, one line.
- **Builder's deviations, accepted:** the panel reads reduced motion itself
  instead of taking a prop; the "Dismiss" key is `marketDismiss` because
  `dismiss` already means firing staff; the existing purchase dropdown now shows
  "Price unavailable" for a malformed price instead of breaking the whole page (a
  real defect the robustness test found); the Supply section spans the full row
  of the Business grid (three lines of `style.css`, outside the task's file list,
  needed for the 720 px threshold); the i18n JSON imports gained `with { type:
  "json" }`; the client tests were written after the code.
- **An older server shows no outcomes.** Without `purchases` an accepted line
  says only "Sent. Check your stock for what arrived." instead of promising a fill
  (the review's Important finding, fixed in the fix round).

## Product looks that were judgement calls

All of these are placed by a person's reading of the name, not by any game rule.
Changing one is a one-line edit in `market-goods.json`.

- **Shape guessed from the name:** okra, green beans, plantain and steamed corn
  are drawn as roots (the elongated shape); mixed vegetables as a leafy bunch.
- **Vendor:** firm tofu is at the greengrocer; grated coconut is a sack at grains
  and nuts; hulled white corn, purple corn and coffee are sacks at grains or
  spices (dried kernels assumed); cocoa is a jar at spices; condensed and
  evaporated milk are at dairy (forced by the origin rule); kelp is a dried jar at
  the pantry; sugars are sacks at the pantry.
- **Fresh herbs assumed:** culinary cedar, kawakawa leaf, guascas, nettles and
  prairie mint are leafy at the greengrocer.
- **Spice blends, not sauces:** tikka masala and chole masala are jars at spices.
- **Cooked beans** (black beans, kidney beans, cowpeas) are jars at the pantry;
  barberries and greenthread (used as a tea) are jars at spices; lemon and lime
  juice are bottles at the pantry; arequipe is a jar at dairy; jamun mix,
  kataifi pastry and pastry shell are cartons at the pantry.
- **Meat, fish and dairy exceptions,** named in the coverage test with reasons:
  chicken broth (broth at the pantry), pastry shell (dough with butter), jamun
  mix (a dessert mix), butter masala sauce (a cream sauce).
- **Variants.** A substitute keeps its primary's colour; only the variant tells
  them apart. Anything with "frozen" in its ID is frozen. Value is `_value`,
  `_basic` and a few staples. "Preserved" covers `_shelf_stable`, `_packaged`,
  canned and dried items and also every `_chilled` product, because the catalog
  grades chilled as "Preserved". The legend says "preserved" for that reason.
- **How the 274 products are split** (counted from the file at the time of
  writing): pantry 96, greengrocer 64, grains and nuts 40, spices 30, dairy 22,
  butcher 12, fishmonger 10; 123 are substitutes beside a primary.

## Known limitations

Each is one line. None blocks use.

- **The cart is small in the close-up,** so arrived and draft crates are only a
  few pixels each; the green lids tell them apart when looked at closely.
- **The whole-row view leaves a lot of empty ground** above and below the row.
- **The app's "Updated" toast briefly overlaps the cart's right edge** after a
  send (existing behaviour).
- **Some product names show as lowercase IDs** where the app's existing title
  helper has no name.
- **The pantry's crate-size text is about 7 px** at normal pixel density
  (crisp on high-density screens). The panel's detail line shows exact values.
- **Hover is recomputed only when the pointer moves,** so after the camera eases
  into a close-up, the container under a still pointer is not highlighted.
- **Unchanged updates redo about 2,000 container matrices** and allocate a colour
  per container; cache when inputs are unchanged. (Candidate to fix.)
- **The server builds each product's crate size on every owner view** (274
  products, each scanning every recipe line); build the map once per view or per
  catalog. (Candidate to fix.)
- **`shelves()` would drop a substitute whose primary is at another vendor** (it
  cannot happen with today's data; the server test forces one vendor).
- **Staging assumes batch numbers only rise** and a clearing's trips arrive in
  one update; true of the server today.
- **Standing shoppers' offsets wrap after four rows** (eight or more still
  shoppers at a narrow stall overlap).
- **A cart line is dropped silently** when its offer becomes unusable (a
  malformed price or missing crate), losing an edited limit.
- **An invalid typed limit reverts on blur with no message.**
- **The list-only message flashes on mount** until the panel is measured.
- **When browser storage throws, the star note reappears on every remount**
  (should be once per session).
- **A `skipped` send stops silently.**
- **The "replaces pending" test passes by construction** (the panel lists only
  this session's sends); `menu_products` for a restaurant with no stall is
  untested; the panel's stop-after-uncertain `break` is not pinned (the app's own
  guard makes it redundant; the mutation survived).
- **`pushFore` clamps silently** (it guards only NaN; today's heights are well
  inside reach). `setCrates(Infinity)` does nothing instead of clamping to 99.
  `BigInt()` in the cart throws on a malformed price string (the server always
  sends canonical strings; the panel guards it).
- **Small test and code tidiness:** `management.ex` has an unreachable
  `|| MarketActivity.new()`; one management test reads `submitted_at` from the
  state rather than the committed event; the sorted-file coverage test reads the
  JSON by a regex tied to Prettier's layout (it fails loudly, not silently).
- **Open question for the final review:** whether a scene failure followed by
  disposal double-disposes the renderer.
- **Your own trip is not staged for you.** Your client skips your restaurant's
  trips because you are watching your own cart; other owners do see it.

## Checks that ran, with results

Every figure is from the builder's task report. Each run was a single named file;
no full suite ran. `bun check` is the native type check (no `tsc`).

| Task | Server | Client |
| --- | --- | --- |
| 1. Views and projection | `market_test.exs` 35 passed; `market_activity_test.exs` 6; `management_test.exs` 18; `command_workflow_test.exs` 40; `recovery_test.exs` 41; `market_flow_test.exs` 14; `architecture_test.exs` 9; `public_view_test.exs` 1; `visitor_play_test.exs` 11; `mix format --check-formatted` ok | `bun check` ok (737 files); lint, Prettier ok |
| 2. Goods mapping | `market_goods_coverage_test.exs` 5; `architecture_test.exs` 9; format ok | `market-goods.spec.ts` 5; `bun check`, lint, Prettier ok; the module bundled alone |
| 3. Cart | none | `market-cart.spec.ts` 12; `bun check`, lint, Prettier ok |
| 4. Pose | none | `people.spec.ts` 34; `people-scene.spec.ts` 1; `diner-floor.spec.ts` 32; build, `bun check` (741 files), lint, Prettier ok |
| 5. Scene | none | `market-layout.spec.ts` 8, then 9 after the click ruling, then 11 after the fix round; `market-goods.spec.ts` 5; `bun check` (744 files), lint, Prettier ok; a throwaway bundle with the JSON import built; harness screenshots checked by eye |
| 6. Panel | `management_test.exs` 19; `architecture_test.exs` 9; `public_view_test.exs` 1; format ok | final run: `market.spec.ts` 15; `owner-view.spec.ts` 1; `journeys.spec.ts` 6; `phone-layout.spec.ts` 3; `hall-interactions.spec.ts` 7; `tablet-pages.spec.ts` 1; `market-cart.spec.ts` 12; `market-layout.spec.ts` 11; `bun check` (746 files), lint, Prettier ok |
| 7. Documentation | none | none; links and anchors checked (below) |

Mutation checks (each restored, restore confirmed): the public trip made to carry
quantity (the privacy test failed); the batch state passed instead of the
pre-event state (the same-batch test failed); eight changes to the goods file and
five to the goods module each caught; the cart's limit rounding (two tests failed);
dropped `.reverse()` in tracking; a fixed pose forearm (three tests failed); a
removed click-focus guard (one failed); a loosened staging mark (one failed); a
removed hidden-tab check, which counted 114 timers instead of 0; dropped
substitutes from `menu_products`. One mutation survived (the panel's
stop-after-uncertain `break`, redundant with the app's guard). In Tasks 2, 3, 5
and 6 no red run before the code was captured; the reports show each test's
sensitivity by mutation or by reverting the code instead.

Review: Tasks 1, 2, 3 and 4 were reviewed clean. Task 5's review found one
Important issue (a timer that re-armed in a hidden tab) and two Minors made
requirements; one fix round, then clean. Task 6's review found one Important
issue (an older server leaving a sent line saying it would fill for ever); one
fix round, then clean.

## What is not verified

- **The full server and browser suites.** Never run locally; hosted CI runs them.
  Only the files named above ran.
- **A real hall with real owners.** The browser tests use a disposable hall with
  scripted views, and the scene was looked at in headless screenshots.
- **The packaged native app.** Not built or run for this work.
- **The frame rate of the market scene.** No bench was planned or run, so no
  figure exists. The scene draws on demand and only while the Supply section is
  visible; the Chromium suite uses software rendering and is not evidence.
- **Phone touch input in the scene.** The narrow layout is tested as the list;
  nothing exercised a real touch on the picture.
- **Japanese text read by a fluent reader.** A catalog check confirms every key
  exists, differs from English and has the same placeholders, and screenshots show
  no overflow, but no one has read the wording.
- **Svelte template types.** `bun check` does not check them; the build compiled
  the new files with no warnings.
- **A clearing with many owners at once.** The tests use two or three.
- **The documentation's own accuracy beyond a read against the code.** No
  automated check covers prose.

## Tuning values

Proposed defaults, easy to change, validated by no measurement:

| Value | Setting |
| --- | --- |
| Crate size | About ten servings of the largest recipe line, rounded up to 1, 2 or 5 times a power of ten |
| Cart sizes | Small 1 to 3 crates, medium 4 to 9, large 10 or more |
| Clearings kept | Six that settled at least one request (about a minute) |
| "Low" | Below 300 of 1,000 of the target stock |
| Default price limit | Published price plus 10%, rounded up to a whole minor unit |
| Settled line leaves | 60 seconds |
| Most rivals drawn at once | Eight |
| Picture needs | A panel at least 720 px wide |

## What was not built

- **A frame-rate bench**, as the spec asked for none.

## Final review

To be completed after the whole-branch review.
