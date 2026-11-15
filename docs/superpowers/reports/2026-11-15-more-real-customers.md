# More real customers: measurements and chosen values

Evidence for Project 4 of the
[livelier hall design](../specs/2026-11-13-livelier-hall-design.md#project-4-more-real-customers):
what a sparse hall does on today's values, the values chosen from measured
runs, what they change, and what they do to profit. Every number here comes
from a run listed in the [tuning log](2026-11-15-more-real-customers-tuning-log.md);
"run 54" means line 54 of that log.

The values are `FeudHall.Domain.Content.Tuning.chosen/0`. They are proposed
tuning. A hall does not start on them and no hall receives them at boot: they
are applied by the recorded `retune_rules` change, as a separate step after
the owner's decision on costs.

## Result in short

- **Served meals.** A sparse hall serves about 3.4 times as many mains a day
  (run A: 102 to 108 a day before, 364 to 366 after; run B: 90 to 94 before,
  297 to 311 after), and a larger share of arrivals is served on every seed
  in both runs (run A 0.38 to 0.40 before, 0.49 after; run B 0.33 to 0.35
  before, 0.40 to 0.42 after).
- **Supply.** Leaving because nothing is available falls from 14% to 25% of
  arrivals to 0.1%. No wholesale product runs out on a measured day and the
  reference stall is never short of an ingredient.
- **Queues at the computer-run stalls.** At 12:00 and 19:00 the open
  computer-run stalls have 2.7 to 4.7 orders waiting and their counters are
  busy 98% to 100% of the time.
- **Queues at the reference stall: the rush targets are not met.** It has 1.2
  to 1.65 orders waiting at the rushes against a target of 2.5 to 4.5, and its
  counter is busy 74% to 85% of the time against 85%. Its mid-morning and
  mid-afternoon targets are met (0.64 to 1.03 against 0.5 to 2), overnight is
  met, and it never runs short.
- **Why.** The reference stall sells the dearest main open in the hall
  (1,220 against 773 to 1,175), so the cheaper stalls fill first. Arrivals
  high enough to fill the reference stall too (about five times today's) drop
  the served share below today's, which the design ranks above the queue
  targets. See [What binds](#what-binds).
- **Profit.** At unchanged prices, rent and wages the reference stall moves
  from losing 7,100 to 10,000 a day to making 26,500 to 33,600 a day, and the
  computer-run restaurants from between -1,700 and +13,800 to between 60,000
  and 80,200. No restaurant was distressed or in arrears in any final run.

## Method

The driver is `server/scripts/customer_sim.exs`
([usage](../../TESTING.md#implemented-backend-entry-points)): a real hall
authority in memory at sparse-hall settings, one warm-up day and three
measured game days. Run A is the three computer-run restaurants plus a
reference owner playing through ordinary commands; run B is the three alone.
The reference stall is open 10:00 to 20:00 (not the design's 09:00 to 21:00:
the three starter staff take a protective break after ten working hours), so
the mid-morning check is 10:00 to 11:00.

Values were tuned on seed 20261109 and confirmed on seeds 7 and 12345. A check
counts as met only if it is met on all three. 83 driver runs were made, one at
a time, of a budget of 150; each three-day run takes 5 to 10 seconds.

Only these were changed: `demand.arrivals_per_equivalent`, the shape of
`demand.hourly_weights`, `market.target_stock_per_equivalent` and
`market.replenish_cap`, and the computer-run planner's
`fallback_trays_per_day` and `starter_shifts`. The planner's expected-use
heuristic stays `even_share`; no new heuristic was needed.

The decisive steps, in the order the design asks for (supply first):

1. **Baseline** (runs 1 to 6). Both supply and arrivals are short. See
   [Before](#before-todays-values).
2. **Supply alone** (runs 7 and 8). Raising only the wholesale targets and the
   fallback, at today's arrivals, took run B's `nothing_available` share of
   leavers from 0.29 to 0.003 and its served share from 0.33 to 0.56. The
   reference stall's queue did not move (0.26 and 0.32 at the rushes): once
   stocked, it is short of customers.
3. **Arrivals alone are not enough to reach the reference stall's targets**
   (runs 10 to 12, today's hourly shape, ample supply). At three times
   today's arrivals the reference stall had 1.77 and 1.48 waiting at the
   rushes; at five times, 3.43 and 3.60 (in range), but the 10:00 queue was
   2.38 (above its range) and run A's served share was 0.32, below today's
   0.38. At seven times the 19:00, mid-day and overnight queues were past
   their ranges and the share was 0.25.
4. **A peakier day does not rescue it** (runs 13 and 14). Concentrating
   arrivals in the two rush hours gave the reference stall 2.21 and 2.67 at a
   run A share of 0.40, but run B's share fell to 0.30, below today's 0.33:
   three computer-run stalls alone cannot serve a rush that size.
5. **Shifts** (runs 18 to 20, 24 to 34). Opening "mainstream" an hour earlier
   and "premium" two hours earlier puts a second computer-run stall into the
   hours that lead into each rush. At the same arrivals run B's served share
   rose from 0.395 to 0.400 (three seeds) to 0.428 to 0.433. A first variant
   with "mainstream" two hours earlier put its protective break at 20:00.
6. **Level** (runs 35 to 40). With those shifts, run B served 799, 834, 914
   and 934 mains over three days at 180, 205, 235 and 270 arrivals per
   equivalent: beyond about 235 the three stalls serve almost nothing more,
   and added arrivals walk away.
7. **Shape** (runs 41 to 46). The hours the reference stall is checked in
   mid-morning and mid-afternoon were filled out and the early morning, when
   one stall is open, was thinned, so that the two mid-day checks sit inside
   their ranges on all three seeds.
8. **Stopping rule.** Arrivals were raised until run B's lowest served share
   across the three seeds (0.398) was 0.05 above today's highest (0.348),
   about three times the spread between seeds. This margin is the builder's
   judgement, not a rule from the design; the table under
   [Either side of the chosen level](#either-side-of-the-chosen-level) shows
   what 15% more or fewer arrivals would give.
9. **Supply and planner re-checked at the chosen level** (runs 47 to 53).

## Before: today's values

Three measured days, 270 arrivals a day (the scale is the floor of three
business equivalents on every day of every run in this report).

Run A (runs 1, 3, 5):

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 |
| --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 0.37 | 0.19 | 0.60 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 0.43 | 0.09 | 0.10 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.31 | 0.19 | 0.43 |
| Reference busy 19:00-20:00 | at least 0.85 | 0.41 | 0.08 | 0.10 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.15 | 0.28 | 0.31 |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.22 | 0.17 | 0.24 |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.067 | 0.032 | 0.044 |
| Reference open instants short of an ingredient | 0 | 31 | 536 | 1,405 |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 |
| Served share | (compared) | 0.379 | 0.393 | 0.401 |
| Mains served, three days | | 307 | 318 | 325 |

Only the overnight and open-hours rows are met. The ingredient the reference
stall runs short of is salmon, every time: the market carries 2,610 g a day
at the floor, 18 portions.

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
| `wait_too_long` | 8% to 10% | 9% to 10% |
| `no_compatible_main`, `chose_to_leave` | under 1% | under 1% |

Twelve to fourteen wholesale products were at zero for part of the measured
days in every baseline run.

## The chosen values

As a difference from today's values (`Tuning.of(LaunchCatalog.catalog())`):

| Value | Today | Chosen |
| --- | --- | --- |
| `demand.arrivals_per_equivalent` | 90 | 249 |
| `demand.hourly_weights` (hour 0 first) | `2,1,1,0,0,1,2,4,6,6,8,12,14,12,8,6,6,8,12,14,10,8,5,3` | `3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5` |
| `market.target_stock_per_equivalent` | 6 portions of each starter main's first-choice ingredients; 400 for most other products | at least 100 portions of the largest recipe line that uses the product; never below today's |
| `market.replenish_cap` | 4 times the target | 4 times the target |
| `npc.fallback_trays_per_day` | 10 | 50 |
| `npc.expected_use` | `even_share` | `even_share` |
| `npc.starter_shifts` "budget" | 05:00-17:00 | 05:00-17:00 |
| `npc.starter_shifts` "mainstream" | 12:00-00:00 | 11:00-23:00 |
| `npc.starter_shifts` "premium" | 19:00-07:00 | 17:00-03:00 |

**Arrivals.** The chosen weights sum to 249, so each weight is that hour's
arrivals per business equivalent: 24 at each rush, 14 or 15 through the
afternoon, 1 to 3 overnight. At the floor of three equivalents that is 747
arrivals a day (270 today), 72 an hour at 12:00 and 19:00 (25 or 26 today).
Compared with today's shape, 10:00 and the afternoon are fuller relative to
the rushes and 07:00 to 09:00 is thinner.

**Wholesale targets.** A product's target is the larger of today's target and
100 times the largest quantity any recipe line uses of it; a substitute counts
at its converted quantity, rounded up. Of 274 products, 257 rise (by 1.25 to
50 times, median 12 times) and 17 already carried 100 portions. Examples per
equivalent: salmon 870 g to 14,500 g; frozen salmon 400 g to 14,500 g;
frozen vegetable mix 400 g to 13,000 g; long rice 1,200 g to 5,500 g; filtered
water 5,000 ml to 22,000 ml. Substitutes matter because the "budget"
computer-run owner buys them by preference and today they sit at 400 g: at
three equivalents that is nine portions a day of its starter's vegetable mix.

How the size was chosen (runs 47 to 50, chosen arrivals, seed 20261109): at
25 portions products run out again (run B's `nothing_available` share 0.078,
served share 0.348, and the reference stall short of water on the first
measured day); at 50 portions what is served is identical to 100 but
`olive_oil_value` and `rice_long` are at zero for part of two or three
measured days; at 100 nothing is at zero on any measured day of any final
run. 100 is twice the smallest size tried that served everything; sizes
between 25 and 50 were not tried.

**Fallback.** Before the first day's summary exists a computer-run owner
stocks for this many trays a day. Run B served 270 mains on day 0 with a
fallback of 10, 304 with 30, 311 with 50 and 312 with 90 (runs 51, 53, 57,
52). 50 is where the first day stops improving.

**Shifts.** Every open hour still has a computer-run stall open. Compared
with today, 11:00 to 12:00 and 17:00 to 19:00 gain a second computer-run
stall, and 05:00 to 07:00 and 23:00 to 00:00 lose their second one.
"Mainstream" takes its protective break at 21:00 instead of 22:00.

## After: the chosen values on three seeds

Runs 54 to 59, by `--tuning chosen --via init`. 747 arrivals a day.

Run A:

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Spread | Met on all three |
| --- | --- | --- | --- | --- | --- | --- |
| Reference waiting 12:00-13:00 | 2.5 to 4.5 | 1.65 | 1.22 | 1.54 | 0.43 | **no**: short by 0.85 to 1.28 |
| Reference waiting 19:00-20:00 | 2.5 to 4.5 | 1.50 | 1.21 | 1.41 | 0.29 | **no**: short by 1.00 to 1.29 |
| Reference busy 12:00-13:00 | at least 0.85 | 0.842 | 0.749 | 0.840 | 0.09 | **no**: short by 0.008 to 0.10 |
| Reference busy 19:00-20:00 | at least 0.85 | 0.847 | 0.736 | 0.798 | 0.11 | **no**: short by 0.003 to 0.11 |
| Reference waiting 10:00-11:00 | 0.5 to 2 | 0.87 | 1.03 | 1.01 | 0.16 | yes |
| Reference waiting 14:00-17:00 | 0.5 to 2 | 0.64 | 0.76 | 0.88 | 0.24 | yes |
| Hall waiting per stall 00:00-03:00 | at most 0.3 | 0.078 | 0.099 | 0.121 | 0.04 | yes |
| Reference open instants short of an ingredient | 0 | 0 | 0 | 0 | 0 | yes |
| Reference open during checked hours | at least 0.99 | 1.0 | 1.0 | 1.0 | 0 | yes |
| Served share | above today's | 0.487 | 0.489 | 0.490 | 0.003 | yes |
| Mains served, three days | | 1,092 | 1,095 | 1,098 | | |

Run B:

| Check | Bound | Seed 20261109 | Seed 7 | Seed 12345 | Spread | Met on all three |
| --- | --- | --- | --- | --- | --- | --- |
| `nothing_available` share of those who left on arrival | at most 0.25 | 0.0015 | 0.0023 | 0.0015 | 0.001 | yes |
| Mains served on day 0 | at least 1 | 311 | 302 | 300 | 11 | yes |
| Served share | above today's | 0.408 | 0.416 | 0.398 | 0.019 | yes |
| Mains served, three days | | 915 | 933 | 891 | | |

No check is met on one seed and missed on another. The mid-afternoon row is
in the lower part of its range (lowest 0.64 against a bound of 0.5); the
14-day run below gives 0.73.

Single days vary much more than these three-day means: in run 54 the
reference stall's 10:00 queue was 1.25, 0.22 and 1.14 on the three days.

Why arrivals left without ordering, as a share of all arrivals:

| Reason | Run A | Run B |
| --- | --- | --- |
| `nothing_affordable` | 26% to 27% | 25% to 27% |
| `wait_too_long` | 21% to 23% | 27% to 28% |
| `no_compatible_main` | 0.8% to 1.3% | 3.2% to 3.6% |
| `no_open_stall` (every open stall's queue full) | up to 0.1% | 0.5% to 2.2% |
| `nothing_available` | 0.1% | 0.1% |

Of admitted orders, 24 to 27 in run A and 22 to 29 in run B (about 2% to 3%)
ended without a main served (`main_failed`); today's values had 0 to 2. The
driver does not print each one's cause, but 142 of the 152 fall in an hour
when a stall starts its protective break or ends its shift (15:00, 17:00,
20:00, 21:00, 23:00): a stall that stops with three or four orders waiting
does not serve them. With today's near-empty queues this hardly happens.

Orders waiting per stall, three-day mean, three seeds:

| Stall | 10:00 | 12:00 | 14:00-17:00 | 19:00 | 00:00-03:00 |
| --- | --- | --- | --- | --- | --- |
| Reference (run A) | 0.87 to 1.03 | 1.22 to 1.65 | 0.64 to 0.88 | 1.21 to 1.50 | closed |
| "Budget" (run A) | 3.86 to 4.38 | 3.84 to 4.15 | 1.79 to 1.98 | closed | closed |
| "Mainstream" (run A) | closed | 2.99 to 3.92 | 2.14 to 2.88 | 3.16 to 4.57 | closed |
| "Premium" (run A) | closed | closed | closed | 2.71 to 2.95 | 0.31 to 0.48 |
| "Budget" (run B) | 4.21 to 4.26 | 4.26 to 4.73 | 1.90 to 2.58 | closed | closed |
| "Mainstream" (run B) | closed | 3.86 to 4.46 | 3.08 to 3.43 | 3.57 to 4.50 | closed |
| "Premium" (run B) | closed | closed | closed | 3.25 to 3.56 | 0.31 to 0.43 |

The computer-run stalls are at the owner's rush feel (three or four waiting,
counter busy 98% to 100%) and above "one or two" in mid-morning and
mid-afternoon, while the reference stall is below the rush feel and at "about
one" mid-day. The budget stall's afternoon mean includes its break hour.

### Hour by hour, seed 20261109

Means over the three measured days. "Before" is today's values (runs 1 and
2), "after" the chosen values (runs 54 and 57). Stall columns are orders
waiting. A number in an hour when a stall is on its break or has just closed
is the queue it is still clearing.

Run A:

| Hour | Before: arrivals | Before: served | Before: reference | After: arrivals | After: served | After: reference | After: reference busy | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 1.3 | closed | 9 | 2.3 | closed | closed | closed | closed | 0.40 |
| 01 | 2 | 1.0 | closed | 6 | 3.7 | closed | closed | closed | closed | 0.45 |
| 02 | 2 | 1.3 | closed | 3 | 0.7 | closed | closed | closed | closed | 0.09 |
| 03 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 04 | 0 | 0.0 | closed | 0 | 0.0 | closed | closed | closed | closed | closed |
| 05 | 2 | 0.3 | closed | 6 | 3.7 | closed | closed | 0.63 | closed | closed |
| 06 | 3 | 3.3 | closed | 9 | 5.3 | closed | closed | 1.03 | closed | closed |
| 07 | 7 | 5.0 | closed | 15 | 10.7 | closed | closed | 1.87 | closed | closed |
| 08 | 11 | 5.3 | closed | 21 | 11.7 | closed | closed | 2.66 | closed | closed |
| 09 | 11 | 5.3 | closed | 27 | 12.0 | closed | closed | 3.67 | closed | closed |
| 10 | 15 | 4.3 | 0.15 | 45 | 17.7 | 0.87 | 0.65 | 4.19 | closed | closed |
| 11 | 21 | 5.7 | 0.30 | 57 | 28.7 | 0.83 | 0.54 | 3.94 | 3.24 | closed |
| 12 | 26 | 13.0 | 0.37 | 72 | 31.7 | 1.65 | 0.84 | 4.09 | 3.66 | closed |
| 13 | 22 | 10.7 | 0.10 | 57 | 30.3 | 1.04 | 0.74 | 3.67 | 3.06 | closed |
| 14 | 14 | 4.7 | 0.31 | 42 | 25.7 | 0.64 | 0.49 | 2.52 | 2.42 | closed |
| 15 | 11 | 2.0 | 0.15 | 42 | 15.0 | 0.54 | 0.42 | 0.72 | 3.64 | closed |
| 16 | 11 | 3.0 | 0.20 | 42 | 27.0 | 0.73 | 0.56 | 2.25 | 2.58 | closed |
| 17 | 14 | 3.7 | 0.24 | 45 | 26.0 | 0.63 | 0.56 | 0.60 | 2.58 | 1.73 |
| 18 | 22 | 5.0 | 0.30 | 57 | 26.3 | 0.65 | 0.54 | closed | 3.06 | 2.00 |
| 19 | 25 | 10.0 | 0.43 | 72 | 32.0 | 1.50 | 0.85 | closed | 3.72 | 2.71 |
| 20 | 19 | 5.3 | 0.08 | 48 | 22.0 | 0.62 | closed | closed | 3.66 | 1.99 |
| 21 | 14 | 6.0 | closed | 33 | 11.7 | closed | closed | closed | 1.53 | 2.41 |
| 22 | 9 | 4.3 | closed | 24 | 13.3 | closed | closed | closed | 1.27 | 1.07 |
| 23 | 6 | 1.7 | closed | 15 | 6.7 | closed | closed | closed | 0.36 | 0.93 |

Run B:

| Hour | Before: arrivals | Before: served | Before: budget | Before: mainstream | Before: premium | After: arrivals | After: served | After: budget | After: mainstream | After: premium |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 00 | 3 | 0.3 | closed | closed | 0.04 | 9 | 4.7 | closed | closed | 0.66 |
| 01 | 2 | 0.7 | closed | closed | 0.08 | 6 | 2.3 | closed | closed | 0.50 |
| 02 | 2 | 0.3 | closed | closed | 0.04 | 3 | 1.0 | closed | closed | 0.13 |
| 03 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 04 | 0 | 0.0 | closed | closed | closed | 0 | 0.0 | closed | closed | closed |
| 05 | 2 | 0.7 | 0.07 | closed | 0.09 | 6 | 3.0 | 0.41 | closed | closed |
| 06 | 3 | 3.3 | 0.31 | closed | 0.10 | 9 | 6.0 | 0.97 | closed | closed |
| 07 | 7 | 4.3 | 0.76 | closed | 0.13 | 15 | 9.0 | 1.34 | closed | closed |
| 08 | 11 | 4.7 | 0.70 | closed | closed | 21 | 10.3 | 2.23 | closed | closed |
| 09 | 11 | 5.7 | 0.95 | closed | closed | 27 | 12.3 | 2.84 | closed | closed |
| 10 | 15 | 5.3 | 1.14 | closed | closed | 45 | 11.7 | 4.26 | closed | closed |
| 11 | 21 | 4.7 | 0.80 | closed | closed | 57 | 21.0 | 4.83 | 3.32 | closed |
| 12 | 26 | 10.0 | 0.06 | 2.28 | closed | 72 | 25.0 | 4.26 | 3.86 | closed |
| 13 | 22 | 9.7 | 0.00 | 2.38 | closed | 57 | 23.3 | 3.75 | 3.23 | closed |
| 14 | 14 | 3.0 | 0.00 | 0.61 | closed | 42 | 23.3 | 2.68 | 3.18 | closed |
| 15 | 11 | 2.7 | closed | 0.47 | closed | 42 | 13.0 | 0.50 | 3.49 | closed |
| 16 | 11 | 1.3 | 0.00 | 0.20 | closed | 42 | 20.7 | 2.51 | 3.61 | closed |
| 17 | 14 | 3.7 | closed | 0.71 | closed | 45 | 19.7 | 0.66 | 2.67 | 1.67 |
| 18 | 22 | 4.7 | closed | 0.94 | closed | 57 | 24.7 | closed | 4.07 | 2.79 |
| 19 | 25 | 8.7 | closed | 0.25 | 1.12 | 72 | 22.7 | closed | 3.57 | 3.56 |
| 20 | 19 | 6.7 | closed | 0.41 | 0.86 | 48 | 20.0 | closed | 3.36 | 2.76 |
| 21 | 14 | 5.3 | closed | 0.20 | 0.79 | 33 | 10.7 | closed | 1.07 | 2.12 |
| 22 | 9 | 3.3 | closed | closed | 0.42 | 24 | 14.3 | closed | 1.74 | 1.13 |
| 23 | 6 | 0.7 | closed | 0.04 | 0.05 | 15 | 6.3 | closed | 0.44 | 1.09 |

Before, the budget stall is open from 12:00 to 17:00 with nothing waiting: it
is out of stock.

## Served share

Mains served as a share of arrivals, same run and seed, today's values
against the chosen values. It is higher under the chosen values in all six
comparisons.

| Run | Seed | Today | Chosen | Change |
| --- | --- | --- | --- | --- |
| A | 20261109 | 0.379 | 0.487 | +0.108 |
| A | 7 | 0.393 | 0.489 | +0.096 |
| A | 12345 | 0.401 | 0.490 | +0.089 |
| B | 20261109 | 0.332 | 0.408 | +0.076 |
| B | 7 | 0.348 | 0.416 | +0.068 |
| B | 12345 | 0.343 | 0.398 | +0.054 |

## Either side of the chosen level

The chosen shape, supply, fallback and shifts with 15% fewer or more arrivals
(runs 71 to 76 and 65 to 70; values are seed 20261109 / 7 / 12345):

| Arrivals per equivalent | 212 | 249 (chosen) | 286 |
| --- | --- | --- | --- |
| Reference waiting 12:00 | 1.11 / 1.27 / 1.76 | 1.65 / 1.22 / 1.54 | 1.97 / 2.02 / 1.54 |
| Reference waiting 19:00 | 0.48 / 1.09 / 1.26 | 1.50 / 1.21 / 1.41 | 1.47 / 1.52 / 1.39 |
| Reference busy 12:00 | 0.807 / 0.691 / 0.909 | 0.842 / 0.749 / 0.840 | 0.967 / 0.958 / 0.864 |
| Reference busy 19:00 | 0.402 / 0.691 / 0.649 | 0.847 / 0.736 / 0.798 | 0.829 / 0.809 / 0.816 |
| Reference waiting 10:00 | 0.86 / 0.82 / 0.73 | 0.87 / 1.03 / 1.01 | 1.28 / 1.12 / 1.49 |
| Reference waiting 14:00-17:00 | 0.57 / 0.65 / 0.65 | 0.64 / 0.76 / 0.88 | 0.99 / 0.82 / 1.00 |
| Run A served share | 0.504 / 0.521 / 0.515 | 0.487 / 0.489 / 0.490 | 0.450 / 0.449 / 0.441 |
| Run B served share | 0.466 / 0.458 / 0.458 | 0.408 / 0.416 / 0.398 | 0.363 / 0.373 / 0.369 |
| Run B share above today's | 0.134 / 0.109 / 0.114 | 0.076 / 0.068 / 0.054 | 0.031 / 0.024 / 0.026 |

With 15% more arrivals the noon busy check is met on all three seeds and the
mid-day checks sit nearer the middle of their ranges, but the rush queues are
still 0.5 to 1.1 short of 2.5 and run B's served share is only 0.024 to 0.031
above today's.

## Sensitivity

Each row reverts one chosen value to today's and re-runs seed 20261109.

| Reverted | Run | What moved |
| --- | --- | --- |
| `arrivals_per_equivalent` to 90 (run 61) | A | Reference waiting 10:00 from 0.87 to 0.24 and 14:00-17:00 from 0.64 to 0.27, both out of their range; at the rushes from 1.65 and 1.50 to 0.09 and 0.51; busy from 0.84 and 0.85 to 0.09 and 0.45 |
| Market targets and caps to today's (run 62) | B | `nothing_available` share of leavers from 0.0015 to 0.616, out of its bound; served share from 0.408 to 0.146; mains on day 0 from 311 to 85 |
| Starter shifts to today's (run 63) | B | Served share from 0.408 to 0.370; arrivals finding every open queue full from 12 to 92 |
| Fallback to 10 (run 51) | B | Mains on day 0 from 311 to 270 |

The brief's first check asks that the reference stall's rush-hour waiting
move out of its range; at the chosen values it is not in its range to begin
with, so the row shows the size of the move and the two mid-day checks
leaving theirs.

## Applied by the recorded change

Run 60 starts the hall on today's values and applies the chosen values with
`retune_rules` at 12:00 of the warm-up day (`--via retune`), seed 20261109.
The new arrivals start at the next midnight. Over the three measured days:

| Check | `--via init` (run 54) | `--via retune` (run 60) |
| --- | --- | --- |
| Reference waiting 12:00-13:00 | 1.65 | 0.93 |
| Reference waiting 19:00-20:00 | 1.50 | 1.75 |
| Reference busy 12:00-13:00 | 0.842 | 0.682 |
| Reference busy 19:00-20:00 | 0.847 | 0.904 |
| Reference waiting 10:00-11:00 | 0.87 | 0.99 |
| Reference waiting 14:00-17:00 | 0.64 | 0.64 |
| Hall waiting per stall 00:00-03:00 | 0.078 | 0.089 |
| Reference open instants short of an ingredient | 0 | **10** |
| Served share | 0.487 | 0.475 |

First measured day only (read from each run's hourly output):

| | `--via init` | `--via retune` |
| --- | --- | --- |
| Reference waiting 12:00 / 19:00 | 1.57 / 1.42 | 0.87 / 1.61 |
| Reference busy 12:00 / 19:00 | 0.82 / 0.78 | 0.53 / 0.90 |
| Reference waiting 10:00 / 14:00-17:00 | 1.25 / 0.58 | 0.61 / 0.76 |
| Reference short of an ingredient | 0 | 10 instants, salmon |
| Served share | 0.477 | 0.459 |
| Reference purchases | 15,378 | 31,718 |
| Wholesale products at zero | none | none |

The one difference in which rows are met is the ingredient row: under the
retune the reference stall was short of salmon for 10 samples (four hall
minutes, one market clearing) on the first measured day, and bought twice as
much that day. This is consistent with it opening that day with no salmon:
the warm-up day ran on today's market, where salmon was at zero from before
the change until midnight (the recorded top-up scales existing stock, so a
product at zero stays at zero until the midnight replenishment), and the
stall's first delivery arrives one clearing after it opens. The driver does
not print the stall's stock, so this was not confirmed directly. The other
rows differ by no more than they do between days of one run. On days 2 and 3
the stall was not short.

The row "busy 19:00" is met in run 60 (0.904) and not in run 54 (0.847); with
single days ranging from 0.78 to 0.99 this is not a difference between the
two paths.

## Profit

For the owner's decision on costs. Prices, rents and wages are unchanged.
Profit is the change in cash minus the change in rent arrears between two
midnights; rent and wages are charged together and the hall does not record
them separately. Means per measured day over three days, run A.

**No restaurant was distressed on any measured day or in arrears at the end
of any run in this section**, on today's values or the chosen ones, so no
profit below is missing charges.

Today's values (runs 1, 3, 5):

| Seed | Restaurant | Profit | Revenue | Purchases | Rent and wages | Other |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Reference | -9,979 | 19,927 | 4,706 | 25,200 | 0 |
| 20261109 | Budget | -745 | 29,083 | 4,278 | 25,550 | 0 |
| 20261109 | Mainstream | 5,853 | 42,700 | 10,272 | 26,575 | 0 |
| 20261109 | Premium | 3,530 | 33,979 | 5,723 | 24,725 | 0 |
| 7 | Reference | -7,134 | 22,773 | 4,707 | 25,200 | 0 |
| 7 | Budget | -1,716 | 28,158 | 4,324 | 25,550 | 0 |
| 7 | Mainstream | 10,610 | 48,230 | 11,045 | 26,575 | 0 |
| 7 | Premium | -203 | 29,976 | 5,454 | 24,725 | 0 |
| 12345 | Reference | -7,945 | 21,960 | 4,705 | 25,200 | 0 |
| 12345 | Budget | -1,219 | 28,732 | 4,401 | 25,550 | 0 |
| 12345 | Mainstream | 13,815 | 52,297 | 11,907 | 26,575 | 0 |
| 12345 | Premium | -420 | 29,922 | 5,617 | 24,725 | 0 |

Chosen values (runs 54, 55, 56):

| Seed | Restaurant | Profit | Revenue | Purchases | Rent and wages | Other |
| --- | --- | --- | --- | --- | --- | --- |
| 20261109 | Reference | 26,511 | 67,100 | 15,389 | 25,200 | 0 |
| 20261109 | Budget | 64,826 | 107,834 | 17,457 | 25,550 | 0 |
| 20261109 | Mainstream | 80,161 | 129,210 | 22,474 | 26,575 | 0 |
| 20261109 | Premium | 61,487 | 99,001 | 12,789 | 24,725 | 0 |
| 7 | Reference | 28,284 | 70,760 | 17,276 | 25,200 | 0 |
| 7 | Budget | 65,241 | 107,884 | 17,093 | 25,550 | 0 |
| 7 | Mainstream | 76,381 | 125,107 | 22,151 | 26,575 | 0 |
| 7 | Premium | 60,600 | 98,025 | 12,700 | 24,725 | 0 |
| 12345 | Reference | 33,614 | 77,267 | 18,452 | 25,200 | 0 |
| 12345 | Budget | 60,047 | 101,978 | 16,381 | 25,550 | 0 |
| 12345 | Mainstream | 72,082 | 119,580 | 20,923 | 26,575 | 0 |
| 12345 | Premium | 68,773 | 106,768 | 13,269 | 24,725 | 0 |

What this says for the cost decision:

- Rent and wages are a fixed 24,725 to 26,575 a day for a single stall. Today
  that is more than a new owner's whole revenue (19,900 to 22,800); at the
  chosen values it is 33% to 38% of the reference stall's revenue and 21% to
  25% of a computer-run restaurant's.
- The reference stall's purchases stay at 23% to 24% of its revenue (21% to
  24% today), so the larger market did not make ingredients cheaper for it.
- The computer-run restaurants gain most: 60,000 to 80,200 a day each, on a
  starting grant of 500,000.
- In run B (runs 57 to 59, no reference stall) the computer-run restaurants'
  mean daily profits are 57,400 to 65,400 (budget), 78,200 to 81,500
  (mainstream) and 61,100 to 65,900 (premium); on today's values (runs 2, 4,
  6) they are -1,900 to -600, 12,600 to 13,900 and 1,900 to 8,200.

### Fourteen days

Run 64: run A, chosen values, seed 20261109, 14 measured days. The reference
stall survives and grows; it was never in arrears or distressed, and neither
was any computer-run restaurant.

| End of day | Reference cash | End of day | Reference cash |
| --- | --- | --- | --- |
| 0 (warm-up) | 500,418 | 8 | 733,310 |
| 1 | 529,380 | 9 | 755,587 |
| 2 | 545,563 | 10 | 792,026 |
| 3 | 579,951 | 11 | 817,605 |
| 4 | 610,440 | 12 | 851,840 |
| 5 | 647,223 | 13 | 873,201 |
| 6 | 673,336 | 14 | 899,407 |
| 7 | 704,387 | | |

That is 28,499 a day on average. From the end of the warm-up day to the end
of day 14 the computer-run restaurants' cash went from 431,249 to 1,348,786
(budget), 464,785 to 1,535,926 (mainstream) and 427,890 to 1,263,444
(premium).

On the warm-up day the reference stall was short of salmon and water for its
first 160 samples (64 hall minutes): its restock policy first runs at the
hour after it opens. The warm-up day is not measured.

The 14-day verdict: reference waiting 1.53 at 12:00 and 1.20 at 19:00; busy
0.846 and 0.731; waiting 1.07 at 10:00 and 0.73 from 14:00 to 17:00; hall
0.098 per stall overnight; never short of an ingredient; served share 0.481.
The same four rows miss their bounds as in the three-day runs.

## What binds

The reference stall's rush targets cannot be met with the allowed values
while the served share stays above today's. Four things, none of them an
allowed value, produce this.

1. **The reference stall's price.** The driver gives the reference owner the
   first cuisine in sorted order that no restaurant has, which is
   `coast_salish`. Its starter, `roasted_salmon`, has a suggested price of
   1,220: the second dearest of the 22 launch-menu starters (median 940), and
   a roast, the slowest method. The other mains open in the hall cost 773
   (budget), 910 (mainstream) and 1,175 (premium). Diners who can afford a
   cheaper stall fill it first, so at the chosen values the budget and
   mainstream stalls have 3.0 to 4.7 waiting at 12:00 while the reference
   stall has 1.2 to 1.65. One evidence run with the reference owner's cuisine
   forced to `european` (`tomato_pasta`, 920), on a scratch copy of the
   driver, gave 1.82 and 2.95 waiting at the rushes and busy 0.93 and 1.00,
   against 1.06 and 1.17 and busy 0.73 and 0.84 for the salmon stall at the
   same tuning and seed (runs 21 and 20, an earlier candidate with arrivals
   235). That is one seed and no value was chosen from it. **Whether the
   reference stall should sell a typical starter is a decision for the owner
   or the plan's controller; the chosen values do not depend on it.**
2. **Segment budgets against menu prices.** A quarter of all arrivals (25% to
   27%) leave because nothing open is affordable; it was 26% to 29% at every
   other arrival level tried once supply was in place.
   By the content's numbers, not a measurement: "value" diners are 40% of
   arrivals and carry 400 to 1,200, the cheapest main in this hall is 773,
   and none of them can afford the reference stall's 1,220.
3. **The counter against patience.** A stall hands over one tray at a time
   and a handover takes four hall minutes, so a stall serves at most 15 trays
   an hour; a saturated computer-run stall open alone served about 12 mains
   an hour. A fifth to a
   quarter of arrivals (21% to 28%) leave because the wait is too long. By the
   content's numbers: "time-sensitive" diners are 25% of arrivals and wait 5
   to 12 minutes, and the reference stall's roast takes 10 minutes with an
   empty kitchen.
4. **Three stalls alone (run B).** With the reference stall absent, one
   computer-run stall is open in most hours and two around each rush. Run B
   served about 300 mains a day from 235 arrivals per equivalent upward
   (914 and 934 over three days at 235 and 270, runs 32 and 39), so its
   served share falls as arrivals rise: 0.398 to 0.416 at 249 and 0.363 to
   0.373 at 286. A straight line through those reaches today's 0.33 to 0.35
   at roughly 300 to 315; that is an extrapolation, not a run.

The measured reach of the reference stall's rush queue: 1.2 to 1.65 at 249
arrivals per equivalent; 1.4 to 2.0 at 286; 2.2 and 2.7 with a peaky day at
298, where run B's share (0.296) is already below today's; 3.4 and 3.6 at 450
with today's shape, where run A's share (0.324) is below today's too.

The 300,000 storage capacity did not show up as a shortage: at the chosen
values `nothing_available` was 0.1% of arrivals and the reference stall was
never short. Whether it trimmed any computer-run purchase was not measured.

## What was not measured

- A hall with more than four restaurants, a hall above the floor of three
  business equivalents, or any human owner other than the reference owner.
- Real guests. Every diner in these runs is simulated.
- More than three seeds, and more than three measured days except run 64.
- The recorded change on seeds 7 and 12345, at another time of day, or in a
  hall with open orders and leases (the change's own tests cover pinned
  terms; they do not use these values).
- Live, genesis and snapshot-tail agreement at the chosen values.
- The reference stall with the design's 09:00 to 21:00 hours, or with any
  cuisine other than the one evidence run above.
- Wholesale prices paid. The driver prints purchases, not prices; the claim
  that ingredients did not get cheaper rests on purchases as a share of
  revenue.
- Mains served per stall. The driver prints hall totals and each restaurant's
  revenue.
- The cause of each `main_failed` order, and whether a diner whose order
  fails when a stall stops is charged.
- Whether storage capacity trimmed any purchase (the driver does not print
  unfilled purchase requests).
- Market sizes between 25 and 50 portions, and above 100.
- Memory use of these runs. The driver's own check measured about 200 MB.
- The full test suite and hosted CI. Only the files named in
  [Checks](#checks) were run.

## Checks

From `server/`, one at a time:

- `mix test test/feud_hall/domain/tuning_test.exs`: 28 passed.
- `mix test test/feud_hall/domain/npc_planner_test.exs`: 24 passed.
- `mix test --only acceptance test/feud_hall/scripts/customer_acceptance_test.exs`:
  2 passed (runs A and B at the chosen values, seed 20261109; asserts the rows
  marked "yes" above and that each served share is above today's). With
  today's values in place of the chosen ones both tests fail.
- `mix test test/feud_hall/domain/arrivals_test.exs`: 21 passed.
- `mix test test/feud_hall/domain/demand_forecast_test.exs`: 25 passed.
- `mix test test/feud_hall/domain/invariants_test.exs`: 35 passed.
- `mix test test/feud_hall/architecture_test.exs`: 9 passed.
- `mix test test/feud_hall/scripts/customer_sim_test.exs --max-cases 1`: 10 passed.
- `mix format --check-formatted`: clean.
