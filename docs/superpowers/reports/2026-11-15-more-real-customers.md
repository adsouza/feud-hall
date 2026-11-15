# More real customers: measurements and chosen values

Evidence for Project 4 of the
[livelier hall design](../specs/2026-11-13-livelier-hall-design.md#project-4-more-real-customers):
what a sparse hall does on today's values, the values chosen from measured
runs, what they change, and what they do to profit. Every number here comes
from a run listed in the [tuning log](2026-11-15-more-real-customers-tuning-log.md);
"run 95" means line 95 of that log.

A log line holds a run's verdict rows, its arrivals, its mains served and its
arrivals' reasons for leaving. The other figures here (profit and its
components, orders waiting per stall and per hour, wholesale products at
zero, `main_failed` counts, single-day values and the first-day table) are
not in the log lines: they are read from the fuller output the driver prints
for the same run. Runs are deterministic, so repeating a line's command
prints them again;
[Reproducing the tables](#reproducing-the-tables) gives the command for each
table.

The values are `FeudHall.Domain.Content.Tuning.chosen/0`. They are proposed
tuning. A hall does not start on them and no hall receives them at boot: they
are applied by the recorded `retune_rules` change, as a separate step after
the owner's decision on costs.

## What to decide

1. **Apply the change or not.** The chosen values are proposed tuning and no
   hall has them; an operator applies them with
   [the operator request](../../DEPLOYMENT.md#applying-the-customer-tuning).
   The measurements are in [Result in short](#result-in-short).
2. **Whether costs should rise first.** At unchanged prices, rent and wages a
   stall's profit goes from about -10,000 to about 64,000 a day. See
   [Profit](#profit).
3. **Which day shape.** The chosen shape meets every acceptance check; the
   gentler one gives up one check on one seed for fewer full queues. See
   [The choice between two day shapes](#the-choice-between-two-day-shapes).
4. **Whether to act on findings 1 to 3** under
   [For the owner's attention](#for-the-owners-attention): the ten-hour staff
   rule, orders lost at a break or closing, and diners who cannot afford any
   open stall. None is tuning, and none was changed.

## Result in short

- **Every acceptance check is met on all three seeds**, with the reference
  stall selling a typical starter (the median-priced one). At the lunch and
  dinner rush it has 3.0 to 3.5 orders waiting (target 2.5 to 4.5) and its
  counter is busy 98% to 100% of the time; mid-morning and mid-afternoon it
  has 0.9 to 1.3 (target 0.5 to 2); overnight the hall has 0.11 to 0.14 per
  stall; it never runs short of an ingredient.
- **Served meals.** A sparse hall serves 3.2 to 3.7 times as many mains a day
  (run A: 108 to 109 a day before, 384 to 400 after; run B: 90 to 94 before,
  304 to 305 after), and a larger share of arrivals is served in all six
  comparisons (run A 0.40 before, 0.51 to 0.53 after; run B 0.33 to 0.35
  before, 0.40 after).
- **Supply.** Leaving because nothing is available falls from 14% to 25% of
  arrivals to 0.1%. No wholesale product runs out on a measured day.
- **The harder case.** A reference stall selling the second dearest starter
  (roasted salmon, 1,220) misses the two rush-waiting targets on all three
  seeds at the same values: 2.2 to 2.4 at 12:00 and 1.8 to 2.1 at 19:00. Its
  other checks are met except the 19:00 busy share on one seed (0.83 against
  0.85). See [What binds](#what-binds).
- **Run B is close to full.** With no fourth stall, the computer-run stalls
  hold 4.7 to 5.3 orders at 12:00 (the queue limit is 6) and 1.9% to 3.3% of
  arrivals find every open queue full. Run B's served share is 0.055 to 0.072
  above today's; that margin is what stopped the rushes being set higher.
- **The rush targets were bought with served share.** Meeting them needed a
  sharper one-hour rush than the first chosen shape. Against that flatter
  shape, run A's served share is lower on every seed (mean 0.516 against
  0.535), run B's on two seeds (mean 0.403 against 0.407), and when the
  computer-run stalls trade alone about twice as many arrivals find every
  queue full (2.6% against 1.25% on average). A gentler rush avoids the extra
  full queues and misses one row on one seed. The owner can choose it: see
  [The choice between two day shapes](#the-choice-between-two-day-shapes).
- **Profit.** At unchanged prices, rent and wages the reference stall moves
  from losing 10,100 a day to making 63,100 to 66,500 a day (the salmon stall
  from losing 7,100 to 10,000 to making 30,300 to 34,700), and the
  computer-run restaurants from between -1,400 and +13,300 to between 50,800
  and 67,000. No restaurant was distressed or in arrears in any final run.
- **Findings for the owner**, not tuning: five are listed under
  [For the owner's attention](#for-the-owners-attention), among them a new
  owner's 09:00 to 21:00 stall closing for the dinner hour, about 2% of
  accepted orders lost when a stall stops with a queue, and about a quarter of
  arrivals who cannot afford any open stall.

## Method

The driver is `server/scripts/customer_sim.exs`
([usage](../../TESTING.md#implemented-backend-entry-points)): a real hall
authority in memory at sparse-hall settings, one warm-up day and three
measured game days. Run A is the three computer-run restaurants plus a
reference owner playing through ordinary commands; run B is the three alone.

**The reference stall.** It is open 10:00 to 20:00 (not the design's 09:00 to
21:00: the three starter staff take a protective break after ten working
hours), so the mid-morning check is 10:00 to 11:00. It sells the starter main
with the median suggested price among the cuisines no computer-run restaurant
took (the lower middle price of the 22, then the first cuisine ID): in every
run here that is `colombian`, `arepa_con_queso` at 940. Until run 76 the
driver took the first unused cuisine in sorted order instead, which is
`coast_salish`, `roasted_salmon` at 1,220: the second dearest launch starter
and the slowest method. That stall is kept as the harder case
(`--cuisine coast_salish`).

Values were tuned on seed 20261109 and confirmed on seeds 7 and 12345. A check
counts as met only if it is met on all three. 123 driver runs were made, one
at a time, of a budget of 150; each three-day run takes 5 to 10 seconds.

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
    afternoon into the two rush hours, and trimmed from 09:00, 13:00, 20:00
    and 21:00. A first step (30 and 28 at the rushes) still missed noon on
    seed 7 (2.45); the second (34 and 33) meets every row on every seed.
    Supply, fallback and shifts were not touched. The step has a cost: against
    the first chosen shape, run A's served share fell on all three seeds
    (0.532 to 0.529, 0.531 to 0.513, 0.543 to 0.508), run B's on two (0.408 to
    0.404, 0.416 to 0.403; 0.398 to 0.402 on the third), and the share of run
    B's arrivals that found every open queue full rose on two (0.5% to 3.3%,
    1.0% to 2.7%; 2.2% to 1.9% on the third). The first step cost less and
    missed one row on one seed. See
    [The choice between two day shapes](#the-choice-between-two-day-shapes).
11. **Stop.** Tuning stopped there, with the rush rows at least 0.47 inside
    their bounds on every seed and run B's lowest served share (0.402) 0.054
    above today's highest (0.348). The second step was kept because it is the
    only candidate that meets every row on every seed while served share
    stays above today's in all six comparisons. No value was tuned toward the
    salmon stall.

## Before: today's values

Three measured days, 270 arrivals a day (the scale is the floor of three
business equivalents on every day of every run in this report).

Run A with the median-priced reference stall (runs 80, 81, 82):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 |
| --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 0.63 | 0.38 | 0.78 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 0.00 | 0.00 | 0.00 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.48 | 0.31 | 0.59 |
| Reference busy 19:00-20:00 | at least 0.85 | 0.00 | 0.00 | 0.00 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.52 | 0.46 | 0.32 |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.00 | 0.00 | 0.00 |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.053 | 0.028 | 0.035 |
| Reference open instants short of an ingredient | 0 | 3,397 | 3,494 | 3,281 |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 |
| Served share | (compared) | 0.401 | 0.401 | 0.405 |
| Mains served, three days | | 325 | 325 | 328 |

The reference stall sells exactly 18 mains every day and is then out of
cornmeal: the market carries 6 portions of a starter's ingredients per
equivalent, 18 a day at the floor. It is short for 1,041 to 1,223 of its
1,500 open samples each day, and from 13:00 it has nothing to sell. Only the
overnight and open-hours rows are met on all three seeds.

The salmon stall on today's values (runs 1, 3, 5) sold 13 to 19 mains a day
for the same reason: 0.19 to 0.60 waiting at 12:00, 0.09 to 0.43 at 19:00,
served share 0.379, 0.393 and 0.401.

Run B (runs 2, 4, 6):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 |
| --- | --- | --- | --- | --- |
| `nothing_available` share of those who left on arrival | at most 0.25 | 0.288 | 0.382 | 0.355 |
| Mains served on day 0 | at least 1 | 88 | 95 | 86 |
| Served share | (compared) | 0.332 | 0.348 | 0.343 |
| Mains served, three days | | 269 | 282 | 278 |

Why arrivals left without ordering, as a share of all arrivals over the three
measured days:

| Reason | Run A | Run B |
| --- | --- | --- |
| `nothing_affordable` | 35% to 37% | 32% to 37% |
| `nothing_available` | 14% to 17% | 19% to 25% |
| `wait_too_long` | 7% to 8% | 9% to 10% |
| `no_compatible_main`, `chose_to_leave` | under 1% | under 1% |

Thirteen to fifteen wholesale products were at zero for part of the measured
days in every baseline run.

## The chosen values

As a difference from today's values (`Tuning.of(LaunchCatalog.catalog())`):

| Value | Today | Chosen |
| --- | --- | --- |
| `demand.arrivals_per_equivalent` | 90 | 252 |
| `demand.hourly_weights` (hour 0 first) | `2,1,1,0,0,1,2,4,6,6,8,12,14,12,8,6,6,8,12,14,10,8,5,3` | `3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5` |
| `market.target_stock_per_equivalent` | 6 portions of each starter main's first-choice ingredients; 400 for most other products | at least 100 portions of the largest recipe line that uses the product; never below today's |
| `market.replenish_cap` | 4 times the target | 4 times the target |
| `npc.fallback_trays_per_day` | 10 | 50 |
| `npc.expected_use` | `even_share` | `even_share` |
| `npc.starter_shifts` "budget" | 05:00-17:00 | 05:00-17:00 |
| `npc.starter_shifts` "mainstream" | 12:00-00:00 | 11:00-23:00 |
| `npc.starter_shifts` "premium" | 19:00-07:00 | 17:00-03:00 |

**Arrivals.** The chosen weights sum to 252, so each weight is that hour's
arrivals per business equivalent: 34 and 33 at the rushes, 15 to 19 in the
hours beside them, 11 to 14 mid-morning and through the afternoon, 1 to 3
overnight. At the floor of three equivalents that is 756 arrivals a day (270
today): 102 and 99 an hour at 12:00 and 19:00 (26 and 25 today) and 33 to 42
an hour mid-morning and afternoon (11 to 15 today).

Each rush is now one hour long: 34 at 12:00 against 19 at 11:00 and 17 at
13:00, and 33 at 19:00 against 19 at 18:00 and 15 at 20:00, so a rush hour
has 1.7 to 2.2 times the arrivals of the hours beside it (today's shape: 1.2
to 1.4 times). 12:00 and 19:00 are exactly the hours the rush checks
measure. The reference stall's queue shows the same single-hour peak (runs
95 to 97, seeds 20261109 / 7 / 12345): 1.86 / 1.61 / 1.48 at 11:00, 2.97 /
3.11 / 3.54 at 12:00 and 1.33 / 1.90 / 2.08 at 13:00; 1.46 / 1.83 / 1.93 at
18:00 and 3.45 / 3.09 / 3.49 at 19:00 (it closes at 20:00). "Three or four
people queuing" holds for the checked hour, not for the hours around it,
where the stall has one or two.

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
median-priced one, to lift its rush queues into range. That change has a
cost, and there is a gentler alternative. Three candidates follow, each
measured on seeds 20261109 / 7 / 12345 with the median-priced reference
stall. Supply, fallback and shifts are the same in all three.

| | Flat rush (the first chosen shape) | Gentler rush | Chosen rush |
| --- | --- | --- | --- |
| Runs (A; B) | 77-79; 57-59 | 83-85; 86-88 | 95-97; 98-100 |
| Arrivals per equivalent | 249 | 248 | 252 |
| Weights 09:00 to 21:00 | 9, 15, 19, 24, 19, 14, 14, 14, 15, 19, 24, 16, 11 | 9, 11, 19, 30, 19, 12, 12, 12, 14, 19, 28, 16, 11 | 8, 11, 19, 34, 17, 12, 12, 12, 14, 19, 33, 15, 10 |
| Reference waiting 12:00 (2.5 to 4.5) | 2.10 / 2.17 / 2.46 | 3.25 / 2.45 / 3.05 | 2.97 / 3.11 / 3.54 |
| Reference waiting 19:00 (2.5 to 4.5) | 2.52 / 2.28 / 3.03 | 2.76 / 2.54 / 3.15 | 3.45 / 3.09 / 3.49 |
| Reference busy 12:00 (at least 0.85) | 0.951 / 0.991 / 0.947 | 1.000 / 0.998 / 1.000 | 1.000 / 1.000 / 0.978 |
| Reference busy 19:00 (at least 0.85) | 0.964 / 0.993 / 0.987 | 0.996 / 0.953 / 0.976 | 1.000 / 0.991 / 1.000 |
| Reference waiting 10:00 (0.5 to 2) | 1.92 / 1.70 / 1.50 | 1.04 / 1.42 / 1.03 | 1.28 / 0.99 / 0.94 |
| Reference waiting 14:00-17:00 (0.5 to 2) | 1.38 / 1.40 / 1.46 | 1.01 / 1.03 / 0.98 | 1.16 / 1.21 / 1.08 |
| **Acceptance rows missed** | Noon waiting on all three seeds (short by 0.40, 0.33, 0.04); 19:00 waiting on seed 7 (short by 0.22) | Noon waiting on seed 7 (short by 0.05) | None |
| Run A served share | 0.532 / 0.531 / 0.543 | 0.522 / 0.531 / 0.522 | 0.529 / 0.513 / 0.508 |
| Run B served share | 0.408 / 0.416 / 0.398 | 0.411 / 0.413 / 0.395 | 0.404 / 0.403 / 0.402 |
| Run B served share above today's | 0.076 / 0.068 / 0.054 | 0.079 / 0.065 / 0.052 | 0.072 / 0.055 / 0.059 |
| Run B arrivals that found every open queue full | 0.5% / 1.0% / 2.2% (12, 23, 49 of 2,241) | 0.6% / 1.5% / 1.5% (14, 34, 33 of 2,232) | 3.3% / 2.7% / 1.9% (74, 61, 44 of 2,268) |
| Run B arrivals that left for the wait | 27.6% / 27.6% / 27.0% | 27.0% / 28.3% / 27.8% | 26.7% / 26.9% / 26.2% |
| Run A mains served, three days | 1,192 / 1,189 / 1,217 | 1,165 / 1,186 / 1,165 | 1,199 / 1,163 / 1,152 |
| Run B mains served, three days | 915 / 933 / 891 | 917 / 922 / 881 | 916 / 915 / 911 |

Every candidate meets every other acceptance row on every seed, and in every
candidate served share is above today's in all six comparisons.

The chosen shape buys the rush queue targets with a lower served share than
the flat shape and with about twice the full-queue turnaways when the
computer-run stalls trade alone: run A's served share is a mean of 0.516
(0.508 to 0.529) against 0.535 (0.531 to 0.543), lower on every seed, with
28 fewer mains served over three days on average; run B's is 0.403 (0.402 to
0.404) against 0.407 (0.398 to 0.416), lower on two seeds, with the same
mains served (914 against 913 on average) from 27 more arrivals; and 2.6% of
run B's arrivals find every open queue full against 1.25% (more on two
seeds, fewer on seed 12345). The gentler shape is the alternative if the
owner prefers fewer full queues: its full-queue share is the flat shape's
(1.2% on average) and run A's served share is 0.525, and it misses exactly
one acceptance row on one seed, the noon queue on seed 7 (2.45 against 2.5);
on the other two seeds, including the one the acceptance test pins, it meets
every row.

The design ranks served share above the queue targets where the two pull
against each other. The chosen shape was kept because it is the only one of
the three that meets every acceptance row on every seed while served share
stays above today's in all six comparisons, not because it serves more: it
does not.

To switch to the gentler shape, two values change in `Tuning.chosen/0`
(`server/lib/feud_hall/domain/content/tuning.ex`):
`@chosen_arrivals_per_equivalent` from 252 to 248, and
`@chosen_hourly_weights` to
`3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5`. Two
tests then change, and neither needs its lists regenerated.
`customer_acceptance_test.exs` pins seed 20261109, on which the gentler shape
meets every row, so its lists of rows met and not met stay as they are; only
its comment that the rows pass "on all three measured seeds" becomes untrue
(the noon row fails on seed 7). `tuning_test.exs` pins the arrival figure 252
and the content fingerprint of the chosen values, which both change. The
acceptance test's served-share constants are for today's values and do not
depend on the shape.

Earlier measurements with the salmon stall at 15% fewer and 15% more arrivals
than the first chosen values are runs 65 to 76 in the log: at 15% more, run
B's share was only 0.024 to 0.031 above today's.

## After: the chosen values on three seeds

Runs 95 to 100, by `--tuning chosen --via init`. 756 arrivals a day.

Run A, median-priced reference stall:

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Spread | Met on all three |
| --- | --- | --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 2.97 | 3.11 | 3.54 | 0.56 | yes |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 3.45 | 3.09 | 3.49 | 0.40 | yes |
| Reference busy 12:00-13:00 | at least 0.85 | 1.000 | 1.000 | 0.978 | 0.02 | yes |
| Reference busy 19:00-20:00 | at least 0.85 | 1.000 | 0.991 | 1.000 | 0.01 | yes |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 1.28 | 0.99 | 0.94 | 0.34 | yes |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 1.16 | 1.21 | 1.08 | 0.13 | yes |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.136 | 0.118 | 0.112 | 0.02 | yes |
| Reference open instants short of an ingredient | 0 | 0 | 0 | 0 | 0 | yes |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 | 0 | yes |
| Served share | above today's | 0.529 | 0.513 | 0.508 | 0.02 | yes |
| Mains served, three days | | 1,199 | 1,163 | 1,152 | | |

Run B:

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Spread | Met on all three |
| --- | --- | --- | --- | --- | --- | --- |
| `nothing_available` share of those who left on arrival | at most 0.25 | 0.0023 | 0.0023 | 0.0022 | 0.0001 | yes |
| Mains served on day 0 | at least 1 | 302 | 291 | 298 | 11 | yes |
| Served share | above today's | 0.404 | 0.403 | 0.402 | 0.002 | yes |
| Mains served, three days | | 916 | 915 | 911 | | |

Every check is met on every seed. The rush queues sit 0.47 to 1.04 above
their lower bound and 0.96 to 1.53 below their upper bound; the mid-day
queues are near the middle of their range.

Single days vary much more than these three-day means: in run 95 the noon
queue was 2.51, 3.04 and 3.37 on the three days and the 19:00 queue 2.56,
4.23 and 3.55. The 14-day run below gives 3.32 and 3.02.

The harder case, run A with `--cuisine coast_salish` at the same values (runs
107, 108, 109):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Met on all three |
| --- | --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 2.40 | 2.19 | 2.21 | **no**: short by 0.10 to 0.31 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 1.84 | 1.78 | 2.11 | **no**: short by 0.39 to 0.72 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.980 | 0.951 | 0.882 | yes |
| Reference busy 19:00-20:00 | at least 0.85 | 0.827 | 0.887 | 0.973 | **no**: seed 20261109 short by 0.023 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.61 | 0.69 | 0.69 | yes |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.84 | 0.78 | 0.59 | yes |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.127 | 0.106 | 0.121 | yes |
| Reference open instants short of an ingredient | 0 | 0 | 0 | 0 | yes |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 | yes |
| Served share | above today's (0.379, 0.393, 0.401) | 0.482 | 0.473 | 0.469 | yes |

Why arrivals left without ordering, as a share of all arrivals (runs 95 to
100):

| Reason | Run A | Run B |
| --- | --- | --- |
| `nothing_affordable` | 26% | 25% to 27% |
| `wait_too_long` | 17% to 19% | 26% to 27% |
| `no_compatible_main` | 2.9% to 3.2% | 3.0% to 3.4% |
| `no_open_stall` (every open stall's queue full) | up to 0.1% | 1.9% to 3.3% |
| `nothing_available` | 0.1% | 0.1% |

Orders waiting per stall, three-day mean, three seeds:

| Stall | 10:00 | 12:00 | 14:00-17:00 | 19:00 | 00:00-03:00 |
| --- | --- | --- | --- | --- | --- |
| Reference, median (run A) | 0.94 to 1.28 | 2.97 to 3.54 | 1.08 to 1.21 | 3.09 to 3.49 | closed |
| "Budget" (run A) | 2.14 to 2.76 | 3.86 to 4.61 | 1.36 to 1.71 | closed | closed |
| "Mainstream" (run A) | closed | 3.38 to 4.05 | 1.41 to 2.03 | 3.56 to 3.99 | closed |
| "Premium" (run A) | closed | closed | closed | 2.74 to 3.06 | 0.45 to 0.54 |
| "Budget" (run B) | 3.94 to 4.23 | 4.82 to 5.28 | 1.90 to 2.26 | closed | closed |
| "Mainstream" (run B) | closed | 4.72 to 5.05 | 2.36 to 2.66 | 4.22 to 4.72 | closed |
| "Premium" (run B) | closed | closed | closed | 3.65 to 4.54 | 0.31 to 0.48 |
| Reference, salmon (harder case) | 0.61 to 0.69 | 2.19 to 2.40 | 0.59 to 0.84 | 1.78 to 2.11 | closed |

Against the owner's feel (three or four at the rushes, one or two mid-day,
nearly empty overnight), run A reads: at 12:00 the reference stall has 3.0
to 3.5, the mainstream stall 3.4 to 4.1 and the budget stall 3.9 to 4.6
(over four on two seeds); at 19:00 the reference stall has 3.1 to 3.5, the
mainstream stall 3.6 to 4.0 and the premium stall 2.7 to 3.1, about three
rather than three or four. Mid-day the reference stall has about one, the mainstream stall
1.4 to 2.0 and the budget stall 1.4 to 1.7 in the afternoon but 2.1 to 2.8
at 10:00, when it is the only computer-run stall open. Overnight the one
open stall has about half an order waiting. In run B, with one stall fewer,
the rush queues are above the feel: 4.7 to 5.3 at 12:00 and 3.7 to 4.7 at
19:00, against a queue limit of 6. The budget stall's afternoon mean
includes its break hour.

### Hour by hour, seed 20261109

Means over the three measured days. "Before" is today's values (runs 80 and
2), "after" the chosen values (runs 95 and 98). Stall columns are orders
waiting. A number in an hour when a stall is on its break or has just closed
is the queue it is still clearing.

Run A:

| Hour | Before: arrivals | Before: served | Before: reference | After: arrivals | After: served | After: reference | After: reference busy | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 2.3 | closed | 9 | 5.0 | closed | closed | closed | closed | 0.69 |
| 01 | 2 | 0.7 | closed | 6 | 3.7 | closed | closed | closed | closed | 0.57 |
| 02 | 2 | 1.3 | closed | 3 | 2.3 | closed | closed | closed | closed | 0.37 |
| 03 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 04 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 05 | 2 | 1.0 | closed | 6 | 2.7 | closed | closed | 0.34 | closed | closed |
| 06 | 3 | 2.7 | closed | 9 | 6.0 | closed | closed | 1.18 | closed | closed |
| 07 | 7 | 5.3 | closed | 15 | 10.3 | closed | closed | 1.58 | closed | closed |
| 08 | 11 | 5.3 | closed | 21 | 12.3 | closed | closed | 2.50 | closed | closed |
| 09 | 11 | 6.3 | closed | 24 | 12.3 | closed | closed | 2.95 | closed | closed |
| 10 | 15 | 7.0 | 0.52 | 33 | 20.7 | 1.28 | 0.74 | 2.14 | closed | closed |
| 11 | 21 | 10.3 | 0.87 | 57 | 33.7 | 1.86 | 0.85 | 3.35 | 1.81 | closed |
| 12 | 26 | 11.7 | 0.63 | 102 | 40.3 | 2.97 | 1.00 | 4.26 | 3.38 | closed |
| 13 | 22 | 9.0 | 0.00 | 51 | 33.7 | 1.33 | 0.78 | 2.82 | 2.58 | closed |
| 14 | 14 | 5.3 | 0.00 | 36 | 26.3 | 0.83 | 0.60 | 2.78 | 1.53 | closed |
| 15 | 11 | 3.0 | 0.00 | 36 | 22.0 | 1.54 | 0.96 | 0.78 | 2.83 | closed |
| 16 | 11 | 3.0 | 0.00 | 36 | 26.3 | 1.10 | 0.73 | 1.56 | 1.74 | closed |
| 17 | 14 | 4.7 | 0.00 | 42 | 25.3 | 1.20 | 0.83 | 0.96 | 1.94 | 0.86 |
| 18 | 22 | 4.3 | 0.00 | 57 | 27.0 | 1.46 | 0.84 | closed | 2.21 | 1.55 |
| 19 | 25 | 8.0 | 0.00 | 99 | 36.3 | 3.45 | 1.00 | closed | 3.99 | 2.96 |
| 20 | 19 | 7.0 | closed | 45 | 22.0 | 0.67 | closed | closed | 2.50 | 2.21 |
| 21 | 14 | 5.3 | closed | 30 | 11.7 | closed | closed | closed | 0.47 | 2.52 |
| 22 | 9 | 4.0 | closed | 24 | 14.7 | closed | closed | closed | 1.36 | 1.13 |
| 23 | 6 | 0.7 | closed | 15 | 5.0 | closed | closed | closed | 0.46 | 0.77 |

Run B:

| Hour | Before: arrivals | Before: served | Before: budget | Before: mainstream | Before: premium | After: arrivals | After: served | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 0.3 | closed | closed | 0.04 | 9 | 2.3 | closed | closed | 0.40 |
| 01 | 2 | 0.7 | closed | closed | 0.08 | 6 | 3.7 | closed | closed | 0.45 |
| 02 | 2 | 0.3 | closed | closed | 0.04 | 3 | 0.7 | closed | closed | 0.09 |
| 03 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 04 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 05 | 2 | 0.7 | 0.07 | closed | 0.09 | 6 | 3.7 | 0.63 | closed | closed |
| 06 | 3 | 3.3 | 0.31 | closed | 0.10 | 9 | 5.3 | 1.03 | closed | closed |
| 07 | 7 | 4.3 | 0.76 | closed | 0.13 | 15 | 10.7 | 1.87 | closed | closed |
| 08 | 11 | 4.7 | 0.70 | closed | closed | 21 | 11.3 | 2.58 | closed | closed |
| 09 | 11 | 5.7 | 0.95 | closed | closed | 24 | 12.3 | 3.18 | closed | closed |
| 10 | 15 | 5.3 | 1.14 | closed | closed | 33 | 12.3 | 4.04 | closed | closed |
| 11 | 21 | 4.7 | 0.80 | closed | closed | 57 | 24.0 | 4.14 | 2.99 | closed |
| 12 | 26 | 10.0 | 0.06 | 2.28 | closed | 102 | 24.7 | 5.28 | 5.05 | closed |
| 13 | 22 | 9.7 | 0.00 | 2.38 | closed | 51 | 21.3 | 4.03 | 2.78 | closed |
| 14 | 14 | 3.0 | 0.00 | 0.61 | closed | 36 | 22.0 | 3.40 | 1.96 | closed |
| 15 | 11 | 2.7 | closed | 0.47 | closed | 36 | 11.7 | 0.81 | 3.49 | closed |
| 16 | 11 | 1.3 | 0.00 | 0.20 | closed | 36 | 20.0 | 2.39 | 2.34 | closed |
| 17 | 14 | 3.7 | closed | 0.71 | closed | 42 | 19.0 | 0.84 | 3.18 | 1.38 |
| 18 | 22 | 4.7 | closed | 0.94 | closed | 57 | 23.0 | closed | 3.28 | 2.11 |
| 19 | 25 | 8.7 | closed | 0.25 | 1.12 | 99 | 25.0 | closed | 4.72 | 4.15 |
| 20 | 19 | 6.7 | closed | 0.41 | 0.86 | 45 | 20.0 | closed | 3.19 | 2.51 |
| 21 | 14 | 5.3 | closed | 0.20 | 0.79 | 30 | 12.0 | closed | 0.54 | 2.32 |
| 22 | 9 | 3.3 | closed | closed | 0.42 | 24 | 14.0 | closed | 1.44 | 0.88 |
| 23 | 6 | 0.7 | closed | 0.04 | 0.05 | 15 | 6.3 | closed | 0.40 | 0.95 |

Before, the reference stall has nothing waiting from 13:00 and the budget
stall is open from 12:00 to 17:00 with nothing waiting: both are out of
stock.

## Served share

Mains served as a share of arrivals, same run, seed and reference stall,
today's values against the chosen values. It is higher under the chosen
values in all six comparisons, and in the three with the salmon stall.

| Run | Seed | Today | Chosen | Change |
| --- | --- | --- | --- | --- |
| A | 20261109 | 0.401 | 0.529 | +0.128 |
| A | 7 | 0.401 | 0.513 | +0.112 |
| A | 12345 | 0.405 | 0.508 | +0.103 |
| B | 20261109 | 0.332 | 0.404 | +0.072 |
| B | 7 | 0.348 | 0.403 | +0.055 |
| B | 12345 | 0.343 | 0.402 | +0.059 |
| A, salmon reference | 20261109 | 0.379 | 0.482 | +0.103 |
| A, salmon reference | 7 | 0.393 | 0.473 | +0.080 |
| A, salmon reference | 12345 | 0.401 | 0.469 | +0.068 |

The margin to defend is run B's: its lowest chosen share (0.402) is 0.054
above today's highest (0.348), where the spread between seeds is 0.016 for
today's values and 0.002 for the chosen ones. Run B's share falls as arrivals
rise, because its three stalls are already full at the rushes; that is why
the rushes were not set higher than the checks needed.

## Sensitivity

Each row reverts one chosen value to today's and re-runs seed 20261109.

| Reverted | Run | What moved |
| --- | --- | --- |
| `arrivals_per_equivalent` to 90 (run 103) | A | All six reference rows leave their ranges: waiting at the rushes from 2.97 and 3.45 to 0.83 and 1.09; busy from 1.00 and 1.00 to 0.60 and 0.74; waiting at 10:00 from 1.28 to 0.17 and at 14:00-17:00 from 1.16 to 0.34 |
| Market targets and caps to today's (run 104) | B | `nothing_available` share of leavers from 0.0023 to 0.622, out of its bound; served share from 0.404 to 0.145; mains on day 0 from 302 to 85 |
| Starter shifts to today's (run 105) | B | Served share from 0.404 to 0.370; mains served over three days from 916 to 840 |
| Fallback to 10 (run 106) | B | Mains on day 0 from 302 to 254 |

## Applied by the recorded change

Run 102 starts the hall on today's values and applies the chosen values with
`retune_rules` at 12:00 of the warm-up day (`--via retune`), seed 20261109.
Over the three measured days:

| Check | `--via init` (run 95) | `--via retune` (run 102) |
| --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.97 | 3.40 |
| Reference waiting 19:00-20:00 | 3.45 | 3.43 |
| Reference busy 12:00-13:00 | 1.000 | 0.982 |
| Reference busy 19:00-20:00 | 1.000 | 1.000 |
| Reference waiting 10:00-11:00 | 1.28 | 1.19 |
| Reference waiting 14:00-17:00 | 1.16 | 0.99 |
| Hall waiting per stall 00:00-03:00 | 0.136 | 0.108 |
| Reference open instants short of an ingredient | 0 | **10** |
| Served share | 0.529 | 0.510 |

Every row is met by both paths except the ingredient row, which the retune
run misses by 10 instants on its first measured day. What that day looks
like, and why, is under
[The first day after the recorded change](#the-first-day-after-the-recorded-change).

## Profit

For the owner's decision on costs. Prices, rents and wages are unchanged.
Profit is the change in cash minus the change in rent arrears between two
midnights; rent and wages are charged together and the hall does not record
them separately. Means per measured day over three days, run A.

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

Chosen values, median-priced reference stall (runs 95, 96, 97):

| Seed | Restaurant | Profit | Revenue | Purchases | Rent and wages | Other |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Reference | 63,919 | 102,460 | 13,341 | 25,200 | 0 |
| 20261109 | Budget | 59,661 | 102,636 | 17,425 | 25,550 | 0 |
| 20261109 | Mainstream | 66,991 | 114,787 | 21,221 | 26,575 | 0 |
| 20261109 | Premium | 58,620 | 96,272 | 12,926 | 24,725 | 0 |
| 7 | Reference | 66,540 | 105,280 | 13,540 | 25,200 | 0 |
| 7 | Budget | 60,327 | 101,949 | 16,073 | 25,550 | 0 |
| 7 | Mainstream | 62,428 | 109,423 | 20,420 | 26,575 | 0 |
| 7 | Premium | 50,770 | 87,247 | 11,752 | 24,725 | 0 |
| 12345 | Reference | 63,144 | 101,520 | 13,176 | 25,200 | 0 |
| 12345 | Budget | 56,964 | 98,230 | 15,716 | 25,550 | 0 |
| 12345 | Mainstream | 64,993 | 111,627 | 20,059 | 26,575 | 0 |
| 12345 | Premium | 52,619 | 89,656 | 12,312 | 24,725 | 0 |

The salmon reference stall, for comparison (today's values runs 1, 3, 5;
chosen values runs 107, 108, 109):

| Seed | Values | Profit | Revenue | Purchases | Rent and wages |
| --- | --- | --- | --- | --- | --- |
| 20261109 | Today | -9,979 | 19,927 | 4,706 | 25,200 |
| 20261109 | Chosen | 34,720 | 78,893 | 18,974 | 25,200 |
| 7 | Today | -7,134 | 22,773 | 4,707 | 25,200 |
| 7 | Chosen | 30,332 | 73,607 | 18,075 | 25,200 |
| 12345 | Today | -7,945 | 21,960 | 4,705 | 25,200 |
| 12345 | Chosen | 31,627 | 74,827 | 18,000 | 25,200 |

What this says for the cost decision:

- Rent and wages are a fixed 24,725 to 26,575 a day for a single stall. Today
  that is more than a new owner's whole revenue (16,900 for the median stall,
  19,900 to 22,800 for the salmon stall). At the chosen values it is 24% to
  25% of the median reference stall's revenue, 32% to 34% of the salmon
  stall's, and 23% to 28% of a computer-run restaurant's.
- A typical new owner clears about 64,000 a day on a starting grant of
  500,000; the dearest-starter owner about half that.
- The median reference stall's purchases are 13% of its revenue (11% today);
  the salmon stall's are 24% to 25% (21% to 24% today).
- In run B (runs 98 to 100, no reference stall) the computer-run restaurants'
  mean daily profits are 59,600 to 63,000 (budget), 76,000 to 78,800
  (mainstream) and 59,900 to 67,900 (premium); on today's values (runs 2, 4,
  6) they are -1,900 to -600, 12,600 to 13,900 and 1,900 to 8,200.

### Fourteen days

Run 101: run A, chosen values, median-priced reference stall, seed 20261109,
14 measured days. The reference stall survives and grows; it was never in
arrears or distressed, and neither was any computer-run restaurant.

| End of day | Reference cash | End of day | Reference cash |
| --- | --- | --- | --- |
| 0 (warm-up) | 537,873 | 8 | 1,054,136 |
| 1 | 596,332 | 9 | 1,115,646 |
| 2 | 665,751 | 10 | 1,177,951 |
| 3 | 729,631 | 11 | 1,237,495 |
| 4 | 785,036 | 12 | 1,298,855 |
| 5 | 853,174 | 13 | 1,357,466 |
| 6 | 922,580 | 14 | 1,417,806 |
| 7 | 989,329 | | |

That is 62,852 a day on average. From the end of the warm-up day to the end
of day 14 the computer-run restaurants' cash went from 427,497 to 1,276,333
(budget), 444,689 to 1,350,126 (mainstream) and 426,794 to 1,181,241
(premium).

The 14-day verdict meets every row: reference waiting 3.32 at 12:00 and 3.02
at 19:00; busy 0.997 and 0.991; waiting 1.10 at 10:00 and 1.09 from 14:00 to
17:00; hall 0.094 per stall overnight; never short of an ingredient; served
share 0.508.

The salmon stall was run for 14 days at the first chosen values (run 64): its
cash went from 500,418 to 899,407, 28,499 a day, never in arrears. It was not
re-run for 14 days at the final values.

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
   driver's reference stall had to be moved to 10:00 to 20:00 for this reason;
   the driver observed the closure on the design's schedule while it was being
   built, and it is not one of the logged runs. The ten-hour rule is a staff
   rule, not one of the allowed values.
2. **About 2% of accepted orders are lost when a stall stops with a queue.** A
   stall that reaches its break or the end of its shift with orders waiting
   does not serve them. In the final runs 1.6% to 3.0% of admitted orders
   ended with no main served, and in the 14-day run 134 trays were cancelled
   (2.4% of visits that ended). Detail under
   [Orders lost when a stall stops](#orders-lost-when-a-stall-stops).
3. **About a quarter of arrivals leave because nothing open is affordable.**
   The share is 25% to 27% at the chosen values and 25% to 29% at every arrival
   level tried once supply was in place. Diner budgets are not among the
   allowed values, so tuning cannot move it. Detail under
   [What binds](#what-binds), item 3.
4. **The profit effect at unchanged prices, rent and wages** is the input to
   the decision on costs. The reference stall goes from losing about 10,000 a
   day to making 63,100 to 66,500 a day. See [Profit](#profit).
5. **The choice between the chosen day shape and the gentler one.** The chosen
   shape meets every check on every seed and has about twice the full-queue
   turnaways and a lower served share; the gentler shape misses one check on
   one seed. See
   [The choice between two day shapes](#the-choice-between-two-day-shapes).

One further observation, about applying the change rather than the game, is
under [The first day after the recorded change](#the-first-day-after-the-recorded-change).

### Orders lost when a stall stops

With real queues, a stall that stops serving with orders waiting does not
serve them. A stall stops when its staff take their protective break (after
ten working hours, for an hour) and when its shift ends.

- In the final runs 19 to 29 admitted orders per three days ended with no
  main served (`main_failed`): 1.6% to 2.4% of admitted orders in run A and
  2.0% to 3.0% in run B. On today's values there were 0 to 2, because queues
  were nearly empty.
- In the 14-day run (run 101), read from the committed events: 134 trays were
  cancelled, 2.4% of the 5,513 visits that ended, and 14 desserts. 95 trays
  and 6 desserts missed their deadline (`deadline_missed`), all 101 in an
  hour when a stall had just stopped: 15:00 (the budget stall's break), 17:00
  (its shift end), 20:00 (the reference stall's shift end), 21:00 (the
  mainstream stall's break) and 23:00 (its shift end). 39 trays and 8
  desserts were cooked and then expired (`ready_food_expired`): 35 of those
  47 in the same hours and 12 at the rushes (12:00, 13:00, 19:00), where
  cooked food waited too long for the single counter.
- **The diner's money.** The cancellation event carries no price. Reading the
  hall's rules for that event: the diner is not charged (a guest's reserved
  funds are released; a simulated diner's committed budget is released), the
  restaurant receives nothing, and the cost of ingredients already used moves
  from work in progress to waste. 131 of the 134 cancelled trays had used
  ingredients; 14,786 was written off over the 14 days across the four
  restaurants. The visit is finalised as failed with a score of zero, which
  the event marks as counting toward the restaurant's recognition.
- The driver has no real guests, so a guest's side of this was read from the
  rules, not observed.

Whether a stall should stop accepting orders before a break or the end of its
shift, or finish its queue first, is a rule about staff and closing, outside
this project's allowed values.

### The first day after the recorded change

Run 102 against run 95, first measured day only (read from each run's hourly
and daily output), seed 20261109:

| | `--via init` | `--via retune` |
| --- | --- | --- |
| Reference waiting 12:00 / 19:00 | 2.51 / 2.56 | 3.78 / 3.51 |
| Reference busy 12:00 / 19:00 | 1.00 / 1.00 | 1.00 / 1.00 |
| Reference waiting 10:00 / 14:00-17:00 | 0.90 / 1.24 | 0.91 / 1.02 |
| Reference short of an ingredient | 0 | 10 instants: cornmeal, vegetarian cheese |
| Reference purchases | 12,221 | 31,579 |
| "Premium" purchases / revenue | 15,189 / 97,178 | 6,320 / 83,375 |
| Arrivals leaving for `nothing_available` | 1 | 12 |
| Mains served / served share | 385 / 0.509 | 379 / 0.501 |
| Wholesale products at zero | none | none |

What differs, and why:

- **The change itself.** Arrivals and market replenishment switch at the
  first midnight after the change, and the new shifts are in force from the
  first measured day (mainstream opened at 11:00 and premium at 17:00 that
  day). At the moment of the change the market's stock is topped up in
  proportion to the raised targets, which by the change's design keeps
  wholesale prices where they were (prices were not measured here); a product
  that had already sold out stays at zero until midnight.
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
  bought 6,320 instead of 15,189 and took 83,375 instead of 97,178; 12
  arrivals instead of 1 left because nothing was available. From the second
  day the planner has a full day at the new level and the purchases catch up.
- The queue rows on that day differ by no more than days of one run differ
  from each other (the three days of run 95 had 2.51, 3.04 and 3.37 at noon).

From the second measured day there is no difference beyond that variation.
Only seed 20261109 was run this way.

## What binds

With a typical reference stall every check is met. What limits going further,
and what makes the harder case miss, are the same four things; none is an
allowed value.

1. **Three stalls alone (run B).** With the reference stall absent, one
   computer-run stall is open in most hours and two around each rush. Run B
   served between 294 and 320 mains a day in all 26 runs from 235 to 286
   arrivals per equivalent with the chosen supply and shifts (about 305 at
   the chosen values, 312 to 320 at 286), so its served share falls as
   arrivals rise. At the chosen values its stalls hold 4.7 to 5.3 orders at
   noon, 1.9% to 3.3% of arrivals find every open queue full, and its share
   is 0.055 to 0.072 above today's. This is what caps the rush weights.
2. **The reference stall's price.** At the same values the median-priced
   stall (940) has 3.0 to 3.5 waiting at the rushes and the salmon stall
   (1,220, second dearest of the 22 launch starters, and a roast, the slowest
   method) has 1.8 to 2.4. Diners who can afford a cheaper stall fill it
   first. Raising arrivals until the salmon stall reached 2.5 would push the
   other stalls past the queue limit and run B's share toward today's; that
   was not done.
3. **Segment budgets against menu prices.** A quarter of all arrivals (25% to
   27%) leave because nothing open is affordable, at every arrival level
   tried once supply was in place (25% to 29%). By the content's numbers, not
   a measurement: "value" diners are 40% of arrivals and carry 400 to 1,200,
   and the cheapest main in this hall is 773.
4. **The counter against patience.** A stall hands over one tray at a time
   and a handover takes four hall minutes, so a stall serves at most 15 trays
   an hour; a saturated computer-run stall open alone served about 12 mains
   an hour. 17% to 19% of arrivals in run A and 26% to 27% in run B leave
   because the wait is too long. By the content's numbers: "time-sensitive"
   diners are 25% of arrivals and wait 5 to 12 minutes, and the fastest
   starter takes 7 minutes with an empty kitchen.

The 300,000 storage capacity did not show up as a shortage: at the chosen
values `nothing_available` was 0.1% of arrivals and the reference stall was
never short. Whether it trimmed any computer-run purchase was not measured.

## Rulings made while building

Decisions made while the work was being built, in the order they were made,
each with what it decided, why, and what it costs if wrong. The first five
were made before any task started, the rest as tasks reported.

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
   *If wrong:* a failing target is documented but not enforced. With the
   median-priced reference stall no row fails, so the test pins all of them;
   the dearest-starter stall's misses are in
   [After](#after-the-chosen-values-on-three-seeds) and are not asserted.
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
10. **The run budget was raised from 30 to 150 driver runs** (123 were used). A
    three-day run takes 5 to 10 seconds, not the minutes the plan assumed, so
    the cap no longer protected anything and a wider search over several seeds
    gives sturdier values. Runs stay one at a time. *If wrong:* only time was
    spent.
11. **The chosen values must hold on at least three seeds,** not only the one
    the acceptance test pins. *Why:* a single seed could pass by luck near a
    bound. *If wrong:* a few more runs were spent.
12. **The reference stall sells the unused cuisine whose starter main has the
    median suggested price** (ties to the lower price, then by cuisine ID),
    not the first unused cuisine in sorted order. *Why:* the earlier rule
    happened to pick the second dearest of 22 starters and the slowest method,
    and the design's reference stands for a competent new owner with a default
    starter, which a typical price represents better. *If wrong:* the owner
    may want the targets judged on the dearest stall too; its result stays in
    this report as a second column (it misses the rush-waiting rows) and the
    cuisine is a driver option.
13. **The final values (252 arrivals, rush weights 34 and 33) stand,** and the
    report presents the cost of the last step and the gentler alternative as
    the owner's choice. *Why:* they are the only candidate that meets every
    acceptance row on all three seeds with served share above today's in all
    six comparisons, which is the design's stated bar. *If wrong:* the owner
    picks the alternative; `Tuning.chosen/0` changes by two values and two
    tests change (see
    [The choice between two day shapes](#the-choice-between-two-day-shapes)).
14. **A test pins a fingerprint of `Tuning.chosen/0`** (product count, sum of
    market targets and a SHA-256 hash). *Why:* the market values are computed
    from the launch catalog's recipes, so a later catalog change could
    silently make "version 2" mean different values. *If wrong:* the test
    fails on a legitimate catalog change and has to be updated knowingly.

## Not verified

- **No full test suite was run.** Only the files named under
  [Checks](#checks), one at a time.
- **Nobody has played a hall on these values.** No human owner or guest has
  seen them.
- **The measurements are a simulation** at sparse-hall settings, on three
  seeds, with simulated diners only and no real guests.
- **The change has not been applied** to any real hall or trial copy of one.
  The recorded change was exercised only by its own tests and by the driver's
  in-memory `--via retune` run (run 102, one seed).
- **The packaged apps are unaffected and were not rebuilt.** No client code
  changed.

Not measured, as a list of what the runs do not cover:

- A hall with more than four restaurants, a hall above the floor of three
  business equivalents, or any human owner other than the reference owner.
- Real guests. Every diner in these runs is simulated.
- More than three seeds, and more than three measured days except runs 64
  and 101.
- The recorded change on seeds 7 and 12345, at another time of day, or in a
  hall with open orders and leases (the change's own tests cover pinned
  terms; they do not use these values).
- Live, genesis and snapshot-tail agreement at the chosen values.
- The reference stall with the design's 09:00 to 21:00 hours (the driver
  showed the closure at 19:00 while it was being built; no tuning was
  measured on that schedule), or with any cuisine other than the
  median-priced one and `coast_salish`.
- Arrival levels above or below the final values with the median-priced
  reference stall, other than the three columns under
  [The choice between two day shapes](#the-choice-between-two-day-shapes).
- Market size and fallback at the final arrivals: they were sized at 249
  arrivals per equivalent and re-checked at 252 only by the absence of
  shortages in the final runs and by the two reverts.
- Wholesale prices paid. The driver prints purchases, not prices.
- Mains served per stall. The driver prints hall totals and each restaurant's
  revenue.
- Whether storage capacity trimmed any purchase (the driver does not print
  unfilled purchase requests).
- Market sizes between 25 and 50 portions, and above 100.
- Memory use of these runs. The driver's own check measured about 200 MB.
- Hosted CI.

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
  catalog expansion. This is now documented (deployment and architecture) but
  not covered by a test with these values.
- The `Retune` module documentation overstates "prices do not move": with a
  target ratio that is not a whole multiple the price can fall by one rounding
  step, and with a demand floor that is not a multiple of 1,000 it could rise
  by a few units (the launch floor is 3,000, so it only falls).
- The every-product price test uses an exact doubling, which cannot show the
  rounding effect.
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
- An empty-counts literal is repeated three times; the usage comment omits
  `--hours`; `Hall.run` leaves the authority running if an unexpected
  exception escapes.
- Releasing a location while distressed moves arrears into released debt,
  which the profit's arrears sum misses (the distressed warning flags it).
- One helper shift anywhere turns off the reconciliation check for every
  restaurant that day.
- Distressed days hide accruing rent and wages, because the rules charge
  nothing then, so profit on such a day is incomplete. No day in the profit
  tables was distressed.

Task 4 (the choice of values):

- Ten acceptance-test runs, a duplicate of run 1 and a zero-day header run
  are disclosed but not logged one line each.
- `reference_cuisine/1` raises `Enum.EmptyError` if no unused cuisine has a
  starter main.
- `customer_sim_test.exs` asserts an even count of unused starter prices,
  which ties it to today's catalog.
- The fingerprint assertion in `tuning_test.exs` was never seen failing (the
  sum assertion before it fires first).

Task 5 (the operator request):

- No test for an empty or short configured operator key (nil, empty, 31
  bytes) on the retune route.
- The 403-before-422 order is tested only for the secret check alone.
- The retune route repeats the seed route's authorisation chain verbatim.

## Reproducing the tables

All commands run from `server/`; `SIM` stands for
`mix run --no-start scripts/customer_sim.exs --`. Add `--json FILE` to get
the same numbers as data. Runs are deterministic: the same command prints the
same output.

| Table | Runs | Command (repeat for seeds 20261109, 7, 12345 unless one seed is named) | Where in the output |
| --- | --- | --- | --- |
| Before, run A and run B | 80-82; 2, 4, 6 | `SIM --run a --tuning current --days 3 --seed SEED`; the same with `--run b` | "Verdict" block; "Per game day" lines for arrivals, served, reasons and products at zero |
| Before, salmon stall | 1, 3, 5 | `SIM --run a --tuning current --days 3 --seed SEED --cuisine coast_salish` | "Verdict" block |
| After, run A and run B | 95-97; 98-100 | `SIM --run a --tuning chosen --days 3 --seed SEED`; the same with `--run b` | "Verdict" block; "Per game day" lines, where `main_failed` is the count after the bar |
| Harder case | 107-109 | `SIM --run a --tuning chosen --days 3 --seed SEED --cuisine coast_salish` | "Verdict" block |
| Orders waiting per stall; hour by hour | 80, 2, 95-100, 107-109 | the Before, After and Harder-case commands | "Per hall hour" lines: `w` is orders waiting and `b` the busy share for each stall; each figure here is the mean of the three measured days' lines for that hour |
| The choice between two day shapes | 77-79, 57-59; 83-88; 95-100 | flat: `SIM --run a --tuning chosen --days 3 --seed SEED --set demand.arrivals_per_equivalent=249 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5`; gentler: the same with `248` and `3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5`; chosen: no `--set`; each also with `--run b` | "Verdict" block; "Per game day" lines: `no_open_stall` and `wait_too_long` before the bar, summed over days 1 to 3 and divided by arrivals |
| Served share | as Before and After | as Before and After | the "served share" verdict row |
| Sensitivity | 103-106 | seed 20261109: `SIM --run a --tuning chosen --days 3 --seed 20261109 --set demand.arrivals_per_equivalent=90`; `SIM --run b --tuning FILE --days 3 --seed 20261109` with FILE holding `%{Tuning.chosen() \| market: Tuning.of(LaunchCatalog.catalog()).market}` after `alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}`; `SIM --run b --tuning chosen --days 3 --seed 20261109 --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7`; `SIM --run b --tuning chosen --days 3 --seed 20261109 --set npc.fallback_trays_per_day=10` | "Verdict" block; day 0 line for mains on day 0 |
| Applied by the recorded change; first day | 102 against 95 | `SIM --run a --tuning chosen --days 3 --seed 20261109 --via retune`, against the same without `--via retune` | "Verdict" block; for the first day, the `d1` hour lines and the "day 1" line with its `profit` lines |
| Profit | 80-82, 95-97, 1, 3, 5, 107-109, 2, 4, 6, 98-100 | the Before, After and Harder-case commands | "Per game day": each `profit` line gives profit, revenue, purchases, rent+wages and other for one restaurant and day; each figure here is the mean of days 1 to 3 |
| Fourteen days: verdict | 101 | `SIM --run a --tuning chosen --days 14 --seed 20261109` | "Verdict" block |
| Fourteen days: cash by day; cancelled trays by reason and hour | 101 | the wrapper script printed in the tuning log under "Runs not in the table", with the same arguments | its "Ledger at each midnight" and "Cancelled trays" lines; the command line alone prints each day's cash change, not the balance, and no cancellation reasons |

## Checks

From `server/`, one at a time, at the final values:

- `mix test test/feud_hall/scripts/customer_sim_test.exs`: 14 passed (four
  new: the median rule on hand-built catalogs, the override's refusals, the
  option's parsing, and a run whose reference price equals the median the
  test computes from the launch catalog).
- `mix test test/feud_hall/domain/tuning_test.exs`: 29 passed (one pins the
  chosen values: product count, sum of market targets and a SHA-256
  fingerprint, so a launch-catalog change cannot silently change them).
- `mix test --only acceptance test/feud_hall/scripts/customer_acceptance_test.exs`:
  2 passed (runs A and B at the chosen values, seed 20261109; asserts every
  verdict row and that each served share is above today's).
- `mix format --check-formatted`: clean.

Run before the reference-cuisine change, at the first chosen values, and not
affected by it: `npc_planner_test.exs` (24 passed), `arrivals_test.exs` (21),
`demand_forecast_test.exs` (25), `invariants_test.exs` (35),
`architecture_test.exs` (9).
