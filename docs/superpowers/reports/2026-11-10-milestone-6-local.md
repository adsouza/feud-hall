# Milestone 6 local release evidence

The probes ran on an Apple M4 with macOS 27.0.1 and loopback PostgreSQL 18.6.
The capacity run used Elixir 1.20.4 and two BEAM schedulers. Its worktree base
was `69f8ef2` and the measured source SHA-256 was
`edcfbacd96894e4816ee273eda24514c02602c7a823c00a8fc8007abb1bf1129`.
The source hash describes the measured code and fixture. It does not identify
a published release.

## Session peaks

Each scenario made three bursts of 450 authenticated HTTP reads on established
connections. The first burst also sent 30 ordinary owner presence commands.
Each response was checked against its expected account and private restaurant,
visit, or shift. Both halls had 150 occupied stalls, 150 funded dining visits,
and 150 active paid helper shifts.

| Layout | Owner principals | Highest state-read p95 | Owner heartbeat p95 | Slowest owner heartbeat |
| --- | ---: | ---: | ---: | ---: |
| One stall per owner | 150 | 499.91 ms | 351.60 ms | 354.97 ms |
| Three stalls per owner | 50 | 409.14 ms | 498.67 ms | 500.52 ms |

The expansion sample exceeded the proposed 500 ms command target once.
These timings cover synchronized requests at a fixed gameplay instant.
Sustained traffic and other command types still need release measurements.
The source fingerprints for the two HTTP probes were
`5bae67762254e5b40685bcc5c6db457b350185e59a707f758a8c33c454581c79`
and `0995014709b147dbd9834cd5696fad68a47074d78cc70e584854e1736038b1b4`.

## Launch simulation and restore

The separate launch-catalog run used 150 managed NPC stalls across all 24
cuisines. One game day processed 13,500 arrivals and 96,977 events, including
2,380 served main-only trays, 341 served paired trays, 323 served desserts and
23 contested market clearings. The p95 wake took 212 ms and the p95 append
took 8 ms. The largest sampled projector backlog was 160 batches, and the
combined sampled peak stayed below 1.0 GiB.

| Recovery measurement | Observed |
| --- | ---: |
| Genesis replay of 102,933 events at the recovery cut | 5.48 s |
| Snapshot startup with 336 tail batches, including live reconciliation | 185 ms |
| PostgreSQL logical backup size | 5.52 MB |
| Restore the backup to a separate disposable database | 723 ms |
| Rebuild balances, inventory, and daily activity after restore | 7.39 s |

The restored state and projection fingerprints matched the source. The
rebuild reproduced the restored projections. The archive contains one game
day and its recovery tail. The proposed 30-real-day history and protected
operational backups still need production-like qualification.

## Client and release checks

The assembled local release ran its migration entry point and served
`/healthz` and protocol 1. An ad-hoc signed Apple-silicon Mac app connected to
that isolated hall and displayed the English and Japanese interfaces.
Four focused Chromium journeys passed, including WebGL fallback and rejection
of a copied revoked cookie. The Japanese font loaded from the packaged web
assets. There were 183 passing focused backend checks and three passing Rust
transport checks. A curated mutation that bypassed the replay page cutoff
failed the page-boundary test.

Hosted package builds, Linux install and full gameplay verification, native
Japanese IME, reference-GPU frame rates, and live Render qualification remain
open. Follow the [reproduction commands](../../TESTING.md#release-qualification-commands)
for the next run.
