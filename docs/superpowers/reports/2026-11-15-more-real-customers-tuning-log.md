# More real customers: tuning log

Every run of the customer driver made while choosing the values in
[the report](2026-11-15-more-real-customers.md), in the order they were run.
One line per run. All runs are from `server/` at commit 316500e plus the
working tree of this change, one at a time, with one warm-up day and three
measured game days unless the line says otherwise:

    mix run --no-start scripts/customer_sim.exs -- --run a|b --tuning current|chosen|FILE --days 3 --seed SEED

## How to read a line

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
- `chosen`: `Tuning.chosen/0`, which is `arrivals 249; weights
  3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5; market 100;
  fallback 50; shifts mainstream 11-23, premium 17-3`. Runs 41 to 46 are the
  same values before they were written into the code, and runs 54 to 59
  repeat them through `--tuning chosen` with identical results.
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

**Measured** is the total over the measured days: arrivals, mains served, and
arrivals who left without ordering, by reason.

## Runs

| # | Run | Seed | Tuning | Verdict | Measured | Why |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | A | 20261109 | today's values | w12=0.3733! w19=0.4333! b12=0.3111! b19=0.4089! w10=0.1533! w14-17=0.2215! night=0.067 short=31! open=1.0 share=0.379 | arrivals 810, served 307; left on arrival: chose_to_leave:1, no_compatible_main:3, nothing_affordable:280, nothing_available:138, wait_too_long:80 | baseline |
| 2 | B | 20261109 | today's values | na_share=0.2884! day0=88 share=0.3321 | arrivals 810, served 269; left on arrival: chose_to_leave:1, no_compatible_main:1, nothing_affordable:303, nothing_available:156, wait_too_long:80 | baseline |
| 3 | A | 7 | today's values | w12=0.1889! w19=0.0911! b12=0.1889! b19=0.0756! w10=0.2844! w14-17=0.1674! night=0.0317 short=536! open=1.0 share=0.3926 | arrivals 810, served 318; left on arrival: no_compatible_main:2, nothing_affordable:301, nothing_available:113, wait_too_long:76 | baseline |
| 4 | B | 7 | today's values | na_share=0.3819! day0=95 share=0.3481 | arrivals 810, served 282; left on arrival: chose_to_leave:1, nothing_affordable:257, nothing_available:202, wait_too_long:69 | baseline |
| 5 | A | 12345 | today's values | w12=0.5956! w19=0.1022! b12=0.4333! b19=0.1022! w10=0.3067! w14-17=0.2422! night=0.0435 short=1405! open=1.0 share=0.4012 | arrivals 810, served 325; left on arrival: chose_to_leave:1, no_compatible_main:5, nothing_affordable:293, nothing_available:121, wait_too_long:64 | baseline |
| 6 | B | 12345 | today's values | na_share=0.3553! day0=86 share=0.3432 | arrivals 810, served 278; left on arrival: no_compatible_main:1, nothing_affordable:270, nothing_available:189, wait_too_long:72 | baseline |
| 7 | B | 20261109 | fallback 100; market 50 | na_share=0.0028 day0=166 share=0.5642 | arrivals 810, served 457; left on arrival: chose_to_leave:3, no_compatible_main:27, nothing_affordable:220, nothing_available:1, wait_too_long:100 | supply first: 50 portions per equivalent of every recipe line, fallback 100 |
| 8 | A | 20261109 | fallback 100; market 50 | w12=0.2556! w19=0.3244! b12=0.2556! b19=0.3089! w10=0.2556! w14-17=0.2207! night=0.0535 short=10! open=1.0 share=0.5963 | arrivals 810, served 483; left on arrival: chose_to_leave:1, no_compatible_main:7, nothing_affordable:212, nothing_available:1, wait_too_long:101 | supply first, run A |
| 9 | A | 20261109 | arrivals 180; fallback 100; market 50 | w12=1.1133! w19=0.6333! b12=0.6333! b19=0.4844! w10=0.4489! w14-17=0.3467! night=0.0696 short=10! open=1.0 share=0.513 | arrivals 1620, served 831; left on arrival: chose_to_leave:1, no_compatible_main:11, nothing_affordable:446, wait_too_long:318 | then arrivals x2 |
| 10 | A | 20261109 | arrivals 270; fallback 50; market 100 | w12=1.7667! w19=1.48! b12=0.9178 b19=0.8644 w10=1.0956 w14-17=0.5911 night=0.1 short=0 open=1.0 share=0.4374 | arrivals 2430, served 1063; left on arrival: chose_to_leave:3, no_compatible_main:38, no_open_stall:7, nothing_affordable:663, wait_too_long:631 | explore arrival scale with ample supply |
| 11 | A | 20261109 | arrivals 450; fallback 50; market 100 | w12=3.4311 w19=3.6044 b12=0.9933 b19=1.0 w10=2.3756! w14-17=1.3385 night=0.2613 short=0 open=1.0 share=0.3244 | arrivals 4050, served 1314; left on arrival: chose_to_leave:2, no_compatible_main:154, no_open_stall:99, nothing_affordable:1115, nothing_available:3, wait_too_long:1308 | explore arrival scale with ample supply |
| 12 | A | 20261109 | arrivals 630; fallback 50; market 100 | w12=4.4067 w19=4.5222! b12=1.0 b19=1.0 w10=3.1578! w14-17=2.3089! night=0.3117! short=0 open=1.0 share=0.2476 | arrivals 5670, served 1404; left on arrival: chose_to_leave:6, no_compatible_main:317, no_open_stall:298, nothing_affordable:1624, nothing_available:4, wait_too_long:1943 | explore arrival scale with ample supply |
| 13 | A | 20261109 | arrivals 298; fallback 50; market 100; weights 2,1,1,0,0,2,3,4,5,7,16,20,42,20,19,19,19,19,20,42,17,10,7,3 | w12=2.2111! w19=2.6667 b12=0.8867 b19=0.9778 w10=1.2067 w14-17=1.0659 night=0.063 short=0 open=1.0 share=0.4034 | arrivals 2682, served 1082; left on arrival: chose_to_leave:2, no_compatible_main:56, no_open_stall:1, nothing_affordable:736, nothing_available:3, wait_too_long:771 | peaky shape: weights are arrivals per equivalent per hour, sized from the response of runs 008-012 |
| 14 | B | 20261109 | arrivals 298; fallback 50; market 100; weights 2,1,1,0,0,2,3,4,5,7,16,20,42,20,19,19,19,19,20,42,17,10,7,3 | na_share=0.0016 day0=270 share=0.2964 | arrivals 2682, served 795; left on arrival: chose_to_leave:4, no_compatible_main:82, no_open_stall:276, nothing_affordable:629, nothing_available:3, wait_too_long:863 | same, run B |
| 15 | B | 20261109 | arrivals 180; fallback 50; market 100 | na_share=0.0 day0=246 share=0.4722 | arrivals 1620, served 765; left on arrival: chose_to_leave:1, no_compatible_main:51, no_open_stall:18, nothing_affordable:410, wait_too_long:365 | run B served share against arrival scale, today's shape |
| 16 | B | 20261109 | arrivals 270; fallback 50; market 100 | na_share=0.0 day0=278 share=0.3613 | arrivals 2430, served 878; left on arrival: chose_to_leave:2, no_compatible_main:84, no_open_stall:112, nothing_affordable:591, wait_too_long:745 | run B served share against arrival scale, today's shape |
| 17 | A | 20261109 | arrivals 180; fallback 50; market 100 | w12=1.0978! w19=0.7267! b12=0.6022! b19=0.5911! w10=0.8222 w14-17=0.4489! night=0.0791 short=0 open=1.0 share=0.5167 | arrivals 1620, served 837; left on arrival: chose_to_leave:2, no_compatible_main:21, nothing_affordable:417, wait_too_long:332 | run A at x2 with ample supply |
| 18 | B | 20261109 | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=272 share=0.3972 | arrivals 2115, served 840; left on arrival: no_compatible_main:64, no_open_stall:80, nothing_affordable:525, wait_too_long:584 | x2.6 today's shape, today's shifts |
| 19 | B | 20261109 | arrivals 235; fallback 50; market 100; shifts mainstream 10-22, premium 17-3 | na_share=0.0 day0=300 share=0.426 | arrivals 2115, served 901; left on arrival: chose_to_leave:4, no_compatible_main:77, no_open_stall:16, nothing_affordable:592, wait_too_long:505 | same with mainstream 10-22, premium 17-3 |
| 20 | A | 20261109 | arrivals 235; fallback 50; market 100; shifts mainstream 10-22, premium 17-3 | w12=1.0578! w19=1.1667! b12=0.7311! b19=0.8422! w10=0.7356 w14-17=0.6252 night=0.0654 short=0 open=1.0 share=0.4827 | arrivals 2115, served 1021; left on arrival: chose_to_leave:4, no_compatible_main:23, nothing_affordable:605, wait_too_long:439 | run A at x2.6 with mainstream 10-22, premium 17-3 |
| 21 | A | 20261109 | arrivals 235; fallback 50; market 100; REFERENCE CUISINE FORCED TO european (scratch copy of the driver); shifts mainstream 10-22, premium 17-3 | w12=1.8222! w19=2.9467 b12=0.9289 b19=0.9956 w10=0.8467 w14-17=0.8748 night=0.0726 short=0 open=1.0 share=0.5073 | arrivals 2115, served 1073; left on arrival: chose_to_leave:4, no_compatible_main:65, no_open_stall:3, nothing_affordable:563, wait_too_long:384 | evidence only: scratch copy of the driver with the reference cuisine forced to european (tomato_pasta, 920, simmer) |
| 22 | B | 20261109 | arrivals 229; fallback 50; market 100; shifts mainstream 10-22, premium 17-3; weights 2,1,1,0,0,1,2,3,4,5,8,12,14,12,8,6,6,8,12,14,10,8,5,3 | na_share=0.0 day0=290 share=0.4459 | arrivals 2061, served 919; left on arrival: chose_to_leave:2, no_compatible_main:68, no_open_stall:8, nothing_affordable:561, wait_too_long:480 | lighter 07-09 (weights 3,4,5 for 4,6,6), same rate elsewhere |
| 23 | A | 20261109 | arrivals 229; fallback 50; market 100; shifts mainstream 10-22, premium 17-3; weights 2,1,1,0,0,1,2,3,4,5,8,12,14,12,8,6,6,8,12,14,10,8,5,3 | w12=1.0756! w19=1.1067! b12=0.6667! b19=0.7222! w10=0.42! w14-17=0.543 night=0.1296 short=0 open=1.0 share=0.4925 | arrivals 2061, served 1015; left on arrival: chose_to_leave:2, no_compatible_main:22, no_open_stall:3, nothing_affordable:591, wait_too_long:408 | lighter 07-09 (weights 3,4,5 for 4,6,6), same rate elsewhere |
| 24 | A | 20261109 | arrivals 235; fallback 50; market 100 | w12=1.5089! w19=1.2978! b12=0.8467! b19=0.7889! w10=1.1556 w14-17=0.5733 night=0.1154 short=0 open=1.0 share=0.4851 | arrivals 2115, served 1026; left on arrival: chose_to_leave:3, no_compatible_main:28, nothing_affordable:560, wait_too_long:483 | today's shifts at x2.6 |
| 25 | A | 7 | arrivals 235; fallback 50; market 100 | w12=1.12! w19=1.1311! b12=0.7733! b19=0.6578! w10=0.9244 w14-17=0.6207 night=0.1102 short=0 open=1.0 share=0.4719 | arrivals 2115, served 998; left on arrival: chose_to_leave:2, no_compatible_main:35, no_open_stall:1, nothing_affordable:547, wait_too_long:516 | today's shifts at x2.6 |
| 26 | A | 12345 | arrivals 235; fallback 50; market 100 | w12=1.6756! w19=1.5556! b12=0.8644 b19=0.84! w10=0.9333 w14-17=0.5407 night=0.1017 short=0 open=1.0 share=0.4794 | arrivals 2115, served 1014; left on arrival: chose_to_leave:3, no_compatible_main:26, nothing_affordable:567, wait_too_long:486 | today's shifts at x2.6 |
| 27 | B | 7 | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=279 share=0.4 | arrivals 2115, served 846; left on arrival: no_compatible_main:68, no_open_stall:73, nothing_affordable:525, wait_too_long:586 | today's shifts at x2.6 |
| 28 | B | 12345 | arrivals 235; fallback 50; market 100 | na_share=0.0 day0=266 share=0.3948 | arrivals 2115, served 835; left on arrival: chose_to_leave:5, no_compatible_main:72, no_open_stall:48, nothing_affordable:506, wait_too_long:631 | today's shifts at x2.6 |
| 29 | A | 20261109 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.6067! w19=1.4333! b12=0.8356! b19=0.86 w10=0.9111 w14-17=0.837 night=0.0898 short=0 open=1.0 share=0.4875 | arrivals 2115, served 1031; left on arrival: chose_to_leave:2, no_compatible_main:21, nothing_affordable:599, wait_too_long:449 | mainstream 11-23, premium 17-3 at x2.6 |
| 30 | A | 7 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.34! w19=1.3067! b12=0.9 b19=0.88 w10=0.8689 w14-17=0.56 night=0.0828 short=0 open=1.0 share=0.4979 | arrivals 2115, served 1053; left on arrival: chose_to_leave:2, no_compatible_main:31, no_open_stall:8, nothing_affordable:531, wait_too_long:469 | mainstream 11-23, premium 17-3 at x2.6 |
| 31 | A | 12345 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.3511! w19=0.9644! b12=0.84! b19=0.6267! w10=0.5911 w14-17=0.5563 night=0.1487 short=0 open=1.0 share=0.4837 | arrivals 2115, served 1023; left on arrival: chose_to_leave:2, no_compatible_main:19, no_open_stall:2, nothing_affordable:583, wait_too_long:469 | mainstream 11-23, premium 17-3 at x2.6 |
| 32 | B | 20261109 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=305 share=0.4322 | arrivals 2115, served 914; left on arrival: chose_to_leave:3, no_compatible_main:55, no_open_stall:10, nothing_affordable:554, wait_too_long:564 | mainstream 11-23, premium 17-3 at x2.6 |
| 33 | B | 7 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=292 share=0.4331 | arrivals 2115, served 916; left on arrival: chose_to_leave:4, no_compatible_main:63, no_open_stall:21, nothing_affordable:541, wait_too_long:552 | mainstream 11-23, premium 17-3 at x2.6 |
| 34 | B | 12345 | arrivals 235; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0 day0=300 share=0.4284 | arrivals 2115, served 906; left on arrival: no_compatible_main:64, no_open_stall:11, nothing_affordable:555, wait_too_long:564 | mainstream 11-23, premium 17-3 at x2.6 |
| 35 | B | 20261109 | arrivals 180; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.0037 day0=254 share=0.4932 | arrivals 1620, served 799; left on arrival: chose_to_leave:1, no_compatible_main:49, no_open_stall:3, nothing_affordable:421, nothing_available:3, wait_too_long:335 | level sweep with mainstream 11-23, premium 17-3 |
| 36 | A | 20261109 | arrivals 180; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=1.1067! w19=0.5289! b12=0.6978! b19=0.4133! w10=0.6444 w14-17=0.3089! night=0.0515 short=0 open=1.0 share=0.5185 | arrivals 1620, served 840; left on arrival: chose_to_leave:4, no_compatible_main:11, no_open_stall:2, nothing_affordable:471, nothing_available:3, wait_too_long:283 | level sweep with mainstream 11-23, premium 17-3 |
| 37 | B | 20261109 | arrivals 205; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.003 day0=269 share=0.452 | arrivals 1845, served 834; left on arrival: chose_to_leave:2, no_compatible_main:64, no_open_stall:8, nothing_affordable:474, nothing_available:3, wait_too_long:444 | level sweep with mainstream 11-23, premium 17-3 |
| 38 | A | 20261109 | arrivals 205; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=0.88! w19=1.0489! b12=0.7133! b19=0.7022! w10=0.8378 w14-17=0.4341! night=0.075 short=0 open=1.0 share=0.51 | arrivals 1845, served 941; left on arrival: no_compatible_main:14, nothing_affordable:511, nothing_available:3, wait_too_long:366 | level sweep with mainstream 11-23, premium 17-3 |
| 39 | B | 20261109 | arrivals 270; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | na_share=0.002 day0=301 share=0.3844 | arrivals 2430, served 934; left on arrival: chose_to_leave:1, no_compatible_main:67, no_open_stall:42, nothing_affordable:678, nothing_available:3, wait_too_long:682 | level sweep with mainstream 11-23, premium 17-3 |
| 40 | A | 20261109 | arrivals 270; fallback 50; market 100; shifts mainstream 11-23, premium 17-3 | w12=2.2244! w19=1.8911! b12=0.9644 b19=0.8044! w10=1.2289 w14-17=0.8081 night=0.0967 short=0 open=1.0 share=0.4683 | arrivals 2430, served 1138; left on arrival: chose_to_leave:5, no_compatible_main:30, no_open_stall:12, nothing_affordable:677, nothing_available:3, wait_too_long:548 | level sweep with mainstream 11-23, premium 17-3 |
| 41 | A | 20261109 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 42 | A | 7 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.2222! w19=1.2133! b12=0.7489! b19=0.7356! w10=1.0311 w14-17=0.7593 night=0.0994 short=0 open=1.0 share=0.4886 | arrivals 2241, served 1095; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:1, nothing_affordable:574, nothing_available:3, wait_too_long:522 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 43 | A | 12345 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.5378! w19=1.4111! b12=0.84! b19=0.7978! w10=1.0089 w14-17=0.88 night=0.1211 short=0 open=1.0 share=0.49 | arrivals 2241, served 1098; left on arrival: chose_to_leave:4, no_compatible_main:18, nothing_affordable:611, nothing_available:3, wait_too_long:480 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 44 | B | 20261109 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 45 | B | 7 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=302 share=0.4163 | arrivals 2241, served 933; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:23, nothing_affordable:559, nothing_available:3, wait_too_long:619 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 46 | B | 12345 | arrivals 249; fallback 50; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=300 share=0.3976 | arrivals 2241, served 891; left on arrival: chose_to_leave:1, no_compatible_main:72, no_open_stall:49, nothing_affordable:596, nothing_available:2, wait_too_long:606 | weights as arrivals per equivalent per hour: fuller 10:00 and afternoon, lighter early morning |
| 47 | A | 20261109 | arrivals 249; fallback 50; market 25; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.5978! w19=1.8356! b12=0.9156 b19=0.9044 w10=1.5422 w14-17=0.997 night=0.1026 short=10! open=1.0 share=0.4355 | arrivals 2241, served 976; left on arrival: chose_to_leave:5, no_compatible_main:21, nothing_affordable:765, nothing_available:16, wait_too_long:448 | market size: 25 portions per equivalent |
| 48 | B | 20261109 | arrivals 249; fallback 50; market 25; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.078 day0=273 share=0.3476 | arrivals 2241, served 779; left on arrival: no_compatible_main:39, no_open_stall:16, nothing_affordable:730, nothing_available:113, wait_too_long:551 | market size: 25 portions per equivalent |
| 49 | A | 20261109 | arrivals 249; fallback 50; market 50; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | market size: 50 portions per equivalent |
| 50 | B | 20261109 | arrivals 249; fallback 50; market 50; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | market size: 50 portions per equivalent |
| 51 | B | 20261109 | arrivals 249; fallback 10; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=270 share=0.4159 | arrivals 2241, served 932; left on arrival: chose_to_leave:2, no_compatible_main:77, no_open_stall:27, nothing_affordable:598, nothing_available:3, wait_too_long:583 | fallback trays 10 |
| 52 | B | 20261109 | arrivals 249; fallback 90; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0015 day0=312 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | fallback trays 90 |
| 53 | B | 20261109 | arrivals 249; fallback 30; market 100; shifts mainstream 11-23, premium 17-3; weights 3,2,1,0,0,2,3,5,7,9,15,19,24,19,14,14,14,15,19,24,16,11,8,5 | na_share=0.0023 day0=304 share=0.4186 | arrivals 2241, served 938; left on arrival: chose_to_leave:4, no_compatible_main:77, no_open_stall:24, nothing_affordable:589, nothing_available:3, wait_too_long:584 | fallback trays 30 |
| 54 | A | 20261109 | chosen | w12=1.6467! w19=1.5022! b12=0.8422! b19=0.8467! w10=0.8689 w14-17=0.6378 night=0.078 short=0 open=1.0 share=0.4873 | arrivals 2241, served 1092; left on arrival: chose_to_leave:1, no_compatible_main:30, no_open_stall:3, nothing_affordable:577, nothing_available:3, wait_too_long:507 | FINAL: --tuning chosen, via init |
| 55 | A | 7 | chosen | w12=1.2222! w19=1.2133! b12=0.7489! b19=0.7356! w10=1.0311 w14-17=0.7593 night=0.0994 short=0 open=1.0 share=0.4886 | arrivals 2241, served 1095; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:1, nothing_affordable:574, nothing_available:3, wait_too_long:522 | FINAL: --tuning chosen, via init |
| 56 | A | 12345 | chosen | w12=1.5378! w19=1.4111! b12=0.84! b19=0.7978! w10=1.0089 w14-17=0.88 night=0.1211 short=0 open=1.0 share=0.49 | arrivals 2241, served 1098; left on arrival: chose_to_leave:4, no_compatible_main:18, nothing_affordable:611, nothing_available:3, wait_too_long:480 | FINAL: --tuning chosen, via init |
| 57 | B | 20261109 | chosen | na_share=0.0015 day0=311 share=0.4083 | arrivals 2241, served 915; left on arrival: chose_to_leave:1, no_compatible_main:80, no_open_stall:12, nothing_affordable:588, nothing_available:2, wait_too_long:619 | FINAL: --tuning chosen, via init |
| 58 | B | 7 | chosen | na_share=0.0023 day0=302 share=0.4163 | arrivals 2241, served 933; left on arrival: chose_to_leave:1, no_compatible_main:73, no_open_stall:23, nothing_affordable:559, nothing_available:3, wait_too_long:619 | FINAL: --tuning chosen, via init |
| 59 | B | 12345 | chosen | na_share=0.0015 day0=300 share=0.3976 | arrivals 2241, served 891; left on arrival: chose_to_leave:1, no_compatible_main:72, no_open_stall:49, nothing_affordable:596, nothing_available:2, wait_too_long:606 | FINAL: --tuning chosen, via init |
| 60 | A | 20261109 | chosen; applied by --via retune | w12=0.9333! w19=1.7511! b12=0.6822! b19=0.9044 w10=0.9867 w14-17=0.6407 night=0.0894 short=10! open=1.0 share=0.4752 | arrivals 2241, served 1065; left on arrival: chose_to_leave:1, no_compatible_main:23, nothing_affordable:638, nothing_available:21, wait_too_long:476 | FINAL: chosen applied by the recorded change at 12:00 of the warm-up day |
| 61 | A | 20261109 | chosen; --set demand.arrivals_per_equivalent=90 | w12=0.0933! w19=0.5111! b12=0.0933! b19=0.4467! w10=0.2444! w14-17=0.2667! night=0.0641 short=0 open=1.0 share=0.5975 | arrivals 810, served 484; left on arrival: chose_to_leave:2, no_compatible_main:10, nothing_affordable:214, wait_too_long:93 | SENSITIVITY: chosen with arrivals per equivalent back at 90 |
| 62 | B | 20261109 | chosen with the market targets and caps at today's values | na_share=0.6157! day0=85 share=0.1455 | arrivals 2241, served 326; left on arrival: chose_to_leave:5, no_compatible_main:3, nothing_affordable:520, nothing_available:1179, wait_too_long:208 | SENSITIVITY: chosen with the market targets and caps back at today's |
| 63 | B | 20261109 | chosen; --set npc.starter_shifts.mainstream=12,0 --set npc.starter_shifts.premium=19,7 | na_share=0.0022 day0=281 share=0.3695 | arrivals 2241, served 828; left on arrival: chose_to_leave:3, no_compatible_main:75, no_open_stall:92, nothing_affordable:546, nothing_available:3, wait_too_long:666 | SENSITIVITY: chosen with the starter shifts back at today's |
| 64 | A | 20261109 | chosen; 14 measured days | w12=1.5338! w19=1.2029! b12=0.8462! b19=0.7314! w10=1.0676 w14-17=0.7263 night=0.0983 short=0 open=1.0 share=0.4807 | see report: reference cash by day, no arrears, no distress | FINAL: 14 measured days, reference survival |
| 65 | A | 20261109 | chosen; --set demand.arrivals_per_equivalent=286 | w12=1.9689! w19=1.4667! b12=0.9667 b19=0.8289! w10=1.2778 w14-17=0.9941 night=0.0896 short=0 open=1.0 share=0.4495 | arrivals 2574, served 1157; left on arrival: chose_to_leave:3, no_compatible_main:25, nothing_affordable:691, wait_too_long:678 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 66 | A | 7 | chosen; --set demand.arrivals_per_equivalent=286 | w12=2.0156! w19=1.5222! b12=0.9578 b19=0.8089! w10=1.1178 w14-17=0.8207 night=0.1302 short=0 open=1.0 share=0.4491 | arrivals 2574, served 1156; left on arrival: chose_to_leave:3, no_compatible_main:37, no_open_stall:4, nothing_affordable:694, wait_too_long:651 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 67 | A | 12345 | chosen; --set demand.arrivals_per_equivalent=286 | w12=1.54! w19=1.3911! b12=0.8644 b19=0.8156! w10=1.4933 w14-17=0.9985 night=0.1057 short=0 open=1.0 share=0.4409 | arrivals 2574, served 1135; left on arrival: chose_to_leave:5, no_compatible_main:27, no_open_stall:9, nothing_affordable:724, wait_too_long:640 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 68 | B | 20261109 | chosen; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=325 share=0.3632 | arrivals 2574, served 935; left on arrival: chose_to_leave:2, no_compatible_main:96, no_open_stall:55, nothing_affordable:700, wait_too_long:763 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 69 | B | 7 | chosen; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=320 share=0.3726 | arrivals 2574, served 959; left on arrival: chose_to_leave:2, no_compatible_main:87, no_open_stall:58, nothing_affordable:673, wait_too_long:775 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 70 | B | 12345 | chosen; --set demand.arrivals_per_equivalent=286 | na_share=0.0 day0=307 share=0.3691 | arrivals 2574, served 950; left on arrival: no_compatible_main:76, no_open_stall:64, nothing_affordable:693, wait_too_long:763 | FRONTIER: chosen shape and supply with arrivals per equivalent 286 |
| 71 | A | 20261109 | chosen; --set demand.arrivals_per_equivalent=212 | w12=1.1067! w19=0.4822! b12=0.8067! b19=0.4022! w10=0.8578 w14-17=0.5748 night=0.067 short=0 open=1.0 share=0.5042 | arrivals 1908, served 962; left on arrival: chose_to_leave:2, no_compatible_main:14, nothing_affordable:544, nothing_available:3, wait_too_long:367 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 72 | A | 7 | chosen; --set demand.arrivals_per_equivalent=212 | w12=1.2711! w19=1.0911! b12=0.6911! b19=0.6911! w10=0.8222 w14-17=0.6496 night=0.1035 short=0 open=1.0 share=0.521 | arrivals 1908, served 994; left on arrival: chose_to_leave:2, no_compatible_main:20, no_open_stall:2, nothing_affordable:491, nothing_available:3, wait_too_long:381 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 73 | A | 12345 | chosen; --set demand.arrivals_per_equivalent=212 | w12=1.7644! w19=1.2644! b12=0.9089 b19=0.6489! w10=0.7311 w14-17=0.6467 night=0.1022 short=0 open=1.0 share=0.5152 | arrivals 1908, served 983; left on arrival: chose_to_leave:6, no_compatible_main:23, nothing_affordable:508, nothing_available:2, wait_too_long:367 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 74 | B | 20261109 | chosen; --set demand.arrivals_per_equivalent=212 | na_share=0.003 day0=284 share=0.4659 | arrivals 1908, served 889; left on arrival: no_compatible_main:62, no_open_stall:10, nothing_affordable:474, nothing_available:3, wait_too_long:452 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 75 | B | 7 | chosen; --set demand.arrivals_per_equivalent=212 | na_share=0.0029 day0=286 share=0.4575 | arrivals 1908, served 873; left on arrival: chose_to_leave:4, no_compatible_main:65, no_open_stall:10, nothing_affordable:482, nothing_available:3, wait_too_long:454 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |
| 76 | B | 12345 | chosen; --set demand.arrivals_per_equivalent=212 | na_share=0.0029 day0=286 share=0.4575 | arrivals 1908, served 873; left on arrival: chose_to_leave:3, no_compatible_main:56, no_open_stall:15, nothing_affordable:452, nothing_available:3, wait_too_long:489 | FRONTIER: chosen shape and supply with arrivals per equivalent 212 |

## Runs not in the table

- Before run 1, the same command as run 1 was run once directly (not through
  the logging helper); its output was identical to run 1.
- Run 21 is not a run of the committed driver: it used a scratch copy whose
  only change forces the reference owner's cuisine. It is evidence for the
  report's "What binds" section and no value was chosen from it.
- Run 64 was started through a scratch wrapper that calls the driver's own
  `Hall.run` and `CLI.print` and then prints the midnight ledger the driver
  already collects (cash and arrears per restaurant), which the command line
  does not print.
- The acceptance test (`test/feud_hall/scripts/customer_acceptance_test.exs`)
  repeats runs 54 and 57 each time it is run. It was run three times while
  writing it, once of those with today's values in place of the chosen ones
  to see it fail (which repeats runs 1 and 2).

Counting those, 83 driver runs were made, of a budget of 150.
