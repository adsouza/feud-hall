# Supply market: what was built, the calls made, and what is unchecked

## What to decide

1. **One click adds one crate, but only in a stall's close-up.** In the
   whole-row view the containers are about 10 pixels wide, so a click there
   brings that stall into close-up instead of buying; in the close-up one click
   adds one crate. This changes the call you saw ("one click adds one crate")
   by one extra click from the row view. To undo, remove the rule; see
   [Decisions made while building](#decisions-made-while-building).
2. **A supply is starred only if a stall can cook a recipe that uses it now.**
   Stars follow each stall's menu as the kitchen cooks it (priced, the stall's
   cuisine, equipment ready). A recipe still waiting on equipment draws no star
   for its supplies. The other choice is to star everything on the
   restaurant's menu; it is a one-line change.
3. **Whether to accept the product looks.** Every one of the 274 products was
   given a vendor and a shape by judgement, and about 25 were close calls. See
   [Product looks that were judgement calls](#product-looks-that-were-judgement-calls).
4. **Automatic restock orders are listed under "On its way".** Orders placed by
   restock automation appear beside the owner's own, marked "automatic", so the
   owner sees every request the market is holding for them. If that is noise,
   they can be hidden by that mark.
5. **What became public about purchases.** Other players now see, for the two
   most recent clearings, which supplies each restaurant bought and one of
   three cart sizes. Nothing else. See
   [What became public, and what did not](#what-became-public-and-what-did-not).
6. **A stall's close-up now looks a little to the right of the stall,** to make
   room for your cart beside it, so less of the neighbouring stall on the left
   shows. You have not seen this; the other choice is a smaller cart.
7. **Whether the tuning values stand** ([Tuning values](#tuning-values)), and
   **whether to act on** the [Known limitations](#known-limitations).
8. **Whether to merge.** Nothing is pushed. A whole-branch review was done and
   its seven issues fixed ([Final review](#final-review)). Neither full test
   suite has run on this branch: open a pull request so hosted CI runs both
   before merging (see [What is not verified](#what-is-not-verified)).

Evidence for Project 5 of the
[livelier hall design](../specs/2026-11-13-livelier-hall-design.md#project-5-supply-market),
built from the [plan](../plans/2026-11-15-supply-market.md) on the branch
`supply-market`. The rules now live in the
[game design](../../GAME_DESIGN.md#the-supply-market), the contracts in the
[architecture](../../ARCHITECTURE.md#the-supply-market-view) and the checks in
[Testing](../../TESTING.md#supply-market-checks).

## What was built

- **A 3D market on the owner's Business page.** Seven vendor stalls in a row
  (greengrocer, butcher, fishmonger, dairy and eggs, grains and nuts, spices and
  tea, bakery and pantry). Clicking a stall brings it into close-up; each
  container shows how much stock is left and its published price and crate size.
  A click on a container in the close-up adds one crate to a draft cart. Nothing
  is bought until "Send order", which sends one purchase request per line through
  the same path the text form uses.
- **"On its way" lists what the market holds for you.** Every request the server
  reports as waiting for your restaurant, and the outcome of each recent one,
  wherever it was sent from: the market, the text form, another device, before a
  reload, or restock automation (marked "automatic"). Each line shows waiting,
  then filled, short (how much arrived and why) or rejected (why), and leaves a
  minute after its outcome was first shown, or when you dismiss it. Sending the
  same supply twice shows one line, because the second request replaces the
  first. A line just sent says "sent" until the server's next report includes
  it.
- **Filled crates arrive on your cart.** While a filled or short line is listed,
  its crates (filled units divided by the crate size, rounded up) stand on your
  cart closed with a green lid, in their own group beside the draft crates, and
  leave with the line. In a stall's close-up the cart stands in the foreground,
  about twice its earlier size, so both groups can be counted roughly.
- **A cart that does not lose your work.** A mistyped price limit (such as
  "2.50") stays in its field with a message, and "Send order" waits until it is
  fixed. A line whose supply stops being offered stays in the cart, marked
  unavailable, and is skipped when sending; only you remove it.
- **Stars, markers and a legend.** Supplies your menu uses are starred. Low
  stock has a red tag; a grey tag and an empty container mean the market has
  none at all. Frozen, value and preserved substitutes look different. A
  one-time note explains the stars and fades; a legend stays under the shelves.
- **Rivals shopping.** When another restaurant's purchase fills, a figure (the
  same person as at their stall) pushes an unlabelled cart of the goods bought
  past the stalls. Pointing at one shows only the restaurant's name.
- **The list.** A synchronized list with the same cart is the market whenever
  the picture is not available: no WebGL, a panel under 720 px, or a failed
  scene. The existing text form, starter stock, restock automation and pricing
  controls are untouched; the hall's Stock panel gains an "Open the market" link.
- **The picture runs only when seen.** It is created the first time the Supply
  section comes on screen and draws only while it is on screen.
- **Server fields.** The owner's view gains each product's crate size and stock
  level, the owner's own pending requests and recent outcomes, and the supplies
  the menu uses. The public hall view gains rivals' recent trips (below). No
  rule, event, command or stored state changed.
- **Presentation data and checks.** `market-goods.json` maps every product to
  its vendor, shape, colour and variant. A server test fails if a catalog
  product has no entry, and now also runs when only that file changes; a client
  test fails if any entry in it is malformed.
- **A cart-pushing pose** for figures, used for the shoppers.
- **Carts with their handle joined to the basket.** The handle's struts used to
  stop short of the basket, which showed once your cart was enlarged; they now
  run from the handle bar to the basket's rim, on every cart.
- Both languages: every new string exists in English and Japanese.

## What became public, and what did not

The public view used to carry no orders at all. It now carries, for the two
most recent clearings that settled a request, per restaurant that had a fill:
the product IDs that filled, one of three cart sizes (small, medium, large), and
the clearing's sequence number, so each trip is drawn once. It carries no time.
Guests see the same. (An earlier version also sent the clearing's time and six
clearings; nothing used them, so they were removed.)

Still private to the owner: quantities, costs, prices paid, price limits,
pending requests, unfilled amounts, reasons, request IDs, whether an order was
automatic, and the supplies the menu uses. A test encodes the public hall view
another owner receives and checks that none of those key names appear, and
checks that a guest receives the same trips. As you accepted in the design, an
attentive player can infer a rival's menu plans from the shapes of what they
buy.

## Rulings

Each line gives the ruling, the reason, and what it costs if wrong. They are
grouped by when they were made. Nothing is left out.

### Errors found in the plan, before or while building

These are mistakes in the plan, not choices. The plan was not reviewed by you
before building. A check of it against the code before building found the first
two; the third was found while building the panel; the fourth while writing the
documentation.

1. **The request ID form.** The plan said a command's ID is its request ID. In
   the code the request ID is `"PR:"` plus the command ID
   (`server/lib/feud_hall/domain/hall/decider.ex`, line 250). Ruling: the client
   derives `"PR:" + command ID` and a server test pins the form through the
   owner's view. Cost if wrong: if the prefix ever changes, the server test
   fails first.
2. **Automatic restocks are requested and cleared in the same batch.** The plan
   said a request is always created before the batch that clears it. Restock
   automation can request and clear inside one clock advance, so the state
   before the batch does not hold the request. Ruling: the outcome store reads
   each event against the state immediately before that event, in the one pass
   that already applies the batch; a test covers it through a real clock
   advance. Cost if wrong: a slightly larger change to `command_workflow.ex`
   than planned; unneeded care at worst. Deliberately reading the state from
   before the batch made that test fail.
3. **No source for the stars.** The plan assumed the client could tell which
   supplies the menu uses. Nothing it received carried recipe lines. Ruling:
   the owner's private view gains a derived `menu_products` list. Cost if
   wrong: one more private view field; to undo, remove it and the stars.
4. **No arriving crates.** The design says crates arrive on the cart when an
   order fills; the plan drew only the draft cart. Ruling: filled crates are
   drawn on your cart while their line is listed, marked so they cannot be
   taken for the draft, and only from a fill the server committed. Cost: one
   more round of work before the final review.

Smaller plan inconsistencies, each settled by reading the code:

5. **Containers per row.** The plan's six containers per row cannot hold 96
   products at the pantry. Each stall's shelf is sized from its own count
   (columns about the square root of 1.5 times the count, at least three), and a
   primary and its substitutes never split across a tier's end. Cost if wrong:
   the market reads as crowded and the layout constants change.
6. **Reason name.** The plan listed `:storage_full`; the code uses
   `:insufficient_storage`. The code won. No cost.
7. **The scene's appearance type.** The plan's interface block left out the
   vendor label, its prose included it. The later, more specific statement won.
   No cost.
8. **Pose literals.** The plan's file list for the pose work was incomplete (the
   pose appears in more files, and three test helpers it named did not exist).
   Every file that needed it was edited and the helpers written. No cost.
9. **Tests written as comments.** Some tests in the plan were comments. Each
   was treated as a specification and became real assertions: a test that
   asserts nothing is a defect. No cost.
10. **Sending returned nothing.** The panel needs to know what happened to each
    send and its command ID. Ruling: the app's one sending function now reports
    accepted, refused, uncertain or skipped, with the command ID, and existing
    callers are unchanged. After an uncertain result, sending stops and the
    remaining lines stay in the cart (the app holds one uncertain command at a
    time). Cost if wrong: an owner with a lost response must use the existing
    Retry before the rest of the cart goes.
11. **A product that substitutes for two primaries.** The plan was ambiguous
    there. Ruling: the lowest ID wins. Moot: no launch product does.
12. **Empty vendors and money formats.** A vendor with no products is omitted,
    and a pending request's price limit is a cents string like the view's other
    money. No cost.

### Design decisions made in the plan

1. **Recent outcomes are a short-lived read model, not hall state.** They are
   built from committed events beside the existing counter animation markers,
   which avoids changing the stored state and every snapshot. Cost if wrong: the
   store is empty after a restart, so an outcome settled just before a restart
   shows as "settled, check your stock" and rivals' recent trips start from
   nothing.
2. **The server computes crate size and stock level** and sends them with each
   price, so the picture, list, cart and tests share one definition. Cost if
   wrong: the client could compute them, but two definitions would drift.
3. **Crate size is ten servings** of the largest recipe line using the product,
   rounded up to 1, 2 or 5 times a power of ten. Cost if wrong: crates are a
   little larger than ten servings for some products.
4. **Cart sizes and window.** One to three crates is small, four to nine medium,
   ten or more large; six clearings (about a minute) are kept for the owner's
   outcomes; a container is "low" below 30% of its target stock at the demand
   floor. Tuning only.
5. **The mapping lives in `app/src/market-goods.json`** and a server test checks
   it against the launch catalog, because the client has no catalog at test
   time and the design requires a failing check for a missing product. Cost if
   wrong: move the check to a browser test against a live hall.
6. **No frame-rate measurement** for the market scene; the design asks for none.
   See [What is not verified](#what-is-not-verified).

### Decisions made while building

The server:

- **Trip size sums exact crate fractions and rounds up once** (1.5 and 1.5
  crates is 3, small, not 2 plus 2). The design says "roughly how much". Tuning
  only.
- **The outcome store has no separate batch walk of its own.** It is updated
  inside the same pass that applies each batch, so it cannot drift from the
  real one. The counter markers' own separate walk, which only a test still
  used, was removed. No cost.
- **Where a request has several shortfalls its reason is the first.** No cost.
- **Each outcome says whether restock automation sent it,** taken from the
  committed request, so the list can mark automatic orders even after a reload.
  Private to the owner. No cost.
- **Crate sizes are computed in one pass per view.** The first version scanned
  every recipe line for each of the 274 products on every owner view, about
  3 ms each time, inside the hall's single process and every 850 ms per owner
  online. Now one pass serves the whole view and one each clearing. A test
  checks the result against an independent per-product scan for every launch
  product. No cost.
- **Public trips lose their time and keep two clearings, not six.** Nothing read
  the time, and a client draws only clearings newer than the last it saw. Cost
  if wrong: a client that polls less often than every 20 seconds misses a
  rival's trip, which only means no shopper is drawn.

The data:

- **The coverage test pins no product count.** `AGENTS.md` forbids hardcoding a
  roster count; the test derives both sides from the catalog. No cost.
- The JSON import uses `with { type: "json" }` because the browser test runner
  cannot load a bare JSON import. No cost.
- **The shelves never drop a product.** A substitute whose primary is at another
  vendor, or is itself a substitute, stands as a primary. It cannot happen with
  today's data, but the report tells you a look is a one-line edit, and such an
  edit must not make a product vanish. A randomized test checks every product
  appears exactly once. No cost.

The cart:

- **Setting crates to NaN, or for a product not in the cart, changes nothing**,
  and at the 99-crate maximum adding a crate returns an equal cart. No cost.
- **A mistyped limit blocks sending** instead of silently reverting to the
  previous limit, which sent an order at a price you had not seen accepted.
  No cost.
- **An unavailable line stays in the cart** instead of being dropped with its
  edited limit when the server's data for it is briefly unusable (for example a
  rollback to an older server). No cost.

The pose:

- **The hand position takes the figure's stride,** because walking moves the
  hand slightly. No cost.

The scene:

- **A shopper never blocks a purchase click.** Clicks pick containers and stalls
  only; hovering a shopper still names the restaurant. A rival walking past must
  not eat your click. No cost.
- **A container adds only when its stall is in close-up; in the whole-row view
  any click on a stall brings it into close-up.** See
  [What to decide](#what-to-decide). Cost if wrong: remove the rule.
- **A test-only attribute gives the screen position** of the selected container,
  so a browser test can click a real container. No cost.
- **A clearing already seen is never drawn again,** so a reconnect cannot replay
  old clearings as a burst of shoppers. No cost.
- **With motion off, shoppers stand in the aisle in front of the first stall**,
  inside the close-up. No cost.
- **The scene was checked by eye** with a temporary page and screenshots from a
  real graphics processor, because a scene judged only by test attributes can be
  unreadable. Cost: builder time. (That review also found, and a fix stopped, a
  timer that re-armed every 20 ms in a hidden tab.)
- **Your own trip is not drawn for you** as a shopper; you see your purchase as
  crates on your cart. Other owners do see it. Cost if wrong: one filter.
- **Your cart is legible in the close-up.** It stands in the foreground right of
  the stall, seen from the side, spanning about 13% of the picture's width
  (about twice its earlier size at the largest stall), with draft crates and
  arrived crates in two separate groups of at most 36 each. The close-up frames
  a little right of the stall to make room (see
  [What to decide](#what-to-decide)). The cart is never picked by a click.
  Cost: tuning.
- **The scene is created when first seen and draws only while on screen,**
  rather than whenever the Business page is open, as the design says. WebGL is
  checked once up front so that without it the list says it is the market
  before you scroll to it. No cost.
- **Test attributes report what is drawn,** so a test fails if a crate is not
  drawn; separate attributes give the counts asked for. No cost.

The panel:

- **Drafts live outside the panel**, so the cart, chosen stall and typed limits
  survive leaving the Supply section and coming back in a session. Only the star
  note flag is kept across a reload. No cost.
- **"On its way" is built from the server's own lists,** not only from what this
  page sent. The first version listed only this page's sends, so after a reload,
  on a second device, or for a text-form order the list was empty, and a price
  rejection was never shown. Cost if wrong: automatic orders may be noise and
  can be filtered by their mark.
- **A second send of a supply drops the first line,** because the server
  replaced that request; one line is shown, never a false "settled". No cost.
- **Uncertain sends are resolved inside the app's sending function,** not in the
  panel, so a Retry made while the Supply section is closed still settles the
  line. No cost.
- **The legend explains the frozen, value and preserved looks and the empty
  tag,** and "preserved" is the word because it includes chilled products. The
  green-lid entry shows only when the picture does. No cost.
- **The market is on the Business page only;** the hall's Stock panel gets an
  "Open the market" link and keeps its text panel, as the design says.
- **`menu_products` follows each stall's menu as the kitchen cooks it.** See
  [What to decide](#what-to-decide). Cost if wrong: one line.
- **Smaller choices, accepted:** the panel reads the reduced-motion setting
  itself; the "Dismiss" label has its own key because the existing one means
  firing staff; the existing purchase dropdown now shows "Price unavailable" for
  a malformed price instead of breaking the page (a real defect a test found);
  the Supply section spans the full row of the Business grid (three lines of
  `style.css`), needed for the 720 px threshold; accessible names are whole
  translated messages with the product name as a parameter.
- **An older server shows no outcomes.** Without the purchase lists, a sent line
  says only "Sent. Check your stock for what arrived." and leaves after a
  minute, instead of promising a fill.

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

Each is one line. The first group is what a player would notice.

What a player would notice:

- **The whole-row view leaves a lot of empty ground** above and below the row,
  and your cart there is small (it is legible only in a close-up).
- **The app's "Updated" notice can overlap the cart's edge** briefly after a
  send (existing behaviour).
- **Some product names show as lowercase fallbacks** where the app's existing
  name helper has none; this predates the market.
- **In a close-up of a narrow stall, your cart can stand in front of the
  neighbouring stall on the right**, never in front of the stall you are
  looking at; clicks pass through it.
- **The pantry's crate-size text is about 7 px** at normal pixel density
  (crisp on high-density screens). The panel's detail line shows exact values.
- **Hover is recomputed only when the pointer moves,** so after the camera eases
  into a close-up, the container under a still pointer is not highlighted.
- **When browser storage is unavailable, the star note reappears** each time the
  market is opened, instead of once per session.
- **A send skipped because the app is busy stops without a message.**
- **A replaced order can read "settled".** If another of your devices replaces
  an order and the replacement clears while this page was not checking (for
  example a background tab the browser slowed down), the first order shows as
  "settled, check your stock" beside the replacement's result.

For whoever works on it next:

- **Unchanged updates redo about 2,000 container positions.** The panel already
  skips unchanged updates, so this happens only on a real change.
- **Drawing of rivals assumes clearing numbers only rise** and a clearing's
  trips arrive together; true of the server today.
- **Standing shoppers overlap after four rows** (eight or more still shoppers at
  a narrow stall).
- **The panel's stop after an uncertain send is not pinned by a test** (the
  app's own guard makes it redundant; deliberately removing it changed no test).
- **Silent clamps:** the pushing pose clamps an out-of-reach handle; setting a
  line to infinite crates does nothing rather than 99; the cart's arithmetic
  throws on a malformed price string, which the panel guards.
- **Small tidiness:** an unreachable fallback in `management.ex`; one test reads
  a request's time from the state rather than the event; the sorted-file check
  reads the JSON by a pattern tied to the formatter's layout (it fails loudly).
- **The list-only message no longer risks showing before the panel is
  measured;** no flash could be reproduced in Chromium even without the guard,
  so no test pins it.

## Checks that ran, with results

Each run was a single named file; no full suite ran. `bun check` is the native
type check (no `tsc`). Some tests were proven by deliberately breaking the code
to see the test fail, then restoring it.

| Work                         | Server                                                                                                                                                                                                                                                               | Client                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Views and outcome store      | `market_test.exs` 35 passed; `market_activity_test.exs` 6; `management_test.exs` 18; `command_workflow_test.exs` 40; `recovery_test.exs` 41; `market_flow_test.exs` 14; `architecture_test.exs` 9; `public_view_test.exs` 1; `visitor_play_test.exs` 11; format ok   | `bun check` ok (737 files); lint, Prettier ok                                                                                                                                                                                                                                                                                                                                  |
| Goods mapping                | `market_goods_coverage_test.exs` 5; `architecture_test.exs` 9; format ok                                                                                                                                                                                             | `market-goods.spec.ts` 5; `bun check`, lint, Prettier ok; the module bundled alone                                                                                                                                                                                                                                                                                             |
| Cart model                   | none                                                                                                                                                                                                                                                                 | `market-cart.spec.ts` 12; `bun check`, lint, Prettier ok                                                                                                                                                                                                                                                                                                                       |
| Pushing pose                 | none                                                                                                                                                                                                                                                                 | `people.spec.ts` 34; `people-scene.spec.ts` 1; `diner-floor.spec.ts` 32; build, `bun check` (741 files), lint, Prettier ok                                                                                                                                                                                                                                                     |
| Scene                        | none                                                                                                                                                                                                                                                                 | `market-layout.spec.ts` 8, then 9 after the click rule, then 11 after the hidden-tab fix; `market-goods.spec.ts` 5; `bun check` (744 files), lint, Prettier ok; screenshots checked by eye                                                                                                                                                                                     |
| Panel                        | `management_test.exs` 19; `architecture_test.exs` 9; `public_view_test.exs` 1; format ok                                                                                                                                                                             | `market.spec.ts` 15; `owner-view.spec.ts` 1; `journeys.spec.ts` 6; `phone-layout.spec.ts` 3; `hall-interactions.spec.ts` 7; `tablet-pages.spec.ts` 1; `market-cart.spec.ts` 12; `market-layout.spec.ts` 11; `bun check` (746 files), lint, Prettier ok                                                                                                                         |
| Arriving crates              | none                                                                                                                                                                                                                                                                 | `market.spec.ts` 16; `market-cart.spec.ts` 13; `bun check`, lint, Prettier ok                                                                                                                                                                                                                                                                                                  |
| Documentation                | none                                                                                                                                                                                                                                                                 | links and anchors checked                                                                                                                                                                                                                                                                                                                                                      |
| Fixes after the final review | `management_test.exs` 20; `market_activity_test.exs` 6; `command_workflow_test.exs` 40; `recovery_test.exs` 41; `visitor_play_test.exs` 11; `market_test.exs` 36; `public_view_test.exs` 1; `architecture_test.exs` 9; `market_goods_coverage_test.exs` 5; format ok | `market.spec.ts` 24 (one of them end to end); `market-cart.spec.ts` 24; `market-layout.spec.ts` 13; `market-goods.spec.ts` 8; `people-scene.spec.ts` 1; `owner-view.spec.ts` 1; `journeys.spec.ts` 6; `phone-layout.spec.ts` 3; `hall-interactions.spec.ts` 7; build, `bun check` (746 files), lint, Prettier ok; screenshots of the close-up and the whole row checked by eye |
| Cart handle and the second look | none | `market-layout.spec.ts` 14; `market-cart.spec.ts` 26; `market.spec.ts` 24 (run after each of the two commits); build, `bun check`, lint, Prettier ok; screenshots of your cart and a rival's cart checked by eye |

Checks made by breaking the code on purpose (each restored): the public trip made
to carry a quantity (the privacy test failed); the state before the batch used
instead of the state before each event (the same-batch test failed); eight
changes to the goods file and five to the goods module; the cart's limit
rounding; the order of "On its way"; a fixed pose forearm; a removed click-focus
guard; a loosened rule for clearings already seen; a removed hidden-tab check
(114 timers instead of 0); substitutes dropped from the starred list. After the
final review: crate sizes ignoring substitutes; the outcome store adopted before
the append; the no-stall menu fallback removed; the automatic mark always off;
the panel listing only its own sends (the reload, sent-elsewhere and text-form
tests failed); "settled" from a view older than the send; no outcome memory;
replaced requests not hidden; the old limit behaviour; the old dropping of
unavailable lines; the scene created at once rather than when seen; summed
instead of drawn crate counts; the old shelves rule; a misspelt vendor in the
goods file. Each made its test fail. One survived: the panel's stop after an
uncertain send, redundant with the app's guard.

The end-to-end browser test was also checked the other way: with a price limit
of one cent the real server rejected the order for price and the test failed
at "filled".

## What is not verified

- **Both full suites.** Hosted CI runs them; none has run on this branch. Only
  the files named above ran. `command_workflow.ex` is on every command's path,
  so the full server suite matters here.
- **A real hall with real owners.** The browser tests use a disposable hall;
  all but two market cases answer the purchase command themselves and serve
  edited views. One case sends a real order to the real server and sees it
  filled.
- **The packaged native app.** Not built or run for this work.
- **The frame rate of the market scene.** No measurement was planned or run, so
  no figure exists. The browser suite uses software rendering and is not
  evidence.
- **Phone touch input in the scene.** The narrow layout is tested as the list;
  nothing exercised a real touch on the picture.
- **Japanese text read by a fluent reader.** A check confirms every key exists,
  differs from English and has the same placeholders; no one has read the
  wording.
- **Nothing type-checks the Svelte components.** `bun check` reads only `.ts`
  files; a wrong value passed to the panel is caught only by a browser test that
  exercises it. The logic was kept in `.ts` modules for that reason. A
  component check in hosted CI is a recommended follow-up.
- **That the scene stops drawing when scrolled away again.** Its creation on
  first sight is tested; stopping is not.
- **A clearing with many owners at once.** The tests use two or three.

## Tuning values

Proposed defaults, easy to change, validated by no measurement:

| Value                      | Setting                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------- |
| Crate size                 | About ten servings of the largest recipe line, rounded up to 1, 2 or 5 times a power of ten    |
| Cart sizes                 | Small 1 to 3 crates, medium 4 to 9, large 10 or more                                           |
| Clearings kept             | Six that settled at least one request (about a minute) for your outcomes; two for public trips |
| "Low"                      | Below 300 of 1,000 of the target stock at the demand floor                                     |
| Default price limit        | Published price plus 10%, rounded up to a whole minor unit                                     |
| A line leaves "On its way" | 60 seconds after its outcome is first shown                                                    |
| Most rivals drawn at once  | Eight                                                                                          |
| Picture needs              | A panel at least 720 px wide                                                                   |
| Your cart in a close-up    | About 13% of the picture's width; at most 36 draft and 36 arrived crates drawn                 |

## What was not built

- **A frame-rate measurement**, as the design asked for none.

## Final review

A whole-branch review found no blocking faults and seven issues worth fixing
before merge. All seven were fixed:

1. "On its way" showed only what the page had sent since it loaded: it is now
   built from the server's own lists of waiting requests and outcomes.
2. Sending a supply twice showed two lines, the first wrongly "settled": now one
   line, and "settled" only when a fresh report truly lacks the order.
3. Crate sizes cost about 3 ms of the hall's single process on every owner view:
   now computed in one pass per view.
4. The picture was built and animated while scrolled out of sight: it is now
   created when first seen and draws only while on screen.
5. The goods check did not run when only the goods file changed, and a malformed
   entry or a cross-vendor substitute could make a product vanish: the check now
   runs, every entry is checked, and the shelves never drop a product.
6. No test sent a market order to the real server: one now does, end to end.
7. A mistyped price limit was discarded and the order went out at the old
   limit: it now stays, is marked, and blocks sending.

The review's smaller points were fixed too: outcomes remembered for their
minute; "sent" until a fresh report; unavailable cart lines kept; test
attributes that report what is drawn; a test that the outcome store is adopted
only when saving succeeds; public trips trimmed; "out of stock" meaning none;
an independent bound in the limit test; the legend and accessible names; and
these documents. Screenshots of the close-up and the whole-row view were checked
by eye.

After a second look at these fixes, three more small things were fixed: an
order confirmed late (by Retry, more than a minute after the market had already
filled or rejected it) now shows its outcome for a minute instead of vanishing;
a mistyped limit on a line whose supply became unavailable no longer keeps
"Send order" disabled for the other lines (the text is kept for when the supply
returns); and the cart's handle is joined to its basket.

Still not verified: both full suites (hosted CI runs them; none has run on this
branch), a real hall, the packaged app, the scene's frame rate, phone touch in
the scene, Japanese read by a fluent reader, and that nothing type-checks the
Svelte components.
