# Milestone 2C capacity measurement

Measured locally on 2026-11-10. The three-day run completed with 150 occupied
stalls, 40,500 simulated arrivals, and 7,779 served main trays. The slowest of
10,800 wake-ups took 450.14 ms. Restart from the latest verified snapshot took
51.64 ms, compared with the proposed 30-second target. The owner accepted these
results on 2026-11-10, completing Milestone 2.
[Milestone 2 design](../specs/2026-11-09-milestone-2-design.md#goals).

## Workload and method

The benchmark initializes 150 restaurants through `HallAuthority`, one stall
per restaurant and 50 NPCs of each of the three existing planner profiles.
The first pilot, with the ordinary catalog floor of three business equivalents,
produced 270 arrivals and zero served trays over one game day. The benchmark
catalog sets the floor to 150 equivalents and scales the wholesale replenishment
caps by 50 to keep the same baseline cap per equivalent. It schedules 13,500
arrivals per game day and uses the ordinary menu, meal peaks, cleaning, NPC
planning, wholesale requests and clearing, kitchen, and settlement rules.

An injected clock advances by exactly one available-service second for each
manual authority wake-up. A measured wake includes simulation, synchronous
projections, appends, due NPC plans, and any snapshot work triggered during the
call. Append timings cover the PostgreSQL adapter call. The asynchronous daily
activity projector runs on a separate connection. The driver starts a catch-up
when none is active and samples its backlog every ten service seconds.
Elapsed throughput includes the driver and those sampling reads. An in-process
diagnostic sink records snapshot timings and selected failure codes.

The driver checks complete game days and cleaning boundaries, scheduled arrival
counts, and positive counts for served main-only trays, served paired trays,
desserts, and stock-contended clearings. After the measured days it advances
another 299 service seconds to exercise a nonempty snapshot tail, stops the
writer, and waits for the projector to catch up. It checks projection totals
against event counts, compares a full genesis replay to the live hall and control
state at the same committed head, then restarts the authority from the latest
verified snapshot. The restarted state must agree with genesis plus the newly
committed recovery suffix.

Run from `server/` with the pinned Elixir and OTP versions, installed locked
dependencies, and the existing local PostgreSQL 18 server.

```sh
python3 scripts/capacity_bench.py --output /tmp/feud-hall-capacity.json
```

The output path must be new. The launcher creates and drops `feud_hall_bench`,
refuses a database that already exists under that name, and samples the combined
RSS of BEAM, PostgreSQL and the launcher once a second. It stops the benchmark
process above 2 GiB. The JSON records the Git revision, runtime and harness source
fingerprint, catalog hash, machine and database settings, and per-day metrics.

This accelerated local workload covers the Milestone 2 shared simulation. The
450-session workload, staffed kitchen and helpers, live transport, production
diagnostic export, Render hardware, and 30-real-day replay belong to later
qualification. Rates below describe only this run.

## Measured results

The measured period began after 152 bootstrap batches. Each game day
represented 3,600 seconds of available-service time. The three days processed
in 482.55 wall seconds, or 22.38 service seconds per wall second. The run
sustained 44.76 committed batches and 557.75 events per wall second. Encoded
event payloads averaged 132.38 KiB per wall second.

| Game day | Arrivals | Main trays served | Desserts served | Batches | Events | Encoded payload bytes | Events per service second | Payload KiB per service second |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 13,500 | 2,552 | 378 | 7,200 | 89,674 | 20,962,722 | 24.91 | 5.69 |
| 2 | 13,500 | 2,602 | 407 | 7,200 | 89,778 | 22,217,214 | 24.94 | 6.03 |
| 3 | 13,500 | 2,625 | 412 | 7,200 | 89,693 | 22,232,469 | 24.91 | 6.03 |
| Total | 40,500 | 7,779 | 1,197 | 21,600 | 269,145 | 65,412,405 | 24.92 | 5.91 |

Served trays included 6,325 mains alone and 1,454 mains with drinks. Seventy-one
clearing intervals recorded at least one stock-exhausted shortfall. The
simulation recorded `nothing_available` for 28,081 departures, so the measured
kitchen workload reflects constrained supply and availability.

| Timing | Samples | p50 | p95 | p99 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| PostgreSQL append | 21,600 | 1.55 ms | 8.07 ms | 9.89 ms | 87.12 ms |
| Authority wake-up | 10,800 | 33.08 ms | 131.72 ms | 181.79 ms | 450.14 ms |
| Snapshot write and verification | 41 | 50.35 ms | 58.32 ms | 62.64 ms | 62.64 ms |

Zero wake-ups exceeded either one second or five seconds. The slowest occurred
at 13:00 on day two, an hourly NPC planning and market-clearing boundary.
Snapshot timing includes encoding, storage, reading back, verification, and
pruning. The benchmark recorded no storage, scheduler gap, fencing, planner,
or snapshot failures.

### Storage and projection

| Checkpoint | Public table space | Public index space |
| --- | ---: | ---: |
| After bootstrap | 0.65 MiB | 0.35 MiB |
| After day 1 | 44.05 MiB | 10.97 MiB |
| After day 2 | 86.34 MiB | 21.98 MiB |
| After day 3 | 129.23 MiB | 33.40 MiB |

At the end of day three, the events relation accounted for 115.68 MiB of table
space and 29.85 MiB of indexes. Receipts occupied 8.73 MiB plus 1.30 MiB of
indexes, and batch records occupied 1.84 MiB plus 1.78 MiB of indexes. These
are PostgreSQL relation sizes. The encoded-payload counts above measure just
event payload text.

The sampled daily activity projector backlog was 10 batches at p50 and 160 at
p95, p99, and maximum across 1,080 samples. At the recovery cut it took 8.33 ms
to finish draining, reached position 22,201, and matched the committed visit and
tray counts. This backlog is in batch positions under an accelerated driver.

### Recovery and memory

The recovery cut at position 22,201 held 274,029 events, including bootstrap
and the extra 299 service seconds. Full replay through `CommandWorkflow.open/2`
took 4.55 seconds and reproduced the live hall and control state exactly.
The latest verified snapshot held 2,177,473 bytes at position 21,845. The
previous verified snapshot held 2,107,027 bytes at position 21,245. Restart
used the latest snapshot and replayed 356 later batches in its 51.64 ms
start-up, including fencing and reconciliation. The restarted state matched
genesis replay plus the two newly committed recovery batches at position 22,203.

Peak sampled BEAM plus PostgreSQL RSS was 1.48 GiB. Including the launcher,
the peak was 1.50 GiB against the 2 GiB guard. The once-per-second sum includes
PostgreSQL shared pages counted across processes.

### Environment and inputs

Apple M4 (`Mac16,10`, 10 logical CPUs, 16 GiB RAM), macOS 27.0.1, Elixir
1.20.4, OTP 29.1, and PostgreSQL 18.6 (Homebrew). PostgreSQL ran locally with
128 MiB shared buffers, `fsync`, `synchronous_commit`, and `full_page_writes`
enabled, and `wal_compression` off. Recovery used the same running database
server after the workload.

- Base revision `29fefd75b4967a20354293688056f5180cebacad`
- Runtime and harness SHA-256 `b80e7ab33201650c477335cfae8bdd634fc67f73afdb8831df65f76a76de7e2d`
- Benchmark catalog SHA-256 `bd4ab4db47d624ce5b91bb776593b09074d037e95154df0cb7409885b6a20288`

The benchmark exited successfully and dropped its database. A separate check
confirmed that an existing database under the benchmark name kept its sentinel
row when the launcher refused to run. All 146 focused tests in the hall
authority, daily activity projector, market, and demand forecast files passed
against a separate disposable database.
