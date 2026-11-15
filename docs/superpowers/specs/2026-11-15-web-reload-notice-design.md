# Web reload notice

Approved by the owner on 2026-11-15.

## Intent

A browser tab left open across a deploy keeps running the old client until
someone reloads it, and nothing tells the player a newer version is live. Tabs
should notice and offer a reload. The web client is served by Phoenix from
`server/priv/static`; the Tauri apps bundle their own client and change only
through a new package, so they are out of scope.

## Goals

- An open web tab notices that the server now serves a different client build
  and shows "A new version of Feud Hall is available" with a Reload button.
- An open web tab that the server can no longer serve (protocol mismatch) says
  "This page is out of date. Reload to continue." with the same button.
- English and Japanese for both messages.

## Non-goals and anti-goals

- No automatic reload: a reload loses in-memory drafts, focus and IME input, so
  the player chooses when (AGENTS.md: preserve drafts during live updates).
- No prompt when a deploy ships identical client code.
- Keeping drafts across a reload is not part of this change.
- The desktop apps keep their current "update the app" message and never run
  the build check.

## Approaches

1. **Compare the served page's entry script (chosen).** Fetch `/` uncached,
   parse the `<script type="module" src>` and compare it with the running
   document's. Vite content-hashes that name, so it changes exactly when the
   client code does. No server or build changes.
2. Build-ID endpoint or response header: a Vite plugin writes an ID and the
   server exposes it. More moving parts for the same answer.
3. Push over the Phoenix socket: the web client polls rather than holding a
   channel, and a deploy restarts the server anyway, so the reconnect is the
   signal.

## Design

- **Check triggers:** after the first successful poll that follows a failed
  one (a deploy restarts the server), when the document becomes visible, and
  every 10 minutes. Skipped under Tauri.
- **Notice:** while `updateAvailable`, a page banner with the message and a
  Reload button (`location.reload()`). When the 3D hall's tablet carries the
  notices (`inWorldNotices`), the tablet gets a message row and a Reload action
  row instead, and no page banner appears.
- **Protocol:** web requests send `x-feud-protocol: 1`, so the router's existing
  426 `client_update_required` reaches old tabs. On the web, that state shows
  the reload-required message with the Reload button; under Tauri, the existing
  desktop message stays.
- **Messages:** new `en` and `ja` catalog keys; `ja: Record<Key, string>` keeps
  the catalogs in step.

## Verification

Browser tests (written before the code) against the disposable hall:
notice after a simulated deploy (served page with a different entry script),
no notice when the served page is unchanged (with the check shown to have run),
the protocol header on API requests, the reload-required message on a 426, and
the tablet's Reload row in the 3D hall.

## Left to the builder

Exact banner placement and styling within the existing banner styles, and the
check's error handling (a failed check shows nothing and retries on the next
trigger).
