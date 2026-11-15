# Web Reload Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open web tabs notice a newer client or an incompatible server and offer a Reload button, in English and Japanese.

**Architecture:** The web client sends `x-feud-protocol: 1` so the router's existing 426 reaches old tabs. A small module compares the entry script of the freshly served `/` with the running document's; App.svelte runs it on reconnect, on visibility and every 10 minutes, and shows a page banner or, in the 3D hall, tablet rows.

**Tech Stack:** Svelte 5 + TypeScript (Bun), Playwright browser suite with the disposable hall fixture.

**Spec:** `docs/superpowers/specs/2026-11-15-web-reload-notice-design.md`

## Global Constraints

- Never reload automatically; only the Reload button calls `location.reload()`.
- Skip the build check under Tauri (`isTauri()`); the desktop "update the app" message stays as is.
- Check interval: `10 * 60 * 1000` ms. Triggers: first successful poll after a failed one, `visibilitychange` to visible, interval.
- Copy (exact): en `newVersion` "A new version of Feud Hall is available.", `reload` "Reload", `reloadRequired` "This page is out of date. Reload to continue."; ja `newVersion` "新しいバージョンのFeud Hallが利用できます。", `reload` "再読み込み", `reloadRequired` "このページは古くなっています。続けるには再読み込みしてください。"
- AGENTS.md limits: never run `tsc`; Bun/Node checks within 2 GiB (`NODE_OPTIONS=--max-old-space-size=1536`); run browser specs by file or `--grep`, one worker, after `bun run --bun build`.

## Review Focus

- The check's fetch of `/` fails or returns a non-HTML/503 page ("frontend is not built"): no notice, no unhandled rejection (test in Task 2).
- A notice already showing: later triggers do not re-fetch or duplicate it (`checkClient` returns early; test in Task 2 counts fetches).
- Tab hidden: the interval does not check while `document.hidden` (guard mirrors the existing poll; no test, matches existing poll pattern).
- Vite dev server: entry `/src/main.ts` is identical before and after, so no prompt (comparison-based; no test).
- In the 3D hall with the tablet open, no page banner appears (Task 3 asserts `main > .banner:not(.success-notice)` count 0).

---

### Task 1: Protocol header and reload-required message

**Files:**
- Modify: `app/src/api.ts` (`request`, web `fetch` branch)
- Modify: `app/src/App.svelte` (offline banner ~line 2319; tablet `problem` ~line 768)
- Modify: `app/src/i18n.ts` (`en`, `ja`)
- Create: `app/test/browser/client-version.spec.ts`
- Modify: `docs/ARCHITECTURE.md` (protocol paragraph near "Native protocol version 1 is explicit.")

**Interfaces:**
- Produces: i18n keys `reload`, `reloadRequired`; `function reloadClient(): void` in App.svelte (calls `location.reload()`); `const nativeClient = isTauri()` in App.svelte.

- [ ] **Step 1: Write the failing test** `"web requests send the client protocol and a refused protocol asks for a reload"` (hall fixture, no launch): wait for the first `/api/state` request after `page.goto(hall.origin)` and assert `headers()["x-feud-protocol"] === "1"`; then `page.route("**/api/state**", r => r.fulfill({ status: 426, json: { error: "client_update_required" } }))`; expect `page.getByRole("status").filter({ hasText: "This page is out of date. Reload to continue." })` visible containing `getByRole("button", { name: "Reload" })`, and the text "This desktop app and hall use different versions." absent.
- [ ] **Step 2: Run it to verify it fails** — `cd app && bun run --bun build && bun run test:browser client-version.spec.ts` → FAIL (header missing).
- [ ] **Step 3: Implement** — web `fetch` always sends `"x-feud-protocol": "1"` (merged with the JSON headers for POST); add the two keys to `en`/`ja`; when `updateRequired && !nativeClient`, banner and tablet `problem` use `reloadRequired`, and the banner holds a Reload button calling `reloadClient`.
- [ ] **Step 4: Run it to verify it passes**, plus `bun run test:browser release.spec.ts` (protocol boundary) → PASS.
- [ ] **Step 5: Docs** — ARCHITECTURE.md: web clients send the same protocol header; a mismatch asks the tab to reload.
- [ ] **Step 6: Commit** — "Send the client protocol from the web and ask stale tabs to reload".

### Task 2: Newer-client check and notice banner

**Files:**
- Create: `app/src/client-version.ts`
- Modify: `app/src/App.svelte` (state, `refresh` success branch ~line 1194, `onMount` interval/`resume` ~line 968, banner in `<main>`)
- Modify: `app/src/i18n.ts` (`newVersion`)
- Modify: `app/test/browser/client-version.spec.ts`
- Modify: `docs/TESTING.md` (web checks paragraph)

**Interfaces:**
- Consumes: `reloadClient`, `nativeClient`, key `reload` (Task 1).
- Produces: `export function entryScript(doc: Document): string | null` (src of first `script[type="module"][src]`), `export async function newerClientServed(): Promise<boolean>` (fetch `/` with `cache: "no-store"`; false on any failure, non-OK status or missing script), `export const CLIENT_CHECK_MS = 600_000`; in App.svelte `let updateAvailable = $state(false)` and `async function checkClient(): Promise<void>`.

- [ ] **Step 1: Write the failing tests** in `client-version.spec.ts`, each serving a modified `/` via `page.route(new URL("/", hall.origin).href, …)` that `route.fetch()`es the real page and swaps the entry script's `src` for `/assets/index-newer.js`:
  - `"an open tab offers a reload once the hall serves a newer client"`: after connecting, dispatch `visibilitychange`; expect status "A new version of Feud Hall is available." with a "Reload" button; switch `Language / 言語` to `ja` and expect "新しいバージョンのFeud Hallが利用できます。" and "再読み込み"; unroute, click Reload, await `load`; notice absent.
  - `"no reload is offered while the hall serves the same client or cannot serve it"`: count `fetch` requests to `/`; dispatch `visibilitychange` → count 1, no notice; route `/` to 503 text, dispatch again → count 2, no notice; no `pageerror`.
  - `"a tab checks for a newer client when its connection returns"`: route `/api/state` to abort once then continue; with the modified `/` route, expect the notice without any `visibilitychange`.
  - In the first test, after the notice shows, dispatch `visibilitychange` again and assert no further fetch of `/`.
- [ ] **Step 2: Run them to verify they fail** — `bun run test:browser client-version.spec.ts` → the three new tests FAIL (no notice).
- [ ] **Step 3: Implement** `client-version.ts`; in App.svelte call `checkClient` from `resume`, from the 850 ms interval when `Date.now() - lastClientCheck >= CLIENT_CHECK_MS`, and from `refresh` success when `pollFailures > 0`; `checkClient` returns early if `nativeClient || updateAvailable`; banner `{#if updateAvailable && connected && !inWorldNotices}` with `newVersion` text and the Reload button.
- [ ] **Step 4: Run them to verify they pass** — `bun run test:browser client-version.spec.ts` → PASS.
- [ ] **Step 5: Docs** — TESTING.md web paragraph: `client-version.spec.ts` covers the reload notice and protocol refusal.
- [ ] **Step 6: Commit** — "Offer a reload when the hall serves a newer web client".

### Task 3: Reload row on the 3D hall tablet

**Files:**
- Modify: `app/src/hall-tablet.ts` (`TabletAction` kinds: add `"reload"`)
- Modify: `app/src/App.svelte` (`tabletView` rows near the `retry` row ~line 782; `tabletAction` ~line 241)
- Modify: `app/test/browser/hall-interactions.spec.ts`

**Interfaces:**
- Consumes: `updateAvailable`, `reloadClient`, `nativeClient`, keys `newVersion`, `reload` (Tasks 1–2).

- [ ] **Step 1: Write the failing test** `"the hall tablet offers the reload in place of a page banner"`: guest opens the s001 tablet as in the first test (`focusStall`, `stationControl(page, "menu")`); serve the modified `/`, dispatch `visibilitychange`; expect `.tablet-text-controls` to contain "A new version of Feud Hall is available." and `[data-tablet-kind="reload"]`; `main > .banner:not(.success-notice)` count 0; unroute, `tapTablet(page, "reload")` and await `load`.
- [ ] **Step 2: Run it to verify it fails** — `bun run test:browser hall-interactions.spec.ts --grep "offers the reload"` → FAIL.
- [ ] **Step 3: Implement** — when `updateAvailable`, push `{ text: t("newVersion") }` and `{ text: t("reload"), action: { kind: "reload" } }`; when `updateRequired && !nativeClient`, push only the action row (the message already comes from `problem`); `tabletAction` handles `"reload"` by calling `reloadClient()`.
- [ ] **Step 4: Run it, and the whole `hall-interactions.spec.ts`, to verify they pass.**
- [ ] **Step 5: Run checks** — `bun run format:check`, `bun run lint`, `bun check` → clean.
- [ ] **Step 6: Commit** — "Put the reload offer on the hall tablet".
