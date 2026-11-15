# More real customers: tuning log

Every run of the customer driver made while choosing the values in
[the report](2026-11-15-more-real-customers.md), in the order they were run.
One line per run. All runs are from `server/`, one at a time, with one warm-up
day and three measured game days unless the line says otherwise:

    mix run --no-start scripts/customer_sim.exs -- --run a|b --tuning current|chosen|FILE --days 3 --seed SEED

Runs 1 to 76 were made at commit 316500e plus the working tree that became
509fe03. Runs 77 onward were made with the driver's reference-cuisine rule
changed (see **Reference** below). Runs 95 to 124 were made with the sharper
day shape (252 arrivals, rush weights 34 and 33) in `Tuning.chosen/0`. Runs
125 onward were made in the final fix wave, after the final review: the
gentler day shape (248 arrivals, rush weights 30 and 28) is in
`Tuning.chosen/0`, and the driver has `--extra-stalls` and prints each day's
recorded equivalents and scale.

## How to read a line

**Reference** is what run A's reference stall sells:

- `salmon (old default)`: runs 1 to 76. The driver then took the first unused
  cuisine in sorted order, `coast_salish`, whose starter `roasted_salmon`
  costs 1,220.
- `median`: runs 77 onward. The driver takes the unused cuisine whose starter
  has the median suggested price, `colombian` (`arepa_con_queso`, 940).
- `salmon (--cuisine)`: `--cuisine coast_salish` on the current driver.
- `mexican (--cuisine)`: `--cuisine mexican`, whose starter `bean_tacos` costs
  850, the cheapest among the unused cuisines.
- `median + N extra`: the median reference plus `--extra-stalls N`: N more
  owner stalls set up like the reference, on `javanese` (940), `yoruba` (930),
  `sichuan` (950), `ethiopian` (920) and `european` (920), in that order.
- `european (scratch)`: run 21 only, on a scratch copy of the old driver.

**Tuning** is a difference from today's values (`Tuning.of(LaunchCatalog.catalog())`):

- `arrivals N`: `demand.arrivals_per_equivalent` (today 90).
- `weights …`: `demand.hourly_weights`, hour 0 first (today
  `2,1,1,0,0,1,2,4,6,6,8,12,14,12,8,6,6,8,12,14,10,8,5,3`).
- `market P`: every product's `market.target_stock_per_equivalent` is the
  larger of today's target and P times the largest quantity any recipe line
  uses of it, a substitute counted at its converted quantity (rounded up);
  every `market.replenish_cap` is four times its target, as today.
- `fallback N`: `npc.fallback_trays_per_day` (today 10).
- `shifts …`: `npc.starter_shifts` for the named profiles (today budget
  5-17, mainstream 12-0, premium 19-7).
- `first chosen values`: `Tuning.chosen/0` as committed in 509fe03: `arrivals
  249; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5;
  market 100; fallback 50; shifts mainstream 11-23, premium 17-3`. Runs 41 to
  46 are the same values before they were written into the code.
- `final chosen values` (runs 95 to 124): `Tuning.chosen/0` as it stood from
  commit c1ff801 until the final fix wave: the first chosen values except
  `arrivals 252; weights
  3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5`. Runs 89 to 94
  are the same values before they were written into the code, and runs 95 to
  100 repeat them through `--tuning chosen` with identical results. These
  values are now the **sharper alternative**; they are no longer what
  `--tuning chosen` gives.
- `final chosen values (gentler shape)` (runs 125 onward): `Tuning.chosen/0`
  now: the first chosen values except `arrivals 248; weights
  3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5`. Runs 83 to 88
  are the same values through `--set` before they were written into the code;
  runs 125 to 130 repeat them through `--tuning chosen`, and every verdict row
  and every count is identical to runs 83 to 88.
- `sharper alternative: chosen values with --set …` (runs 154 and 155): the
  sharper values rebuilt from the current `Tuning.chosen/0`.
- `--set KEY=VALUE` is the driver's own override.

Exploratory tunings were passed as `--tuning FILE`, a file holding one Elixir
term. Any line can be rebuilt with a file like this (the example is run 13):

```elixir
alias FeudHall.Domain.Content.{LaunchCatalog, Tuning}
catalog = LaunchCatalog.catalog()
today = Tuning.of(catalog)
portions = 100

largest =
  for {_, recipe} <- catalog.recipes, line <- recipe.lines,
      {product, qty} <-
        [{line.product, line.qty}] ++
          if(line.substitute,
            do: [{line.substitute.product,
                  div(line.qty * line.substitute.num + line.substitute.den - 1, line.substitute.den)}],
            else: []),
      reduce: %{} do
    acc -> Map.update(acc, product, qty, &max(&1, qty))
  end

targets =
  Map.new(today.market.target_stock_per_equivalent, fn {id, t} ->
    {id, max(t, portions * Map.get(largest, id, 0))}
  end)

%{
  version: 2,
  demand: %{
    arrivals_per_equivalent: 298,
    hourly_weights: [2, 1, 1, 0, 0, 2, 3, 4, 5, 7, 16, 20, 42, 20, 19, 19, 19, 19, 20, 42, 17, 10, 7, 3]
  },
  market: %{
    target_stock_per_equivalent: targets,
    replenish_cap: Map.new(targets, fn {id, t} -> {id, t * 4} end)
  },
  npc: %{today.npc | fallback_trays_per_day: 50}
}
```

The market reverts (runs 62, 104 and 138) used a file holding
`%{Tuning.chosen() | market: Tuning.of(LaunchCatalog.catalog()).market}`.

**Verdict** lists the driver's verdict rows over the measured days; `!`
marks a row outside its bound:

| Code | Verdict row | Bound |
| --- | --- | --- |
| `w12`, `w19` | A ref waiting 12:00-13:00, 19:00-20:00 | 2.5 to 4.5 |
| `b12`, `b19` | A ref busy 12:00-13:00, 19:00-20:00 | at least 0.85 |
| `w10` | A ref waiting 10:00-11:00 | 0.5 to 2 |
| `w14-17` | A ref waiting 14:00-17:00 | 0.5 to 2 |
| `night` | A hall waiting per stall 00:00-03:00 | at most 0.3 |
| `short` | A ref open instants short of an ingredient | 0 |
| `open` | A ref open during checked hours | at least 0.99 |
| `na_share` | B nothing_available share of left on arrival | at most 0.25 |
| `day0` | B mains served on day 0 | at least 1 |
| `share` | served share (mains served / arrivals) | none; compared with today's |
| `ow12`, `ow19` | A mean over the owner stalls (the reference and any extras) of orders waiting 12:00-13:00, 19:00-20:00; from run 125 | none; reported |

**Measured** is the total over the measured days: arrivals, mains served, and
arrivals who left without ordering, by reason. From run 125 a line also gives
`main_failed` (admitted orders that ended with no main served), and each
measured day's business equivalents and the scale its arrivals used, both read
from the recorded `day_closed` events (the floor is 3.000). A line with extra
stalls adds the arrivals a day in the 12:00 hour, the stalls open in that hour
and the first divided by the second, and the mean daily profit of the
reference stall and of each extra stall.

## Runs

| # | Run | Seed | Reference | Tuning | Verdict | Measured | Why |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | A | 20261109 | salmon (old default) | today's values | w12=0.3733! w19=0.4333! b12=0.3111! b19=0.4089! w10=0.1533! w14-17=0.2215! night=0.067 short=31! open=1.0 share=0.379 | arrivals 810, served 307; left on arrival: chose_to_leave:1, no_compatible_main:3, nothing_affordable:280, nothing_available:138, wait_too_long:80 | baseline |
| 2 | B | 20261109 | - | today's values | na_share=0.2884! day0=88 share=0.3321 | arrivals 810, served 269; left on arrival: chose_to_leave:1, no_compatible_main:1, nothing_affordable:303, nothing_available:156, wait_too_long:80 | baseline |
| 3 | A | 7 | salmon (old default) | today's values | w12=0.1889! w19=0.0911! b12=0.1889! b19=0.0756! w10=0.2844! w14-17=0.1674! night=0.0317 short=536! open=1.0 share=0.3926 | arrivals 810, served 318; left on arrival: no_compatible_main:2, nothing_affordable:301, nothing_available:113, wait_too_long:76 | baseline |
| 4 | B | 7 | - | today's values | na_share=0.3819! day0=95 share=0.3481 | arrivals 810, served 282; left on arrival: chose_to_leave:1, nothing_affordable:257, nothing_available:202, wait_too_long:69 | baseline |
| 5 | A | 12345 | salmon (old default) | today's values | w12=0.5956! w19=0.1022! b12=0.4333! b19=0.1022! w10=0.3067! w14-17=0.2422! night=0.0435 short=1405! open=1.0 share=0.4012 | arrivals 810, served 325; left on arrival: chose_to_leave:1, no_compatible_main:5, nothing_affordable:293, nothing_available:121, wait_too_long:64 | baseline |
| 6 | B | 12345 | - | today's values | na_share=0.3553! day0=86 share=0.3432 | arrivals 810, served 278; left on arrival: no_compatible_main:1, nothing_affordable:270, nothing_available:189, wait_too_long:72 | baseline |
| 7 | B | 20261109 | - | fallback 100; market 50 | na_share=0.0028 day0=166 share=0.5642 | arrivals 810, served 457; left on arrival: chose_to_leave:3, no_compatible_main:27, nothing_affordable:220, nothing_available:1, wait_too_long:100 | supply first: 50 portions per equivalent of every recipe line, fallback 100 |
| 8 | A | 20261109 | salmon (old default) | fallback 100; market 50 | w12=0.2556! w19=0.3244! b12=0.2556! b19=0.3089! w10=0.2556! w14-17=0.2207! night=0.0535 short=10! open=1.0 share=0.5963 | arrivals 810, served 483; left on arrival: chose_to_leave:1, no_compatible_main:7, nothing_affordable:212, nothing_available:1, wait_too_long:101 | supply first, run A |
| 9 | A | 20261109 | salmon (old default) | arrivals 180; fallback 100; market 50 | w12=1.1133! w19=0.6333! b12=0.6333! b19=0.4844! w10=0.4489! w14-17=0.3467! night=0.0696 short=10! open=1.0 share=0.513 | arrivals 1620, served 831; left on arrival: chose_to_leave:1, no_compatible_main:11, nothing_affordable:446, wait_too_long:318 | then arrivals x2 |
| 10 | A | 20261109 | salmon (old default) | arrivals 270; fallback 50; market 100 | w12=1.7667! w19=1.48! b12=0.9178 b19=0.8644 w10=1.0956 w14-17=0.5911 night=0.1 short=0 open=1.0 share=0.4374 | arrivals 2430, served 1063; left on arrival: chose_to_leave:3, no_compatible_main:38, no_open_stall:7, nothing_affordable:663, wait_too_long:631 | explore arrival scale with ample supply |
| 11 | A | 20261109 | salmon (old default) | arrivals 450; fallback 50; market 100 | w12=3.4311 w19=3.6044 b12=0.9933 b19=1.0 w10=2.3756! w14-17=1.3385 night=0.2613 short=0 open=1.0 share=0.3244 | arrivals 4050, served 1314; left on arrival: chose_to_leave:2, no_compatible_main:154, no_open_stall:99, nothing_affordable:1115, nothing_available:3, wait_too_long:1308 | explore arrival scale with ample supply |
| 12 | A | 20261109 | salmon (old default) | arrivals 630; fallback 50; market 100 | w12=4.4067 w19=4.5222! b12=1.0 b19=1.0 w10=3.1578! w14-17=2.3089! night=0.3117! short=0 open=1.0 share=0.2476 | arrivals 5670, served 1404; left on arrival: chose_to_leave:6, no_compatible_main:317, no_open_stall:298, nothing_affordable:1624, nothing_available:4, wait_too_long:1943 | explore arrival scale with ample supply |
| 13 | A | 20261109 | salmon (old default) | arrivals 298; fallback 50; market 100; weights 2,1,1,0,0,2,3,4,5,7,16,20,42,20,19,19,19,19,20,42,17,10,7,3 | w12=2.2111! w19=2.6667 b12=0.8867 b19=0.9778 w10=1.2067 w14-17=1.0659 night=0.063 short=0 open=1.0 share=0.4034 | arrivals 2682, served 1082; left on arrival: chose_to_leave:2, no_compatible_main:56, no_open_stall:1, nothing_affordable:736, nothing_available:3, wait_too_long:771 | peaky shape: weights are arrivals per equivalent per hour, sized from the response of runs 008-012 |
| 14 | B | 20261109 | - | arrivals 298; fallback 50; market 100; weights 2,1,1,0,0,2,3,4,5,7,16,20,42,20,19,19,19,19,20,42,17,10,7,3 | na_share=0.0016 day0=270 share=0.2964 | arrivals 2682, served 795; left on arrival: chose_to_leave:4, no_compatible_main:82, no_open_stall:276, nothing_affordable:629, nothing_available:3, wait_too_long:863 | same, run B |
| 15 | B | 20261109 | - | arrivals 180; fallback 50; market 100 | na_share=0.0 day0=246 share=0.4722 | arrivals 1620, served 765; left on arrival: chose_to_leave:1, no_compatible_main:51, no_open_stall:18, nothing_affordable:410, wait_too_long:365 | run B served share against arrival scale, today's shape |
| 16 | B | 20261109 | - | arrivals 270; fallback 50; market 100 | na_share=0.0 day0=278 share=0.3613 | arrivals 2430, served 878; left on arrival: chose_to_leave:2, no_compatible_main:84, no_open_stall:112, nothing_affordable:591, wait_too_long:745 | run B served share against arrival scale, today's shape |
| 17 | A | 20261109 | salmon (old default) | arrivals 180; fallback 50; market 100 | w12=1.0978! w19=0.7267! b12=0.6022! b19=0.5911! w10=0.8222 w14-17=0.4489! night=0.0791 short=0 open=1.0 share=0.5167 | arrivals 1620, served 837; left on arrival: chose_to_leave:2, no_compatible_main:21, nothing_affordable:417, wait_too_long:332 | run A at x2 with ample supply |
| 18 | B | 20261109 | - | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=272 share=0.3972 | arrivals 2115, served 840; left on arrival: no_compatible_main:64, no_open_stall:80, nothing_affordable:525, wait_too_long:584 | x2.6 today's shape, today's shifts |
| 19 | B | 20261109 | - | arrivals 235; fallback 50; market 100; shifts mainstream 10-22, premium 17-3 | na_share=0.0 day0=300 share=0.426 | arrivals 2115, served 901; left on arrival: chose_to_leave:4, no_compatible_main:77, no_open_stall:16, nothing_affordable:592, wait_too_long:505 | same with mainstream 10-22, premium 17-3 |
| 20 | A | 20261109 | salmon (old default) | arrivals 235; fallback 50; market 100; shifts mainstream 10-22, premium 17-3 | w12=1.0578! w19=1.1667! b12=0.7311! b19=0.8422! w10=0.7356 w14-17=0.6252 night=0.0654 short=0 open=1.0 share=0.4827 | arrivals 2115, served 1021; left on arrival: chose_to_leave:4, no_compatible_main:23, nothing_affordable:605, wait_too_long:439 | run A at x2.6 with mainstream 10-22, premium 17-3 |
| 21 | A | 20261109 | european (scratch) | arrivals 235; fallback 50; market 100; shifts mainstream 10-22, premium 17-3 | w12=1.8222! w19=2.9467 b12=0.9289 b19=0.9956 w10=0.8467 w14-17=0.8748 night=0.0726 short=0 open=1.0 share=0.5073 | arrivals 2115, served 1073; left on arrival: chose_to_leave:4, no_compatible_main:65, no_open_stall:3, nothing_affordable:563, wait_too_long:384 | evidence only: scratch copy of the driver with the reference cuisine forced to european (tomato_pasta, 920, simmer) |
| 22 | B | 20261109 | - | arrivals 229; fallback 50; market 100; shifts mainstream 10-22, premium 17-3; weights 2,1,1,0,0,1,2,3,4,5,8,12,14,12,8,6,6,8,12,14,10,8,5,3 | na_share=0.0 day0=290 share=0.4459 | arrivals 2061, served 919; left on arrival: chose_to_leave:2, no_compatible_main:68, no_open_stall:8, nothing_affordable:561, wait_too_long:480 | lighter 07-09 (weights 3,4,5 for 4,6,6), same rate elsewhere |
| 23 | A | 20261109 | salmon (old default) | arrivals 229; fallback 50; market 100; shifts mainstream 10-22, premium 17-3; weights 2,1,1,0,0,1,2,3,4,5,8,12,14,12,8,6,6,8,12,14,10,8,5,3 | w12=1.0756! w19=1.1067! b12=0.6667! b19=0.7222! w10=0.42! w14-17=0.543 night=0.1296 short=0 open=1.0 share=0.4925 | arrivals 2061, served 1015; left on arrival: chose_to_leave:2, no_compatible_main:22, no_open_stall:3, nothing_affordable:591, wait_too_long:408 | lighter 07-09 (weights 3,4,5 for 4,6,6), same rate elsewhere |
| 24 | A | 20261109 | salmon (old default) | arrivals 235; fallback 50; market 100 | w12=1.5089! w19=1.2978! b12=0.8467! b19=0.7889! w10=1.1556 w14-17=0.5733 night=0.1154 short=0 open=1.0 share=0.4851 | arrivals 2115, served 1026; left on arrival: chose_to_leave:3, no_compatible_main:28, nothing_affordable:560, wait_too_long:483 | today's shifts at x2.6 |
| 25 | A | 7 | salmon (old default) | arrivals 235; fallback 50; market 100 | w12=1.12! w19=1.1311! b12=0.7733! b19=0.6578! w10=0.9244 w14-17=0.6207 night=0.1102 short=0 open=1.0 share=0.4719 | arrivals 2115, served 998; left on arrival: chose_to_leave:2, no_compatible_main:35, no_open_stall:1, nothing_affordable:547, wait_too_long:516 | today's shifts at x2.6 |
| 26 | A | 12345 | salmon (old default) | arrivals 235; fallback 50; market 100 | w12=1.6756! w19=1.5556! b12=0.8644 b19=0.84! w10=0.9333 w14-17=0.5407 night=0.1017 short=0 open=1.0 share=0.4794 | arrivals 2115, served 1014; left on arrival: chose_to_leave:3, no_compatible_main:26, nothing_affordable:567, wait_too_long:486 | today's shifts at x2.6 |
| 27 | B | 7 | - | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=279 share=0.4 | arrivals 2115, served 846; left on arrival: no_compatible_main:68, no_open_stall:73, nothing_affordable:525, wait_too_long:586 | today's shifts at x2.6 |
| 28 | B | 12345 | - | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=266 share=0.3948 | arrivals 2115, served 835; left on arrival: chose_to_leave:5, no_compatible_main:72, no_open_stall:48, nothing_affordable:506, wait_too_long:631 | today's shifts at x2.6 |
| 29 | A | 20261109 | salmon (old default) | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.6067! w19=1.4333! b12=0.8356! b19=0.86 w10=0.9111 w14-17=0.837 night=0.0898 short=0 open=1.0 share=0.4875 | arrivals 2115, served 1031; left on arrival: chose_to_leave:2, no_compatible_main:21, nothing_affordable:599, wait_too_long:449 | mainstream 11-23, premium 17-3 at x2.6 |
| 30 | A | 7 | salmon (old default) | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.34! w19=1.3067! b12=0.9 b19=0.88 w10=0.8689 w14-17=0.56 night=0.0828 short=0 open=1.0 share=0.4979 | arrivals 2115, served 1053; left on arrival: chose_to_leave:2, no_compatible_main:31, no_open_stall:8, nothing_affordable:531, wait_too_long:469 | mainstream 11-23, premium 17-3 at x2.6 |
| 31 | A | 12345 | salmon (old default) | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.3511! w19=0.9644! b12=0.84! b19=0.6267! w10=0.5911 w14-17=0.5563 night=0.1487 short=0 open=1.0 share=0.4837 | arrivals 2115, served 1023; left on arrival: chose_to_leave:2, no_compatible_main:19, no_open_stall:2, nothing_affordable:583, wait_too_long:469 | mainstream 11-23, premium 17-3 at x2.6 |
| 32 | B | 20261109 | - | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=305 share=0.4322 | arrivals 2115, served 914; left on arrival: chose_to_leave:3, no_compatible_main:55, no_open_stall:10, nothing_affordable:554, wait_too_long:564 | mainstream 11-23, premium 17-3 at x2.6 |
| 33 | B | 7 | - | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=292 share=0.4331 | arrivals 2115, served 916; left on arrival: chose_to_leave:4, no_compatible_main:63, no_open_stall:21, nothing_affordable:541, wait_too_long:552 | mainstream 11-23, premium 17-3 at x2.6 |
| 34 | B | 12345 | - | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=300 share=0.4284 | arrivals 2115, served 906; left on arrival: no_compatible_main:64, no_open_stall:11, nothing_affordable:555, wait_too_long:564 | mainstream 11-23, premium 17-3 at x2.6 |
| 35 | B | 20261109 | - | arrivals 180; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0037 day0=254 share=0.4932 | arrivals 1620, served 799; left on arrival: chose_to_leave:1, no_compatible_main:49, no_open_stall:3, nothing_affordable:421, nothing_available:3, wait_too_long:335 | level sweep with mainstream 11-23, premium 17-3 |
| 36 | A | 20261109 | salmon (old default) | arrivals 180; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.1067! w19=0.5289! b12=0.6978! b19=0.4133! w10=0.6444 w14-17=0.3089! night=0.0515 short=0 open=1.0 share=0.5185 | arrivals 1620, served 840; left on arrival: chose_to_leave:4, no_compatible_main:11, no_open_stall:2, nothing_affordable:471, nothing_available:3, wait_too_long:283 | level sweep with mainstream 11-23, premium 17-3 |
| 37 | B | 20261109 | - | arrivals 205; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.003 day0=269 share=0.452 | arrivals 1845, served 834; left on arrival: chose_to_leave:2, no_compatible_main:64, no_open_stall:8, nothing_affordable:474, nothing_available:3, wait_too_long:444 | level sweep with mainstream 11-23, premium 17-3 |
| 38 | A | 20261109 | salmon (old default) | arrivals 205; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=0.88! w19=1.0489! b12=0.7133! b19=0.7022! w10=0.8378 w14-17=0.4341! night=0.075 short=0 open=1.0 share=0.51 | arrivals 1845, served 941; left on arrival: no_compatible_main:14, nothing_affordable:511, nothing_available:3, wait_too_long:366 | level sweep with mainstream 11-23, premium 17-3 |
| 39 | B | 20261109 | - | arrivals 270; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.002 day0=301 share=0.3844 | arrivals 2430, served 934; left on arrival: chose_to_leave:1, no_compatible_main:67, no_open_stall:42, nothing_affordable:678, nothing_available:3, wait_too_long:682 | level sweep with mainstream 11-23, premium 17-3 |
| 40 | A | 20261109 | salmon (old default) | arrivals 270; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=2.2244! w19=1.8911! b12=0.9644 b19=0.8044! w10=1.2289 w14-17=0.8081 night=0.0967 short=0 open=1.0 share=0.4683 | arrivals 2430, served 1138; left on arrival: chose_to_leave:5, no_compatible_main:30, no_open_stall:12, nothing_affordable:677, nothing_available:3, wait_too_long:548 | level sweep with mainstream 11-23, premium 17-3 |
| 41 | A | 20261109 | salmon (old default) | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 42 | A | 7 | salmon (old default) | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.2222! w19=1.2133! b12=0.7489! b19=0.7356! w10=1.0311 w14-17=0.7593 night=0.0994 short=0 open=1.0 share=0.4886 | arrivals 2241, served 1095; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:1, nothing_affordable:574, nothing_available:3, wait_too_long:522 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 43 | A | 12345 | salmon (old default) | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.5378! w19=1.4111! b12=0.84! b19=0.7978! w10=1.0089 w14-17=0.88 night=0.1211 short=0 open=1.0 share=0.49 | arrivals 2241, served 1098; left on arrival: chose_to_leave:4, no_compatible_main:18, nothing_affordable:611, nothing_available:3, wait_too_long:480 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 44 | B | 20261109 | - | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 45 | B | 7 | - | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=302 share=0.4163 | arrivals 2241, served 933; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:23, nothing_affordable:559, nothing_available:3, wait_too_long:619 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 46 | B | 12345 | - | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=300 share=0.3976 | arrivals 2241, served 891; left on arrival: chose_to_leave:1, no_compatible_main:72, no_open_stall:49, nothing_affordable:596, nothing_available:2, wait_too_long:606 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 47 | A | 20261109 | salmon (old default) | arrivals 249; fallback 50; market 25; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.5978! w19=1.8356! b12=0.9156 b19=0.9044 w10=1.5422 w14-17=0.997 night=0.1026 short=10! open=1.0 share=0.4355 | arrivals 2241, served 976; left on arrival: chose_to_leave:5, no_compatible_main:21, nothing_affordable:765, nothing_available:16, wait_too_long:448 | market size: 25 portions per equivalent |
| 48 | B | 20261109 | - | arrivals 249; fallback 50; market 25; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.078 day0=273 share=0.3476 | arrivals 2241, served 779; left on arrival: no_compatible_main:39, no_open_stall:16, nothing_affordable:730, nothing_available:113, wait_too_long:551 | market size: 25 portions per equivalent |
| 49 | A | 20261109 | salmon (old default) | arrivals 249; fallback 50; market 50; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | market size: 50 portions per equivalent |
| 50 | B | 20261109 | - | arrivals 249; fallback 50; market 50; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | market size: 50 portions per equivalent |
| 51 | B | 20261109 | - | arrivals 249; fallback 10; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=270 share=0.4159 | arrivals 2241, served 932; left on arrival: chose_to_leave:2, no_compatible_main:77, no_open_stall:27, nothing_affordable:598, nothing_available:3, wait_too_long:583 | fallback trays 10 |
| 52 | B | 20261109 | - | arrivals 249; fallback 90; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=312 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | fallback trays 90 |
| 53 | B | 20261109 | - | arrivals 249; fallback 30; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=304 share=0.4186 | arrivals 2241, served 938; left on arrival: chose_to_leave:4, no_compatible_main:77, no_open_stall:24, nothing_affordable:589, nothing_available:3, wait_too_long:584 | fallback trays 30 |
| 54 | A | 20261109 | salmon (old default) | first chosen values | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | FINAL: --tuning chosen, via init |
| 55 | A | 7 | salmon (old default) | first chosen values | w12=1.2222! w19=1.2133! b12=0.7489! b19=0.7356! w10=1.0311 w14-17=0.7593 night=0.0994 short=0 open=1.0 share=0.4886 | arrivals 2241, served 1095; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:1, nothing_affordable:574, nothing_available:3, wait_too_long:522 | FINAL: --tuning chosen, via init |
| 56 | A | 12345 | salmon (old default) | first chosen values | w12=1.5378! w19=1.4111! b12=0.84! b19=0.7978! w10=1.0089 w14-17=0.88 night=0.1211 short=0 open=1.0 share=0.49 | arrivals 2241, served 1098; left on arrival: chose_to_leave:4, no_compatible_main:18, nothing_affordable:611, nothing_available:3, wait_too_long:480 | FINAL: --tuning chosen, via init |
| 57 | B | 20261109 | - | first chosen values | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | FINAL: --tuning chosen, via init |
| 58 | B | 7 | - | first chosen values | na_share=0.0023 day0=302 share=0.4163 | arrivals 2241, served 933; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:23, nothing_affordable:559, nothing_available:3, wait_too_long:619 | FINAL: --tuning chosen, via init |
| 59 | B | 12345 | - | first chosen values | na_share=0.0015 day0=300 share=0.3976 | arrivals 2241, served 891; left on arrival: chose_to_leave:1, no_compatible_main:72, no_open_stall:49, nothing_affordable:596, nothing_available:2, wait_too_long:606 | FINAL: --tuning chosen, via init |
| 60 | A | 20261109 | salmon (old default) | first chosen values; applied by --via retune | w12=0.9333! w19=1.7511! b12=0.6822! b19=0.9044 w10=0.9867 w14-17=0.6407 night=0.0894 short=10! open=1.0 share=0.4752 | arrivals 2241, served 1065; left on arrival: chose_to_leave:1, no_compatible_main:23, nothing_affordable:638, nothing_available:21, wait_too_long:476 | FINAL: chosen applied by the recorded change at 12:00 of the warm-up day |
| 61 | A | 20261109 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=90 | w12=0.0933! w19=0.5111! b12=0.0933! b19=0.4467! w10=0.2444! w14-17=0.2667! night=0.0641 short=0 open=1.0 share=0.5975 | arrivals 810, served 484; left on arrival: chose_to_leave:2, no_compatible_main:10, nothing_affordable:214, wait_too_long:93 | SENSITIVITY: chosen with arrivals per equivalent back at 90 |
| 62 | B | 20261109 | - | first chosen values with the market targets and caps at today's values | na_share=0.6157! day0=85 share=0.1455 | arrivals 2241, served 326; left on arrival: chose_to_leave:5, no_compatible_main:3, nothing_affordable:520, nothing_available:1179, wait_too_long:208 | SENSITIVITY: chosen with the market targets and caps back at today's |
| 63 | B | 20261109 | - | first chosen values; --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7 | na_share=0.0022 day0=281 share=0.3695 | arrivals 2241, served 828; left on arrival: chose_to_leave:3, no_compatible_main:75, no_open_stall:92, nothing_affordable:546, nothing_available:3, wait_too_long:666 | SENSITIVITY: chosen with the starter shifts back at today's |
| 64 | A | 20261109 | salmon (old default) | first chosen values; 14 measured days | w12=1.5338! w19=1.2029! b12=0.8462! b19=0.7314! w10=1.0676 w14-17=0.7263 night=0.0983 short=0 open=1.0 share=0.4807 | see report: reference cash by day, no arrears, no distress | FINAL: 14 measured days, reference survival |
| 65 | A | 20261109 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=286 | w12=1.9689! w19=1.4667! b12=0.9667 b19=0.8289! w10=1.2778 w14-17=0.9941 night=0.0896 short=0 open=1.0 share=0.4495 | arrivals 2574, served 1157; left on arrival: chose_to_leave:3, no_compatible_main:25, nothing_affordable:691, wait_too_long:678 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 66 | A | 7 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=286 | w12=2.0156! w19=1.5222! b12=0.9578 b19=0.8089! w10=1.1178 w14-17=0.8207 night=0.1302 short=0 open=1.0 share=0.4491 | arrivals 2574, served 1156; left on arrival: chose_to_leave:3, no_compatible_main:37, no_open_stall:4, nothing_affordable:694, wait_too_long:651 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 67 | A | 12345 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=286 | w12=1.54! w19=1.3911! b12=0.8644 b19=0.8156! w10=1.4933 w14-17=0.9985 night=0.1057 short=0 open=1.0 share=0.4409 | arrivals 2574, served 1135; left on arrival: chose_to_leave:5, no_compatible_main:27, no_open_stall:9, nothing_affordable:724, wait_too_long:640 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 68 | B | 20261109 | - | first chosen values; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=325 share=0.3632 | arrivals 2574, served 935; left on arrival: chose_to_leave:2, no_compatible_main:96, no_open_stall:55, nothing_affordable:700, wait_too_long:763 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 69 | B | 7 | - | first chosen values; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=320 share=0.3726 | arrivals 2574, served 959; left on arrival: chose_to_leave:2, no_compatible_main:87, no_open_stall:58, nothing_affordable:673, wait_too_long:775 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 70 | B | 12345 | - | first chosen values; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=307 share=0.3691 | arrivals 2574, served 950; left on arrival: no_compatible_main:76, no_open_stall:64, nothing_affordable:693, wait_too_long:763 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 71 | A | 20261109 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=212 | w12=1.1067! w19=0.4822! b12=0.8067! b19=0.4022! w10=0.8578 w14-17=0.5748 night=0.067 short=0 open=1.0 share=0.5042 | arrivals 1908, served 962; left on arrival: chose_to_leave:2, no_compatible_main:14, nothing_affordable:544, nothing_available:3, wait_too_long:367 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 72 | A | 7 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=212 | w12=1.2711! w19=1.0911! b12=0.6911! b19=0.6911! w10=0.8222 w14-17=0.6496 night=0.1035 short=0 open=1.0 share=0.521 | arrivals 1908, served 994; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:2, nothing_affordable:491, nothing_available:3, wait_too_long:381 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 73 | A | 12345 | salmon (old default) | first chosen values; --set demand.arrivals_per_equivalent=212 | w12=1.7644! w19=1.2644! b12=0.9089 b19=0.6489! w10=0.7311 w14-17=0.6467 night=0.1022 short=0 open=1.0 share=0.5152 | arrivals 1908, served 983; left on arrival: chose_to_leave:6, no_compatible_main:23, nothing_affordable:508, nothing_available:2, wait_too_long:367 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 74 | B | 20261109 | - | first chosen values; --set demand.arrivals_per_equivalent=212 | na_share=0.003 day0=284 share=0.4659 | arrivals 1908, served 889; left on arrival: no_compatible_main:62, no_open_stall:10, nothing_affordable:474, nothing_available:3, wait_too_long:452 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 75 | B | 7 | - | first chosen values; --set demand.arrivals_per_equivalent=212 | na_share=0.0029 day0=286 share=0.4575 | arrivals 1908, served 873; left on arrival: chose_to_leave:4, no_compatible_main:65, no_open_stall:10, nothing_affordable:482, nothing_available:3, wait_too_long:454 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 76 | B | 12345 | - | first chosen values; --set demand.arrivals_per_equivalent=212 | na_share=0.0029 day0=286 share=0.4575 | arrivals 1908, served 873; left on arrival: chose_to_leave:3, no_compatible_main:56, no_open_stall:15, nothing_affordable:452, nothing_available:3, wait_too_long:489 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 77 | A | 20261109 | median | first chosen values | w12=2.1044! w19=2.5178 b12=0.9511 b19=0.9644 w10=1.9156 w14-17=1.3785 night=0.0815 short=0 open=1.0 share=0.5319 | arrivals 2241, served 1192; left on arrival: chose_to_leave:2, no_compatible_main:64, no_open_stall:3, nothing_affordable:587, nothing_available:3, wait_too_long:363 | MEDIAN REFERENCE (colombian, 940): chosen values |
| 78 | A | 7 | median | first chosen values | w12=2.1689! w19=2.28! b12=0.9911 b19=0.9933 w10=1.7 w14-17=1.4 night=0.1185 short=0 open=1.0 share=0.5306 | arrivals 2241, served 1189; left on arrival: chose_to_leave:5, no_compatible_main:62, no_open_stall:1, nothing_affordable:595, nothing_available:3, wait_too_long:357 | MEDIAN REFERENCE (colombian, 940): chosen values |
| 79 | A | 12345 | median | first chosen values | w12=2.4556! w19=3.0267 b12=0.9467 b19=0.9867 w10=1.4978 w14-17=1.4593 night=0.1235 short=0 open=1.0 share=0.5431 | arrivals 2241, served 1217; left on arrival: no_compatible_main:76, nothing_affordable:554, nothing_available:2, wait_too_long:363 | MEDIAN REFERENCE (colombian, 940): chosen values |
| 80 | A | 20261109 | median | today's values | w12=0.6333! w19=0.0! b12=0.4778! b19=0.0! w10=0.5178 w14-17=0.0! night=0.0533 short=3397! open=1.0 share=0.4012 | arrivals 810, served 325; left on arrival: chose_to_leave:2, no_compatible_main:1, nothing_affordable:297, nothing_available:116, wait_too_long:68 | MEDIAN REFERENCE baseline: today's values |
| 81 | A | 7 | median | today's values | w12=0.3844! w19=0.0! b12=0.3111! b19=0.0! w10=0.4644! w14-17=0.0! night=0.0283 short=3494! open=1.0 share=0.4012 | arrivals 810, served 325; left on arrival: no_compatible_main:4, nothing_affordable:286, nothing_available:141, wait_too_long:54 | MEDIAN REFERENCE baseline: today's values |
| 82 | A | 12345 | median | today's values | w12=0.78! w19=0.0! b12=0.5933! b19=0.0! w10=0.3156! w14-17=0.0! night=0.0346 short=3281! open=1.0 share=0.4049 | arrivals 810, served 328; left on arrival: chose_to_leave:1, no_compatible_main:2, nothing_affordable:286, nothing_available:129, wait_too_long:64 | MEDIAN REFERENCE baseline: today's values |
| 83 | A | 20261109 | median | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | w12=3.2467 w19=2.76 b12=1.0 b19=0.9956 w10=1.0444 w14-17=1.0119 night=0.0607 short=0 open=1.0 share=0.522 | arrivals 2232, served 1165; left on arrival: chose_to_leave:2, no_compatible_main:63, nothing_affordable:615, nothing_available:3, wait_too_long:349 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 84 | A | 7 | median | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | w12=2.4511! w19=2.5378 b12=0.9978 b19=0.9533 w10=1.4178 w14-17=1.0348 night=0.0815 short=0 open=1.0 share=0.5314 | arrivals 2232, served 1186; left on arrival: no_compatible_main:70, no_open_stall:2, nothing_affordable:564, nothing_available:3, wait_too_long:384 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 85 | A | 12345 | median | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | w12=3.0467 w19=3.1533 b12=1.0 b19=0.9756 w10=1.0289 w14-17=0.9807 night=0.1235 short=0 open=1.0 share=0.522 | arrivals 2232, served 1165; left on arrival: chose_to_leave:1, no_compatible_main:69, no_open_stall:1, nothing_affordable:580, nothing_available:3, wait_too_long:391 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 86 | B | 20261109 | - | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | na_share=0.0023 day0=305 share=0.4108 | arrivals 2232, served 917; left on arrival: chose_to_leave:2, no_compatible_main:72, no_open_stall:14, nothing_affordable:599, nothing_available:3, wait_too_long:602 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 87 | B | 7 | - | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | na_share=0.0023 day0=299 share=0.4131 | arrivals 2232, served 922; left on arrival: chose_to_leave:1, no_compatible_main:71, no_open_stall:34, nothing_affordable:546, nothing_available:3, wait_too_long:631 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 88 | B | 12345 | - | first chosen values; --set demand.arrivals_per_equivalent=248 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,11,19,30,19,12,12,12,14,19,28,16,11,8,5 | na_share=0.0015 day0=304 share=0.3947 | arrivals 2232, served 881; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:33, nothing_affordable:608, nothing_available:2, wait_too_long:620 | MEDIAN REFERENCE: sharper rushes (30 at 12:00, 28 at 19:00), lighter 10:00 and afternoon |
| 89 | A | 20261109 | median | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | w12=2.9733 w19=3.4467 b12=1.0 b19=1.0 w10=1.2778 w14-17=1.157 night=0.1359 short=0 open=1.0 share=0.5287 | arrivals 2268, served 1199; left on arrival: chose_to_leave:2, no_compatible_main:66, no_open_stall:2, nothing_affordable:583, nothing_available:3, wait_too_long:385 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 90 | A | 7 | median | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | w12=3.1111 w19=3.0911 b12=1.0 b19=0.9911 w10=0.9889 w14-17=1.2089 night=0.118 short=0 open=1.0 share=0.5128 | arrivals 2268, served 1163; left on arrival: chose_to_leave:3, no_compatible_main:69, no_open_stall:1, nothing_affordable:589, nothing_available:3, wait_too_long:416 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 91 | A | 12345 | median | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | w12=3.5356 w19=3.4889 b12=0.9778 b19=1.0 w10=0.9378 w14-17=1.0815 night=0.1119 short=0 open=1.0 share=0.5079 | arrivals 2268, served 1152; left on arrival: chose_to_leave:3, no_compatible_main:73, no_open_stall:2, nothing_affordable:599, nothing_available:3, wait_too_long:419 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 92 | B | 20261109 | - | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | na_share=0.0023 day0=302 share=0.4039 | arrivals 2268, served 916; left on arrival: chose_to_leave:2, no_compatible_main:68, no_open_stall:74, nothing_affordable:571, nothing_available:3, wait_too_long:605 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 93 | B | 7 | - | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | na_share=0.0023 day0=291 share=0.4034 | arrivals 2268, served 915; left on arrival: chose_to_leave:3, no_compatible_main:70, no_open_stall:61, nothing_affordable:577, nothing_available:3, wait_too_long:611 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 94 | B | 12345 | - | first chosen values; --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | na_share=0.0022 day0=298 share=0.4017 | arrivals 2268, served 911; left on arrival: chose_to_leave:2, no_compatible_main:77, no_open_stall:44, nothing_affordable:618, nothing_available:3, wait_too_long:595 | MEDIAN REFERENCE: rushes at 34 and 33, trimmed 09:00, 13:00, 20:00, 21:00 |
| 95 | A | 20261109 | median | final chosen values | w12=2.9733 w19=3.4467 b12=1.0 b19=1.0 w10=1.2778 w14-17=1.157 night=0.1359 short=0 open=1.0 share=0.5287 | arrivals 2268, served 1199; left on arrival: chose_to_leave:2, no_compatible_main:66, no_open_stall:2, nothing_affordable:583, nothing_available:3, wait_too_long:385 | FINAL (median reference): --tuning chosen, via init |
| 96 | A | 7 | median | final chosen values | w12=3.1111 w19=3.0911 b12=1.0 b19=0.9911 w10=0.9889 w14-17=1.2089 night=0.118 short=0 open=1.0 share=0.5128 | arrivals 2268, served 1163; left on arrival: chose_to_leave:3, no_compatible_main:69, no_open_stall:1, nothing_affordable:589, nothing_available:3, wait_too_long:416 | FINAL (median reference): --tuning chosen, via init |
| 97 | A | 12345 | median | final chosen values | w12=3.5356 w19=3.4889 b12=0.9778 b19=1.0 w10=0.9378 w14-17=1.0815 night=0.1119 short=0 open=1.0 share=0.5079 | arrivals 2268, served 1152; left on arrival: chose_to_leave:3, no_compatible_main:73, no_open_stall:2, nothing_affordable:599, nothing_available:3, wait_too_long:419 | FINAL (median reference): --tuning chosen, via init |
| 98 | B | 20261109 | - | final chosen values | na_share=0.0023 day0=302 share=0.4039 | arrivals 2268, served 916; left on arrival: chose_to_leave:2, no_compatible_main:68, no_open_stall:74, nothing_affordable:571, nothing_available:3, wait_too_long:605 | FINAL (median reference): --tuning chosen, via init |
| 99 | B | 7 | - | final chosen values | na_share=0.0023 day0=291 share=0.4034 | arrivals 2268, served 915; left on arrival: chose_to_leave:3, no_compatible_main:70, no_open_stall:61, nothing_affordable:577, nothing_available:3, wait_too_long:611 | FINAL (median reference): --tuning chosen, via init |
| 100 | B | 12345 | - | final chosen values | na_share=0.0022 day0=298 share=0.4017 | arrivals 2268, served 911; left on arrival: chose_to_leave:2, no_compatible_main:77, no_open_stall:44, nothing_affordable:618, nothing_available:3, wait_too_long:595 | FINAL (median reference): --tuning chosen, via init |
| 101 | A | 20261109 | median | final chosen values; 14 measured days | w12=3.321 w19=3.02 b12=0.9971 b19=0.9914 w10=1.1024 w14-17=1.0914 night=0.0938 short=0 open=1.0 share=0.5083 | see report: reference cash by day, no arrears, no distress; cancelled trays tallied from events | FINAL (median reference): 14 measured days |
| 102 | A | 20261109 | median | final chosen values; applied by --via retune | w12=3.3956 w19=3.4267 b12=0.9822 b19=1.0 w10=1.1911 w14-17=0.9852 night=0.1081 short=10! open=1.0 share=0.5101 | arrivals 2268, served 1157; left on arrival: chose_to_leave:4, no_compatible_main:78, nothing_affordable:583, nothing_available:14, wait_too_long:403 | FINAL (median reference): chosen applied by the recorded change at 12:00 of the warm-up day |
| 103 | A | 20261109 | median | final chosen values; --set demand.arrivals_per_equivalent=90 | w12=0.8289! w19=1.0911! b12=0.6! b19=0.7444! w10=0.1733! w14-17=0.3385! night=0.0383 short=0 open=1.0 share=0.6259 | arrivals 810, served 507; left on arrival: chose_to_leave:1, no_compatible_main:28, nothing_affordable:193, nothing_available:2, wait_too_long:74 | SENSITIVITY (median reference): arrivals per equivalent back at 90 |
| 104 | B | 20261109 | - | final chosen values with the market targets and caps at today's values | na_share=0.6216! day0=85 share=0.1446 | arrivals 2268, served 328; left on arrival: no_compatible_main:3, nothing_affordable:522, nothing_available:1206, wait_too_long:209 | SENSITIVITY: market targets and caps back at today's |
| 105 | B | 20261109 | - | final chosen values; --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7 | na_share=0.0021 day0=272 share=0.3704 | arrivals 2268, served 840; left on arrival: chose_to_leave:2, no_compatible_main:79, no_open_stall:77, nothing_affordable:586, nothing_available:3, wait_too_long:663 | SENSITIVITY: starter shifts back at today's |
| 106 | B | 20261109 | - | final chosen values; --set npc.fallback_trays_per_day=10 | na_share=0.0022 day0=254 share=0.3981 | arrivals 2268, served 903; left on arrival: chose_to_leave:2, no_compatible_main:64, no_open_stall:51, nothing_affordable:621, nothing_available:3, wait_too_long:601 | SENSITIVITY: fallback back at 10 |
| 107 | A | 20261109 | salmon (--cuisine) | final chosen values | w12=2.4022! w19=1.8422! b12=0.98 b19=0.8267! w10=0.6133 w14-17=0.8422 night=0.1272 short=0 open=1.0 share=0.4819 | arrivals 2268, served 1093; left on arrival: chose_to_leave:3, no_compatible_main:23, nothing_affordable:602, nothing_available:3, wait_too_long:514 | HARDER CASE: --cuisine coast_salish (roasted_salmon, 1220) at the final values |
| 108 | A | 7 | salmon (--cuisine) | final chosen values | w12=2.1933! w19=1.7778! b12=0.9511 b19=0.8867 w10=0.6933 w14-17=0.7778 night=0.1061 short=0 open=1.0 share=0.4731 | arrivals 2268, served 1073; left on arrival: chose_to_leave:3, no_compatible_main:20, nothing_affordable:612, nothing_available:3, wait_too_long:535 | HARDER CASE: --cuisine coast_salish (roasted_salmon, 1220) at the final values |
| 109 | A | 12345 | salmon (--cuisine) | final chosen values | w12=2.2089! w19=2.1067! b12=0.8822 b19=0.9733 w10=0.6911 w14-17=0.5881 night=0.1207 short=0 open=1.0 share=0.4687 | arrivals 2268, served 1063; left on arrival: chose_to_leave:2, no_compatible_main:16, nothing_affordable:625, nothing_available:2, wait_too_long:541 | HARDER CASE: --cuisine coast_salish (roasted_salmon, 1220) at the final values |
| 110 | A | 20261109 | salmon (--cuisine) | today's values | w12=0.3733! w19=0.4333! b12=0.3111! b19=0.4089! w10=0.1533! w14-17=0.2215! night=0.067 short=31! open=1.0 share=0.379 | arrivals 810, served 307; left on arrival: chose_to_leave:1, no_compatible_main:3, nothing_affordable:280, nothing_available:138, wait_too_long:80 | REPRODUCTION CHECK: run 1 through --cuisine coast_salish on the current driver |
| 111 | A | 20261109 | median | final chosen values; --set demand.arrivals_per_equivalent=249 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=2.1044! w19=2.5178 b12=0.9511 b19=0.9644 w10=1.9156 w14-17=1.3785 night=0.0815 short=0 open=1.0 share=0.5319 | arrivals 2241, served 1192; left on arrival: chose_to_leave:2, no_compatible_main:64, no_open_stall:3, nothing_affordable:587, nothing_available:3, wait_too_long:363 | REPRODUCTION CHECK: run 77 (flat shape) through --set on the final chosen values |
| 124 | A | 20261109 | median | final chosen values; --hours 9-21 | w12=3.1267 w19=0.5222! b12=1.0 b19=0.0289! w10=1.2822 w14-17=1.0815 night=0.1285 short=0 open=0.8333! share=0.5075 | arrivals and reasons not recorded (the controller kept only the verdict rows) | RUN BY THE CONTROLLER at commit 3442eb8, after the task: the design's 09:00-21:00 schedule; open share by hour 10:1.0, 12:1.0, 14:1.0, 15:1.0, 16:1.0, 19:0.0; exit status 1 by design |
| 125 | A | 20261109 | median | final chosen values (gentler shape) | w12=3.2467 w19=2.76 b12=1.0 b19=0.9956 w10=1.0444 w14-17=1.0119 night=0.0607 short=0 open=1.0 ow12=3.2467 ow19=2.76 share=0.522 | arrivals 2232, served 1165; left on arrival: chose_to_leave:2, no_compatible_main:63, nothing_affordable:615, nothing_available:3, wait_too_long:349; main_failed 33; equivalents by day 1.890/1.884/1.888; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 126 | A | 7 | median | final chosen values (gentler shape) | w12=2.4511! w19=2.5378 b12=0.9978 b19=0.9533 w10=1.4178 w14-17=1.0348 night=0.0815 short=0 open=1.0 ow12=2.4511 ow19=2.5378 share=0.5314 | arrivals 2232, served 1186; left on arrival: no_compatible_main:70, no_open_stall:2, nothing_affordable:564, nothing_available:3, wait_too_long:384; main_failed 21; equivalents by day 1.895/1.881/1.896; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 127 | A | 12345 | median | final chosen values (gentler shape) | w12=3.0467 w19=3.1533 b12=1.0 b19=0.9756 w10=1.0289 w14-17=0.9807 night=0.1235 short=0 open=1.0 ow12=3.0467 ow19=3.1533 share=0.522 | arrivals 2232, served 1165; left on arrival: chose_to_leave:1, no_compatible_main:69, no_open_stall:1, nothing_affordable:580, nothing_available:3, wait_too_long:391; main_failed 23; equivalents by day 1.885/1.901/1.882; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 128 | B | 20261109 | - | final chosen values (gentler shape) | na_share=0.0023 day0=305 share=0.4108 | arrivals 2232, served 917; left on arrival: chose_to_leave:2, no_compatible_main:72, no_open_stall:14, nothing_affordable:599, nothing_available:3, wait_too_long:602; main_failed 22; equivalents by day 1.437/1.403/1.385; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 129 | B | 7 | - | final chosen values (gentler shape) | na_share=0.0023 day0=299 share=0.4131 | arrivals 2232, served 922; left on arrival: chose_to_leave:1, no_compatible_main:71, no_open_stall:34, nothing_affordable:546, nothing_available:3, wait_too_long:631; main_failed 25; equivalents by day 1.405/1.385/1.390; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 130 | B | 12345 | - | final chosen values (gentler shape) | na_share=0.0015 day0=304 share=0.3947 | arrivals 2232, served 881; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:33, nothing_affordable:608, nothing_available:2, wait_too_long:620; main_failed 13; equivalents by day 1.408/1.379/1.419; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: --tuning chosen, via init |
| 131 | A | 424242 | median | final chosen values (gentler shape) | w12=2.3311! w19=3.0044 b12=0.9756 b19=1.0 w10=0.9667 w14-17=1.0467 night=0.093 short=0 open=1.0 ow12=2.3311 ow19=3.0044 share=0.5237 | arrivals 2232, served 1169; left on arrival: chose_to_leave:3, no_compatible_main:70, no_open_stall:1, nothing_affordable:603, nothing_available:3, wait_too_long:357; main_failed 25; equivalents by day 1.887/1.901/1.892; scale by day 3.000/3.000/3.000 | HELD-OUT SEED (never used for selection): chosen values |
| 132 | B | 424242 | - | final chosen values (gentler shape) | na_share=0.0023 day0=304 share=0.4055 | arrivals 2232, served 905; left on arrival: chose_to_leave:3, no_compatible_main:71, no_open_stall:44, nothing_affordable:553, nothing_available:3, wait_too_long:631; main_failed 23; equivalents by day 1.377/1.381/1.399; scale by day 3.000/3.000/3.000 | HELD-OUT SEED (never used for selection): chosen values |
| 133 | A | 424242 | median | today's values | w12=0.58! w19=0.0! b12=0.4822! b19=0.0! w10=0.4044! w14-17=0.0! night=0.0344 short=3383! open=1.0 ow12=0.58 ow19=0.0 share=0.3951 | arrivals 810, served 320; left on arrival: no_compatible_main:2, nothing_affordable:283, nothing_available:128, wait_too_long:76; main_failed 0; equivalents by day 1.269/1.349/1.364; scale by day 3.000/3.000/3.000 | HELD-OUT SEED (never used for selection): today's values |
| 134 | B | 424242 | - | today's values | na_share=0.3047! day0=88 share=0.3395 | arrivals 810, served 275; left on arrival: no_compatible_main:1, nothing_affordable:276, nothing_available:163, wait_too_long:95; main_failed 0; equivalents by day 1.090/1.138/1.199; scale by day 3.000/3.000/3.000 | HELD-OUT SEED (never used for selection): today's values |
| 135 | A | 20261109 | median | final chosen values (gentler shape); applied by --via retune | w12=2.5978 w19=2.8889 b12=0.9333 b19=1.0 w10=0.9022 w14-17=1.1 night=0.1009 short=10! open=1.0 ow12=2.5978 ow19=2.8889 share=0.5242 | arrivals 2232, served 1170; left on arrival: chose_to_leave:1, no_compatible_main:81, nothing_affordable:577, nothing_available:15, wait_too_long:368; main_failed 20; equivalents by day 1.894/1.884/1.899; scale by day 3.000/3.000/3.000 | FINAL FIX WAVE: chosen applied by the recorded change at 12:00 of the warm-up day |
| 136 | A | 20261109 | median | final chosen values (gentler shape); 14 measured days | w12=3.0871 w19=2.6238 b12=0.9929 b19=0.9957 w10=1.2762 w14-17=1.0849 night=0.0898 short=0 open=1.0 ow12=3.0871 ow19=2.6238 share=0.518 | arrivals 10416, served 5396; left on arrival: chose_to_leave:10, no_compatible_main:281, no_open_stall:3, nothing_affordable:2758, nothing_available:13, wait_too_long:1824; main_failed 131; equivalents 1.876 to 1.899; scale 3.000 to 3.000 | FINAL FIX WAVE: 14 measured days, through the wrapper (ledger and cancelled trays) |
| 137 | A | 20261109 | median | final chosen values (gentler shape); --set demand.arrivals_per_equivalent=90 | w12=0.7956! w19=0.6689! b12=0.6289! b19=0.5356! w10=0.2978! w14-17=0.2607! night=0.045 short=0 open=1.0 ow12=0.7956 ow19=0.6689 share=0.6173 | arrivals 810, served 500; left on arrival: chose_to_leave:1, no_compatible_main:30, nothing_affordable:198, wait_too_long:75; main_failed 7; equivalents by day 1.902/1.902/1.902; scale by day 3.000/3.000/3.000 | SENSITIVITY: arrivals per equivalent back at 90 |
| 138 | B | 20261109 | - | final chosen values (gentler shape) with the market targets and caps at today's values | na_share=0.6027! day0=85 share=0.1452 | arrivals 2232, served 324; left on arrival: chose_to_leave:1, no_compatible_main:2, nothing_affordable:533, nothing_available:1150, wait_too_long:222; main_failed 0; equivalents by day 0.657/0.618/0.611; scale by day 3.000/3.000/3.000 | SENSITIVITY: market targets and caps back at today's |
| 139 | A | 20261109 | salmon (--cuisine) | final chosen values (gentler shape) | w12=1.5622! w19=1.8467! b12=0.8778 b19=0.7667! w10=0.7444 w14-17=0.5615 night=0.0965 short=0 open=1.0 ow12=1.5622 ow19=1.8467 share=0.4624 | arrivals 2232, served 1032; left on arrival: chose_to_leave:3, no_compatible_main:25, nothing_affordable:638, nothing_available:3, wait_too_long:506; main_failed 25; equivalents by day 1.883/1.887/1.868; scale by day 3.000/3.000/3.000 | HARDER BRACKET: --cuisine coast_salish (roasted_salmon, 1220, second dearest unused starter) |
| 140 | A | 7 | salmon (--cuisine) | final chosen values (gentler shape) | w12=2.1644! w19=1.4156! b12=0.96 b19=0.8489! w10=0.9467 w14-17=0.5133 night=0.0909 short=0 open=1.0 ow12=2.1644 ow19=1.4156 share=0.4915 | arrivals 2232, served 1097; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:3, nothing_affordable:586, nothing_available:3, wait_too_long:498; main_failed 23; equivalents by day 1.885/1.873/1.874; scale by day 3.000/3.000/3.000 | HARDER BRACKET: --cuisine coast_salish (roasted_salmon, 1220, second dearest unused starter) |
| 141 | A | 12345 | salmon (--cuisine) | final chosen values (gentler shape) | w12=1.7889! w19=1.82! b12=0.8733 b19=0.9222 w10=0.6511 w14-17=0.8259 night=0.098 short=0 open=1.0 ow12=1.7889 ow19=1.82 share=0.4816 | arrivals 2232, served 1075; left on arrival: chose_to_leave:3, no_compatible_main:20, nothing_affordable:609, nothing_available:3, wait_too_long:503; main_failed 19; equivalents by day 1.891/1.888/1.893; scale by day 3.000/3.000/3.000 | HARDER BRACKET: --cuisine coast_salish (roasted_salmon, 1220, second dearest unused starter) |
| 142 | A | 20261109 | mexican (--cuisine) | final chosen values (gentler shape) | w12=3.7511 w19=4.2511 b12=1.0 b19=1.0 w10=1.3111 w14-17=1.26 night=0.0728 short=0 open=1.0 ow12=3.7511 ow19=4.2511 share=0.5228 | arrivals 2232, served 1167; left on arrival: chose_to_leave:1, no_compatible_main:67, nothing_affordable:573, nothing_available:3, wait_too_long:393; main_failed 27; equivalents by day 1.893/1.894/1.891; scale by day 3.000/3.000/3.000 | EASIER BRACKET: --cuisine mexican (bean_tacos, 850, cheapest unused starter) |
| 143 | A | 7 | mexican (--cuisine) | final chosen values (gentler shape) | w12=3.5333 w19=3.58 b12=0.9911 b19=1.0 w10=1.3644 w14-17=1.503 night=0.0941 short=0 open=1.0 ow12=3.5333 ow19=3.58 share=0.5314 | arrivals 2232, served 1186; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:1, nothing_affordable:552, nothing_available:3, wait_too_long:396; main_failed 22; equivalents by day 1.896/1.886/1.897; scale by day 3.000/3.000/3.000 | EASIER BRACKET: --cuisine mexican (bean_tacos, 850, cheapest unused starter) |
| 144 | A | 12345 | mexican (--cuisine) | final chosen values (gentler shape) | w12=3.3867 w19=3.2956 b12=1.0 b19=1.0 w10=1.4511 w14-17=1.4844 night=0.133 short=0 open=1.0 ow12=3.3867 ow19=3.2956 share=0.5399 | arrivals 2232, served 1205; left on arrival: chose_to_leave:3, no_compatible_main:60, nothing_affordable:552, nothing_available:3, wait_too_long:387; main_failed 23; equivalents by day 1.896/1.887/1.893; scale by day 3.000/3.000/3.000 | EASIER BRACKET: --cuisine mexican (bean_tacos, 850, cheapest unused starter) |
| 145 | A | 20261109 | median + 1 extra | final chosen values (gentler shape); --extra-stalls 1 | w12=1.6556! w19=2.12! b12=0.92 b19=0.92 w10=0.4911! w14-17=0.8141 night=0.0699 short=0 open=1.0 ow12=2.0367 ow19=2.05 share=0.5645 | arrivals 2232, served 1260; left on arrival: chose_to_leave:1, no_compatible_main:61, no_open_stall:4, nothing_affordable:599, nothing_available:3, wait_too_long:282; main_failed 21; equivalents by day 2.356/2.349/2.346; scale by day 3.000/3.000/3.000; noon arrivals a day 90.0 over 4.00 open stalls = 22.50 per stall; mean daily profit: reference 46078; extra-1 (javanese, 940) 43702 | MORE STALLS: 1 extra owner stall beside the reference |
| 146 | A | 20261109 | median + 2 extra | final chosen values (gentler shape); --extra-stalls 2 | w12=1.3489! w19=1.3556! b12=0.8578 b19=0.8289! w10=0.7089 w14-17=0.5726 night=0.0662 short=0 open=1.0 ow12=1.3941 ow19=1.6044 share=0.5757 | arrivals 2232, served 1285; left on arrival: chose_to_leave:4, no_compatible_main:71, no_open_stall:4, nothing_affordable:596, nothing_available:3, wait_too_long:242; main_failed 26; equivalents by day 2.810/2.799/2.806; scale by day 3.000/3.000/3.000; noon arrivals a day 90.0 over 5.00 open stalls = 18.00 per stall; mean daily profit: reference 32469; extra-1 (javanese, 940) 29341, extra-2 (yoruba, 930) 19187 | MORE STALLS: 2 extra owner stalls beside the reference |
| 147 | A | 20261109 | median + 3 extra | final chosen values (gentler shape); --extra-stalls 3 | w12=1.0844! w19=1.4911! b12=0.7733! b19=0.8511 w10=0.4711! w14-17=0.5007 night=0.0661 short=0 open=1.0 ow12=1.0611 ow19=1.4089 share=0.5676 | arrivals 2366, served 1343; left on arrival: chose_to_leave:2, no_compatible_main:72, no_open_stall:3, nothing_affordable:611, nothing_available:3, wait_too_long:309; main_failed 22; equivalents by day 3.264/3.256/3.263; scale by day 3.023/3.264/3.256; noon arrivals a day 95.0 over 6.00 open stalls = 15.83 per stall; mean daily profit: reference 25789; extra-1 (javanese, 940) 19331, extra-2 (yoruba, 930) 12438, extra-3 (sichuan, 950) 24064 | MORE STALLS: 3 extra owner stalls beside the reference |
| 148 | A | 20261109 | median + 5 extra | final chosen values (gentler shape); --extra-stalls 5 | w12=1.3689! w19=1.2444! b12=0.8711 b19=0.8889 w10=0.3533! w14-17=0.6111 night=0.0616 short=0 open=1.0 ow12=1.3204 ow19=1.2693 share=0.5623 | arrivals 3016, served 1696; left on arrival: chose_to_leave:3, no_compatible_main:81, no_open_stall:21, nothing_affordable:777, nothing_available:9, wait_too_long:397; main_failed 31; equivalents by day 4.171/4.158/4.138; scale by day 3.835/4.171/4.158; noon arrivals a day 121.7 over 8.00 open stalls = 15.21 per stall; mean daily profit: reference 34077; extra-1 (javanese, 940) 20754, extra-2 (yoruba, 930) 9636, extra-3 (sichuan, 950) 30396, extra-4 (ethiopian, 920) 14725, extra-5 (european, 920) 11632 | MORE STALLS: 5 extra owner stalls beside the reference |
| 149 | A | 7 | median + 2 extra | final chosen values (gentler shape); --extra-stalls 2 | w12=1.5133! w19=1.4044! b12=0.8378! b19=0.8511 w10=0.3778! w14-17=0.5563 night=0.0702 short=0 open=1.0 ow12=1.5363 ow19=1.4919 share=0.569 | arrivals 2232, served 1270; left on arrival: chose_to_leave:5, no_compatible_main:69, no_open_stall:3, nothing_affordable:583, nothing_available:3, wait_too_long:272; main_failed 27; equivalents by day 2.806/2.805/2.810; scale by day 3.000/3.000/3.000; noon arrivals a day 90.0 over 5.00 open stalls = 18.00 per stall; mean daily profit: reference 30300; extra-1 (javanese, 940) 27202, extra-2 (yoruba, 930) 18530 | MORE STALLS: 2 extra owner stalls beside the reference |
| 150 | A | 12345 | median + 2 extra | final chosen values (gentler shape); --extra-stalls 2 | w12=1.4444! w19=1.6711! b12=0.8578 b19=0.8933 w10=0.5222 w14-17=0.6296 night=0.0772 short=0 open=1.0 ow12=1.7156 ow19=1.8178 share=0.5874 | arrivals 2232, served 1311; left on arrival: chose_to_leave:2, no_compatible_main:67, no_open_stall:1, nothing_affordable:549, nothing_available:3, wait_too_long:280; main_failed 20; equivalents by day 2.808/2.808/2.810; scale by day 3.000/3.000/3.000; noon arrivals a day 90.0 over 5.00 open stalls = 18.00 per stall; mean daily profit: reference 34666; extra-1 (javanese, 940) 30966, extra-2 (yoruba, 930) 21162 | MORE STALLS: 2 extra owner stalls beside the reference |
| 151 | B | 20261109 | - | final chosen values (gentler shape); --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7 | na_share=0.0022 day0=288 share=0.3678 | arrivals 2232, served 821; left on arrival: chose_to_leave:3, no_compatible_main:83, no_open_stall:90, nothing_affordable:565, nothing_available:3, wait_too_long:648; main_failed 16; equivalents by day 1.383/1.414/1.351; scale by day 3.000/3.000/3.000 | SENSITIVITY (added so the report's table is all at the chosen values): starter shifts back at today's |
| 152 | B | 20261109 | - | final chosen values (gentler shape); --set npc.fallback_trays_per_day=10 | na_share=0.0023 day0=255 share=0.4091 | arrivals 2232, served 913; left on arrival: chose_to_leave:2, no_compatible_main:72, no_open_stall:28, nothing_affordable:577, nothing_available:3, wait_too_long:618; main_failed 20; equivalents by day 1.388/1.412/1.403; scale by day 3.000/3.000/3.000 | SENSITIVITY (added so the report's table is all at the chosen values): fallback back at 10 |
| 153 | A | 20261109 | median | final chosen values (gentler shape); --hours 9-21 | w12=2.3889! w19=0.3489! b12=0.9578 b19=0.0267! w10=1.1111 w14-17=0.9281 night=0.0622 short=0 open=0.8333! ow12=2.3889 ow19=0.3489 share=0.5242 | arrivals 2232, served 1170; left on arrival: chose_to_leave:4, no_compatible_main:70, no_open_stall:6, nothing_affordable:610, nothing_available:3, wait_too_long:347; main_failed 20; equivalents by day 1.933/1.932/1.914; scale by day 3.000/3.000/3.000 | FINDING 1 at the chosen values (added beyond the requested list): the design's 09:00-21:00 schedule; open share by hour 10:1.0, 12:1.0, 14:1.0, 15:1.0, 16:1.0, 19:0.0; exit status 1 by design |
| 154 | A | 424242 | median | sharper alternative: chosen values with --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | w12=3.2489 w19=2.9889 b12=0.9756 b19=0.9978 w10=0.8089 w14-17=1.1044 night=0.0872 short=0 open=1.0 ow12=3.2489 ow19=2.9889 share=0.5181 | arrivals 2268, served 1175; left on arrival: chose_to_leave:3, no_compatible_main:82, nothing_affordable:585, nothing_available:3, wait_too_long:393; main_failed 27; equivalents by day 1.882/1.894/1.893; scale by day 3.000/3.000/3.000 | HELD-OUT SEED, sharper alternative (added beyond the requested list, for a like-for-like column) |
| 155 | B | 424242 | - | sharper alternative: chosen values with --set demand.arrivals_per_equivalent=252 --set demand.hourly_weights=3,2,1,0,0,2,3,5,7,8,11,19,34,17,12,12,12,14,19,33,15,10,8,5 | na_share=0.0022 day0=290 share=0.3977 | arrivals 2268, served 902; left on arrival: chose_to_leave:3, no_compatible_main:64, no_open_stall:21, nothing_affordable:595, nothing_available:3, wait_too_long:657; main_failed 21; equivalents by day 1.385/1.393/1.406; scale by day 3.000/3.000/3.000 | HELD-OUT SEED, sharper alternative (added beyond the requested list, for a like-for-like column) |

## Runs not in the table

- Before run 1, the same command as run 1 was run once directly (not through
  the logging helper); its output was identical to run 1.
- Run 21 is not a run of a committed driver: it used a scratch copy of the old
  driver whose only change forced the reference owner's cuisine. It prompted
  the reference-cuisine ruling; no value was chosen from it.
- Runs 64, 101 and 136 were started through the wrapper script below, which calls
  the driver's own `Hall.run` and `CLI.print` and then prints what the command
  line does not: the midnight ledger the driver already collects (cash and
  arrears per restaurant) and a tally of `tray_cancelled` and
  `dessert_cancelled` events by reason and hall hour read from the run's
  committed events. (Run 64 used an earlier version that printed only the
  ledger.)
- Runs 110 and 111 check that the report's reproduction commands give the
  earlier runs exactly: run 110 repeats run 1 through `--cuisine
  coast_salish` on the current driver, and run 111 repeats run 77 through
  `--set` on the final chosen values. Both match their originals in every
  verdict row and count.
- The acceptance test (`test/feud_hall/scripts/customer_acceptance_test.exs`)
  makes one run A and one run B each time it is run. It was run three times
  against the first chosen values (once with today's values in their place to
  see it fail) and twice against the final values.
- One run with no measured day was made by hand to read the driver's new
  header line.

Counting those, 123 driver runs were made by the task, and the controller made run 124 afterwards: 124 of a budget of 150.

In the final fix wave (runs 125 to 155; the budget was raised to 200):

- Run 125 was made twice. The first was discarded because the driver's new
  per-stall list counted the warm-up day's ingredient shortage; its verdict
  rows and counts were identical to the run 125 in the table.
- Runs 151 to 155 were not in the wave's requested list. Runs 151 and 152
  repeat the starter-shift and fallback reverts at the gentler values so that
  the report's sensitivity table is measured at one set of values; run 153
  repeats run 124 (the design's 09:00 to 21:00 schedule) at the gentler
  values; runs 154 and 155 measure the sharper alternative on the held-out
  seed, so that the two day shapes are compared on the same four seeds.
- The held-out seed, 424242, was used for no choice of value: it was first run
  after the gentler values were written into the code.
- The acceptance test was run five times in this wave (ten driver runs): at
  the gentler values before and after its row lists were restructured, twice
  with its seed changed to 7 to see it fail (it failed once the documented
  miss for seed 7 was removed), and once in the final checks.
- The short runs inside `customer_sim_test.exs` (at most one measured day) are
  not counted, as before.

Counting those, 42 driver runs were made in the wave: 166 of a budget of 200.

### The wrapper for runs 64, 101 and 136

Saved outside the repository as `long_run.exs` and run from `server/`:

    mix run --no-start PATH/long_run.exs -- --run a --tuning chosen --days 14 --seed 20261109

```elixir
# Scratch wrapper: one ordinary driver run (same Hall.run and printing as the CLI), then the
# midnight ledger the driver already collects and a tally of cancelled trays read from the committed events.
System.put_env("CUSTOMER_SIM_NO_MAIN", "1")
Code.require_file("scripts/customer_sim.exs")
alias FeudHall.CustomerSim.{CLI, Hall}
alias FeudHall.Domain.Clock
alias FeudHall.Infrastructure.HallAuthority
{:ok, args} = CLI.parse(System.argv())
{:ok, tuning} = CLI.tuning(args.tuning, args.set)
opts = %{run: args.run, tuning: tuning, via: args.via, days: args.days, seed: args.seed, hours: args.hours, cuisine: args.cuisine, extra_stalls: args.extra_stalls}
{:ok, result} = Hall.run(opts)
{store_mod, store} = HallAuthority.store(result.authority)
{:ok, batches} = store_mod.read_from(store, 0)
GenServer.stop(result.authority)
CLI.print(result, args)
if args.json, do: File.write!(args.json, CLI.json(result, args))
IO.puts("\nLedger at each midnight (day N's row is the end of day N-1): cash, arrears")
for {day, ledger} <- Enum.sort(result.stats.ledger) do
  cells = ledger |> Enum.sort() |> Enum.map_join("  ", fn {id, l} -> "#{id} #{l.cash}/#{l.arrears}" end)
  IO.puts("midnight #{day}: #{cells}")
end
measured = for b <- batches, b.hall_ms != nil and b.hall_ms > Clock.day(), do: b
cancels = for b <- measured, %{type: t} = e <- b.events, t in [:tray_cancelled, :dessert_cancelled], do: {t, e.reason, div(rem(b.hall_ms - 1, Clock.day()), Clock.hour()), e}
IO.puts("\nCancelled trays and desserts on measured days, by type and reason: #{inspect(Enum.frequencies_by(cancels, fn {t, r, _, _} -> {t, r} end))}")
IO.puts("By reason and hall hour: #{inspect(cancels |> Enum.frequencies_by(fn {_, r, h, _} -> {r, h} end) |> Enum.sort())}")
waste = for {:tray_cancelled, _, _, e} <- cancels, c <- e.components, reduce: 0, do: (acc -> acc + c.waste_cost)
started = Enum.count(cancels, fn {t, _, _, e} -> t == :tray_cancelled and Enum.any?(e.components, &(&1.waste_cost > 0)) end)
IO.puts("Cancelled trays with ingredients already consumed: #{started}; waste cost written off: #{waste}")
finals = for b <- measured, %{type: :visit_finalized} = e <- b.events, do: e.reason
IO.puts("Visits finalized on measured days by reason: #{inspect(Enum.frequencies(finals))}")
breaks = for b <- measured, %{type: :staff_condition_changed} = e <- b.events, e.condition == :protective_break, do: {e.stall_id, div(rem(b.hall_ms, Clock.day()), Clock.hour())}
IO.puts("Protective breaks by stall and hall hour: #{inspect(Enum.frequencies(breaks) |> Enum.sort())}")
IO.puts("problems: #{inspect(result.problems)}")
```
