<script lang="ts">
  // Desktop only: tells the player that the last session closed without a
  // clean exit and where its diagnostic report is. There is deliberately no
  // Copy button: putting text on the clipboard makes the webview its owner,
  // the state the Linux WebKit crash this report exists for appears to need.
  import { invoke } from "@tauri-apps/api/core";
  import { onMount } from "svelte";
  import type { Key } from "./i18n";

  let { t }: { t: (key: Key) => string } = $props();

  type Report = { id: string; path: string };
  let reports = $state<Report[]>([]);
  let revealFailed = $state(false);

  function valid(value: unknown): value is Report[] {
    return (
      Array.isArray(value) &&
      value.every(
        (report) =>
          typeof report === "object" &&
          report !== null &&
          typeof report.id === "string" &&
          typeof report.path === "string",
      )
    );
  }

  onMount(() => {
    invoke<unknown>("crash_reports").then(
      (listed) => {
        if (valid(listed)) reports = listed;
      },
      () => {},
    );
  });

  async function reveal() {
    revealFailed = false;
    try {
      await invoke("reveal_crash_report");
    } catch {
      revealFailed = true;
    }
  }

  function dismiss() {
    reports = [];
    invoke("acknowledge_crash_reports").catch(() => {});
  }
</script>

{#if reports.length}
  <section class="banner crash-notice" aria-label={t("crashReportTitle")}>
    <div class="crash-notice-text">
      <p><strong>{t("crashReportTitle")}</strong> {t("crashReportBody")}</p>
      <code>{reports[0].path}</code>
      <button type="button" onclick={reveal}>{t("crashReportShow")}</button>
      {#if revealFailed}<p role="status">{t("crashReportShowFailed")}</p>{/if}
    </div>
    <button
      class="notice-dismiss"
      type="button"
      aria-label={t("dismissNotification")}
      onclick={dismiss}>×</button
    >
  </section>
{/if}

<style>
  .crash-notice {
    align-items: flex-start;
  }
  .crash-notice-text {
    display: grid;
    gap: 0.4rem;
    justify-items: start;
    min-width: 0;
  }
  .crash-notice-text p {
    margin: 0;
  }
  code {
    overflow-wrap: anywhere;
    user-select: text;
  }
</style>
