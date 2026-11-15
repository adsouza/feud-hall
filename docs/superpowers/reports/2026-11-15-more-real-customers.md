# More real customers: measurements and chosen values

## What to decide

**These results are for a hall of four restaurants** (three computer-run, one
owner) at the demand floor of three business equivalents. A hall with more
stalls shares the same diners among them, and both the rush queues and the
profit below fall: see [With more stalls](#with-more-stalls).

1. **Apply the change or not.** The chosen values are proposed tuning and no
   hall has them; an operator applies them with
   [the operator request](../../DEPLOYMENT.md#applying-the-customer-tuning).
   The measurements are in [Result in short](#result-in-short). In the
   four-restaurant hall a typical new stall has 2.3 to 3.3 orders waiting at
   the rushes; with two to five more owner stalls it has 1.1 to 1.7.
2. **Whether costs should rise first.** At unchanged prices, rent and wages,
   a typical new owner's stall in the four-restaurant hall goes from a loss
   of about 10,100 a day to a profit of 60,900 to 66,300 a day (the range
   over three seeds of the three-day mean daily profit; 64,800 a day over 14
   days). In the halls of six to nine restaurants that were measured, the
   same stall makes 25,800 to 34,700 a day and the added owner stalls 9,600
   to 31,000. A rise in rent or wages sized to the four-restaurant profit
   would be paid from those smaller profits. See [Profit](#profit) and
   [With more stalls](#with-more-stalls).
3. **Which day shape.** The chosen shape, the gentler of two, meets every
   acceptance check on the design's run (seed 20261109) and misses one, the
   noon queue, on two of the four seeds measured, by 0.05 and 0.17. The
   sharper alternative meets every check on all four seeds; it serves a
   smaller share of arrivals on three of the four seeds and, when the
   computer-run stalls trade alone, turns more arrivals away at full queues
   on three of the four. See
   [The choice between two day shapes](#the-choice-between-two-day-shapes).
4. **Whether to act on the findings** under
   [For the owner's attention](#for-the-owners-attention): the ten-hour staff
   rule, orders lost at a break or closing, diners who cannot afford any open
   stall, how scarce wholesale stock should be, and what to tell players
   before the change is applied. None is tuning, and none was changed.

Evidence for Project 4 of the
[livelier hall design](../specs/2026-11-13-livelier-hall-design.md#project-4-more-real-customers):
what a sparse hall does on today's values, the values chosen from measured
runs, what they change, and what they do to profit. Every number here comes
from a run listed in the [tuning log](2026-11-15-more-real-customers-tuning-log.md);
"run 125" means the run numbered 125 in that log's table.

A log line holds a run's verdict rows, its arrivals, its mains served and its
arrivals' reasons for leaving; from run 125 it also holds the orders that
ended with no main, each day's business equivalents and scale, and for a run
with extra stalls the noon arrivals per open stall and the mean daily profit
of the owner stalls. The other figures here (profit components, orders
waiting per stall and per hour, wholesale products at zero, single-day values
and the first-day table) are not in the log lines: they are read from the
fuller output the driver prints for the same run. Runs are deterministic, so
repeating a line's command prints them again;
[Reproducing the tables](#reproducing-the-tables) gives the command for each
table.

The values are `FeudHall.Domain.Content.Tuning.chosen/0`. They are proposed
tuning. A hall does not start on them and no hall receives them at boot: they
are applied by the recorded `retune_rules` change, as a separate step after
the owner's decision on costs.

## Result in short

All of this is for a hall of four restaurants (three computer-run, one owner)
at the demand floor of three business equivalents, on four seeds: the seed
the values were chosen on (20261109), two more used while choosing (7 and
12345), and one held out and never used for any choice (424242).

- **The acceptance checks are met on the design's run and on one other seed;
  two seeds miss one check.** The reference stall sells a typical starter
  (the median-priced one). At the lunch rush it has 2.3 to 3.3 orders waiting
  (target 2.5 to 4.5): 3.25 and 3.05 on two seeds, 2.45 on seed 7 and 2.33 on
  the held-out seed. At the dinner rush it has 2.5 to 3.2. Its counter is busy
  95% to 100% of the time at both. Mid-morning and mid-afternoon it has 1.0
  to 1.4 (target 0.5 to 2); overnight the hall has 0.06 to 0.12 per stall; it
  never runs short of an ingredient. The two misses are 0.05 and 0.17, where
  single days of one run differ by 0.5 to 1.5.
- **Served meals.** A sparse hall serves 3.2 to 3.7 times as many mains a day
  (run A: 107 to 109 a day before, 388 to 395 after; run B: 90 to 94 before,
  294 to 307 after), and a larger share of arrivals is served in all eight
  comparisons (run A 0.40 before, 0.52 to 0.53 after; run B 0.33 to 0.35
  before, 0.39 to 0.41 after).
- **Supply.** Leaving because nothing is available falls from 14% to 25% of
  arrivals to 0.1%. No wholesale product runs out on a measured day.
- **More diners leave for the wait.** Arrivals who leave because the wait is
  too long rise from 7% to 9% of arrivals to 16% to 18% in run A, and from 9%
  to 12% to 27% to 28% in run B. In run B 59% to 61% of arrivals still leave
  without a main (65% to 67% today); in run A 47% to 48% (59% to 61% today).
- **More stalls thin the queues and the profit.** With one more owner stall
  the reference stall has 1.7 orders waiting at noon and 2.1 at 19:00; with
  two to five more it has 1.1 to 1.5 at noon and 1.2 to 1.7 at 19:00, and
  its profit is 25,800 to 34,700 a day. Up to six restaurants the hall is
  still under three equivalents and the same 744 arrivals a day are shared;
  beyond that arrivals grow with the hall and each stall's share stays at
  about half the four-restaurant hall's. See
  [With more stalls](#with-more-stalls).
- **Dearer and cheaper stalls.** A reference stall selling the second dearest
  unused starter (roasted salmon, 1,220) misses both rush-waiting targets on
  all three seeds it was run on (1.6 to 2.2 at 12:00, 1.4 to 1.8 at 19:00)
  and the 19:00 busy share on two. One selling the cheapest (bean tacos, 850)
  meets every check on all three (3.4 to 3.8 and 3.3 to 4.3). See
  [The brackets](#the-brackets-a-dearer-and-a-cheaper-reference-stall).
- **Run B is close to full.** With no fourth stall, the computer-run stalls
  hold 4.4 to 5.1 orders at 12:00 (the queue limit is 6) and 0.6% to 2.0% of
  arrivals find every open queue full. Run B's served share is 0.052 to 0.079
  above today's; that margin is what stopped the rushes being set higher.
- **The day shape is a close call.** The sharper alternative lifts the noon
  queue into range on every seed (3.0 to 3.5). Against it, the chosen shape
  serves a larger share of arrivals on three of four seeds in each run (run A
  mean 0.525 against 0.517, run B 0.406 against 0.402) and has fewer
  full-queue turnaways in run B on three of four (1.4% against 2.2% of
  arrivals over the four seeds; on the held-out seed it is the other way,
  2.0% against 0.9%). See
  [The choice between two day shapes](#the-choice-between-two-day-shapes).
- **Profit.** At unchanged prices, rent and wages the reference stall moves
  from a loss of about 10,100 a day to a profit of 60,900 to 66,300 a day
  (the salmon stall from a loss of 7,100 to 10,000 a day to a profit of
  22,900 to 32,000), and the computer-run restaurants from between -1,400 and
  +13,300 to between 51,800 and 69,700. No restaurant was distressed or in
  arrears in any final run. These are four-restaurant figures.
- **Findings for the owner**, not tuning: eight are listed under
  [For the owner's attention](#for-the-owners-attention), among them a new
  owner's 09:00 to 21:00 stall closing for the dinner hour, about 2% of
  accepted orders lost when a stall stops with a queue, about a quarter of
  arrivals who cannot afford any open stall, and what players should be told
  before the change is applied.

## Method

The driver is `server/scripts/customer_sim.exs`
([usage](../../TESTING.md#implemented-backend-entry-points)): a real hall
authority in memory at sparse-hall settings, one warm-up day and three
measured game days. Run A is the three computer-run restaurants plus a
reference owner playing through ordinary commands; run B is the three alone.
`--extra-stalls N` adds N more owners to run A, set up by the same commands
as the reference owner.

**The hall's size.** A four-restaurant hall has 1.88 to 1.90 business
equivalents on a measured day (1.38 to 1.44 in run B), read from the recorded
`day_closed` events. That is under the floor of three, so every measured day
of every run in this report used a scale of exactly three equivalents, except
the runs with three and five extra stalls
([With more stalls](#with-more-stalls)). For runs before 125, whose lines do
not record the scale, this is read from their arrivals, which are three days
at three equivalents.

**The reference stall.** It is open 10:00 to 20:00 (not the design's 09:00 to
21:00: the three starter staff take a protective break after ten working
hours), so the mid-morning check is 10:00 to 11:00. It sells the starter main
with the median suggested price among the cuisines no computer-run restaurant
took (the lower middle price of the 22, then the first cuisine ID): in every
run here that is `colombian`, `arepa_con_queso` at 940. Until run 76 the
driver took the first unused cuisine in sorted order instead, which is
`coast_salish`, `roasted_salmon` at 1,220: the second dearest of the 22
(`lakota`'s is 1,230) and the slowest method. That stall is kept as the
harder bracket (`--cuisine coast_salish`).

**Seeds.** Values were tuned on seed 20261109 and checked on seeds 7 and
12345 while choosing, so those three are both selection and confirmation
seeds. Seed 424242 was held out: it was first run after the chosen values
were final, and no value was chosen from it. Each check is reported per seed,
and a check is called met only for the seeds that meet it. 166 driver runs
were made, one at a time, of a budget of 200 (124 before the final review and
42 after it); each three-day run takes 5 to 10 seconds.

Only these were changed: `demand.arrivals_per_equivalent`, the shape of
`demand.hourly_weights`, `market.target_stock_per_equivalent` and
`market.replenish_cap`, and the computer-run planner's
`fallback_trays_per_day` and `starter_shifts`. The planner's expected-use
heuristic stays `even_share`; no new heuristic was needed.

The decisive steps. Steps 1 to 8 were measured with the salmon reference
stall; their conclusions about supply, shifts and run B do not depend on the
reference stall.

1. **Baseline** (runs 1 to 6). Both supply and arrivals are short. See
   [Before](#before-todays-values).
2. **Supply alone** (runs 7 and 8). Raising only the wholesale targets and the
   fallback, at today's arrivals, took run B's `nothing_available` share of
   leavers from 0.29 to 0.003 and its served share from 0.33 to 0.56. The
   reference stall's queue did not rise: once stocked, it is short of
   customers.
3. **Arrivals alone overshoot** (runs 10 to 12, today's hourly shape). At
   five times today's arrivals the salmon stall's rush queues were in range
   but run A's served share was 0.32, below today's.
4. **A peakier day at that level does not rescue it** (runs 13 and 14): run
   B's share fell to 0.30, below today's 0.33. Three computer-run stalls
   alone cannot serve a rush that size.
5. **Shifts** (runs 18 to 20, 24 to 34). Opening "mainstream" an hour earlier
   and "premium" two hours earlier puts a second computer-run stall into the
   hours that lead into each rush. At the same arrivals run B's served share
   rose from 0.395 to 0.400 (three seeds) to 0.428 to 0.433.
6. **Level** (runs 35 to 40). With those shifts, run B served 799, 834, 914
   and 934 mains over three days at 180, 205, 235 and 270 arrivals per
   equivalent: beyond about 235 the three stalls serve almost nothing more,
   and added arrivals walk away.
7. **Market size and fallback** (runs 47 to 53); see
   [The chosen values](#the-chosen-values).
8. **First chosen values** (runs 54 to 76, arrivals 249). The salmon stall
   had 1.2 to 1.65 waiting at the rushes; nothing allowed reached 2.5 while
   run B's served share stayed above today's.
9. **Reference-cuisine ruling** (runs 77 to 82). With the median-priced
   reference stall the first chosen values gave 2.10 to 2.46 waiting at 12:00
   and 2.28 to 3.03 at 19:00, busy 0.95 to 0.99, and 1.50 to 1.92 at 10:00,
   near the top of its range. Close, but the noon row missed on all three
   seeds and the 19:00 row on one.
10. **Shape only** (runs 83 to 94). Weight was moved from 10:00 and the
    afternoon into the two rush hours. A first step (248 arrivals, 30 and 28
    at the rushes) met every row on seeds 20261109 and 12345 and missed noon
    on seed 7 (2.45). A second step (252 arrivals, 34 and 33, with weight
    also trimmed from 09:00, 13:00, 20:00 and 21:00) met every row on all
    three seeds, at a cost: against the first step, run A's served share fell
    on two of the three seeds and run B's full-queue turnaways rose on all
    three. Supply, fallback and shifts were not touched.
11. **The second step was kept at first** (runs 95 to 124), because it was
    the only candidate that met every row on every seed with served share
    above today's in all six comparisons.
12. **The final review reversed that** (runs 125 to 155). The second step
    moved weight onto the two hours the checks measure, at the cost of served
    share, which the design ranks above the queue targets. The first step is
    now the chosen shape and the second the documented alternative. A
    held-out seed was then run for both: the chosen shape misses the noon row
    there too (2.33), and the alternative meets every row. See
    [The choice between two day shapes](#the-choice-between-two-day-shapes).
    No value was tuned toward the salmon stall, toward the halls with extra
    stalls, or on the held-out seed.

## Before: today's values

Three measured days, 270 arrivals a day (the scale is the floor of three
business equivalents).

Run A with the median-priced reference stall (runs 80, 81, 82; held-out seed
run 133):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Held out: seed 424242 |
| --- | --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 0.63 | 0.38 | 0.78 | 0.58 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 0.00 | 0.00 | 0.00 | 0.00 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.48 | 0.31 | 0.59 | 0.48 |
| Reference busy 19:00-20:00 | at least 0.85 | 0.00 | 0.00 | 0.00 | 0.00 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.52 | 0.46 | 0.32 | 0.40 |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.00 | 0.00 | 0.00 | 0.00 |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.053 | 0.028 | 0.035 | 0.034 |
| Reference open instants short of an ingredient | 0 | 3,397 | 3,494 | 3,281 | 3,383 |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 | 1.0 |
| Served share | (compared) | 0.401 | 0.401 | 0.405 | 0.395 |
| Mains served, three days | | 325 | 325 | 328 | 320 |

On the three selection seeds the reference stall sells exactly 18 mains every
day and is then out of cornmeal: the market carries 6 portions of a starter's
ingredients per equivalent, 18 a day at the floor. It is short for 1,041 to
1,223 of its 1,500 open samples each day, and from 13:00 it has nothing to
sell. Only the overnight and open-hours rows are met, on every seed.

The salmon stall on today's values (runs 1, 3, 5) sold 13 to 19 mains a day
for the same reason: 0.19 to 0.60 waiting at 12:00, 0.09 to 0.43 at 19:00,
served share 0.379, 0.393 and 0.401.

Run B (runs 2, 4, 6; held-out seed run 134):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Held out: seed 424242 |
| --- | --- | --- | --- | --- | --- |
| `nothing_available` share of those who left on arrival | at most 0.25 | 0.288 | 0.382 | 0.355 | 0.305 |
| Mains served on day 0 | at least 1 | 88 | 95 | 86 | 88 |
| Served share | (compared) | 0.332 | 0.348 | 0.343 | 0.340 |
| Mains served, three days | | 269 | 282 | 278 | 275 |

Why arrivals left without ordering, as a share of all arrivals over the three
measured days, four seeds:

| Reason | Run A | Run B |
| --- | --- | --- |
| `nothing_affordable` | 35% to 37% | 32% to 37% |
| `nothing_available` | 14% to 17% | 19% to 25% |
| `wait_too_long` | 7% to 9% | 9% to 12% |
| `no_compatible_main`, `chose_to_leave` | under 1% | under 1% |

Thirteen to fifteen wholesale products were at zero for part of the measured
days in every baseline run.

## The chosen values

As a difference from today's values (`Tuning.of(LaunchCatalog.catalog())`):

| Value | Today | Chosen |
| --- | --- | --- |
| `demand.arrivals_per_equivalent` | 90 | 248 |
| `demand.hourly_weights` (hour 0 first) | `2,1,1,0,0,1,2,4,6,6,8,12,14,12,8,6,6,8,12,14,10,8,5,3` | `3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5` |
| `market.target_stock_per_equivalent` (per product, per business equivalent, in the product's own unit) | the larger of a base quantity (400 by default; nine named staples have their own, 100 to 5,000) and 6 times the quantity the starter mains' recipe lines use; salmon 870 g (6 x 145 g), frozen salmon 400 g | the larger of today's target and 100 times the largest quantity any recipe line uses of the product (a substitute at its converted quantity, rounded up); no target falls; salmon 14,500 g, frozen salmon 14,500 g |
| `market.replenish_cap` | 4 times the target | 4 times the target |
| `npc.fallback_trays_per_day` | 10 | 50 |
| `npc.expected_use` | `even_share` | `even_share` |
| `npc.starter_shifts` "budget" | 05:00-17:00 | 05:00-17:00 |
| `npc.starter_shifts` "mainstream" | 12:00-00:00 | 11:00-23:00 |
| `npc.starter_shifts` "premium" | 19:00-07:00 | 17:00-03:00 |

**Arrivals.** The chosen weights sum to 248, so each weight is that hour's
arrivals per business equivalent: 30 and 28 at the rushes, 16 to 19 in the
hours beside them, 11 to 14 mid-morning and through the afternoon, 1 to 3
overnight. At the floor of three equivalents that is 744 arrivals a day (270
today): 90 and 84 an hour at 12:00 and 19:00 (26 and 25 today) and 33 to 42
an hour mid-morning and afternoon (11 to 15 today).

A hall hour is two and a half minutes of real time (the hall runs at 24
times real time), so each rush below is two and a half real minutes long,
and the whole stretch from 11:00 to 14:00 is seven and a half.

Each rush is one hour long: 30 at 12:00 against 19 at 11:00 and 19 at 13:00,
and 28 at 19:00 against 19 at 18:00 and 16 at 20:00, so a rush hour has 1.5
to 1.8 times the arrivals of the hours beside it (today's shape: 1.2 to 1.4
times; the sharper alternative: 1.7 to 2.2 times). 12:00 and 19:00 are
exactly the hours the rush checks measure. The reference stall's queue shows
the same peak (runs 125 to 127, seeds 20261109 / 7 / 12345): 1.66 / 1.39 /
1.49 at 11:00, 3.25 / 2.45 / 3.05 at 12:00 and 1.83 / 2.22 / 2.09 at 13:00;
1.43 / 2.05 / 1.80 at 18:00 and 2.76 / 2.54 / 3.15 at 19:00 (it closes at
20:00). "Three or four people queuing" holds, where it holds, for the checked
hour, not for the hours around it, where the stall has one or two.

**Wholesale targets.** A product's target is the larger of today's target and
100 times the largest quantity any recipe line uses of it; a substitute counts
at its converted quantity, rounded up. Of 274 products, 257 rise (by 1.25 to
50 times, median 12 times) and 17 already carried 100 portions. Examples per
equivalent: salmon 870 g to 14,500 g; frozen salmon 400 g to 14,500 g;
frozen vegetable mix 400 g to 13,000 g; long rice 1,200 g to 5,500 g; filtered
water 5,000 ml to 22,000 ml. Substitutes matter because the "budget"
computer-run owner buys them by preference and today they sit at 400 g: at
three equivalents that is nine portions a day of its starter's vegetable mix.

How the size was chosen (runs 47 to 50, arrivals 249, seed 20261109): at 25
portions products run out again (run B's `nothing_available` share 0.078,
served share 0.348); at 50 portions what is served is identical to 100 but
`olive_oil_value` and `rice_long` are at zero for part of two or three
measured days; at 100 nothing is at zero on any measured day of any final
run. 100 is twice the smallest size tried that served everything; sizes
between 25 and 50 were not tried.

**Fallback.** Before the first day's summary exists a computer-run owner
stocks for this many trays a day. At arrivals 249 run B served 270 mains on
day 0 with a fallback of 10, 304 with 30, 311 with 50 and 312 with 90 (runs
51, 53, 57, 52). 50 is where the first day stops improving.

**Shifts.** Every open hour still has a computer-run stall open. Compared
with today, 11:00 to 12:00 and 17:00 to 19:00 gain a second computer-run
stall, and 05:00 to 07:00 and 23:00 to 00:00 lose their second one.
"Mainstream" takes its protective break at 21:00 instead of 22:00.

## The choice between two day shapes

The hourly shape was changed after the reference stall became the
median-priced one, to lift its rush queues into range. Three candidates
follow, each measured with the median-priced reference stall on seeds
20261109 / 7 / 12345; the chosen shape and the alternative were also run on
the held-out seed 424242, shown after a semicolon. Supply, fallback and
shifts are the same in all three.

| | Flat rush (the first chosen shape) | Chosen: gentler rush | Alternative: sharper rush |
| --- | --- | --- | --- |
| Runs (A; B) | 77-79; 57-59 | 125-127, 131; 128-130, 132 | 95-97, 154; 98-100, 155 |
| Arrivals per equivalent | 249 | 248 | 252 |
| Weights 09:00 to 21:00 | 9, 15, 19, 24, 19, 14, 14, 14, 15, 19, 24, 16, 11 | 9, 11, 19, 30, 19, 12, 12, 12, 14, 19, 28, 16, 11 | 8, 11, 19, 34, 17, 12, 12, 12, 14, 19, 33, 15, 10 |
| Reference waiting 12:00 (2.5 to 4.5) | 2.10 / 2.17 / 2.46 | 3.25 / 2.45 / 3.05; 2.33 | 2.97 / 3.11 / 3.54; 3.25 |
| Reference waiting 19:00 (2.5 to 4.5) | 2.52 / 2.28 / 3.03 | 2.76 / 2.54 / 3.15; 3.00 | 3.45 / 3.09 / 3.49; 2.99 |
| Reference busy 12:00 (at least 0.85) | 0.951 / 0.991 / 0.947 | 1.000 / 0.998 / 1.000; 0.976 | 1.000 / 1.000 / 0.978; 0.976 |
| Reference busy 19:00 (at least 0.85) | 0.964 / 0.993 / 0.987 | 0.996 / 0.953 / 0.976; 1.000 | 1.000 / 0.991 / 1.000; 0.998 |
| Reference waiting 10:00 (0.5 to 2) | 1.92 / 1.70 / 1.50 | 1.04 / 1.42 / 1.03; 0.97 | 1.28 / 0.99 / 0.94; 0.81 |
| Reference waiting 14:00-17:00 (0.5 to 2) | 1.38 / 1.40 / 1.46 | 1.01 / 1.03 / 0.98; 1.05 | 1.16 / 1.21 / 1.08; 1.10 |
| **Acceptance rows missed** | Noon waiting on all three seeds (short by 0.40, 0.33, 0.04); 19:00 waiting on seed 7 (short by 0.22) | Noon waiting on seed 7 (short by 0.05) and on the held-out seed (short by 0.17) | None on any of the four |
| Run A served share | 0.532 / 0.531 / 0.543 | 0.522 / 0.531 / 0.522; 0.524 | 0.529 / 0.513 / 0.508; 0.518 |
| Run B served share | 0.408 / 0.416 / 0.398 | 0.411 / 0.413 / 0.395; 0.406 | 0.404 / 0.403 / 0.402; 0.398 |
| Run B served share above today's | 0.076 / 0.068 / 0.054 | 0.079 / 0.065 / 0.052; 0.066 | 0.072 / 0.055 / 0.059; 0.058 |
| Run B arrivals that found every open queue full | 0.5% / 1.0% / 2.2% (12, 23, 49 of 2,241) | 0.6% / 1.5% / 1.5%; 2.0% (14, 34, 33; 44 of 2,232) | 3.3% / 2.7% / 1.9%; 0.9% (74, 61, 44; 21 of 2,268) |
| Run B arrivals that left for the wait | 27.6% / 27.6% / 27.0% | 27.0% / 28.3% / 27.8%; 28.3% | 26.7% / 26.9% / 26.2%; 29.0% |
| Run A mains served, three days | 1,192 / 1,189 / 1,217 | 1,165 / 1,186 / 1,165; 1,169 | 1,199 / 1,163 / 1,152; 1,175 |
| Run B mains served, three days | 915 / 933 / 891 | 917 / 922 / 881; 905 | 916 / 915 / 911; 902 |

Every candidate meets every other acceptance row on every seed it was run on,
and in every candidate served share is above today's in every comparison.
The flat shape was not run on the held-out seed. Runs 125 to 130 repeat runs
83 to 88, which measured the gentler shape through `--set` before it was
written into the code: every verdict row and every count is identical.

What separates the chosen shape from the alternative, over the four seeds:

- **The noon queue.** The alternative has 3.0 to 3.5 at noon on every seed.
  The chosen shape has 3.25 and 3.05 on two seeds and falls short on two:
  2.45 on seed 7 and 2.33 on the held-out seed. Single days vary more than
  that: the three days of one run had 2.31, 3.83 and 3.01 at noon (run 127).
- **Served share.** The chosen shape's is higher on three of four seeds in
  each run: run A 0.525 against 0.517 on average (lower on seed 20261109),
  run B 0.406 against 0.402 (lower on seed 12345). The alternative brings 12
  more arrivals a day, so the mains served are nearly the same: 4,685 against
  4,689 over the four run A's, 3,625 against 3,644 over the four run B's.
- **Full queues when the computer-run stalls trade alone.** 1.4% of run B's
  arrivals find every open queue full under the chosen shape against 2.2%
  under the alternative, over the four seeds. On the three selection seeds it
  is 1.2% against 2.6%; on the held-out seed it is the other way round, 2.0%
  against 0.9%.

The design ranks served share above the queue targets where the two pull
against each other, and names a saturated stall turning diners away at a full
queue as the failure to avoid. The first builder's ruling kept the sharper
shape because it alone met every row on every seed. The final review
recommended the opposite order by that priority rule: the sharpening moved
weight onto exactly the two hours the checks measure, bought the noon row
with served share, and about doubled the full-queue turnaways on the seeds
then measured, while the gentler shape met every row on the design's single
run. The ruling was reversed on that advice
([ruling 15](#rulings-made-while-building)).

The held-out seed was run after the reversal, and it weakens both sides of
that argument a little: the chosen shape's noon miss is larger there (0.17,
not 0.05), and the full-queue difference reverses there. Neither shape is
clearly better on these four seeds. The choice is the owner's: the chosen
shape if the served share and a flatter day matter more, the alternative if
every row on every seed matters more.

**How to switch to the alternative.** Before the change has been applied to a
hall, two values change in `Tuning.chosen/0`
(`server/lib/feud_hall/domain/content/tuning.ex`):
`@chosen_arrivals_per_equivalent` from 248 to 252, and
`@chosen_hourly_weights` to
`3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5`. Two tests
then change. `tuning_test.exs` pins the arrival figure, the weights and the
content fingerprint of the chosen values. `customer_acceptance_test.exs` pins
seed 20261109, on which the alternative also meets every row, so its
assertions stay; its `@not_met` list, which records the rows other seeds miss
under the chosen shape, becomes empty.

After the change has been applied to a hall, the day shape is no longer
switched by editing `Tuning.chosen/0`: that hall is at tuning version 2 and
refuses version 2 again. The other shape then has to go out as a new tuning
version, which is a code change. See
[Deployment](../../DEPLOYMENT.md#applying-the-customer-tuning).

Earlier measurements with the salmon stall at 15% fewer and 15% more arrivals
than the first chosen values are runs 65 to 76 in the log: at 15% more, run
B's share was only 0.024 to 0.031 above today's.

## After: the chosen values on four seeds

Runs 125 to 132, by `--tuning chosen --via init`. 744 arrivals a day. Seeds
20261109, 7 and 12345 were used while choosing; seed 424242 was held out.
"Spread" is the largest value minus the smallest over the four seeds.

Run A, median-priced reference stall (runs 125, 126, 127, 131):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Held out: seed 424242 | Spread | Met on all four |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 3.25 | **2.45** | 3.05 | **2.33** | 0.92 | **no**: seed 7 short by 0.05, held-out seed by 0.17 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 2.76 | 2.54 | 3.15 | 3.00 | 0.62 | yes |
| Reference busy 12:00-13:00 | at least 0.85 | 1.000 | 0.998 | 1.000 | 0.976 | 0.02 | yes |
| Reference busy 19:00-20:00 | at least 0.85 | 0.996 | 0.953 | 0.976 | 1.000 | 0.05 | yes |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 1.04 | 1.42 | 1.03 | 0.97 | 0.45 | yes |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 1.01 | 1.03 | 0.98 | 1.05 | 0.07 | yes |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.061 | 0.082 | 0.123 | 0.093 | 0.06 | yes |
| Reference open instants short of an ingredient | 0 | 0 | 0 | 0 | 0 | 0 | yes |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 | 1.0 | 0 | yes |
| Served share | above today's | 0.522 | 0.531 | 0.522 | 0.524 | 0.01 | yes |
| Mains served, three days | | 1,165 | 1,186 | 1,165 | 1,169 | | |

Run B (runs 128, 129, 130, 132):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Held out: seed 424242 | Spread | Met on all four |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `nothing_available` share of those who left on arrival | at most 0.25 | 0.0023 | 0.0023 | 0.0015 | 0.0023 | 0.0008 | yes |
| Mains served on day 0 | at least 1 | 305 | 299 | 304 | 304 | 6 | yes |
| Served share | above today's | 0.411 | 0.413 | 0.395 | 0.406 | 0.018 | yes |
| Mains served, three days | | 917 | 922 | 881 | 905 | | |

**The acceptance row that is missed.** The noon queue of the reference stall
is 2.45 on seed 7 and 2.33 on the held-out seed, against a lower bound of
2.5. Every other row is met on every seed, including the design's own run
(seed 20261109), which meets them all. Set beside the day-to-day spread, the
misses are small: single days at noon were 3.51, 3.30 and 2.93 (run 125),
3.09, 1.91 and 2.35 (run 126), 2.31, 3.83 and 3.01 (run 127) and 2.19, 2.14
and 2.67 (run 131), so one day differs from another in the same run by 0.5
to 1.5. Over 14 days on seed 20261109 the noon mean is 3.09 and the 19:00
mean 2.62 (run 136). The 19:00 row is met on every seed but is close to its
lower bound on two (2.54 and 2.76).

Why arrivals left without ordering, as a share of all arrivals (runs 125 to
132, four seeds):

| Reason | Run A | Run B |
| --- | --- | --- |
| `nothing_affordable` | 25% to 28% | 24% to 27% |
| `wait_too_long` | 16% to 18% | 27% to 28% |
| `no_compatible_main` | 2.8% to 3.1% | 3.2% to 3.3% |
| `no_open_stall` (every open stall's queue full) | up to 0.1% | 0.6% to 2.0% |
| `nothing_available` | 0.1% | 0.1% |

Orders waiting per stall, three-day mean, four seeds (three for the two
bracket stalls):

| Stall | 10:00 | 12:00 | 14:00-17:00 | 19:00 | 00:00-03:00 |
| --- | --- | --- | --- | --- | --- |
| Reference, median (run A) | 0.97 to 1.42 | 2.33 to 3.25 | 0.98 to 1.05 | 2.54 to 3.15 | closed |
| "Budget" (run A) | 2.23 to 3.13 | 3.63 to 4.12 | 1.17 to 1.44 | closed | closed |
| "Mainstream" (run A) | closed | 2.92 to 3.60 | 1.37 to 1.84 | 2.69 to 3.88 | closed |
| "Premium" (run A) | closed | closed | closed | 2.10 to 3.42 | 0.24 to 0.49 |
| "Budget" (run B) | 3.56 to 4.44 | 4.70 to 5.08 | 1.88 to 2.19 | closed | closed |
| "Mainstream" (run B) | closed | 4.42 to 4.86 | 2.42 to 2.90 | 3.92 to 4.46 | closed |
| "Premium" (run B) | closed | closed | closed | 3.97 to 4.53 | 0.29 to 0.40 |
| Reference, salmon (harder bracket) | 0.65 to 0.95 | 1.56 to 2.16 | 0.51 to 0.83 | 1.42 to 1.85 | closed |
| Reference, bean tacos (easier bracket) | 1.31 to 1.45 | 3.39 to 3.75 | 1.26 to 1.50 | 3.30 to 4.25 | closed |

Against the owner's feel (three or four at the rushes, one or two mid-day,
nearly empty overnight), run A reads: at 12:00 the reference stall has 2.3
to 3.3, the mainstream stall 2.9 to 3.6 and the budget stall 3.6 to 4.1; at
19:00 the reference stall has 2.5 to 3.2, the mainstream stall 2.7 to 3.9
and the premium stall 2.1 to 3.4: two and a half to three and a half more
often than three or four. Mid-day the reference stall has about one, the
mainstream stall 1.4 to 1.8 and the budget stall 1.2 to 1.4 in the afternoon
but 2.2 to 3.1 at 10:00, when it is the only computer-run stall open.
Overnight the one open stall has a quarter to half an order waiting. In run
B, with one stall fewer, the rush queues are above the feel: 4.4 to 5.1 at
12:00 and 3.9 to 4.5 at 19:00, against a queue limit of 6. The budget
stall's afternoon mean includes its break hour.

### The brackets: a dearer and a cheaper reference stall

Run A at the same values with the reference owner on another cuisine, seeds
20261109 / 7 / 12345. The harder bracket is `--cuisine coast_salish`
(roasted salmon at 1,220, the second dearest unused starter and the slowest
method; runs 139 to 141). The easier one is `--cuisine mexican` (bean tacos
at 850, the cheapest unused starter; runs 142 to 144). The median reference
(arepa at 940) is repeated from the table above for comparison. Values out
of range are in bold.

| Check | Bound | Salmon, 1,220 | Median, 940 | Bean tacos, 850 |
| --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | **1.56** / **2.16** / **1.79** | 3.25 / **2.45** / 3.05 | 3.75 / 3.53 / 3.39 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | **1.85** / **1.42** / **1.82** | 2.76 / 2.54 / 3.15 | 4.25 / 3.58 / 3.30 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.878 / 0.960 / 0.873 | 1.000 / 0.998 / 1.000 | 1.000 / 0.991 / 1.000 |
| Reference busy 19:00-20:00 | at least 0.85 | **0.767** / **0.849** / 0.922 | 0.996 / 0.953 / 0.976 | 1.000 / 1.000 / 1.000 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.74 / 0.95 / 0.65 | 1.04 / 1.42 / 1.03 | 1.31 / 1.36 / 1.45 |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.56 / 0.51 / 0.83 | 1.01 / 1.03 / 0.98 | 1.26 / 1.50 / 1.48 |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.097 / 0.091 / 0.098 | 0.061 / 0.082 / 0.123 | 0.073 / 0.094 / 0.133 |
| Reference open instants short of an ingredient | 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Served share | (compared) | 0.462 / 0.491 / 0.482 | 0.522 / 0.531 / 0.522 | 0.523 / 0.531 / 0.540 |
| Reference mean daily profit | | 22,936 / 29,295 / 32,030 | 62,751 / 66,276 / 60,904 | 62,822 / 65,918 / 65,432 |

The salmon stall misses both rush-waiting rows on every seed (short by 0.34
to 0.94 at noon and 0.65 to 1.08 at 19:00) and the 19:00 busy row on two
(short by 0.083 and 0.001). The bean-taco stall meets every row on every
seed; its 19:00 queue on seed 20261109 (4.25) is the nearest any reference
stall came to the upper bound at the chosen values. The salmon stall's served share is above
today's with the same stall (0.379, 0.393, 0.401: runs 1, 3, 5). The
bean-taco stall was not run on today's values, and neither bracket was run
on the held-out seed.

### Hour by hour, seed 20261109

Means over the three measured days. "Before" is today's values (runs 80 and
2), "after" the chosen values (runs 125 and 128). Stall columns are orders
waiting. A number in an hour when a stall is on its break or has just closed
is the queue it is still clearing.

Run A:

| Hour | Before: arrivals | Before: served | Before: reference | After: arrivals | After: served | After: reference | After: reference busy | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 2.3 | closed | 9 | 2.3 | closed | closed | closed | closed | 0.34 |
| 01 | 2 | 0.7 | closed | 6 | 2.3 | closed | closed | closed | closed | 0.26 |
| 02 | 2 | 1.3 | closed | 3 | 1.0 | closed | closed | closed | closed | 0.13 |
| 03 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 04 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 05 | 2 | 1.0 | closed | 6 | 3.3 | closed | closed | 0.42 | closed | closed |
| 06 | 3 | 2.7 | closed | 9 | 5.3 | closed | closed | 0.84 | closed | closed |
| 07 | 7 | 5.3 | closed | 15 | 10.3 | closed | closed | 1.78 | closed | closed |
| 08 | 11 | 5.3 | closed | 21 | 11.7 | closed | closed | 2.72 | closed | closed |
| 09 | 11 | 6.3 | closed | 27 | 11.0 | closed | closed | 3.44 | closed | closed |
| 10 | 15 | 7.0 | 0.52 | 33 | 21.3 | 1.04 | 0.79 | 2.23 | closed | closed |
| 11 | 21 | 10.3 | 0.87 | 57 | 34.7 | 1.66 | 0.92 | 3.18 | 2.64 | closed |
| 12 | 26 | 11.7 | 0.63 | 90 | 40.0 | 3.25 | 1.00 | 4.06 | 3.14 | closed |
| 13 | 22 | 9.0 | 0.00 | 57 | 34.7 | 1.83 | 0.91 | 3.38 | 2.66 | closed |
| 14 | 14 | 5.3 | 0.00 | 36 | 26.0 | 0.72 | 0.58 | 2.06 | 1.28 | closed |
| 15 | 11 | 3.0 | 0.00 | 36 | 17.7 | 1.27 | 0.77 | 0.69 | 1.61 | closed |
| 16 | 11 | 3.0 | 0.00 | 36 | 25.3 | 1.05 | 0.77 | 1.50 | 1.23 | closed |
| 17 | 14 | 4.7 | 0.00 | 42 | 23.0 | 1.12 | 0.76 | 0.32 | 1.66 | 0.86 |
| 18 | 22 | 4.3 | 0.00 | 57 | 27.7 | 1.43 | 0.83 | closed | 1.85 | 1.32 |
| 19 | 25 | 8.0 | 0.00 | 84 | 37.0 | 2.76 | 1.00 | closed | 3.88 | 2.59 |
| 20 | 19 | 7.0 | closed | 48 | 22.0 | 0.74 | closed | closed | 3.37 | 2.41 |
| 21 | 14 | 5.3 | closed | 33 | 11.7 | closed | closed | closed | 0.98 | 2.10 |
| 22 | 9 | 4.0 | closed | 24 | 13.0 | closed | closed | closed | 1.40 | 0.88 |
| 23 | 6 | 0.7 | closed | 15 | 7.0 | closed | closed | closed | 0.58 | 1.08 |
Run B:

| Hour | Before: arrivals | Before: served | Before: budget | Before: mainstream | Before: premium | After: arrivals | After: served | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 0.3 | closed | closed | 0.04 | 9 | 3.3 | closed | closed | 0.54 |
| 01 | 2 | 0.7 | closed | closed | 0.08 | 6 | 3.0 | closed | closed | 0.34 |
| 02 | 2 | 0.3 | closed | closed | 0.04 | 3 | 1.0 | closed | closed | 0.20 |
| 03 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 04 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 05 | 2 | 0.7 | 0.07 | closed | 0.09 | 6 | 3.7 | 0.49 | closed | closed |
| 06 | 3 | 3.3 | 0.31 | closed | 0.10 | 9 | 4.7 | 0.72 | closed | closed |
| 07 | 7 | 4.3 | 0.76 | closed | 0.13 | 15 | 9.0 | 1.43 | closed | closed |
| 08 | 11 | 4.7 | 0.70 | closed | closed | 21 | 12.7 | 2.42 | closed | closed |
| 09 | 11 | 5.7 | 0.95 | closed | closed | 27 | 11.7 | 2.81 | closed | closed |
| 10 | 15 | 5.3 | 1.14 | closed | closed | 33 | 12.0 | 3.56 | closed | closed |
| 11 | 21 | 4.7 | 0.80 | closed | closed | 57 | 22.7 | 4.16 | 3.28 | closed |
| 12 | 26 | 10.0 | 0.06 | 2.28 | closed | 90 | 24.7 | 4.92 | 4.42 | closed |
| 13 | 22 | 9.7 | 0.00 | 2.38 | closed | 57 | 25.0 | 3.69 | 3.75 | closed |
| 14 | 14 | 3.0 | 0.00 | 0.61 | closed | 36 | 20.7 | 2.88 | 2.12 | closed |
| 15 | 11 | 2.7 | closed | 0.47 | closed | 36 | 13.3 | 0.47 | 3.26 | closed |
| 16 | 11 | 1.3 | 0.00 | 0.20 | closed | 36 | 21.0 | 2.29 | 2.44 | closed |
| 17 | 14 | 3.7 | closed | 0.71 | closed | 42 | 18.3 | 0.71 | 2.28 | 1.64 |
| 18 | 22 | 4.7 | closed | 0.94 | closed | 57 | 22.7 | closed | 3.43 | 2.24 |
| 19 | 25 | 8.7 | closed | 0.25 | 1.12 | 84 | 23.7 | closed | 4.17 | 4.12 |
| 20 | 19 | 6.7 | closed | 0.41 | 0.86 | 48 | 21.3 | closed | 3.36 | 2.35 |
| 21 | 14 | 5.3 | closed | 0.20 | 0.79 | 33 | 11.0 | closed | 1.25 | 1.85 |
| 22 | 9 | 3.3 | closed | closed | 0.42 | 24 | 13.7 | closed | 1.73 | 0.98 |
| 23 | 6 | 0.7 | closed | 0.04 | 0.05 | 15 | 6.7 | closed | 0.42 | 0.85 |
Before, the reference stall has nothing waiting from 13:00 and the budget
stall is open from 12:00 to 17:00 with nothing waiting: both are out of
stock.

## With more stalls

Everything above is a hall of four restaurants. The game design asks for the
game to be tested at sparse, medium and full occupancy; the design's
acceptance for this project is at sparse-hall settings only, and this
section is evidence beyond it. `--extra-stalls N` adds N more owner stalls to
run A, each set up exactly as the reference owner is (ordinary commands, a
standard spot in an open room, 10:00 to 20:00, the same restock rule, the
starter main at its suggested price), on the unused cuisines whose starter
price is nearest the median: `javanese` (940), `yoruba` (930), `sichuan`
(950), `ethiopian` (920), `european` (920), in that order. The hall placed
every stall asked for.

Chosen values, three measured days. Equivalents and scale are read from the
hall's recorded `day_closed` events. "Arrivals per stall at noon" is the
day's arrivals in the 12:00 hour divided by the stalls open in that hour
(the premium stall is closed then).

| Owner stalls added | Restaurants | Seed | Run | Equivalents on the measured days | Scale used, days 1 / 2 / 3 | Arrivals a day | Arrivals per stall at noon | Reference waiting 12:00 / 19:00 | Mean owner-stall waiting 12:00 / 19:00 | Reference busy 12:00 / 19:00 | Served share | Reference mean daily profit | Added stalls' mean daily profit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 4 | 20261109 | 125 | 1.88 to 1.89 | 3.000 / 3.000 / 3.000 | 744 | 90 / 3 = 30.0 | 3.25 / 2.76 | 3.25 / 2.76 | 1.000 / 0.996 | 0.522 | 62,751 | |
| 1 | 5 | 20261109 | 145 | 2.35 to 2.36 | 3.000 / 3.000 / 3.000 | 744 | 90 / 4 = 22.5 | **1.66** / **2.12** | 2.04 / 2.05 | 0.920 / 0.920 | 0.565 | 46,078 | 43,702 |
| 2 | 6 | 20261109 | 146 | 2.80 to 2.81 | 3.000 / 3.000 / 3.000 | 744 | 90 / 5 = 18.0 | **1.35** / **1.36** | 1.39 / 1.60 | 0.858 / **0.829** | 0.576 | 32,469 | 29,341; 19,187 |
| 2 | 6 | 7 | 149 | 2.81 | 3.000 / 3.000 / 3.000 | 744 | 90 / 5 = 18.0 | **1.51** / **1.40** | 1.54 / 1.49 | **0.838** / 0.851 | 0.569 | 30,300 | 27,202; 18,530 |
| 2 | 6 | 12345 | 150 | 2.81 | 3.000 / 3.000 / 3.000 | 744 | 90 / 5 = 18.0 | **1.44** / **1.67** | 1.72 / 1.82 | 0.858 / 0.893 | 0.587 | 34,666 | 30,966; 21,162 |
| 3 | 7 | 20261109 | 147 | 3.26 | 3.023 / 3.264 / 3.256 | 749, 810, 807 | 95.0 / 6 = 15.8 | **1.08** / **1.49** | 1.06 / 1.41 | **0.773** / 0.851 | 0.568 | 25,789 | 19,331; 12,438; 24,064 |
| 5 | 9 | 20261109 | 148 | 4.14 to 4.17 | 3.835 / 4.171 / 4.158 | 951, 1,034, 1,031 | 121.7 / 8 = 15.2 | **1.37** / **1.24** | 1.32 / 1.27 | 0.871 / 0.889 | 0.562 | 34,077 | 20,754; 9,636; 30,396; 14,725; 11,632 |

Bold marks a reference-stall value outside its acceptance range (2.5 to 4.5
waiting, at least 0.85 busy). With any added stall the reference stall also
misses the 10:00 row on four of the six runs (0.35 to 0.49 against 0.5) and
stays in range from 14:00 to 17:00 (0.50 to 0.81). No owner stall was short
of an ingredient on a measured day, no wholesale product was at zero, and no
restaurant was distressed or in arrears.

**The arithmetic of why.** A day's arrivals are `arrivals_per_equivalent`
times the larger of the hall's business equivalents and three. A stall open
ten of the day's 22 customer hours is 10/22 of an equivalent, 0.45; each
added owner stall raised the hall's measured equivalents by about 0.46
(1.89, 2.35, 2.81, 3.26, and 4.17 with five).

- **Up to three equivalents the pool is fixed.** The four-restaurant hall is
  1.89 equivalents and is given the diners of three: 744 a day. A fifth and
  a sixth restaurant add no diners, so the 90 arrivals of the noon hour are
  shared by three, then four, then five open stalls: 30.0, 22.5, 18.0 each.
- **Past three equivalents arrivals grow with the hall,** which the seventh
  restaurant reaches. Each further ten-hour stall then brings 248 x 0.45 =
  113 arrivals a day with it, 13.6 of them in the noon hour, so a stall's
  share of the noon hour stops falling: 15.8 with seven restaurants and 15.2
  with nine. That is about half the four-restaurant hall's 30.

The measurements agree with that arithmetic. The four-restaurant hall is
therefore the most favourable case for the rush queues, because the floor
gives it more diners than its stalls earn. By the same arithmetic, not by
measurement, a hall larger than nine restaurants would stay at about 15 noon
arrivals per open stall, since arrivals and stalls then grow together.

**What it means for the two decisions.**

- *The rush feel as the hall grows.* "Three or four people queuing at the
  rushes" was measured only in the four-restaurant hall. With five
  restaurants the reference stall has 1.7 at noon and 2.1 at 19:00. With six
  to nine it has 1.1 to 1.5 at noon and 1.2 to 1.7 at 19:00, the feel the
  owner asked for mid-morning, and the mean over all the owner stalls is the
  same (1.1 to 1.7 and 1.3 to 1.8). With any added stall its counter is still
  busy 77% to 92% of the rush hour. Diners do better as the hall fills: the served share rises
  from 0.52 to 0.56 to 0.59, and those leaving for the wait fall from 16% of
  arrivals to 11% to 13%.
- *A rise in rent or wages.* The four-restaurant profit (60,900 to 66,300 a
  day for the reference stall) is the top of what was measured. The same
  stall made 46,100 with five restaurants and 25,800 to 34,700 with six to
  nine. The added stalls, which sell starters of nearly the same price, made
  43,700 with five restaurants and 9,600 to 31,000 with six to nine; rent
  and wages are 25,200 to 26,600 a day for each of them (the rent of a
  standard spot rises as the class fills). A rise sized to the
  four-restaurant profit would be paid from these smaller profits: the
  weakest added stall measured made 9,636 a day, so any rise of more than
  that would have put it at a loss in that run.

**Not measured here.** Medium and full occupancy: the largest hall measured
is nine restaurants (three computer-run and six owner stalls, 4.1 to 4.2
equivalents) of the hall's 150 spots. Halls with one, three and five added
stalls on any seed but 20261109. Added stalls on today's values, on the
sharper day shape, with other hours or prices, or run by computer-run
owners. More than three measured days. Whether the profit spread between
added stalls (9,636 to 30,396 in one run) comes from cuisine, price or
position was not separated.

## Served share

Mains served as a share of arrivals, same run, seed and reference stall,
today's values against the chosen values. It is higher under the chosen
values in all eight comparisons, and in the three with the salmon stall.

| Run | Seed | Today | Chosen | Change |
| --- | --- | --- | --- | --- |
| A | 20261109 | 0.401 | 0.522 | +0.121 |
| A | 7 | 0.401 | 0.531 | +0.130 |
| A | 12345 | 0.405 | 0.522 | +0.117 |
| A | 424242 (held out) | 0.395 | 0.524 | +0.129 |
| B | 20261109 | 0.332 | 0.411 | +0.079 |
| B | 7 | 0.348 | 0.413 | +0.065 |
| B | 12345 | 0.343 | 0.395 | +0.052 |
| B | 424242 (held out) | 0.340 | 0.406 | +0.066 |
| A, salmon reference | 20261109 | 0.379 | 0.462 | +0.083 |
| A, salmon reference | 7 | 0.393 | 0.491 | +0.099 |
| A, salmon reference | 12345 | 0.401 | 0.482 | +0.080 |

The margin to defend is run B's: its lowest chosen share (0.395, seed 12345)
is 0.047 above today's highest (0.348, seed 7), where the spread between
seeds is 0.016 for today's values and 0.018 for the chosen ones. Run B's
share falls as arrivals rise, because its three stalls are already full at
the rushes; that is why the rushes were not set higher than the checks
needed.

## Sensitivity

Each row reverts one chosen value to today's and re-runs seed 20261109,
against run 125 (run A) or run 128 (run B).

| Reverted | Run | What moved |
| --- | --- | --- |
| `arrivals_per_equivalent` to 90 (run 137) | A | All six reference rows leave their ranges: waiting at the rushes from 3.25 and 2.76 to 0.80 and 0.67; busy from 1.00 and 1.00 to 0.63 and 0.54; waiting at 10:00 from 1.04 to 0.30 and at 14:00-17:00 from 1.01 to 0.26 |
| Market targets and caps to today's (run 138) | B | `nothing_available` share of leavers from 0.0023 to 0.603, out of its bound; served share from 0.411 to 0.145; mains on day 0 from 305 to 85 |
| Starter shifts to today's (run 151) | B | Served share from 0.411 to 0.368; mains served over three days from 917 to 821; arrivals finding every queue full from 14 to 90 |
| Fallback to 10 (run 152) | B | Mains on day 0 from 305 to 255 |

## Applied by the recorded change

Run 135 starts the hall on today's values and applies the chosen values with
`retune_rules` at 12:00 of the warm-up day (`--via retune`), seed 20261109.
Over the three measured days:

| Check | `--via init` (run 125) | `--via retune` (run 135) |
| --- | --- | --- |
| Reference waiting 12:00-13:00 | 3.25 | 2.60 |
| Reference waiting 19:00-20:00 | 2.76 | 2.89 |
| Reference busy 12:00-13:00 | 1.000 | 0.933 |
| Reference busy 19:00-20:00 | 0.996 | 1.000 |
| Reference waiting 10:00-11:00 | 1.04 | 0.90 |
| Reference waiting 14:00-17:00 | 1.01 | 1.10 |
| Hall waiting per stall 00:00-03:00 | 0.061 | 0.101 |
| Reference open instants short of an ingredient | 0 | **10** |
| Served share | 0.522 | 0.524 |

Every row is met by both paths except the ingredient row, which the retune
run misses by 10 instants on its first measured day. The two halls have
different histories from the warm-up day on, so their queue rows differ as
two seeds' would: the retune run's noon queue was 2.77, 2.25 and 2.77 on
its three days. What the first day looks like, and why, is under
[The first day after the recorded change](#the-first-day-after-the-recorded-change).

## Profit

For the owner's decision on costs. Prices, rents and wages are unchanged.
Profit is the change in cash minus the change in rent arrears between two
midnights; rent and wages are charged together and the hall does not record
them separately. Means per measured day over three days, run A, in the
four-restaurant hall. The same stall in halls with more restaurants is under
[With more stalls](#with-more-stalls).

**No restaurant was distressed on any measured day or in arrears at the end
of any run in this section**, on today's values or the chosen ones, so no
profit below is missing charges.

Today's values, median-priced reference stall (runs 80, 81, 82):

| Seed | Restaurant | Profit | Revenue | Purchases | Rent and wages | Other |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Reference | -10,058 | 16,920 | 1,778 | 25,200 | 0 |
| 20261109 | Budget | -1,249 | 28,732 | 4,432 | 25,550 | 0 |
| 20261109 | Mainstream | 12,343 | 50,750 | 11,832 | 26,575 | 0 |
| 20261109 | Premium | 3,141 | 33,492 | 5,626 | 24,725 | 0 |
| 7 | Reference | -10,058 | 16,920 | 1,778 | 25,200 | 0 |
| 7 | Budget | -1,313 | 28,599 | 4,363 | 25,550 | 0 |
| 7 | Mainstream | 12,093 | 50,353 | 11,685 | 26,575 | 0 |
| 7 | Premium | 3,294 | 33,567 | 5,548 | 24,725 | 0 |
| 12345 | Reference | -10,058 | 16,920 | 1,778 | 25,200 | 0 |
| 12345 | Budget | -1,373 | 28,557 | 4,380 | 25,550 | 0 |
| 12345 | Mainstream | 13,320 | 51,670 | 11,775 | 26,575 | 0 |
| 12345 | Premium | 3,281 | 33,513 | 5,506 | 24,725 | 0 |

On the held-out seed (run 133) the reference stall lost 10,059 a day and the
computer-run restaurants made -1,098 (budget), 10,616 (mainstream) and 409
(premium).

Chosen values, median-priced reference stall (runs 125, 126, 127; held-out
seed run 131):

| Seed | Restaurant | Profit | Revenue | Purchases | Rent and wages | Other |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Reference | 62,751 | 100,893 | 12,942 | 25,200 | 0 |
| 20261109 | Budget | 60,097 | 102,902 | 17,255 | 25,550 | 0 |
| 20261109 | Mainstream | 61,722 | 109,250 | 20,953 | 26,575 | 0 |
| 20261109 | Premium | 51,822 | 88,591 | 12,044 | 24,725 | 0 |
| 7 | Reference | 66,276 | 104,967 | 13,491 | 25,200 | 0 |
| 7 | Budget | 63,228 | 105,928 | 17,150 | 25,550 | 0 |
| 7 | Mainstream | 63,130 | 110,097 | 20,392 | 26,575 | 0 |
| 7 | Premium | 53,492 | 90,334 | 12,117 | 24,725 | 0 |
| 12345 | Reference | 60,904 | 98,700 | 12,596 | 25,200 | 0 |
| 12345 | Budget | 56,153 | 97,504 | 15,801 | 25,550 | 0 |
| 12345 | Mainstream | 69,745 | 117,567 | 21,247 | 26,575 | 0 |
| 12345 | Premium | 61,915 | 99,554 | 12,914 | 24,725 | 0 |
| 424242 (held out) | Reference | 64,126 | 102,460 | 13,134 | 25,200 | 0 |
| 424242 (held out) | Budget | 57,252 | 98,174 | 15,372 | 25,550 | 0 |
| 424242 (held out) | Mainstream | 66,056 | 113,800 | 21,169 | 26,575 | 0 |
| 424242 (held out) | Premium | 60,126 | 97,671 | 12,820 | 24,725 | 0 |
The bracket stalls, for comparison (salmon: today's values runs 1, 3, 5,
chosen values runs 139, 140, 141; bean tacos: chosen values runs 142, 143,
144, not run on today's values):

| Seed | Stall | Values | Profit | Revenue | Purchases | Rent and wages |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Salmon | Today | -9,979 | 19,927 | 4,706 | 25,200 |
| 20261109 | Salmon | Chosen | 22,936 | 63,033 | 14,898 | 25,200 |
| 7 | Salmon | Today | -7,134 | 22,773 | 4,707 | 25,200 |
| 7 | Salmon | Chosen | 29,295 | 72,387 | 17,892 | 25,200 |
| 12345 | Salmon | Today | -7,945 | 21,960 | 4,705 | 25,200 |
| 12345 | Salmon | Chosen | 32,030 | 75,233 | 18,003 | 25,200 |
| 20261109 | Bean tacos | Chosen | 62,822 | 103,133 | 15,111 | 25,200 |
| 7 | Bean tacos | Chosen | 65,918 | 106,533 | 15,415 | 25,200 |
| 12345 | Bean tacos | Chosen | 65,432 | 106,250 | 15,618 | 25,200 |

What this says for the cost decision, in the four-restaurant hall:

- Rent and wages are a fixed 24,725 to 26,575 a day for a single stall. Today
  that is more than a new owner's whole revenue (16,900 for the median stall,
  19,900 to 22,800 for the salmon stall). At the chosen values it is 24% to
  26% of the median reference stall's revenue, 24% of the bean-taco stall's,
  33% to 40% of the salmon stall's, and 23% to 28% of a computer-run
  restaurant's.
- A typical new owner clears 60,900 to 66,300 a day (three-seed range of the
  three-day mean daily profit; 64,126 on the held-out seed; 64,800 a day over
  14 days) on a starting grant of 500,000. Single days ranged from 57,823 to
  69,854. The owner of the cheapest starter clears about the same (62,800 to
  65,900); the owner of the second dearest a third to a half of that (22,900 to
  32,000).
- The median reference stall's purchases are 13% of its revenue (11% today);
  the bean-taco stall's are 15%; the salmon stall's are 24% to 25% (21% to
  24% today).
- In run B (runs 128 to 130 and 132, no reference stall) the computer-run
  restaurants' mean daily profits are 58,000 to 64,900 (budget), 76,000 to
  77,100 (mainstream) and 61,700 to 66,500 (premium); on today's values (runs
  2, 4, 6 and 134) they are -1,900 to -600, 12,600 to 13,900 and 1,900 to
  8,200.
- **These are the highest profits measured.** With one more owner stall the
  reference stall made 46,100 a day; with two to five more, 25,800 to 34,700,
  and the added stalls 9,600 to 31,000
  ([With more stalls](#with-more-stalls)).

### Fourteen days

Run 136: run A, chosen values, median-priced reference stall, seed 20261109,
14 measured days, four restaurants. The reference stall survives and grows;
it was never in arrears or distressed, and neither was any computer-run
restaurant.

| End of day | Reference cash | End of day | Reference cash |
| --- | --- | --- | --- |
| 0 (warm-up) | 533,082 | 8 | 1,054,356 |
| 1 | 593,781 | 9 | 1,116,648 |
| 2 | 656,367 | 10 | 1,181,173 |
| 3 | 721,335 | 11 | 1,247,068 |
| 4 | 790,589 | 12 | 1,312,190 |
| 5 | 857,275 | 13 | 1,377,016 |
| 6 | 926,340 | 14 | 1,440,531 |
| 7 | 994,954 |  |  |
That is 64,818 a day on average. From the end of the warm-up day to the end
of day 14 the computer-run restaurants' cash went from 430,033 to 1,279,644
(budget), 456,212 to 1,346,853 (mainstream) and 423,671 to 1,168,505
(premium).

The 14-day verdict meets every row: reference waiting 3.09 at 12:00 and 2.62
at 19:00; busy 0.993 and 0.996; waiting 1.28 at 10:00 and 1.08 from 14:00 to
17:00; hall 0.090 per stall overnight; never short of an ingredient; served
share 0.518.

The salmon stall was run for 14 days at the first chosen values (run 64): its
cash went from 500,418 to 899,407, 28,499 a day, never in arrears. It was not
re-run for 14 days at the chosen values, and no hall with added stalls was
run for 14 days.

On the warm-up day the reference stall is short of its ingredients for its
first 160 samples (64 hall minutes): its restock policy first runs at the
hour after it opens. The warm-up day is not measured.

## For the owner's attention

Findings that the measurements show, that are not tuning and that were not
changed. Each is the owner's to act on or leave.

1. **A new owner's 09:00 to 21:00 stall is closed for the dinner hour.** A new
   restaurant has three starter staff, and they take an automatic one-hour
   protective break after ten working hours. A stall opened 09:00 to 21:00
   therefore stops at 19:00, in the middle of the dinner rush, every day. The
   driver's reference stall had to be moved to 10:00 to 20:00 for this reason.
   Run 153 (the design's schedule at the chosen values, seed 20261109) shows
   it: the stall is open for 0.0 of the 19:00 hour on every measured day,
   with 0.35 orders waiting against 2.5 to 4.5 and the counter busy 0.027 of
   the time against 0.85. Its noon queue in that run was 2.39, also under its
   range. (Run 124 is the same schedule at the sharper alternative: 0.52 and
   0.029 at 19:00, 3.13 at noon.) The ten-hour rule is a staff rule, not one
   of the allowed values.
2. **About 2% of accepted orders are lost when a stall stops with a queue.** A
   stall that reaches its break or the end of its shift with orders waiting
   does not serve them. In the final runs 1.5% to 2.8% of admitted orders
   ended with no main served, and in the 14-day run 131 trays were cancelled
   (2.4% of visits that ended). The reference schedule makes this worse for a
   new owner than it need be: its ten hours end at 20:00, straight after the
   dinner rush, so its busiest hour is its closing hour and the queue it has
   built is the queue it abandons. 30 of the 141 trays and desserts cancelled
   in the 14-day run fell in the 20:00 hour, the only hour in which the
   reference stall is the one that has just stopped. Detail under
   [Orders lost when a stall stops](#orders-lost-when-a-stall-stops).
3. **About a quarter of arrivals leave because nothing open is affordable.**
   The share is 24% to 28% at the chosen values and 25% to 29% at every
   arrival level tried once supply was in place. Diner budgets are not among
   the allowed values, so tuning cannot move it. Detail under
   [What binds](#what-binds), item 3.
4. **The profit effect at unchanged prices, rent and wages** is the input to
   the decision on costs. In the four-restaurant hall the reference stall
   goes from a loss of about 10,100 a day to a profit of 60,900 to 66,300 a
   day (three-seed range of the three-day mean daily profit). See
   [Profit](#profit).
5. **The rush feel and that profit belong to a hall of four restaurants.**
   With six to nine restaurants the same stall has 1.1 to 1.7 orders waiting
   at the rushes and makes 25,800 to 34,700 a day, and an added owner stall
   makes as little as 9,600. Nothing in the allowed values can hold three or
   four at the rushes both in a four-restaurant hall and in a fuller one,
   because the diners of a hall under three equivalents do not grow with its
   stalls. Whether the floor, the arrivals per equivalent above the floor, or
   the target itself should change for a fuller hall is a design question,
   not tuning. See [With more stalls](#with-more-stalls).
6. **The choice between the chosen day shape and the sharper one.** The
   chosen shape misses the noon queue check on two of four seeds, by 0.05 and
   0.17; the sharper one meets every check on all four, serves a smaller
   share of arrivals on three of four seeds, and has more full-queue
   turnaways on three of four when the computer-run stalls trade alone. See
   [The choice between two day shapes](#the-choice-between-two-day-shapes).
7. **How scarce wholesale stock should be.** The market was sized at 100
   portions per equivalent so that nothing runs out. At 50 portions the hall
   served exactly the same meals, with two shared staples (`olive_oil_value`
   and `rice_long`) at zero for part of two or three measured days (runs 49
   and 50 against 41 and 44, at the first chosen values with the salmon
   stall). The chosen size therefore leaves nothing scarce. The supply-market
   project that follows wants owners to see rivals competing for supplies; if
   scarcity is meant to be part of the game, the owner may prefer a smaller
   market. Sizes between 25 and 50 portions were not tried.
8. **Players should be told before the change is applied.** Arrivals nearly
   triple from the next game midnight. An owner's restock targets and daily
   budgets are their own settings, and ones sized for today's trade (the
   median stall sells 18 mains a day today and 105 to 112 after) will run the
   stall out of stock on the first day until the owner raises them. This is
   read from the rules and from the computer-run owners' first day below,
   not measured with a human owner: the driver's reference owner has a
   deliberately generous policy. The operator should announce the change
   before applying it.

One further observation, about applying the change rather than the game, is
under [The first day after the recorded change](#the-first-day-after-the-recorded-change).

### Orders lost when a stall stops

With real queues, a stall that stops serving with orders waiting does not
serve them. A stall stops when its staff take their protective break (after
ten working hours, for an hour) and when its shift ends.

- In the final runs (125 to 132) 13 to 33 admitted orders per three days
  ended with no main served (`main_failed`): 1.7% to 2.8% of admitted orders
  in run A and 1.5% to 2.6% in run B. On today's values there were 0 to 2,
  because queues were nearly empty.
- In the 14-day run (run 136), read from the committed events: 131 trays were
  cancelled, 2.4% of the 5,527 visits that ended, and 10 desserts. 104 trays
  and 5 desserts missed their deadline (`deadline_missed`), all 109 in an
  hour when a stall had just stopped: 15:00 (the budget stall's break), 17:00
  (its shift end), 20:00 (the reference stall's shift end), 21:00 (the
  mainstream stall's break) and 23:00 (its shift end). 27 trays and 5
  desserts were cooked and then expired (`ready_food_expired`): 23 of those
  32 in the same hours and 9 at the lunch rush (12:00 and 13:00), where
  cooked food waited too long for the single counter.
- **The diner's money.** The cancellation event carries no price. Reading the
  hall's rules for that event: the diner is not charged (a guest's reserved
  funds are released; a simulated diner's committed budget is released), the
  restaurant receives nothing, and the cost of ingredients already used moves
  from work in progress to waste. 129 of the 131 cancelled trays had used
  ingredients; 14,391 was written off over the 14 days across the four
  restaurants. The visit is finalised as failed with a score of zero, which
  the event marks as counting toward the restaurant's recognition.
- The driver has no real guests, so a guest's side of this was read from the
  rules, not observed.

Whether a stall should stop accepting orders before a break or the end of its
shift, or finish its queue first, is a rule about staff and closing, outside
this project's allowed values.

### The first day after the recorded change

Run 135 against run 125, first measured day only (read from each run's hourly
and daily output), seed 20261109:

| | `--via init` | `--via retune` |
| --- | --- | --- |
| Reference waiting 12:00 / 19:00 | 3.51 / 2.49 | 2.77 / 2.85 |
| Reference busy 12:00 / 19:00 | 1.00 / 1.00 | 0.89 / 1.00 |
| Reference waiting 10:00 / 14:00-17:00 | 0.82 / 1.30 | 0.65 / 1.32 |
| Reference short of an ingredient | 0 | 10 instants: cornmeal, vegetarian cheese |
| Reference purchases | 12,801 | 33,003 |
| "Premium" purchases / revenue | 12,847 / 84,484 | 6,790 / 91,436 |
| Arrivals leaving for `nothing_available` | 1 | 13 |
| Mains served / served share | 382 / 0.513 | 381 / 0.512 |
| Wholesale products at zero | none | none |

What differs, and why:

- **The change itself.** Arrivals and market replenishment switch at the
  first midnight after the change, and the new shifts are in force from the
  first measured day. At the moment of the change the market's stock is
  topped up in proportion to the raised targets, which by the change's design
  keeps wholesale prices from rising (prices were not measured here); a
  product that had already sold out stays at zero until midnight.
- **The reference stall starts the day empty.** The warm-up day ran on
  today's market, where its cornmeal and cheese sold out before the change
  (the stall was short for 1,253 of its 1,500 open samples that day). It
  opened the first measured day with none, waited one market clearing (10
  samples, four hall minutes) for its first delivery, and bought two and a
  half times as much that day. This is the only verdict row the retune run
  misses. The driver does not print the stall's stock, so "started empty" is
  inferred from the timing, not read directly.
- **Computer-run owners stock for yesterday.** The planner expects the
  previous day's admitted trays, which were still today's small numbers (114
  across four stalls). The "premium" owner, which restocks one day at a time,
  bought 6,790 instead of 12,847, and 13 arrivals instead of 1 left because
  nothing was available. Its revenue that day was not lower (91,436 against
  84,484). On the second day it bought 16,970, and the purchases have caught
  up.
- The queue rows on that day differ by no more than days of one run differ
  from each other (the three days of run 125 had 3.51, 3.30 and 2.93 at
  noon).

From the second measured day there is no difference beyond that variation.
Only seed 20261109 was run this way, with a reference owner whose restock
policy is generous; what a human owner's tighter policy does on that day is
finding 8 above.

## What binds

With a typical reference stall in a four-restaurant hall, every check is met
on two seeds and all but the noon queue on the other two. What limits going
further, and what makes the harder cases miss, are these five things; none
is an allowed value.

1. **Three stalls alone (run B).** With the reference stall absent, one
   computer-run stall is open in most hours and two around each rush. In
   every run B from 235 to 286 arrivals per equivalent with the chosen supply
   and shifts, the hall served between 294 and 320 mains a day (294 to 307 at
   the chosen values, 312 to 320 at 286), so its served share falls as
   arrivals rise. At the chosen values its stalls hold 4.4 to 5.1 orders at
   noon, 0.6% to 2.0% of arrivals find every open queue full, and its share
   is 0.052 to 0.079 above today's. This is what caps the rush weights.
2. **The reference stall's price.** At the same values the bean-taco stall
   (850) has 3.3 to 4.3 waiting at the rushes, the median-priced stall (940)
   2.3 to 3.3, and the salmon stall (1,220, the second dearest of the 22
   unused starters, and a roast, the slowest method) 1.4 to 2.2. Diners who
   can afford a cheaper stall fill it first. Raising arrivals until the
   salmon stall reached 2.5 would push the other stalls past the queue limit
   and run B's share toward today's; that was not done.
3. **Segment budgets against menu prices.** A quarter of all arrivals (24% to
   28%) leave because nothing open is affordable, at every arrival level
   tried once supply was in place (25% to 29%). By the content's numbers, not
   a measurement: "value" diners are 40% of arrivals and carry 400 to 1,200,
   and the cheapest main in this hall is 773.
4. **The counter against patience.** A stall hands over one tray at a time
   and a handover takes four hall minutes, so a stall serves at most 15 trays
   an hour; a saturated computer-run stall open alone served about 12 mains
   an hour. 16% to 18% of arrivals in run A and 27% to 28% in run B leave
   because the wait is too long. By the content's numbers: "time-sensitive"
   diners are 25% of arrivals and wait 5 to 12 minutes, and the fastest
   starter takes 7 minutes with an empty kitchen.
5. **The number of stalls.** Under three equivalents the hall's diners do not
   grow with its stalls, so a fifth and a sixth restaurant thin every queue;
   above three they grow in step, at about half the four-restaurant hall's
   arrivals per stall. See [With more stalls](#with-more-stalls).

The 300,000 storage capacity did not show up as a shortage: at the chosen
values `nothing_available` was 0.1% of arrivals and no owner stall was short
on a measured day. Whether it trimmed any computer-run purchase was not
measured.

## Rulings made while building

Decisions made while the work was being built, in the order they were made,
each with what it decided, why, and what it costs if wrong. The first five
were made before any task started, the next nine as tasks reported, and the
last four after the final review. Ruling 13 was reversed by ruling 15, and
ruling 11 was amended by ruling 16.

1. **"Counter busy".** It is measured as the hall view's
   `activity.cooking > 0 or activity.handover`: some station working, or a
   tray at the counter. *Why:* the design says "the counter busy" and "kitchen
   working close to flat out" without a formula, and this uses numbers a player
   sees. *If wrong:* the 85% rows measure a different quantity and the tuning
   may be slightly off; the driver prints the raw shares so they can be
   recomputed.
2. **New halls start on today's values.** The launch catalog is unchanged; the
   chosen values exist only as `Tuning.chosen/0` and reach a hall through the
   recorded change. *Why:* the design says the change is not applied
   automatically and the owner decides on costs first. *If wrong:* a one-line
   change makes the launch catalog start at the chosen values.
3. **The recorded change takes effect at the next game midnight.** Arrival
   quotas and market replenishment are already recorded per day, so this needs
   no mid-day arithmetic and keeps "earlier events replay under the old
   values" true without further work. *If wrong:* an operator waits up to one
   game day (an hour of real time) to see more customers.
4. **The acceptance test pins only the checks that pass at the chosen values,**
   with the failing ones named in this report. *Why:* the design tells the
   builder to report the closest result rather than widen the allowed values.
   *If wrong:* a failing target is documented but not enforced. On the
   seed the test pins (20261109) no row fails with the median-priced
   reference stall, so the test asserts all of them there. The noon row that
   seed 7 and the held-out seed miss is listed in the test and not asserted,
   and the salmon stall's misses are in
   [The brackets](#the-brackets-a-dearer-and-a-cheaper-reference-stall).
5. **The change is applied through an operator HTTP endpoint** guarded by the
   operator secret, like the existing seed endpoint. *Why:* "a separate,
   explicit step" needs some trigger, and this is the existing operator
   pattern. *If wrong:* replace it with a release task; the domain command is
   the same.
6. **The recorded change tops up wholesale stock.** For each product whose
   target rises, the event records `added = ceil(stock * new_target /
   old_target) - stock`, and evolution adds it; nothing is recorded for
   unchanged or lowered targets, and stock is never removed. *Why:* the
   published price depends on the stock target, so without a top-up every
   raised target raised wholesale prices at once until midnight, and the
   planner's price limits, restock budgets and salvage values moved with it. A
   full replenishment would also have reset prices of products that were
   scarce. This reverses the plan's statement that the change leaves stock
   alone. *If wrong:* drop the stock field and accept a one-day price spike.
7. **Two review findings were fixed in the same round because start-up depends
   on them:** the tuning and retune modules are loaded before safe term
   decoding (a cold VM could otherwise reject a snapshot taken after a
   retune), and a test pins that a catalog expansion after a retune keeps the
   retuned values (start-up issues an expansion when a new launch version
   ships). *If wrong:* the cost is a small amount of extra test code.
8. **The reference stall opens 10:00 to 20:00, and its mid-morning check is
   10:00 to 11:00,** instead of the design's 09:00 to 21:00 and 09:00 to
   11:00. *Why:* ten hours is the longest the three starter staff can work
   without the protective break, and on the design's schedule the 19:00 to
   20:00 checks cannot be met by any allowed value. *If wrong:* the owner may
   prefer to keep 09:00 to 21:00 and drop or move the dinner check, or change
   the fatigue rule; the driver takes the hours as an option (`--hours`), so
   either can be re-measured in seconds. See finding 1 under
   [For the owner's attention](#for-the-owners-attention).
9. **The determinism test gains a one-measured-day run A comparison.** It
   settles a reviewer's doubt that multi-day output is byte-identical. *If
   wrong:* none beyond test time.
10. **The run budget was raised from 30 to 150 driver runs** (124 were used before the final review; the
    budget was then raised to 200 for the final fix wave, and 166 were used in
    all). A
    three-day run takes 5 to 10 seconds, not the minutes the plan assumed, so
    the cap no longer protected anything and a wider search over several seeds
    gives sturdier values. Runs stay one at a time. *If wrong:* only time was
    spent.
11. **The chosen values must hold on at least three seeds,** not only the one
    the acceptance test pins. *Why:* a single seed could pass by luck near a
    bound. *If wrong:* a few more runs were spent. Amended by ruling 16.
12. **The reference stall sells the unused cuisine whose starter main has the
    median suggested price** (ties to the lower price, then by cuisine ID),
    not the first unused cuisine in sorted order. *Why:* the earlier rule
    happened to pick the second dearest of 22 starters and the slowest method,
    and the design's reference stands for a competent new owner with a default
    starter, which a typical price represents better. *If wrong:* the owner
    may want the targets judged on the dearest stall too; its result stays in
    this report as a second column (it misses the rush-waiting rows) and the
    cuisine is a driver option.
13. **Reversed by ruling 15.** ~~The final values (252 arrivals, rush weights
    34 and 33) stand,~~ with the report presenting the cost of the last step
    and the gentler alternative as the owner's choice. *Why, at the time:*
    they were the only candidate that met every acceptance row on all three
    seeds with served share above today's in all six comparisons. *If wrong:*
    the owner picks the alternative. The final review judged it wrong by the
    design's own priority rule.
14. **A test pins a fingerprint of `Tuning.chosen/0`** (product count, sum of
    market targets and a SHA-256 hash). *Why:* the market values are computed
    from the launch catalog's recipes, so a later catalog change could
    silently make "version 2" mean different values. *If wrong:* the test
    fails on a legitimate catalog change and has to be updated knowingly.
15. **The chosen values become the gentler day shape** (248 arrivals, rush
    weights 30 and 28), and the sharper shape (252, 34 and 33) becomes the
    documented alternative. This reverses ruling 13. *Why:* the final
    reviewer was right that the sharpening is tuning to the test: weight was
    moved onto the two measured hours at the cost of served share and with
    about twice the full-queue turnaways, which is what the design's "served
    share wins" sentence names. The gentler shape meets every row on the
    design's single run and, on the seeds measured when the ruling was made,
    missed one row on one extra seed by 0.05 against a day-to-day spread of
    about 0.4. The three-seed bar that had pushed toward the sharper shape
    was the controller's, not the design's. *If wrong:* the owner prefers
    every row on every seed; two values change back, and both shapes stay
    measured side by side in this report. *Measured after the ruling:* on
    the held-out seed the gentler shape misses the same row by 0.17 and has
    more full-queue turnaways than the sharper one, not fewer (see
    [The choice between two day shapes](#the-choice-between-two-day-shapes)).
16. **The three-seed requirement of ruling 11 becomes "reported on three seeds
    plus one held-out seed (424242) never used for selection";** the
    acceptance test pins seed 20261109 and lists any row another seed misses.
    *Why:* the three seeds had all been used while choosing, so none was an
    independent check. *If wrong:* four more runs were spent; the rows the
    extra seeds miss are documented and not enforced.
17. **The driver gains `--extra-stalls N`** (more owner stalls like the
    reference, each on a different mid-priced cuisine), so that a hall of
    five to nine restaurants is measured, not argued from arithmetic. *Why:*
    the owner's two biggest decisions (apply, and raise costs) depend on
    whether the feel and the profit survive more stalls. *If wrong:* some
    driver work was spent; the results are reported as evidence beyond the
    design's sparse-hall acceptance.
18. **The acceptance test runs in hosted CI as its own step** (about 20
    seconds). *Why:* a tuned feel that no automated run checks will rot. *If
    wrong:* 20 seconds per CI run.
19. **The gentler shape stays the chosen default after the held-out seed's
    result** (on seed 424242 it misses the noon row by 0.17 while the sharper
    shape meets every row with fewer full-queue turnaways). *Why:* the result
    shows the two shapes are within seed noise of each other on the queue
    rows, and served share, which the design ranks first, still favours the
    gentler shape on three of the four seeds. *If wrong:* two values change;
    the choice is the owner's and both shapes are measured side by side in
    [The choice between two day shapes](#the-choice-between-two-day-shapes).

## Final review

The whole branch was reviewed once more after the last task. The review found
nothing critical, three important problems and one ruling it disagreed with.

**Important findings, and how each was fixed.**

1. *The report did not say its results hold for a hall of exactly four
   restaurants at the demand floor.* Fixed by measurement, not wording alone:
   the driver gained `--extra-stalls`, halls of five to nine restaurants were
   run (runs 145 to 150), and the stall count now stands beside the headline
   in [What to decide](#what-to-decide) and
   [Result in short](#result-in-short), with the results and their meaning
   for both decisions in [With more stalls](#with-more-stalls).
2. *The test that pins the chosen values ran nowhere automatically* (it is
   excluded by tag, and hosted CI ran the plain suite). Fixed: the hosted CI
   check job now runs it as its own step after the suite, and the testing
   document says so. The step has not yet run, because nothing has been
   pushed.
3. *The deployment text said a backup restore is the only way back.* Fixed:
   it now says the event cannot be removed but the values can be changed
   again by a newer tuning version, what stays meanwhile (added stock, low
   wholesale prices), that no version 3 exists in the code today, and that
   after the change is applied the day shape, too, is switched only by a new
   version.

**The ruling the review disagreed with** was ruling 13, a close call; it was
reversed (ruling 15).

**Fixed alongside.**

- The operator route builds the chosen tuning only after the secret is
  accepted; before, it built a whole launch catalog for unauthenticated
  requests.
- Tests that an unset, empty or 31-byte configured operator key opens neither
  the retune route nor the seed route, even to a request presenting exactly
  that key.
- The documented command ID is now `upgrade:retune-2`, under a prefix devices
  cannot use, with a test that a device cannot spend it first. The earlier
  documented ID could have been spent by any device before the operator.
- A test that a retune to the chosen values never raises a wholesale price
  and lowers one by at most a rounding step, from a market at a third of its
  opening stock (where every price is at its ceiling) and from seven units
  above that (where none is, and the rounding shows). The `Retune` module's
  documentation now says this instead of "prices do not move".
- A test that a product added by a later launch version, after a retune, gets
  the launch catalog's own target while every retuned value is kept; the
  architecture document says so, and that only a newer tuning version can
  change it.
- The deployment text tells the operator to announce the change first and to
  unset the operator key afterwards.
- A held-out seed, the sharper shape on that seed, both brackets, the rise in
  diners leaving for the wait, and the real-time length of a hall hour are in
  this report.

**Deliberately left.**

- The retune route repeats the seed route's authorisation chain.
- No golden event fixture pins `Retune.evolve` against a later edit to
  `Tuning.put`.
- The "counter busy" rows are nearly implied by the waiting rows.
- Start-up command IDs (`web-init`, `web-launch-catalog:<n>`,
  `web-visitor-play`) can be spent first by a device. This predates the
  branch and deserves its own issue.
- No rate limit on operator routes.
- The minor findings from earlier reviews that the final review left: they
  remain listed under [Not verified](#not-verified).

## Not verified

- **No full test suite was run.** Only the files named under
  [Checks](#checks), one at a time.
- **Nobody has played a hall on these values.** No human owner or guest has
  seen them.
- **The measurements are a simulation** at sparse-hall settings, with
  simulated diners only and no real guests.
- **Three of the four seeds were used while choosing.** Seeds 20261109, 7 and
  12345 are both the seeds the values were selected on and the seeds they
  were confirmed on. Only seed 424242 is independent, and it is one seed.
- **Medium and full occupancy.** The game design asks for sparse, medium and
  full. The largest hall measured is nine restaurants of 150 spots, on one
  seed, for three days.
- **Load.** Arrivals per equivalent rise about 2.8 times (90 to 248). The
  capacity evidence in the
  [Project C report](2026-11-10-milestone-2c-capacity.md) was measured at 90
  per equivalent (13,500 arrivals a day with 150 stalls). Event volume,
  timing and database growth at the chosen values were not measured. The
  hosted database fails writes beyond 1 GB of storage, and that capacity run
  grew by about 43 MiB per game day
  ([Deployment](../../DEPLOYMENT.md#render-blueprint)).
- **The change has not been applied** to any real hall or trial copy of one.
  The recorded change was exercised only by its own tests and by the driver's
  in-memory `--via retune` run (run 135, one seed).
- **The hosted CI step** that runs the acceptance test was added and has not
  run: nothing was pushed.
- **The packaged apps are unaffected and were not rebuilt.** No client code
  changed.

Not measured, as a list of what the runs do not cover:

- Any human owner. The reference owner and the added owners are driven by the
  script, with one fixed policy.
- Real guests. Every diner in these runs is simulated.
- More than four seeds, and more than three measured days except runs 64, 101
  and 136.
- Halls with added stalls beyond the six runs under
  [With more stalls](#with-more-stalls).
- The recorded change on any seed but 20261109, at another time of day, or in
  a hall with open orders and leases (the change's own tests cover pinned
  terms; they do not use these values).
- Live, genesis and snapshot-tail agreement at the chosen values.
- The reference stall with the design's 09:00 to 21:00 hours beyond runs 124
  and 153 (one seed each, no tuning chosen on them), or with any cuisine
  other than the median-priced one, `coast_salish` and `mexican`.
- The bracket stalls on the held-out seed; the bean-taco stall on today's
  values; the flat shape on the held-out seed.
- Arrival levels above or below the chosen values with the median-priced
  reference stall, other than the three columns under
  [The choice between two day shapes](#the-choice-between-two-day-shapes).
- Market size and fallback at the chosen arrivals: they were sized at 249
  arrivals per equivalent and re-checked at 248 only by the absence of
  shortages in the final runs and by the reverts.
- Wholesale prices paid. The driver prints purchases, not prices.
- Mains served per stall. The driver prints hall totals and each restaurant's
  revenue.
- Whether storage capacity trimmed any purchase (the driver does not print
  unfilled purchase requests).
- Market sizes between 25 and 50 portions, and above 100.
- Memory use of these runs. The driver's own check measured about 200 MB.

Minor review findings left open, grouped by task. None changes a reported
number; each is a gap in a test, a message or a corner of the driver.

Task 1 (tuning as data):

- A bad shift list reaching `Content.validate/1` (rather than
  `Tuning.validate/2`) is untested.
- `Tuning.npc/1` and `Tuning.of/1` raise on a catalog with no rules.
- The `refused/1` test helper asserts only that some error came back, not
  which problem.
- A bad computer-run profile is reported twice, in two shapes; a non-map
  `products` value would raise in `Tuning` (a shape that was already
  unguarded).

Task 2 (the recorded change):

- An unmanaged launch hall can be retuned.
- The domain test does not assert that the non-tunable parts of the catalog
  are unchanged.
- One assertion (`position == live.position == (tail == [])`) is hard to read.
- A guest offer confirmed before the change must be reconfirmed, as after a
  catalog expansion. This is documented (deployment and architecture) but
  not covered by a test with these values.
- With a demand floor that is not a multiple of 1,000 a price could rise by a
  few units at a retune (the launch floor is 3,000, so it only falls); the
  module documentation now states the launch case.
- The new `ensure_loaded` lines in the safe term decoder have no cold-VM test
  (the project has none for that path).
- `evolve` reads the event's `stock` field and would raise on a retune event
  recorded by the first version of the change, which was never shipped.

Task 3 (the driver):

- The served-share denominator counts simulated arrivals only.
- The ingredient-short check ignores substitutes, so it is stricter than "ran
  out".
- A starter grant posted in a measured day would count as profit.
- `--via retune --tuning current` needs `--set version=2`.
- An empty-counts literal is repeated three times; `Hall.run` leaves the
  authority running if an unexpected exception escapes.
- Releasing a location while distressed moves arrears into released debt,
  which the profit's arrears sum misses (the distressed warning flags it).
- One helper shift anywhere turns off the reconciliation check for every
  restaurant that day.
- Distressed days hide accruing rent and wages, because the rules charge
  nothing then, so profit on such a day is incomplete. No day in the profit
  tables was distressed.
- The no-free-standard-spot refusal for an added stall has no test (22
  cuisines and the open rooms' standard spots outlast the eight stalls the
  option allows).

Task 4 (the choice of values):

- The acceptance-test runs, a duplicate of run 1, a duplicate of run 125 and
  a zero-day header run are disclosed in the tuning log but not logged one
  line each.
- `reference_cuisine/1` raises `Enum.EmptyError` if no unused cuisine has a
  starter main.
- `customer_sim_test.exs` asserts an even count of unused starter prices,
  which ties it to today's catalog.

Task 5 (the operator request):

- The 403-before-422 order is tested only for the secret check alone.
- The retune route repeats the seed route's authorisation chain verbatim.

Task 6 (documents):

- The report writes "ml" for filtered water although every product's unit in
  the catalog is grams; its tables say "Today" where the game design says
  "Current".

## Reproducing the tables

All commands run from `server/`; `SIM` stands for
`mix run --no-start scripts/customer_sim.exs --`. Add `--json FILE` to get
the same numbers as data. Runs are deterministic: the same command prints the
same output. `--tuning chosen` now gives the gentler shape; the sharper
alternative is `SHARP`, which stands for `--set
demand.arrivals_per_equivalent=252 --set
demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5`
after `--tuning chosen`. Runs 95 to 124 were made when `--tuning chosen`
meant the sharper shape; add `SHARP` to repeat them.

| Table | Runs | Command (repeat for seeds 20261109, 7, 12345 and 424242 unless seeds are named) | Where in the output |
| --- | --- | --- | --- |
| Before, run A and run B | 80-82, 133; 2, 4, 6, 134 | `SIM --run a --tuning current --days 3 --seed SEED`; the same with `--run b` | "Verdict" block; "Per game day" lines for arrivals, served, reasons and products at zero |
| Before, salmon stall | 1, 3, 5 | `SIM --run a --tuning current --days 3 --seed SEED --cuisine coast_salish`, three seeds | "Verdict" block |
| After, run A and run B | 125-127, 131; 128-130, 132 | `SIM --run a --tuning chosen --days 3 --seed SEED`; the same with `--run b` | "Verdict" block; "Per game day" lines, where `main_failed` is the count after the bar, and the "business equivalents" line under each day |
| The brackets | 139-141; 142-144 | `SIM --run a --tuning chosen --days 3 --seed SEED --cuisine coast_salish`; the same with `--cuisine mexican`; three seeds | "Verdict" block; `profit reference` lines |
| Orders waiting per stall; hour by hour | 80, 2, 125-132, 139-144 | the Before, After and bracket commands | "Checked hours per stall" block for the checked hours; "Per hall hour" lines for every hour: `w` is orders waiting and `b` the busy share for each stall; each figure here is the mean of the three measured days' lines for that hour |
| The choice between two day shapes | 77-79, 57-59; 125-132; 95-100, 154, 155 | flat: `SIM --run a --tuning chosen --days 3 --seed SEED --set demand.arrivals_per_equivalent=249 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5`, three seeds; chosen: no `--set`; alternative: `SHARP`; each also with `--run b` | "Verdict" block; "Per game day" lines: `no_open_stall` and `wait_too_long` before the bar, summed over days 1 to 3 and divided by arrivals |
| With more stalls | 125, 145-148; 149, 150 | `SIM --run a --tuning chosen --days 3 --seed 20261109 --extra-stalls N` for N of 1, 2, 3, 5; N of 2 on seeds 7 and 12345 | "business equivalents" line under each day; "Rush hours" block; "Checked hours per stall" block; the two "owner stalls mean waiting" verdict rows; `profit` lines |
| Served share | as Before, After and the brackets | as Before, After and the brackets | the "served share" verdict row |
| Sensitivity | 137, 138, 151, 152 | seed 20261109: `SIM --run a --tuning chosen --days 3 --seed 20261109 --set demand.arrivals_per_equivalent=90`; `SIM --run b --tuning FILE --days 3 --seed 20261109` with FILE holding `%{Tuning.chosen() \| market: Tuning.of(LaunchCatalog.catalog()).market}` after `alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}`; `SIM --run b --tuning chosen --days 3 --seed 20261109 --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7`; `SIM --run b --tuning chosen --days 3 --seed 20261109 --set npc.fallback_trays_per_day=10` | "Verdict" block; day 0 line for mains on day 0 |
| Applied by the recorded change; first day | 135 against 125 | `SIM --run a --tuning chosen --days 3 --seed 20261109 --via retune`, against the same without `--via retune` | "Verdict" block; for the first day, the `d1` hour lines and the "day 1" line with its `profit` lines |
| Profit | 80-82, 133, 125-127, 131, 1, 3, 5, 139-144, 2, 4, 6, 134, 128-130, 132 | the Before, After and bracket commands | "Per game day": each `profit` line gives profit, revenue, purchases, rent+wages and other for one restaurant and day; each figure here is the mean of days 1 to 3 |
| Finding 1, design schedule | 153; 124 | `SIM --run a --tuning chosen --days 3 --seed 20261109 --hours 9-21` (exits non-zero by design); with `SHARP` for run 124 | "Verdict" block, row "A ref open during checked hours" |
| Fourteen days: verdict | 136 | `SIM --run a --tuning chosen --days 14 --seed 20261109` | "Verdict" block |
| Fourteen days: cash by day; cancelled trays by reason and hour | 136 | the wrapper script printed in the tuning log under "Runs not in the table", with the same arguments | its "Ledger at each midnight" and "Cancelled trays" lines; the command line alone prints each day's cash change, not the balance, and no cancellation reasons |

## Checks

From `server/`, one at a time, at the chosen values, after the final fix
wave:

- `mix test test/feud_hall/domain/tuning_test.exs`: 29 passed (one pins the
  chosen values: the arrival figure, the 24 weights, product count, sum of
  market targets and a SHA-256 fingerprint).
- `mix test test/feud_hall/domain/retune_test.exs`: 17 passed (four new: no
  price rises at a retune to the chosen values, from two stock levels; the
  two stock levels are what the test says they are; a product added by a
  later launch version keeps the launch target).
- `mix test test/feud_hall/application/retune_test.exs`: 5 passed.
- `mix test test/feud_hall/scripts/customer_sim_test.exs`: 19 passed (five
  new, for `--extra-stalls` and the owner-stall rows).
- `mix test --only acceptance test/feud_hall/scripts/customer_acceptance_test.exs`:
  2 passed (runs A and B at the chosen values, seed 20261109; asserts every
  acceptance row and that each served share is above today's; lists the noon
  row that seeds 7 and 424242 miss without asserting it).
- `mix test test/feud_hall/web/endpoint_test.exs`: 8 passed (four new: the
  three weak operator keys on both operator routes, and the reserved command
  ID).
- `mix test test/feud_hall/web/bootstrap_test.exs`: 1 passed.
- `mix test test/feud_hall/domain/market_test.exs`: 31 passed.
- `mix compile --warnings-as-errors`: clean.
- `mix format --check-formatted`: clean.

Not run: the full suite, and hosted CI (nothing was pushed).

Run before the final fix wave and not repeated in it: `npc_planner_test.exs`
(24 passed), `arrivals_test.exs` (21), `demand_forecast_test.exs` (25),
`invariants_test.exs` (35), `architecture_test.exs` (9). They were run at the
first chosen values, before the reference-cuisine change; none reads
`Tuning.chosen/0`'s day shape.
