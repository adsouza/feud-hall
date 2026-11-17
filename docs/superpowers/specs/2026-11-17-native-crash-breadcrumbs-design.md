# Native crash breadcrumbs: design

Status: proposed, 2026-11-17. Size: small change (short design).

## Why

A Linux Flatpak tester hit a SEGV inside the runtime's WebKitGTK
(`libwebkit2gtk-4.1`, entered from a GTK event handler) while Feud Hall was in
the background and they copied text in another app. The systemd coredump held
the stack, but nothing recorded the context: the session type, GPU, library
versions, or what the app had just been through. The leading guess is that
WebKit crashes when it loses ownership of the clipboard or primary selection.
That is unproven and, so far, unreproduced.

Goal: every desktop crash from now on leaves behind a report holding the
context needed to debug it, and the player is told where it is on the next
launch.

## Goals, non-goals, anti-goals

- Goals: a per-session breadcrumb log written as events happen; detection of
  an unclean exit on the next launch; a readable report kept on disk; a
  bilingual notice that shows the report's path and has a **Show in folder**
  action.
- Non-goals: catching the signal inside the app or producing a stack
  ourselves (the coredump or the macOS crash report holds the stack); uploading
  reports; the web/browser client; fixing the WebKit crash itself.
- Anti-goals: anything that writes to the clipboard (a Copy button would make
  WebKit the clipboard owner, the state the crash appears to need); logging
  credentials (the `_feud_device` token), request or response bodies, selected
  or player-entered text; a channel through which the page can log arbitrary
  strings; diagnostics that can block or break the game when the disk or
  folder is unavailable.

## Approaches

1. **Chosen:** the Rust side writes a breadcrumb file and flushes each line.
   Native events come from Tauri window events and, on Linux, GTK's
   clipboard/primary owner-change signals. The webview reports a fixed set of
   event kinds through one bounded command. A locked session marker detects an
   unclean exit, and the next launch keeps a report and shows a notice.
   Context only: the stack comes from the system's crash capture.
2. Approach 1 plus an in-app minidump writer (`crash-handler` + `minidumper`).
   Rejected: a helper process and native dependencies that duplicate
   systemd-coredump on Linux, and WebKit frames still need the GNOME debug
   symbols to read.
3. `tauri-plugin-log` as a general logger. Rejected: it gives the page a call
   that logs any string (against the
   [logging contract](../../ARCHITECTURE.md#observability-and-diagnostic-logging)),
   it doesn't detect an unclean exit, and most of approach 1 would still have to
   be built.

The owner chose approach 1, without a Copy button.

## Design

**Where.** The Tauri app log directory: on Linux
`$XDG_DATA_HOME/io.github.adsouza.FeudHall/logs` (inside a Flatpak that is
`~/.var/app/io.github.adsouza.FeudHall/data/...`), and on macOS
`~/Library/Logs/io.github.adsouza.FeudHall`. A failure to create the folder
or write to it turns diagnostics off for the session and never fails startup.

**Session log.** One JSON Lines file per session (schema `v: 1`). Every record
has a stable `event` name, a UTC `at`, monotonic `elapsed_ms`, a `source`
(`native` or `webview`), and allowlisted fields. Each record is written with a
single `write` and no user-space buffering, so a hard crash loses at most the
record being written. The first record, `session_started`, carries: app version
and target OS; `XDG_SESSION_TYPE`; whether `WAYLAND_DISPLAY` and `DISPLAY` are
set; `GDK_BACKEND`; every `WEBKIT_*` variable; the `runtime=` line from
`/.flatpak-info` when present; and the GTK and WebKitGTK versions. Each file is
capped (256 KiB proposed); past the cap, one `log_truncated` record is written
and later records are dropped. Clean session logs are pruned so only the most
recent few remain.

**Native events.** Window focus gained/lost, resized, scale-factor changes,
close requested, and exit. On Linux, `owner-change` on the CLIPBOARD and
PRIMARY selections, with the selection name and the GDK reason. The breadcrumb
records only that ownership changed, never the contents.

**Webview events** (`src-tauri/src/diagnostics.js`, an initialization script
like `zoom.js`). Page visibility changes; window focus/blur; `copy` and `cut`
(kind only); the first non-empty text selection after an empty one (length
only, never text); `webglcontextlost` and `webglcontextrestored`; uncaught
errors and unhandled rejections (message truncated to 300 characters, plus
source file name and line); and a one-off GPU renderer string read from a
throwaway WebGL context once idle. Each event is sent through the
`diagnostic_breadcrumb` command, which accepts only the known `kind`s and
bounded, typed fields, rejects unknown fields, and rate-limits the webview
(about 20 records per second, with excess counted and reported as a single
record).

**Unclean-exit detection.** At startup the session creates
`session-<start>.marker` and holds an exclusive `File::try_lock` on it until a
clean exit deletes it. Then, for every other marker: if it can be locked, its
session died, so its log becomes a report; if it can't be locked, another
instance is still running and it is left alone. The check doesn't use PIDs,
because a Flatpak's PID is namespaced (the coredump's host PID differs from
the PID the app sees).

**Report.** `crash-<start>.txt` holds a readable header (when the session
started and when its last record was written, the environment, and the last 40
breadcrumbs as readable lines). After the header come instructions for finding
the stack: on Linux,
`coredumpctl list feud-hall --since "<start>"` and
`flatpak-coredumpctl -m <PID> io.github.adsouza.FeudHall` with the needed
`org.gnome.Sdk.Debug//50` and `org.gnome.Platform.Debug//50`; on macOS,
`~/Library/Logs/DiagnosticReports`. Then the full JSON Lines log. Only the
most recent 5 reports are kept.

**Notice.** When native, `App.svelte` asks for unacknowledged reports with a
`crash_reports` command. If there are any, it shows a dismissible banner saying
the last session closed unexpectedly, that a diagnostic report was saved
without passwords or game text, the path as selectable text, and **Show in
folder**. That action calls a Rust command that reveals the newest report.
Dismissing the banner marks the reports as acknowledged. The text goes into the
English and Japanese catalogs in `i18n.ts`. The notice wording says "closed
unexpectedly", because a forced quit or power loss looks the same as a crash.

## Constraints

- `decide/evolve` and the server are untouched. This is presentation and
  native-integration diagnostics, and it never claims a game outcome.
- No clipboard writes. No new Flatpak permissions unless **Show in folder**
  proves to need one. The builder checks this and writes down what was needed.
- The new Rust crates (`gtk`, `gdk`, `webkit2gtk`) are Linux-only and pinned to
  the versions already in `Cargo.lock`.

## Left to the builder

The exact cap and number of logs kept, the reveal mechanism (Flatpak portal via
the opener plugin or `xdg-open` on the folder, `open -R` on macOS), the
readable line format, and the test shape. Rust unit tests should cover
validation, the cap, rate limits, lock-based detection, report assembly, and
the absence of credentials. A Playwright spec for `diagnostics.js` with a mocked
`__TAURI_INTERNALS__`, as `ui-zoom.spec.ts` does. A notice test.
