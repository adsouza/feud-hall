# Livelier Hall and Visual Supply Market — Design

**Approved by the owner on 2026-11-13. Nothing here is implemented.** A fresh
reviewer read it as a builder would before approval; the answers to their
questions are folded in below.

This document scopes five projects that came out of one request: "make the
game more fun". Unlike the
[Milestone 2 design](2026-11-09-milestone-2-design.md), it **does change
gameplay rules and presentation contracts**. Each project lists the sections of
the [game design](../../GAME_DESIGN.md) and
[architecture](../../ARCHITECTURE.md) it must update; those documents stay the
owners of rules and contracts, and a project is not complete until they agree
with what was built.

Two kinds of decision appear below:

- **(owner decision, 2026-11-13)** — chosen by the owner in the design
  conversation. Changing it needs the owner.
- **(designer's call)** — chosen while writing this up, within the owner's
  decisions and the existing contracts. It may be revisited without reopening
  an owner decision. Where a designer's call was shown to the owner as a guess
  and accepted without change, it says **(designer's call, owner saw it)**.

## Intent

The owner played as a stall owner and reported two disappointments:

1. They expected to do more from inside the 3D hall. Buying supplies in
   particular is not fun: there is nothing to look at, only text to select.
2. The game feels slow because there are not enough diners in the hall.

Investigation found the causes:

- Supplies are bought through one dropdown listing every product as text plus
  two number boxes (`app/src/App.svelte`, supply section of `managementPanel`).
  The launch catalog has 117 products and no artwork for any of them.
- A sparse hall receives a fixed 270 potential diners per game day, shared by
  all stalls. A stall at the lunch peak averages about one visible diner.
- Most diners who exist are never drawn. The scene shows only orders in a
  kitchen (at most four per stall), for 10–20 real seconds each. Nobody sits
  and eats; diners who look and leave are invisible.
- People are drawn as a capsule with a ball head and stub legs.
- Stall positions in the scene are unrelated to the location quality the
  server charges rent for, and the hall has no entrance.

The aim is a hall that looks and feels inhabited, with enough real trade to
keep an owner busy, and a supply market where buying is something you see and
touch and where rival buying is visible.

## Goals

- People look like people, everywhere they appear.
- The hall is a row of small halls that fill up in order, with tables in the
  middle and location quality visible in where a stall stands.
- Diners who exist are seen: queuing, browsing, eating, leaving.
- More real customers, tuned to an agreed feel, with supply to serve them.
- Buying supplies is visual, and rivals can be seen shopping.

## Non-goals

- Imported or downloaded character models.
- Seating or pedestrian collisions as economic constraints (the game design
  keeps these as presentation in the first release).
- Live avatars or position sharing for other players.
- The supply market as a place inside the hall's 3D world.
- Rebalancing prices, rents or wages. Project 4 reports the profit effect and
  the owner decides afterwards.
- New owner actions on the in-world stall tablet, or reports and ledgers inside
  the hall.
- An owner-facing "customers lost and why" report. The data exists; it was not
  asked for.
- Restock automation and pricing policy redesign. Those controls stay as text.
- Single-player execution, native phone apps.

## Anti-goals

These would make the work a failure even if it ran:

- A figure that is not backed by a diner or purchase the server committed.
  Decoration must never pass as custom.
- Animation that implies a purchase or sale that has not been committed.
- More arrivals that mostly walk away. Success is measured in served meals.
- A second submitting path for purchases or leases. The scene produces drafts
  and intents; `App.svelte` use cases submit.
- Losing the HTML, no-WebGL or phone equivalents of any action.
- Labels, quantities or prices on a rival's cart.
- A stall that moves after it has been placed.
- A customer pool that grows because someone added stalls.
- An existing hall whose rules change without a recorded event, or an existing
  lease or accepted order whose terms change.

## Existing contracts that constrain this work

- The server owns outcomes; the renderer emits typed intents only
  ([architecture, commands and synchronization](../../ARCHITECTURE.md#commands-state-synchronization-and-authorization)).
- One hall-wide finite arrival pool; adding stalls, rows or devices never
  multiplies it ([game design §7](../../GAME_DESIGN.md#a-finite-pool-of-diners)).
  Confirmed, not tuning.
- Representative figures "must not masquerade as extra paying customers";
  counts and inspection stay exact
  ([game design §15](../../GAME_DESIGN.md#performance-and-truthful-animation)).
- Managing must not require avatar travel or camera precision; an HTML
  management/list view must work without WebGL; phone layouts expose the same
  core actions.
- English and Japanese for every new string, with stable message codes.
- Money crosses the wire as canonical decimal integer strings.
- Managed halls receive rule and catalog changes through recorded events that
  preserve pinned terms (`hall_catalog_expanded`, `hall_simulation_upgraded`,
  `visitor_play_enabled` are the precedents).
- Queries cannot accrue time or write. Anything new in a view is derived from
  committed state.
- Local verification limits in [AGENTS.md](../../../AGENTS.md#verification-and-local-resource-limits):
  no local `tsc`, no full suite without permission, 2 GiB combined RSS.
- A usable 30 fps low-detail hall on the reference machine is the design's
  performance target.

## Projects and order

| # | Project | Touches | Depends on |
| --- | --- | --- | --- |
| 1 | People | client | — |
| 2 | Row of halls | client, server lease and rent rules, catalog | — |
| 3 | Visible diners | client, one public view field | 1, 2 |
| 4 | More real customers | server tuning, recorded rule change | — (its effect is seen through 3) |
| 5 | Supply market | client, one public view field, the owner's own order status | 1 |

**(designer's call)** Build in this order. Each project gets its own
implementation plan, is verified on its own, and updates its own documentation.
Projects 2 and 4 are the only ones that change server rules.

**Look references.** The owner reacted to five browser mockups: the market's
first look, rivals in the market, the three-way people preview, the busy hall
from above, and the row of rooms. They are throwaway files kept outside version
control under `.superpowers/brainstorm/` in the owner's checkout and will not
exist in a fresh clone or worktree. This document describes what was agreed in
words; where a mockup and this document differ, this document wins.

---

## Project 1: People

**(owner decision, 2026-11-13)** People are the "rounded" figures the owner
chose from a live three-way preview: proportioned bodies built in code from
basic shapes, not the current capsule-and-ball figures, not box-built figures,
and not imported models.

What a rounded figure has:

- Upper and lower legs with a knee, and feet.
- A torso wider than it is deep, a neck, and a head carrying the existing
  painted face (two eyes and a smile).
- Upper arms and forearms with an elbow, and hands.
- Hair: a cap over the crown, in four styles (short, long at the back, bun,
  and a brimmed cap in a clothing colour).
- Clothing variety: trousers or a skirt; long or short sleeves.
- Build variety: height and width each vary by roughly ±8–10%.
- Walking: hips swing, the trailing knee bends, arms counter-swing, a small
  bob. Standing: the head turns to look around and the body sways slightly.

**(designer's call, owner saw it)**

- Every person uses this figure: diners, kitchen staff, owners, helpers and
  market shoppers, in the hall and in the market. The first-person pickup arms
  are unchanged.
- Owners wear an apron so a rival can be told from a diner.
- A person's look is derived from the same stable serial the scene uses today,
  so a figure never changes appearance between frames or snapshots.
- Distant and reduced-detail figures are drawn simpler (single-piece limbs, no
  hands, hair reduced to the cap) while keeping the silhouette.
- Colours reuse the scene's existing shirt and skin palettes; hair and trouser
  palettes are added.

**(designer's call)**

- Figures stay batched. Each body part is drawn as an instanced mesh, as bodies
  and heads are today; no per-person draw calls.
- The people code moves out of `hall-scene.ts` into its own module so the
  market scene can use it.
- Poses needed by later projects are part of this module: carrying a tray
  (exists today), seated (Project 3), pushing a cart (Project 5).

**Left to the builder:** exact dimensions, instancing layout, distance
thresholds, how reduced motion is honoured.

**Verification:** unit tests for pose and variety determinism; the existing
browser specs that exercise the hall still pass; frame time measured before and
after in the densest view the scene can show, reported with the hardware. The
throwaway preview did not test batching, so this measurement is the evidence
that the figure is affordable.

**Pass bar (designer's call).** The game design's reference machine is still to
be agreed, so the bar is this workstation: at least 30 fps in the densest
low-detail view, measured again after Project 3 adds diners. A result below
that sends the builder back to simplify the figure; it is not merely reported.

**Documentation:** game design §15 visual language.

---

## Project 2: Row of halls

In this document a **room** is one of the small halls. Player-facing text
calls them "Hall 1" to "Hall 10" **(designer's call)**; "the hall" keeps its
existing meaning in the rules, the whole economic place.

### Owner decisions (2026-11-13)

- The hall is a row of ten square rooms, each holding up to 15 stalls around
  its walls, with the centre kept for tables. The island blocks in the middle
  of the floor go away.
- Each room has its own entrance from outside.
- Neighbouring rooms are joined by doorways that stay shut until the next room
  is in use. At the start only room 1 is used.
- The next room opens once every spot of any one price class is taken across
  the rooms already open.
- Location quality is tied to where a stall actually stands.
- The scene draws roughly one room at a time. Rooms directly connected through
  an open doorway may be shown too.

### Spots, rooms and quality

- Each of the 150 spot IDs has a fixed room and a fixed position in that room.
  A stall never moves.
- **(designer's call)** Room membership is rule data, because the server needs
  it to decide which spots can be leased. The versioned catalog layout gains a
  room number and a position index for each spot. Coordinates for a position
  index are presentation data on the client.
- **(designer's call)** The catalog's existing quality of each spot does not
  change, so no existing lease changes class. The totals stay 40 quiet, 60
  standard, 35 busy and 15 prime. Fifteen per room does not divide those
  evenly, so rooms alternate: odd rooms hold 4 quiet, 6 standard, 3 busy and
  2 prime; even rooms hold 4 quiet, 6 standard, 4 busy and 1 prime. Within each
  class, ascending spot IDs fill rooms in order, so room 1 holds `s001`–`s004`,
  `s041`–`s046`, `s101`–`s103` and `s136`–`s137`. The lowest spot IDs of every
  class are in room 1, which is where computer-run owners look first.
- **(designer's call, owner saw it)** Quality follows position: prime beside
  the outside entrance, busy beside the doorways to neighbouring rooms,
  standard along the remaining wall, quiet in the corners. Where a room's mix
  does not fill every such position (one prime in even rooms, three busy in odd
  rooms), the leftover position is standard.
- The end rooms have a blank wall where a further doorway would be.

### Which rooms are open

**(designer's call)** "Open" is derived from committed state, never stored
separately, so the lease check and the view cannot disagree:

- Room 1 is always open.
- Room *k*+1 is open when rooms 1..*k* are open and, for at least one quality
  class, every spot of that class in rooms 1..*k* is leased.
- A room is also open when it, or any later room, holds a lease, a draft
  reservation or an outstanding first-location offer. This keeps the row
  contiguous in halls that existed before this rule and stops a room closing on
  a tenant.
- A room that satisfies none of these is closed. A room can therefore close
  again when a departure reopens a class and the room is empty.

Draft reservations do not count as "taken" for the opening test, so an expiring
draft cannot make a room flicker open and shut.

### What a closed room means

**This is a rule change.** Today any vacant spot of the 150 can be reserved.

- A spot in a closed room cannot be reserved, leased, offered from the waiting
  list or chosen by a computer-run owner.
- The public view states each spot's room and whether that room is open, so
  human owners, the lease list and the computer-run planner all see the same
  availability.
- The newcomer vacancy reserve in the game design's tuning register is not
  implemented in the server today. This project does not add it.
- First-location offers keep their FIFO order and draft deadlines. An offer is
  only made for a spot in an open room.

**Known consequence.** Odd rooms have two prime spots and even rooms one, so
prime is the class most likely to run out first and open the next room while
the current one is still sparse. The owner gave two answers:

- **(owner decision, 2026-11-13)** A new hall does not start with a
  computer-run restaurant on a prime spot. The "premium" computer-run
  restaurant takes a standard spot instead, leaving both of room 1's prime
  spots free.
- The scarcity rent below, which makes the last spots of a class expensive so
  that classes fill evenly. It is a strong nudge, not a guarantee: an owner who
  pays the premium still opens the next room.

**(designer's call)** The first answer is made by changing the premium
profile's preferred class from prime to standard in the catalog's computer-run
profiles. It therefore also applies whenever that profile chooses a spot later,
not only when a hall is created. Its prices and ingredient policy are
unchanged. A new hall's three computer-run restaurants then stand on `s001`
(quiet), `s041` and `s042` (standard), all in room 1. Computer-run restaurants
in halls that already exist keep their leases.

### Scarcity rent

**(owner decision, 2026-11-13)** A quality class's rent rises as that class's
relative availability falls.

**This is a rule change.** The game design's proposed default is "published
fixed tiers". The confirmed rule that better locations cost more, and are shown
before choosing, still holds.

**(designer's call, owner saw it)**

- Only new leases pay the scarcity rent. A lease records the rent it was quoted
  and keeps it, as leases do today; no existing tenant is repriced. An owner
  who signs when a class is nearly full keeps paying more than a neighbour who
  signs after the next room opens.
- The rise is capped, and the numbers are proposed tuning.
- A class's quoted rent always stays below the current quoted rent of the next
  class up, so a nearly full quiet class can never cost as much as standard.

**(designer's call)**

- The quote for a class is its base rent times a factor that depends on the
  share of that class's spots, across the open rooms, that are leased. Proposed
  tuning: the factor is 1 when none are leased and rises in a straight line to
  1.5 when one spot of the class remains. Draft reservations do not count as
  leased, matching the room-opening test.
- When a room opens, the class has more spots, the leased share falls, and new
  quotes drop.
- The closed-state holding fee scales by the same factor. The exposure factor
  does not change: scarcity affects what a spot costs, never how many diners
  pass it.
- A draft reservation or first-location offer holds the rent it was quoted
  until its existing deadline.
- Computer-run owners choose within their budgets using the current quote, like
  human owners. The three restaurants a new hall starts with therefore lease at
  or near base rent.
- Every place that shows a rent shows the current quote: the lease list, the
  "to let" bay, the expansion estimate and break-even figures. Each explains
  the rise in one plain line (for example, how many spots of the class are
  taken and how far above base the rent is), in English and Japanese.
- Arithmetic is exact integers with one documented rounding rule. The rent
  shown, quoted and recorded agree.

### The scene

- The corner-first, bisecting placement and the island layout in
  `app/src/hall-layout.ts` are replaced by the fixed lookup above.
- The viewer's current room is drawn in full. Rooms reached through an open
  doorway are drawn at reduced detail **(designer's call: directly adjacent
  rooms only)**. Closed rooms are not drawn beyond their shut door.
- Moving between rooms: walk through a doorway, or use a room control that
  needs no walking **(designer's call)**. Selecting a stall anywhere (the list
  view, the Business page, the owner's stall picker) moves the camera to that
  stall's room. An owner's first view frames their own room; a visitor's frames
  room 1.
- **(designer's call, owner saw it)** A vacant spot in an open room is an open
  bay with a "to let" sign. Selecting it shows the same quality, rent, holding
  fee and exposure explanation as the lease list, and offers the existing
  reserve or lease action through the existing use case and shared draft state.
- Each room's centre holds tables and seats as scenery. Project 3 puts diners
  at them.
- The list view groups stalls by room and remains complete without WebGL.
- Everything that works in the hall today keeps working: the owner's view from
  behind the counter, stall tablets, tray pickup, walking, the workbench.

### Existing halls

Adding rooms to the layout and enforcing availability reaches managed halls
through a recorded event, following the existing catalog-expansion and
simulation-upgrade pattern. Existing leases keep their spot and terms. Events
before the change replay under the old rule.

**Left to the builder:** room dimensions and exact coordinates, the room
control's form, door and entrance artwork, how adjacent rooms are simplified,
the event's name and shape.

**Verification:**

- Server examples at each boundary: the last spot of a class leased opens the
  next room; a surrender that reopens a class closes an empty next room; a
  draft or offer keeps its room open; a reservation in a closed room is
  refused; replay across the change agrees with live state.
- A property: no lease, draft or offer ever exists in a room the rule calls
  closed, and the open rooms are always a contiguous prefix.
- Scarcity rent examples: the first and the last spot of a class; the cap; a
  class held below the next class up; a room opening lowering new quotes; an
  existing lease's rent unchanged by any later quote; the recorded rent equal
  to the quote shown. A property: within a fixed set of open rooms the quote
  never falls as more of the class is leased, and class order is preserved.
- The guard is exercised through the application boundary, with a
  demonstration that removing it makes a test fail.
- Client unit tests: 150 spots map to 150 distinct, non-overlapping positions
  whose quality matches the position rule; the room mix matches the catalog.
- Browser regression for moving between rooms and leasing from a "to let" bay.
  Specs that asserted the old rotated island layout are replaced.

**Documentation:** game design §6 (rooms, the opening rule, quality by
position, the closed-room lease rule, and scarcity rent in place of fixed
tiers), §14 (computer-run slot choice), §15, the §21 tuning register, the
correctness scenarios, and the architecture's hall presentation section.

---

## Project 3: Visible diners

**(owner decision, 2026-11-13)** At a busy stall the owner wants to see a queue
at each stall, a few people wandering between stalls, and people eating at
tables nearby.

**(designer's call, owner saw it)**

- A served diner carries the tray to a table, eats for about a minute of real
  time, then leaves through the room's entrance.
- An arriving diner walks in and passes a stall or two before joining the queue
  the server put them in, or walking out.
- Diners who leave without buying are shown leaving. They are real arrivals
  that today are never drawn.
- The "orders waiting" number on each stall stays exact at all times, including
  while a figure is still walking to the queue.
- From 03:00 to 05:00 the floor is empty, as now.
- Tables are scenery. A full table never blocks or delays a sale.

### Truthfulness rule

Every drawn figure is staged from a diner the server committed. The client may
delay, route and simplify; it may thin a crowd evenly when it exceeds a drawing
budget; it never adds a figure. This is the existing "representative crowd"
allowance in game design §15, used in one direction only.

### Data

- Queues and served trays are already visible to the client through each
  stall's `activity.waiting` and `last_service`.
- Browsers and leavers need the hall's arrival counts. The domain already keeps
  a running `demand.today` with arrivals, admitted and left-by-reason. The
  public hall view gains today's cumulative **arrivals, admitted and left as
  totals** **(designer's call)**. Reasons for leaving, and any per-stall
  breakdown of lost diners, stay out of the public view.
- The client stages figures from the change in those totals between snapshots.
  Individual diners are not identified, so staging is count-true, not
  identity-true: for each increase in a stall's waiting count a browser ends at
  that stall's queue; for each arrival that was not admitted a browser walks
  out.
- Walk-outs are staged from **arrivals minus admitted**, not from the "left"
  total. "Left" also counts admitted diners whose order later failed, who are
  already drawn in a queue.

**(designer's call)**

- A diner bound for a stall enters by that stall's room entrance. Leavers are
  spread across open rooms' entrances deterministically.
- The queue is drawn up to the server's queue limit, not the current four.
- If no seat is free in the room, the served diner leaves as they do today.
- Loading or reconnecting starts from the current counts. There is no replay of
  earlier arrivals and no burst of figures.
- Under reduced detail or reduced motion, browsing walks are skipped and eaters
  are static.
- A dessert order is staged from a diner already seated where one exists.

**Left to the builder:** routes, timings, seat assignment, the drawing budget
and how thinning is applied, how adjacent rooms' diners are simplified.

**Verification:** a client model test that figures created equal the count
changes received, that none appears without a change, and that the cleaning
window clears the floor; an authorization test that the public view carries
totals only; a browser regression for a served diner sitting and leaving.

**Documentation:** game design §15 (performance and truthful animation), the
public view's module documentation, architecture's hall presentation section.

---

## Project 4: More real customers

**(owner decision, 2026-11-13)** There should be more real customers, not only
better drawing of the existing ones. The target feel:

- at the lunch and dinner rush, a well-stocked stall has three or four people
  queuing and its kitchen is working close to flat out;
- mid-morning and mid-afternoon it has one or two;
- overnight the hall is nearly empty.

**(designer's call, owner saw it)**

- The numbers are found by running the simulation and reading served meals and
  reasons for leaving. No multiplier is fixed in advance. The estimate that
  arrivals roughly double is arithmetic, not a measurement.
- Three things move together: how many diners arrive, how much the wholesale
  market carries, and how much computer-run restaurants expect to sell. Raising
  arrivals alone mostly adds diners who find nothing available: in the measured
  150-stall run only about 19% of arrivals were served and most departures were
  `nothing_available`; wholesale stock is sized per business, and the
  computer-run planner restocks for yesterday's admitted trays.
- The finite-pool rule and the floor's meaning are unchanged.
- Prices, rents, wages and exposure factors are unchanged. The profit effect is
  reported and the owner decides whether costs should rise.
- Existing halls receive the new numbers through a recorded rule change.

### What may be tuned

**(designer's call)**

- Allowed: `arrivals_per_equivalent`; the shape of `hourly_weights`; wholesale
  `target_stock_per_equivalent` and replenishment caps; the computer-run
  planner's fallback and expected-use heuristic; computer-run starter shifts.
- Not without returning to the owner: kitchen stations, the queue limit,
  handover and recipe times; segment budgets and patience; anything in the
  non-goals.

### Acceptance

**(designer's call)** Two runs at sparse-hall settings, each with one warm-up
day followed by at least three measured game days.

**The reference stall** stands for a competent new owner, so that the feel is
one a real player can reach:

- a default new restaurant on a standard spot in room 1: its starter main at
  the suggested price, the three starter staff, open 09:00–21:00;
- it restocks through the hall's wholesale market under the ordinary rules,
  with a restock policy generous enough that it would not run out if the market
  can supply it. Stock is never injected by the driver.

**"Orders waiting"** is the stall's existing `activity.waiting`: everything
accepted and not yet handed over, capped by the queue limit.

**Run A: the three computer-run restaurants plus the reference stall.**

- Reference stall, 12:00–13:00 and 19:00–20:00: time-averaged orders waiting
  between 2.5 and 4.5, and the counter busy at least 85% of the time.
- Reference stall, 09:00–11:00 and 14:00–17:00: time-averaged orders waiting
  between 0.5 and 2.
- Whole hall, 00:00–03:00: time-averaged orders waiting at most 0.3 per stall.
- The reference stall does not run out of any ingredient its menu needs. If it
  does, wholesale stock is the binding constraint and is tuned first.

**Run B: the three computer-run restaurants alone.** This is the run that
tests wholesale stock and computer-run restocking, which the reference stall
would otherwise mask.

- Of diners who left without ordering, no more than a quarter left for
  `nothing_available`.
- The hall serves meals on its first day.

**Served share, both runs.** The share of arrivals that are served a main must
be higher than in the same run under today's values. Where the queue targets
and the served share pull against each other, served share wins: a saturated
stall turning diners away at a full queue is the failure the anti-goals name.

If these cannot all be met with the allowed knobs, the builder reports the
closest result and the binding constraint instead of widening the knob list.
The 300,000 storage capacity is not an allowed knob; if it binds, that is
reported to the owner.

### Deliverables

- A repeatable, bounded simulation driver at sparse-hall settings that prints,
  per hall hour: arrivals, admitted, served, departures by reason, average
  orders waiting and counter utilisation per stall, and daily profit for the
  reference stall and each computer-run restaurant.
- A report under `docs/superpowers/reports/` with before and after tables, the
  chosen values, and the profit comparison for the owner's cost decision.
- The chosen values as a new rules version, and the recorded change that
  applies them to managed halls. Accepted orders, leases and other pinned terms
  keep the rules they were accepted under; earlier events replay under the old
  values.
- **(designer's call)** The recorded change is built and tested, but it is
  **not** applied to a live managed hall automatically at boot. More customers
  at unchanged rent and wages changes how easy the game is, and the owner
  decides on costs from the report. Applying it is a separate, explicit step
  after that decision. Project 2's room rule applies at boot, as earlier
  catalog changes did.

**Verification:** the existing demand properties still hold (the pool does not
grow with stalls; every arrival is accounted for once); live, genesis and
snapshot-tail state agree across the rule change; a sensitivity check shows the
acceptance measurements move when a tuned value is reverted. Local runs stay
serial and under the RSS limit; wider sweeps go to hosted CI.

**Documentation:** game design §7 (arrival scale), §8 (market stock), §14
(computer-run planning), and the §21 tuning register. The values remain
proposed tuning.

---

## Project 5: Supply market

### Owner decisions (2026-11-13)

- A 3D market where the owner clicks things to buy them: baskets of fresh
  produce, a butcher's stall for raw meat, bins of grains and nuts, and so on.
- The look shown in the first mockup: a row of vendor stalls; a close-up of one
  vendor with a price tag on each container; a cart; nothing bought until the
  owner sends the order.
- The first time an owner opens the market, a short note explains what the
  stars mean, then fades away.
- Other stall owners and computer-run owners are seen shopping, so competition
  for supplies is visible.
- A rival's cart shows its goods as 3D objects, without labels.
- The market is on the Business page. It is not part of the hall's 3D world.

### How buying works

**(designer's call, owner saw it)**

- What is drawn is the real market: a fuller container means more stock left;
  the tag shows the current published price; a low, rising item is marked.
- One click adds one crate to the cart. The cart is a draft; nothing is
  requested until "Send order".
- Orders fill at the next clearing (about ten real seconds). Crates then arrive
  on the cart. If the market is short the owner gets fewer and the cart says
  so.
- Supplies the owner's menu uses are starred.
- The existing text form stays, for phones, no-WebGL and exact quantities.
- The star's meaning stays findable after the note fades: pointing at or
  focusing a star shows the same one-line explanation, and a legend stays under
  the shelves. The note is announced politely to assistive technology and never
  takes focus.

**(designer's call)**

- The market is its own scene in the Business page's Supply section, with the
  cart and the existing controls beside it as HTML. It follows the cuisine
  map's pattern: a picture plus a synchronized accessible list, where selection
  is a draft and not an economic command.
- "Send order" submits one `submit_purchase_request` per cart line through the
  existing use case and the shared draft and pending state. Lines appear under
  "On its way" until their fill or rejection is known. An uncertain send is
  resolved by the same command ID, as elsewhere.
- The cart's "On its way" list needs the owner's own pending requests and the
  outcome of each recent request: filled, partly filled with the shortfall, or
  rejected with the reason. The state discards requests and shortfall reasons
  at each clearing today, so recent clearing outcomes are retained for a short
  window and shown in the owner's **private** view. This is the owner's own
  data and is authorized like the rest of their private view.
- Each product has one crate size, derived deterministically from the catalog
  (a round quantity covering about ten servings of the recipe line that uses
  the most of it) and shown on the tag.
- Each line's price limit defaults to the published price plus 10%, shown in
  the cart and editable. It is a willingness-to-pay limit, as today.
- The hall's Stock button keeps its text panel and gains a link to the market.
- Starter stock, restock automation and pricing policy remain text controls.
- No delivery animation is added to the hall scene.
- The first-visit note is remembered per device. It is not a gameplay fact.
- On widths where the scene does not fit, the list is the market.
- The scene renders only while the Supply section is visible.

### Vendors and goods

**(designer's call, owner saw it)** Seven vendors cover the catalog:
Greengrocer; Butcher; Fishmonger; Dairy and eggs; Grains and nuts; Spices and
tea; Bakery and pantry (bread, flatbreads, batters, noodles, sauces, broths,
syrups, pastes).

**(designer's call)**

- Which vendor sells a product, and what the product looks like (a shape family
  and a colour), is presentation data keyed by stable product ID, like the
  cuisine map. Shape families: round produce, leafy bunch, root, cut of meat,
  fish, shellfish, sack or bin, jar, bottle, loaf or flatbread, block, carton.
- Every catalog product, including substitutes, has an entry. A check fails
  when one is missing, and an unmapped product falls back to a plain crate at
  the pantry so the market never breaks on new content.
- A substitute sits beside its primary at the same vendor with a visible
  difference (frosted for frozen, a plain sack for value, and so on).

### Rivals

**(designer's call, owner saw it)**

- A rival appears when a purchase of theirs has filled. Nobody's position is
  tracked; the trip is staged from the committed fill. A rival who bought from
  a phone still appears.
- Human and computer-run owners are shown the same way. An owner's own
  purchases are shown to others the same way.
- Pointing at a rival shows the restaurant's name and nothing else.
- The cart shows roughly how much, not exactly.
- Only the owner's own cart has labels and amounts.

**This makes something public that is private today.** The public view
currently excludes orders entirely. It gains, for recent clearings, per
restaurant: which products filled and a coarse cart-size bucket
**(designer's call: three sizes)**. Quantities, prices, price limits, pending
requests and unfilled amounts stay private. An attentive player can infer a
rival's menu plans from the shapes; the owner accepted this.

**Left to the builder:** the scene's layout and camera, the product artwork
built from basic shapes, how many recent clearings the view keeps, the exact
bucket boundaries, crate-size rounding, phone breakpoints.

**Verification:**

- Mapping coverage: every catalog product has a vendor and a shape.
- Cart-to-request tests, including exact decimal strings for money and the
  price-limit default.
- An authorization test that the public view carries product IDs and a size
  bucket for filled purchases and nothing else about rival orders.
- Browser regression: click a container, see the cart line, send, see it
  pending, see it filled or short; a rival's fill appears as an unlabelled
  shopper; the list stays in sync and works with the scene unavailable.
- English and Japanese catalog checks for every new string.

**Documentation:** game design §8 (what is public about purchases), §15 (main
views and visual language), the public view's module documentation,
architecture's commands and authorization section.

---

## Questions for the owner

None blocks the work.

- **Costs after more customers.** Decided from Project 4's report, not now.
- **Scarcity rent numbers.** The proposed cap and curve are tuning, to be
  revisited once rooms have been seen filling in play.

## Decision trace

All owner decisions were made in the design conversation on 2026-11-13:

- Buying should be a 3D market with clickable goods; the vendor types named.
- First mockup accepted; first-visit fading note for the stars.
- Rivals shop visibly; their carts show unlabelled goods.
- People: the rounded figure.
- Hall: queues, browsers, eaters at tables; more real customers; the target
  feel at rush, mid-day and overnight.
- All stalls on the walls, tables in the centre; then a row of rooms joined by
  doorways in place of one long hall; 15 spots per room, ten rooms, an outside
  entrance each; the next room opens when any one class is fully taken.
- Location quality tied to position.
- The market lives on the Business page, outside the hall's 3D world.
- A class's rent rises as its relative availability falls, in answer to the
  designer's concern that scarce prime spots would open rooms too early.
- A new hall's computer-run "premium" restaurant starts on a standard spot, not
  a prime one.
