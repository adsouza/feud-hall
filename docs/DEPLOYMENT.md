# Feud Hall Deployment

The repository has a Render Blueprint, a container build with an explicit
migration command, and hosted native package jobs. These define release
entry points. Record live environment identifiers and qualification results
separately from the templates, without storing credentials here.

The [architecture](ARCHITECTURE.md#deployment-and-clients) owns system topology,
authority, storage/recovery, and compatibility contracts. [Testing](TESTING.md)
owns qualification and evidence. This document owns build/release sequencing and
operational procedures; [the game design](GAME_DESIGN.md#20-first-release-scope-and-implementation-order)
owns the required release scope.

## Offline single-player delivery (planned)

The server is required only for multiplayer. Current packages still contain a
network client; the procedures below describe that implemented path, including
when the development multiplayer service runs on localhost. They do not deliver
offline play yet.

Offline single-player must ship its runtime, validated content, fonts/UI assets,
and transactional local-save adapter in the client. Players must be able to
start/load without contacting Render, signing in online, obtaining an invitation,
or installing/administering Phoenix or PostgreSQL. Native packages supervise
their local runtime and stop it on quit. Browser/PWA delivery additionally needs
an executable local simulation and offline assets/storage; an install manifest
and service worker alone cannot deliver the game.

A local hall pauses while closed or suspended, resumes from its durable head
without charging elapsed wall time, and has no online economy/account imports.
Provide scoped local save locations, compatible upgrades, full-storage/corrupt-
save recovery, and validated export/import. Keep online credentials outside
those exports. Qualify fresh install, network-disabled launch, quit/relaunch,
crash recovery, and an app/content update on each supported target before
advertising offline support. Keep the existing Flatpak, `.deb`, and macOS
artifact requirements for both execution modes. See
[the execution contract](ARCHITECTURE.md#local-and-multiplayer-execution).

## Deployment shape and inputs

- For multiplayer, Render hosts the canonical Phoenix service and web client, with durable
  PostgreSQL. The simulation remains available without connected players.
  Select actual always-running capacity from measurements.
- Web and Tauri Linux/macOS clients use the same service and protocol. Desktop
  packages contain frontend assets/native integration, not another canonical
  economy. The packaged webview remains the runtime for the browser frontend.
- The web release includes usable smartphone layouts and supported phone-browser
  flows. Qualify actual mobile browser input, suspension, reconnect, and reduced
  rendering as well as desktop sizes; native iOS/Android packages remain later scope.
- Bun installs dependencies and runs frontend build scripts. Oxlint is the
  frontend linter; `bun check` and qualified Svelte diagnostics run in hosted CI
  under [the testing policy](TESTING.md#frontend-toolchain). Keep the Svelte
  compilation/build integration explicit.
- CI checks Elixir formatting with `mix format --check-formatted` and frontend
  formatting with `bun run format:check` (Prettier plus its Svelte plugin), using
  the committed configurations. These checks do not rewrite release source.
- Pin Bun, Oxlint, Prettier/its Svelte plugin, Elixir/OTP, Rust/Tauri, and native
  build/runtime inputs when
  their manifests/jobs are created. Commit the relevant lockfiles, including
  `bun.lock`; CI uses `bun install --frozen-lockfile`. Lint and test tools belong
  in the locked development toolchain, not an unpinned download at release time.
- Keep environment-specific configuration separate from the source/artifact.
  Supply database/session/email credentials through protected runtime settings;
  publish only safe examples. Include the intended service endpoint and supported
  protocol range in client release configuration.

Each release records its source revision, build/toolchain and lockfile versions,
server/client protocol compatibility, event schema/evolution support, rules/content
hashes, translation catalog version, and artifact checksums. A revision label
without the actual built artifact is insufficient for rollback or verification.

## Web and server release sequence

1. **Qualify the candidate.** Run applicable hosted CI gates from Testing against
   the exact revision. Validate content/catalogs, schema compatibility, startup
   configuration, and client protocol range. Build the server release and common
   web assets; keep their compatibility manifest with the artifacts.
2. **Establish recoverability.** Verify a consistent backup covering events,
   immutable content, protected credentials/contact records, command receipts,
   outbox/delivery tracking, and coordination records. Retain the recovery-capable
   previous binary and required decoding/content support. Backup schedules,
   retention, access, and measured recovery objectives must be set before launch.
3. **Prepare storage.** Run explicit versioned schema migrations through the
   established migration entry point. Prefer compatible additive changes. A
   failed migration leaves authoritative mutation unavailable; it cannot silently
   start a new/empty hall or fall back to mutable projections as authority.
   A migration may run alongside the old release only after proving compatibility
   with that writer and its readers. Otherwise drain/fence the old authority and
   pause gameplay clocks before migrating, carrying that unavailable interval
   into handover/recovery. Migration failure must keep the write gate closed;
   readiness on an old instance cannot reopen it against incompatible storage.
   For the Milestone 2 daily-activity attribution correction, stop any old
   daily-activity projector before migration. The migration clears its derived
   rows and resets its checkpoint. Run `Postgres.DailyActivityProjector.catch_up/1`
   with the new code and verify its checkpoint before exposing those reports.
   Before serving Milestone 5, apply the served-tray index migration and retain
   a recovery-capable binary that understands the visitor-play activation and
   staging events. Bootstrap enables them once per launch hall, including
   existing halls. A pre-M5 server cannot replay a hall after activation.
4. **Hand over authority.** Drain/stop the old authority under the defined
   availability protocol, acquire a newer database-fenced ownership epoch, and
   prevent the previous instance from appending or publishing as authority.
   A coordinator owns both hall and identity/control streams at launch.
5. **Recover before readiness.** Capture a committed head, restore a compatible
   snapshot, fold complete batches, validate recovered state, and append the
   idempotent live recovery-reconciliation batch. End stale helper control,
   settle only previously earned coverage, preserve applicable holds and remaining
   deadlines, and rebuild observed presence. Reuse the durable recovery identity
   across retries/new fencing epochs, and require fresh human-presence evidence
   before new population-driven NPC retirements. Then establish the monotonic anchor,
   declare readiness, and resume clocks/acceptance. Outage time is not catch-up
   time; scheduled cleaning is ordinary gameplay and resumes at its restored time.
6. **Serve compatible clients.** Publish matched web assets and allow the
   documented supported client range. Existing sockets/desktop builds may remain
   older; reject incompatible versions clearly. Reconnect uses bounded backoff,
   authoritative resynchronization, and same-ID resolution of uncertain commands.
7. **Verify operation.** Check readiness, one current fenced authority, healthy
   app/database scheduling, clock progress, committed receipts, projection and
   delivery lag, and relevant English/Japanese flows in an isolated release-test
   hall/environment. Production verification must avoid fabricated transactions
   or altering real businesses merely to generate test evidence. Retain results
   and monitor unexpected errors, backlog, resource use, and recovery failures.
   Qualify diagnostic collection/search and the
   [logging contract](ARCHITECTURE.md#observability-and-diagnostic-logging) for
   the exact server and browser/native builds before public release.

Prepare compatible readers/decoders before enabling new event writers, or use a
coordinated unavailable interval when mixed versions cannot safely coexist.
Activate economic content changes only at the declared safe boundary; accepted
orders retain their pinned terms. Routine restarts/redeploys must not rerun seed
grants or NPC bootstrap, reparent accounts, issue replacement credentials, or
replay external notifications.

### Render Blueprint

Import `render.yaml` into the intended Render workspace for an isolated
release-test service. The Blueprint uses an always-running web service and
private PostgreSQL 18. Its service and database sizes are starting values for
qualification. Set `FEUD_HALL_ADMIN_KEY` through Render and retain the generated
signing secret across deploys. Render supplies the canonical external origin
and the internal database URL. Set `FEUD_HALL_ORIGIN` explicitly for a custom
domain.

The pre-deploy command runs `/app/bin/feud_hall eval 'FeudHall.Release.migrate()'`.
It starts the repository for migration without starting the hall.
`/healthz` checks that the local authority has initialized, is keeping up
with the clock, and holds the current database fencing epoch. Auto-deploy is
disabled. Schedule incompatible migrations and the first handover from a
pre-M6 writer as maintenance. Stop the old writer before starting the new
one. A fenced M6 authority exits its supervisor child.

Rehearse the sequence in the release-test service before public provisioning.
Select production capacity from the measured workload and verify that the
service advances, retains existing receipts, and restores from backup.

## Native release artifacts

Build the common web frontend first. Package the same versioned client source for
Linux and macOS through hosted CI, against its declared server protocol range.
Select/document supported CPU architectures, Linux distributions, Flatpak runtime,
webview/runtime dependencies, and macOS minimum version before enabling jobs.

| Target | Required output and qualification |
| --- | --- |
| Linux Flatpak | An installable Flatpak artifact with pinned packaging/runtime inputs, correct app identity/icon and permissions; install, launch, network/server connection, rendering/list fallback, fonts, and Japanese input checks. |
| Linux Debian package | An installable `.deb` with explicit architecture/dependencies and matching app identity/version/icon; the same install, launch, connection, UI/font/input checks on supported targets. |
| macOS | The selected Tauri app/distribution artifact; verify actual signing/install steps and supported webview/GPU/input behavior. No paid Apple Developer account or seamless notarization is assumed. |

**Both Flatpak and `.deb` are required** release outputs. Define explicit packaging
recipes/stages and verify the produced packages; do not infer one format works
because the other, or an unpackaged development build, succeeds. Flatpak sandbox
permissions and filesystem/runtime access must be tested using the installed
package. Preserve English/Japanese catalogs and the chosen Japanese font strategy
in every artifact, including offline startup.

Publish downloadable artifacts with version, target architecture/runtime,
checksums, installation notes, and server compatibility information. Generate
icons from the [SVG masters](../assets/branding/README.md) at the required sizes.
Desktop update automation remains later scope; a backend deployment does not
replace an installed client's assets or remove protocol compatibility obligations.

### Build and open the macOS app

Install the Xcode command-line tools, Bun 1.4.4, and the Rust toolchain pinned in
`app/src-tauri/rust-toolchain.toml`. Start a current local hall at
`http://localhost:4000`, then run these commands from `app/`.

```sh
bun install --frozen-lockfile
CARGO_BUILD_JOBS=1 bun run desktop:build --bundles app -- --locked
open 'src-tauri/target/release/bundle/macos/Feud Hall.app'
```

For development, `bun run desktop:dev` builds the local assets and opens the
unbundled native window. That Cargo-run executable does not receive the bundle's
signing identity. For playtesting with a remembered Keychain session, use the
signed development bundle described below. For a build targeting another server, set
`FEUD_HALL_NATIVE_ORIGIN` at build time to the hall's HTTPS origin.
The packaged client embeds the shared UI and Noto Sans JP fonts. The credential
store is macOS Keychain or Linux Secret Service. Device credentials are
separated by server origin. A new install can restore an existing profile
through the game's device-recovery flow.

The native client saves the main window's size, position, and maximized state
locally on quit and restores them on launch. If the saved window is entirely
outside the connected displays, the window uses the system's default placement.
On Wayland, the compositor controls window placement. UI zoom is saved locally
when changed and restored on launch. Cmd/Ctrl+0 saves 100% as the preference;
subsequent +/- changes start from the restored scale. This preference is
separate from saved window geometry, game accounts, and the hall camera.

The hosted native workflow initially targets Apple silicon on macOS and
x86-64 on Ubuntu 24.04. The macOS minimum is 13.0. Without a local signing override,
macOS bundles are ad-hoc signed.
Public macOS installation still requires qualification for the chosen signing
and distribution path.

#### Stable local macOS signing

Use an existing Apple Development signing identity in the login Keychain:

```sh
security find-identity -v -p codesigning
cp src-tauri/tauri.macos.conf.example.json src-tauri/tauri.macos.conf.json
```

Set `bundle.macOS.signingIdentity` in the copied file to the exact identity
name from that command. Tauri automatically merges this macOS override into
its shared configuration. The override is ignored by Git; certificates and
private keys stay in Keychain. Other checkouts and CI keep their own signing
configuration. An explicit `APPLE_SIGNING_IDENTITY` environment variable takes
precedence, so unset it if it conflicts with the local override.

Build a signed debug app from `app/` with:

```sh
CARGO_BUILD_JOBS=1 bun run desktop:build --debug --bundles app -- --locked
open 'src-tauri/target/debug/bundle/macos/Feud Hall.app'
```

Moving from ad-hoc signing to this identity may require one final Keychain
approval for the game's existing session. Choose **Always Allow** for Feud Hall
when macOS asks. Subsequent bundles signed with the same compatible designated
requirement can retain that authorization. The macOS password stays in the
system dialog. Do not broaden the item's access to all applications.

Check the result with `codesign -d -r- --verbose=2` and
`codesign --verify --deep --strict` against the `.app` path. The designated
requirement must identify the bundle and signing identity, rather than only
the build's `cdhash`. To qualify updates, compare two different signed builds,
then launch, quit, and relaunch using the existing profile without another
session-access prompt. Renew an expired identity and requalify its requirement;
stable development signing does not provide public notarization.

### Linux packages and release artifacts

The hosted native workflow packages the Debian client and repackages its
executable as a GNOME 50 Flatpak. Both packages use the same pinned Rust
dependencies and common frontend build. The Flatpak grants network, display
and GPU access, and access to the Secret Service D-Bus name for credentials.
The release artifacts include the intended server, protocol, source revision,
and SHA-256 checksums. Supply the release-test or canonical HTTPS origin when
dispatching the workflow for that environment.

## Rollback, interruption, and restore

- Resolve an uncertain commit through its original receipt/event range before
  accepting more economic work; never assume a failed acknowledgement rolled back.
- A rollback binary must understand every event already emitted, current database
  schema, active content, and permitted client protocol. Otherwise keep the
  economy unavailable and forward-fix or use a compatible reader release.
- Do not delete/rewrite the authoritative event tail, replay grants, or restore
  stale projections to manufacture a clean rollback. Projection defects are
  repaired with a rebuild at a fixed committed cut; domain corrections append
  explicit compensating facts.
- Isolate a restore target from old writers and delivery workers before admitting
  it as live authority. Never serve a restored clone alongside the original hall
  or reuse historical ownership state as permission to write/send.
- Test backup/archive restore in a disposable environment before release. Restore
  protected operational data as well as events; replay cannot recreate a secret
  or prove that an email was already delivered. Validate genesis/snapshot recovery,
  accounting/resource invariants, authorization, and historical decoding.
- State what interval is unavailable, which deadlines pause, the affected revision,
  and the current recovery status. Credentials still obey their wall-time expiry;
  current safety/absence holds and recorded cleaning state survive recovery.

## Diagnostic operations and retention

Before public launch, provision centralized searchable structured logs and linked
traces for server, background workers, browser, and packaged clients under the
[architecture contract](ARCHITECTURE.md#observability-and-diagnostic-logging).
Do not rely solely on a live process console, a player's open browser, or a
provider's unspecified default retention. Keep collector/vendor export credentials
out of client artifacts; client reports enter a bounded, validated ingestion endpoint
and cannot forge trusted server records.

Record actual configuration and verified procedures for:

- Searchable-log and trace retention durations, size/cost limits, sampling and
  burst policies, per-operation slow thresholds, automatic expiry, and restricted
  incident-export retention.
  Set explicit values before release and prove expiry. These policies are
  separate from authoritative event/receipt history and backup retention; log
  cleanup cannot prune the facts required for replay or command deduplication.
- Authorized operator roles, access auditing, protected transport/storage, and
  redaction. Neither an owner account nor gameplay review permission alone
  grants diagnostic access. Restrict source maps/debug symbols and retain the
  build mappings needed for the supported investigation window.
- Collection-lag, dropped-record, exporter-failure and queue/disk-pressure
  monitoring, including an independent indication when the collector is down.
  Verify bounded resource use and continued gameplay during a diagnostic outage.
- Investigation from a support reference, command/order/shift ID, or time/hall
  range: find attempts and rejections, follow asynchronous work, resolve the
  immutable receipt and committed batches, compare projection/delivery progress,
  and identify exact builds and rules/content. Document access-controlled history
  queries and isolated replay steps; investigation must not mutate a live hall.

Use isolated release-test flows to prove cross-client/server correlation,
post-restart search, sanitized client-error interpretation, and recovery of an
uncertain command's original outcome. Preserve appropriately redacted evidence
and record gaps caused by sampling or collection failure. Diagnostic delivery is
best effort, so reconcile economic facts against durable receipts/events rather
than treating a missing log or trace as a rollback.

## Operational qualification to complete

Before the first public release, establish the actual migration/start/readiness,
backup/restore, authority-handover, and package-build entry points and run them in
release-like environments. Set measured storage/backup retention, connection and
worker budgets, health/observability criteria, and recovery limits from the
[architecture qualification plan](ARCHITECTURE.md#early-qualification-and-ongoing-tests).

Record the 150-stall/mixed-session workload and retained-history proof; verify
WebSocket reconnects, optional email delivery deduplication, and compatible older
clients across deploy/recovery. Qualify HTTPS/WSS, origin/CSRF and session
revocation controls, private-delivery filtering, and installed-client credential
storage/IPC restrictions from the
[transport contract](ARCHITECTURE.md#transport-and-credential-boundaries).
Keep production checks observational where
possible and use isolated test environments for seeded scenarios, failure
injection, and destructive restore exercises. Update this document with verified
procedures rather than treating these planned steps as evidence they ran.

## Local management game

Use the existing PostgreSQL server and a dedicated database for the managed
hall. New halls pin the launch catalog at genesis. After an upgrade, apply
the database migrations and rebuild the web client before restarting the
server. On startup, a managed slice hall or an older managed launch hall records the additive launch catalog update
in its existing event stream. Keep its database and signing secret so current
accounts, orders, and dining receipts remain available. An occupied
Milestone 2 hall still needs an explicit transition to management.

Launch catalog version 3 brings the [row of rooms](GAME_DESIGN.md#rooms). On
start-up, a managed launch hall below version 3 (or a managed slice hall)
records one `hall_catalog_expanded` event under the command ID
`web-launch-catalog:3`. It gives every spot a room and position, adds the room
rules, and changes the premium computer-run profile's preferred class to
standard. Existing leases keep their spot and rent, and every room up to the
highest lease stays open. See
[rooms and lease quotes](ARCHITECTURE.md#rooms-and-lease-quotes).

This upgrade cannot be rolled back: older code cannot decode the stored
version 3 catalog. Before the first start on this code, stop the hall's server
and take a dump of its database with `pg_dump`, so the hall can be restored
together with the older release if needed.

If that expansion is ever rejected, for example because a pinned spot ID is
outside the launch layout, the rejection is recorded under
`web-launch-catalog:3`. Every restart then replays the same rejected receipt
and the server refuses to start. Only a later catalog version, with a new
command ID, gets out of that state. Before restarting a real hall on a new
catalog version, try the upgrade on a copy of its database first: create one
with `createdb -T <hall database> <copy name>` while the hall's server is
stopped, or restore a `pg_dump` of the hall into a new database, start the server against the copy on another port with the same
secret, check the log for one `hall_catalog_expanded` and the hall page for
Hall 1, and then drop only the copy. The version 3 change is tried this way
before it reaches a real hall; the result is recorded in the
[row of halls report](superpowers/reports/2026-11-14-row-of-halls.md#trial-upgrade-on-a-copy-of-a-real-hall).

From `app/`, run `bun install --frozen-lockfile` and `bun run build`. The
build writes the client into `server/priv/static`. From `server/`, set these
variables for the local process:

```sh
export FEUD_HALL_SERVE=1
export FEUD_HALL_DB=feud_hall_management
export FEUD_HALL_ORIGIN=http://localhost:4000
export FEUD_HALL_SECRET="$(openssl rand -hex 32)"
export FEUD_HALL_ADMIN_KEY="$(openssl rand -hex 32)"
mix ecto.create
mix ecto.migrate
mix run --no-halt
```

Keep the signing secret stable across restarts. The endpoint listens on loopback
for HTTP development. A non-loopback origin requires HTTPS. Use the configured
origin in the browser. For hosted configuration, the runtime also accepts
`DATABASE_URL` and `PORT`.

Create a visitor profile in the UI. Retrieve its principal ID from that device's
authorized `GET /api/state` response, then issue one protected operator request
to `POST /api/operator/seed` using the configured key as a Bearer credential
and JSON fields `command_id` and `principal`. The seed account receives its
three invitations and the explicit reviewer capability through the same event
store as other accounts. Unset the operator key and restart after seeding
when the endpoint is no longer required. Use the seeded account to issue codes.
