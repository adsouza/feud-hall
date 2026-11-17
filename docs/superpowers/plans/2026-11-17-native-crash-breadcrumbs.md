# Native Crash Breadcrumbs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every desktop crash leaves behind a context report, and the next launch tells the player where it is.

**Architecture:** The Rust side writes a per-session JSON Lines breadcrumb log and flushes each line.
Native window and (on Linux) GTK selection-owner events are written directly. The webview sends a
fixed set of event kinds through one bounded command. A locked marker file tells a dead session
from a running one. The next launch turns a dead session's log into a readable report, and a
bilingual Svelte notice shows its path with **Show in folder**.

**Tech Stack:** Rust (Tauri 2.12.5, `time` 0.3.55, Linux-only `gtk`/`gdk` 0.18.2 and `webkit2gtk` 2.0.2), plain JS init script, Svelte 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-native-crash-breadcrumbs-design.md`

## Global Constraints

- No clipboard writes anywhere (no Copy button, no `navigator.clipboard`, no `execCommand("copy")`).
- Never log the `_feud_device` token, request/response bodies, selected text, or player-entered text. Environment variables are allowlisted: `XDG_SESSION_TYPE`, `GDK_BACKEND`, every `WEBKIT_*`; `WAYLAND_DISPLAY`/`DISPLAY` recorded as set/unset only.
- Diagnostics failures never fail startup or a game action; they disable diagnostics for the session.
- Log cap 256 KiB per session; keep 5 crash reports and 5 clean session logs; error messages truncated to 300 characters; webview limit 20 records per second.
- New Rust crates pinned to the versions already in `Cargo.lock`; `gtk`, `gdk`, `webkit2gtk` are `cfg(target_os = "linux")` only.
- Notice text in English and Japanese (`app/src/i18n.ts`); wording says "closed unexpectedly".
- Local checks: never run `tsc`; no full test suite; focused `cargo test`, `bun run check:svelte`, `bun check`, `bun run test:browser --grep '<scenario>'` after `bun run build`; keep tooling under 2 GiB RSS. Format with `cargo fmt` and Prettier; lint with `bun run lint`.

## Review Focus

1. The init script's own `invoke` rejecting (command missing, IPC down) must not raise an unhandled rejection that it then reports, an endless loop. Test in Task 5.
2. A log folder that can't be created or written (the path is a file, read-only) must leave the game running and the commands returning empty. Test in Task 1 and Task 3.
3. A second instance launched while the first is running must not report the first as crashed. Test in Task 3.
4. A crash in the middle of writing leaves a partial last line, or a marker without a log. The report must still be built, counting unreadable lines. Test in Task 3.
5. A busy session reaching the cap writes `log_truncated` exactly once and stays within cap plus one record. Test in Task 1.

---

### Task 1: Breadcrumb log writer

**Files:**
- Create: `app/src-tauri/src/diagnostics.rs`
- Modify: `app/src-tauri/Cargo.toml` (add `time = { version = "=0.3.55", features = ["formatting"] }`), `app/src-tauri/src/main.rs` (`mod diagnostics;` only)

**Interfaces:**
- Produces:
  - `pub const LOG_CAP: u64 = 256 * 1024;`
  - `pub enum Source { Native, Webview }` (serializes `"native"`/`"webview"`)
  - `#[derive(Clone)] pub struct Breadcrumbs` (cheap clone; `Arc` inside)
  - `Breadcrumbs::open(path: &Path, cap: u64) -> Breadcrumbs`: creates the parent folder and opens the file for appending. Any error gives a disabled instance.
  - `Breadcrumbs::disabled() -> Breadcrumbs`, `fn is_enabled(&self) -> bool`
  - `fn record(&self, source: Source, event: &str, fields: serde_json::Map<String, Value>)`: one JSON line `{"v":1,"at":<UTC RFC 3339 ms>,"elapsed_ms":<u64>,"source":..,"event":..,..fields}`, written with a single `write_all` to an unbuffered `File`. A write error disables the instance.
  - `pub fn environment_from(vars: impl IntoIterator<Item = (String, String)>, flatpak_info: Option<&str>) -> Map<String, Value>`: allowlisted fields: `session_type`, `wayland_display_set`, `x11_display_set`, `gdk_backend`, `webkit_env` (object), `flatpak_runtime` (the `runtime=` value).

- [ ] **Step 1: Write failing tests** in `diagnostics.rs` `#[cfg(test)]`:
  - `record_writes_one_json_line_per_call`: two records, then the file has 2 lines, each parsing with `v == 1`, `source`, `event`, and the field values; `at` ends in `Z`.
  - `cap_writes_log_truncated_once` (Review Focus 5): with `cap = 600`, 50 records; exactly one line has `event == "log_truncated"`; file length `<= 600 + longest line`.
  - `unwritable_path_is_disabled` (Review Focus 2): the parent "folder" is a regular file; `open` returns `!is_enabled()`, `record` doesn't panic.
  - `environment_keeps_only_allowlist`: input has `XDG_SESSION_TYPE=wayland`, `WAYLAND_DISPLAY=wayland-0`, `WEBKIT_DISABLE_DMABUF_RENDERER=1`, `FEUD_SECRET=hunter2`, `HOME=/home/ria`; flatpak info `"[Application]\nruntime=runtime/org.gnome.Platform/x86_64/50\n"`. Output has `session_type == "wayland"`, `wayland_display_set == true`, `webkit_env.WEBKIT_DISABLE_DMABUF_RENDERER == "1"`, `flatpak_runtime == "runtime/org.gnome.Platform/x86_64/50"`, and the serialized output doesn't contain `hunter2` or `/home/ria`.
- [ ] **Step 2: Run** `cargo test --locked --bin feud-hall diagnostics::` from `app/src-tauri`. Expected: FAIL (not defined).
- [ ] **Step 3: Implement** the interfaces above. `elapsed_ms` comes from an `Instant` taken in `open`. The `log_truncated` record is written once, when a record would cross the cap; later records are dropped.
- [ ] **Step 4: Run** the same command. Expected: PASS. Then `cargo fmt --check`.
- [ ] **Step 5: Commit** `Add a native breadcrumb log writer`.

### Task 2: Webview breadcrumb validation and rate limit

**Files:**
- Modify: `app/src-tauri/src/diagnostics.rs`

**Interfaces:**
- Consumes: `Breadcrumbs::record`, `Source::Webview`.
- Produces:
  - `#[derive(Deserialize)] #[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)] pub enum WebviewCrumb { Visibility { visible: bool }, Focus { focused: bool }, Copy, Cut, Selection { length: u32 }, WebglLost, WebglRestored, Error { message: String, file: String, line: u32 }, Rejection { message: String }, Gpu { vendor: String, renderer: String } }`
  - `fn record_webview(&self, crumb: WebviewCrumb)`: event name `webview_<kind>`; strings truncated on a char boundary (`message` 300, `file` the last path segment, max 120; `vendor`/`renderer` 200). Rate limit: at most 20 records per wall-clock second window. When a window with drops ends, the next accepted record is preceded by `webview_rate_limited {dropped: n}`.

- [ ] **Step 1: Write failing tests:**
  - `unknown_kind_and_extra_field_are_rejected`: `serde_json::from_value::<WebviewCrumb>(json!({"kind":"paste"}))` is `Err`; so is `{"kind":"copy","text":"x"}`.
  - `error_message_is_truncated_to_300_chars`: a 1,000-char message in Japanese (multi-byte) is recorded with `message` of 300 chars and valid UTF-8; a `file` of `"tauri://localhost/assets/index-abc.js"` is recorded as `"index-abc.js"`.
  - `rate_limit_drops_and_reports`: 25 records in one window give 20 `webview_*` lines; the first record after the window gives `webview_rate_limited` with `dropped == 5` before it. Inject the window clock with a `#[cfg(test)]` method `record_webview_at(crumb, window: u64)`.
- [ ] **Step 2: Run** `cargo test --locked --bin feud-hall diagnostics::`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS; `cargo fmt --check`.
- [ ] **Step 5: Commit** `Validate and rate-limit webview breadcrumbs`.

### Task 3: Session markers and crash reports

**Files:**
- Create: `app/src-tauri/src/crash_reports.rs`

**Interfaces:**
- Consumes: `Breadcrumbs`, `LOG_CAP`.
- Produces:
  - `pub fn session_id(now: OffsetDateTime, pid: u32) -> String`: `"20261117T121155.123Z-<pid>"` (sortable; PID only distinguishes instances).
  - `pub struct Session { pub id: String, pub log: PathBuf, marker: File }`
  - `pub fn start(dir: &Path, id: &str) -> io::Result<Session>`: creates `session-<id>.marker` and takes `File::try_lock` on it. The log path is `session-<id>.jsonl`.
  - `Session::finish(self)`: deletes the marker (clean exit) and prunes clean logs to the newest 5.
  - `pub fn collect(dir: &Path, own: &str, os: &str) -> Vec<PathBuf>`: for each other marker, `try_lock` succeeds means its session died. Write `crash-<id>.txt` from `build_report`, delete the marker and its `.jsonl`, and return the new paths. `WouldBlock` means it's running: skip it. Then prune to the newest 5 `crash-*.txt` (with their `.seen`).
  - `pub fn build_report(id: &str, log: Option<&str>, os: &str) -> String`: header (session start from `id`; last record's `at`; the `session_started` environment; the last 40 records as `HH:MM:SS.mmm +elapsed source event key=value…`; `unreadable lines: n` when any). Then the coredump instructions: Linux gives `coredumpctl list feud-hall --since "<start in local-agnostic UTC>"`, `flatpak install --user flathub org.gnome.Sdk//50 org.gnome.Sdk.Debug//50 org.gnome.Platform.Debug//50` and `flatpak-coredumpctl -m <PID from that list> io.github.adsouza.FeudHall`; macOS points to `~/Library/Logs/DiagnosticReports` (files named `feud-hall-*`). Then `--- breadcrumbs (JSON Lines) ---` and the raw log.
  - `#[derive(Serialize)] pub struct ReportSummary { pub id: String, pub path: String }`
  - `pub fn pending(dir: &Path) -> Vec<ReportSummary>`: `crash-*.txt` without a sibling `.seen`, newest first. Errors give an empty list.
  - `pub fn acknowledge(dir: &Path)`: creates a `.seen` for each pending report.

- [ ] **Step 1: Write failing tests** (temp folders under `std::env::temp_dir()`, unique per test):
  - `dead_session_becomes_report`: write a marker and a 3-line log for id A with no lock held. `collect(dir, "B", "linux")` returns `crash-A.txt`, which contains `coredumpctl list feud-hall --since`, the last event name, and the raw lines. The marker and log are gone.
  - `running_session_is_left_alone` (Review Focus 3): `let a = start(dir, "A")`; `collect(dir, "B", "linux")` is empty, and `session-A.marker` still exists.
  - `partial_line_and_missing_log_still_report` (Review Focus 4): a log whose last line is `{"v":1,"at":"2026-` gives a report with `unreadable lines: 1`. A marker with no log gives a report containing `no breadcrumbs were recorded`.
  - `finish_removes_marker`: after `start(...).finish()`, a `collect` from another session returns nothing.
  - `pending_and_acknowledge`: two reports give `pending` in newest-first order, length 2. After `acknowledge`, `pending` is empty.
  - `prune_keeps_five_reports`: 7 dead sessions are collected and 5 `crash-*.txt` remain (the newest).
  - `unreadable_dir_gives_empty_pending` (Review Focus 2): `pending` on a path that is a file returns an empty list.
- [ ] **Step 2: Run** `cargo test --locked --bin feud-hall crash_reports::`. Expected: FAIL.
- [ ] **Step 3: Implement.** Hold the marker `File` inside `Session` for the process's lifetime, because dropping it releases the lock.
- [ ] **Step 4: Run.** Expected: PASS; `cargo fmt --check`.
- [ ] **Step 5: Commit** `Turn dead sessions into crash reports`.

### Task 4: Wire diagnostics into the Tauri app

**Files:**
- Modify: `app/src-tauri/src/main.rs`, `app/src-tauri/Cargo.toml` (Linux-only `gtk = "=0.18.2"`, `gdk = "=0.18.2"`, `webkit2gtk = "=2.0.2"`), `app/src-tauri/capabilities/main.json`, `app/src-tauri/permissions/` (follow the existing `allow-hall-request` pattern)
- Create: `app/src-tauri/src/native_events.rs` (window-event mapping; Linux selection hooks and versions under `cfg`)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces Tauri commands (used by Tasks 5–6):
  - `diagnostic_breadcrumb(crumb: WebviewCrumb) -> ()` (never errors)
  - `crash_reports() -> Vec<ReportSummary>`
  - `acknowledge_crash_reports() -> ()`
  - `reveal_crash_report() -> Result<(), &'static str>`: reveals the newest report. macOS uses `open -R <file>`. Linux uses `xdg-open <folder>` (in a Flatpak, the runtime's `xdg-open` goes through the OpenURI portal). The error is `"reveal_unavailable"`.
  - Permissions `allow-diagnostic-breadcrumb`, `allow-crash-reports`, `allow-acknowledge-crash-reports`, `allow-reveal-crash-report`, added to `main.json`.

- [ ] **Step 1: Write a failing test** in `native_events.rs`: `window_events_map_to_breadcrumbs`. `crumb_for(&WindowEvent::Focused(false))` is `Some(("window_focus", {"focused": false}))`. `Resized(PhysicalSize{width:800,height:600})` maps to `window_resized` with both sizes. `CloseRequested` maps to `window_close_requested`. Moved returns `None` (too noisy).
- [ ] **Step 2: Run** `cargo test --locked --bin feud-hall native_events::`. Expected: FAIL.
- [ ] **Step 3: Implement** `pub fn crumb_for(event: &WindowEvent) -> Option<(&'static str, Map<String, Value>)>`, then wire up `main.rs`:
  1. In `setup`, use the dir from `app.path().app_log_dir()`. Compute the id with `session_id(now_utc, std::process::id())`. A `start` failure gives `Breadcrumbs::disabled()` and no session. Otherwise run `collect(dir, id, std::env::consts::OS)`, then `Breadcrumbs::open(session.log, LOG_CAP)`. Record `session_started` with `app_version` (`app.package_info().version`), `os`, and `environment_from(std::env::vars(), fs::read_to_string("/.flatpak-info").ok())`. Add `gtk_version` and `webkit_version` on Linux, read in `setup` on the main thread. Then `app.manage(...)`.
  2. On Linux, after the window is built, connect `owner-change` on `gtk::Clipboard::get(&gdk::SELECTION_CLIPBOARD)` and `SELECTION_PRIMARY`. Record `selection_owner_changed {selection: "clipboard"|"primary", reason: "new_owner"|"destroy"|"close"}` and nothing else.
  3. Builder `.on_window_event` records `crumb_for` output with `Source::Native`.
  4. Replace `.run(generate_context!())` with `.build(generate_context!())?.run(|app, event|)`. On `RunEvent::Exit`, record `session_exit` and call `Session::finish` (keep the `Session` in a `Mutex<Option<Session>>` managed state).
  5. Register the four commands and the `diagnostics.js` init script (Task 5) after `zoom.js`.
- [ ] **Step 4: Run** the focused test (Expected: PASS), then `cargo build --locked` (macOS here; the Linux `cfg` code compiles in hosted `native.yml`, which nothing can check locally) and `cargo fmt --check`.
- [ ] **Step 5: Commit** `Record native breadcrumbs and collect crash reports at startup`.

### Task 5: Webview breadcrumb script

**Files:**
- Create: `app/src-tauri/src/diagnostics.js`, `app/test/browser/diagnostics.spec.ts`
- Modify: `app/package.json` `lint` script (add `src-tauri/src/diagnostics.js`)

**Interfaces:**
- Consumes: the `diagnostic_breadcrumb` command, called as `window.__TAURI_INTERNALS__.invoke("diagnostic_breadcrumb", { crumb })`.
- Produces: none.

- [ ] **Step 1: Write failing Playwright tests**, installing the script as `ui-zoom.spec.ts` does, with a mock `invoke` that pushes `{command, args}` to `window.crumbs`:
  - `copy sends kind only`: select text in an input holding `日本語秘密`, dispatch `copy`; the last crumb is exactly `{kind:"copy"}`, and `JSON.stringify(window.crumbs)` doesn't contain `秘密`.
  - `selection sends length once per new selection`: select 5 characters gives `{kind:"selection", length:5}`; extending the selection sends nothing new; collapsing and then selecting again sends one more.
  - `errors are truncated`: `setTimeout(() => { throw new Error("x".repeat(1000)) })` gives an `error` crumb with `message.length <= 300` and a numeric `line`.
  - `own invoke failure does not loop` (Review Focus 1): the mock rejects every call; dispatch one `copy`. After 500 ms, exactly 1 call was made and no `rejection` crumb was sent.
  - `gpu is reported once`: after load, poll until one `gpu` crumb exists; reload-free waiting for 1 s gives no second one.
- [ ] **Step 2: Run** `bun run test:browser --grep 'diagnostics'` from `app/`. Expected: FAIL.
- [ ] **Step 3: Implement** an IIFE like `zoom.js`. A `send(crumb)` wraps `invoke` in `try`/`.catch(() => {})`. Listeners: `visibilitychange`, window `focus`/`blur`, `copy`, `cut`, `selectionchange` (transition from empty to non-empty only, `getSelection().toString().length`), capture-phase `webglcontextlost`/`webglcontextrestored` on `document`, `error`, and `unhandledrejection`. Read the GPU once via `requestIdleCallback` (fall back to `setTimeout`): a 1×1 WebGL context with `WEBGL_debug_renderer_info`, then `WEBGL_lose_context`. Skip it silently when WebGL is unavailable.
- [ ] **Step 4: Run.** Expected: PASS; `bun run lint`.
- [ ] **Step 5: Commit** `Report webview breadcrumbs to the native log`.

### Task 6: Crash report notice

**Files:**
- Create: `app/src/CrashReportNotice.svelte`, `app/test/browser/crash-notice.spec.ts`
- Modify: `app/src/App.svelte` (mount it under the banners when `nativeClient`), `app/src/i18n.ts`

**Interfaces:**
- Consumes: `crash_reports`, `acknowledge_crash_reports`, `reveal_crash_report` via `invoke` from `@tauri-apps/api/core`; `t`/`locale` as `App.svelte` passes them (prop `t: (key: Key) => string`).
- Produces: i18n keys `crashReportTitle`, `crashReportBody`, `crashReportShow`, `crashReportShowFailed`.

Copy (exact):
- en `crashReportTitle`: "Feud Hall closed unexpectedly last time."
- en `crashReportBody`: "A diagnostic report was saved. It contains no passwords or game text. Please send it to the developers:"
- en `crashReportShow`: "Show in folder"
- en `crashReportShowFailed`: "The folder could not be opened. The report's location is shown above."
- ja: "前回、Feud Hallが予期せず終了しました。" / "診断レポートを保存しました。パスワードやゲーム内の文章は含まれていません。開発者に送ってください：" / "フォルダーで表示" / "フォルダーを開けませんでした。レポートの場所は上に表示されています。"

- [ ] **Step 1: Write failing Playwright tests.** The init script defines `__TAURI_INTERNALS__.invoke`. `hall_request` forwards to `fetch(path, {method, headers: {"x-feud-protocol":"1", accept:"application/json", ...(body ? {"x-feud-command":"1","content-type":"application/json"} : {})}, body: body && JSON.stringify(body)})` and resolves `{status, body: await r.text()}`. The crash commands are scripted per test, and every call is recorded. Tests:
  - `notice shows the newest report path`: `crash_reports` returns two reports. The banner shows the title and the first path as text inside a `<code>`, and the page has no element with "Copy" in its text.
  - `dismiss acknowledges`: clicking dismiss calls `acknowledge_crash_reports` once and the notice disappears.
  - `show in folder failure is explained`: `reveal_crash_report` rejects with `"reveal_unavailable"`, so `crashReportShowFailed` appears and the notice stays.
  - `no reports, no notice`: `crash_reports` returns `[]` and nothing is shown.
  - `japanese copy`: with the locale switched to Japanese the way existing specs do, the title shows its Japanese text.
- [ ] **Step 2: Run** `bun run build && bun run test:browser --grep 'crash notice'`. Expected: FAIL.
- [ ] **Step 3: Implement** the component (one `invoke("crash_reports")` on mount; errors give no notice). Reuse the `banner` / `notice-dismiss` classes and `dismissNotification` label. Add both catalogs.
- [ ] **Step 4: Run** the same command (Expected: PASS), then `bun run check:svelte`, `bun check`, and `bun run lint`.
- [ ] **Step 5: Commit** `Tell the player where a crash report was saved`.

### Task 7: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md` (Observability: a "Desktop crash breadcrumbs" paragraph covering the allowlist, the webview command bounds, lock-based detection, and the no-clipboard rule), `docs/DEPLOYMENT.md` (where reports live per platform, reading one, symbolizing with `flatpak-coredumpctl`), `docs/TESTING.md` (the new focused cargo tests and the two Playwright scenarios; Linux `cfg` code is compiled only in hosted `native.yml`).

- [ ] **Step 1:** Write the sections, linking to the spec rather than copying it.
- [ ] **Step 2:** Check that relative links resolve (`grep -o '](\.\{0,2\}[^)]*)'` over the changed files and test each path exists) and run `bunx prettier --check` on the changed Markdown.
- [ ] **Step 3: Commit** `Document desktop crash reports`.
