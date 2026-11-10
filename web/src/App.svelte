<script lang="ts">
  import { onMount } from "svelte";
  import { fade } from "svelte/transition";
  import appIcon from "../../assets/branding/feud-hall-icon.svg?no-inline";
  import CuisinePicker from "./CuisinePicker.svelte";
  import {
    ApiError,
    cash,
    clock,
    command,
    getQuote,
    getDiningHistory,
    getView,
    newDevice,
    send,
    serviceDuration,
  } from "./api";
  import type { DiningHistory, Page, Pending, Quote, View } from "./api";
  import { refusalMessage } from "./refusals";
  import { contentLabel, label } from "./i18n";
  import type { Key, Locale } from "./i18n";

  let locale = $state<Locale>("en");
  let page = $state<Page>("hall");
  let view = $state<View | null>(null);
  let connected = $state(true);
  let status = $state<"update" | "uncertain" | { refusal: string } | null>(
    null,
  );
  let dismissFocused = $state(false);
  let pending = $state<Pending | null>(null);
  let acknowledgedHandover = $state<Pending | null>(null);
  let submitting = $state(false);
  let guestName = $state("");
  let restaurantName = $state("");
  let chosenCuisine = $state("");
  let chosenSlot = $state("");
  let ownerStallId = $state("");
  let expansionStallId = $state("");
  let expansionCuisine = $state("");
  let refitCuisine = $state("");
  let stallId = $state("");
  let main = $state("");
  let drink = $state("");
  let diet = $state("unrestricted");
  let quote = $state<Quote | null>(null);
  type QuoteRequest = {
    kind: "tray" | "dessert";
    fields: Record<string, string>;
    key: string;
  };
  let quoteRequest = $state.raw<QuoteRequest | null>(null);
  let recipeId = $state("");
  let price = $state("");
  let product = $state("");
  let quantity = $state(1000);
  let maxPrice = $state("");
  let startHour = $state(5);
  let endHour = $state(17);
  let workerRole = $state("counter");
  let targetStock = $state(1000);
  let restockBudget = $state("10000");
  let minimumPrice = $state("500");
  let maximumPrice = $state("1600");
  let markup = $state(500);
  let cashFloor = $state("10000");
  let invitationCode = $state("");
  let recoveryCode = $state("");
  let motivation = $state("");
  let reviewReasons = $state<Partial<Record<string, string>>>({});
  let receipts = $state<DiningHistory | null>(null);
  let receiptError = $state(false);
  let receiptLoading = $state(false);
  let receiptRequest = 0;
  let composing = false;
  let refreshRunning = false;
  let selectedLanding = false;

  let profile = $derived(view?.profile ?? null);
  let receiptScope = $derived(
    page === "visit" && profile
      ? JSON.stringify([profile.account.id, profile.visit?.id])
      : "",
  );
  let restaurant = $derived(profile?.restaurant ?? null);
  let ownerStall = $derived(
    restaurant?.stalls.find((stall) => stall.id === ownerStallId) ??
      restaurant?.stalls[0],
  );
  let ownerMenu = $derived(ownerStall?.menu ?? restaurant?.menu ?? {});
  let starterStock = $derived(
    ownerStall?.starter_stock ?? restaurant?.starter_stock,
  );
  let expansionSlot = $derived(
    profile?.draft ??
      profile?.slots.find((slot) => slot.stall_id === expansionStallId),
  );
  let expansionEstimate = $derived.by(() => {
    const forecast = view?.hall.lease_forecast;
    if (!forecast || !expansionSlot || !expansionCuisine) return null;
    const margin = BigInt(forecast.starter_margins[expansionCuisine] ?? "0");
    const open = BigInt(forecast.trading_hours);
    const rent =
      (BigInt(expansionSlot.rent) * open +
        BigInt(expansionSlot.holding) * (24n - open)) /
      24n;
    const overhead = rent + BigInt(forecast.wages);
    return {
      overhead: overhead.toString(),
      meals:
        margin > 0n ? ((overhead + margin - 1n) / margin).toString() : null,
    };
  });
  let selectedStall = $derived(
    view?.hall.stalls.find((stall) => stall.stall_id === stallId),
  );
  let orderingStalls = $derived(
    view?.hall.access === "open"
      ? view.hall.stalls.filter((stall) => stall["open?"])
      : [],
  );
  let orderLocation = $derived(
    orderingStalls.find((stall) => stall.stall_id === stallId)?.stall_id ?? "",
  );
  let selectedSlot = $derived(
    profile?.draft ??
      profile?.slots.find((slot) => slot.stall_id === chosenSlot),
  );
  let selectedShift = $derived(profile?.work.active ?? null);
  let selectedHandover = $derived.by(() => {
    const shift = selectedShift;
    if (!shift?.selection) return;
    const { selection } = shift;
    if (selection.choice) return selection.choice;

    // A committed receipt can arrive before the next hall view.
    const acknowledged = acknowledgedHandover?.payload;
    if (
      acknowledged?.shift_id === shift.shift_id &&
      acknowledged.selection_id === selection.id
    ) {
      return selection.items.find((item) => item.id === acknowledged.item_id);
    }
  });
  let navigation = $derived<Page[]>(
    profile?.account["owner?"]
      ? [
          "business",
          "hall",
          "visit",
          "work",
          "profile",
          ...(profile.account["reviewer?"] ? ["review" as const] : []),
        ]
      : ["hall", "visit", "work", "profile"],
  );
  let disabled = $derived(!connected || submitting || pending !== null);

  const t = (key: Key) => label(locale, key);
  const title = (id: string) => contentLabel(locale, id);
  // The original managed hall API did not project its slice catalog's profiles.
  const legacyDietaryProfiles = [
    "unrestricted",
    "vegetarian",
    "vegan",
    "carb_conscious",
  ];
  let dietaryProfiles = $derived(
    view?.hall.dietary_profiles ?? legacyDietaryProfiles,
  );
  let trayRequest = $derived(currentQuoteRequest("tray"));
  let dessertRequest = $derived(currentQuoteRequest("dessert"));
  let currentQuote = $derived(
    quoteRequest && isCurrentQuoteRequest(quoteRequest) ? quote : null,
  );

  onMount(() => {
    locale = navigator.language.startsWith("ja") ? "ja" : "en";
    void refresh();
    const timer = window.setInterval(() => {
      if (!document.hidden) void refresh();
    }, 850);
    const presence = window.setInterval(() => {
      if (!document.hidden && connected && profile?.account["owner?"])
        void heartbeat();
      if (!document.hidden && connected && selectedShift) {
        void send(
          command("report_helper_presence", {
            shift_id: selectedShift.shift_id,
          }),
        ).catch(() => {
          connected = false;
        });
      }
    }, 8000);
    const compositionStart = () => {
      composing = true;
    };
    const compositionEnd = () => {
      composing = false;
    };
    window.addEventListener("compositionstart", compositionStart, true);
    window.addEventListener("compositionend", compositionEnd, true);
    return () => {
      window.clearInterval(timer);
      window.clearInterval(presence);
      window.removeEventListener("compositionstart", compositionStart, true);
      window.removeEventListener("compositionend", compositionEnd, true);
    };
  });

  $effect(() => {
    document.documentElement.lang = locale;
  });

  $effect(() => {
    if (receiptScope) void loadReceipts();
    return () => {
      receiptRequest++;
      receipts = null;
      receiptError = false;
      receiptLoading = false;
    };
  });

  async function loadReceipts(before?: string) {
    const request = ++receiptRequest;
    receiptLoading = true;
    receiptError = false;
    try {
      const next = await getDiningHistory(before);
      if (request === receiptRequest)
        receipts = {
          ...next,
          receipts: before
            ? [...(receipts?.receipts ?? []), ...next.receipts]
            : next.receipts,
        };
    } catch {
      if (request === receiptRequest) receiptError = true;
    } finally {
      if (request === receiptRequest) receiptLoading = false;
    }
  }

  $effect(() => {
    if (quoteRequest && !isCurrentQuoteRequest(quoteRequest)) {
      clearQuote();
    }
  });

  $effect(() => {
    if (status !== "update") {
      dismissFocused = false;
      return;
    }
    if (dismissFocused) return;
    const timer = window.setTimeout(() => {
      status = null;
    }, 4000);
    return () => window.clearTimeout(timer);
  });

  async function refresh() {
    if (refreshRunning) return;
    refreshRunning = true;
    try {
      const current = await getView();
      if (!view || current.hall.position >= view.hall.position) {
        if (
          !current.profile?.account["reviewer?"] ||
          current.profile.account.id !== profile?.account.id
        ) {
          reviewReasons = {};
        } else {
          const queued = new Set(
            current.profile.reviewer_queue.map((app) => app.application_id),
          );
          for (const id of Object.keys(reviewReasons)) {
            if (!queued.has(id)) delete reviewReasons[id];
          }
        }
        if (
          diet &&
          !(current.hall.dietary_profiles ?? legacyDietaryProfiles).includes(
            diet,
          )
        ) {
          diet = "";
        }
        view = current;
        if (!selectedLanding) {
          selectedLanding = true;
          if (current.profile?.account["owner?"]) page = "business";
        }
      }
      connected = true;
    } catch {
      connected = false;
    } finally {
      refreshRunning = false;
    }
  }

  async function heartbeat() {
    try {
      await send(command("report_owner_presence", { present: true }));
    } catch {
      connected = false;
    }
  }

  async function submit(kind: string, payload: Record<string, unknown> = {}) {
    if (disabled || composing) return;
    await deliver(command(kind, payload));
  }

  function reviewApplication(id: string, decision: "approved" | "rejected") {
    const reason = reviewReasons[id] || null;
    if (decision === "rejected" && !reason?.trim()) return;
    void submit("review_license_application", {
      application_id: id,
      decision,
      reason,
    });
  }

  async function deliver(action: Pending) {
    submitting = true;
    status = null;
    try {
      const result = await send(action);
      if (
        result.error === "unknown_outcome" ||
        result.error === "unavailable"
      ) {
        pending = action;
        status = "uncertain";
      } else {
        pending = null;
        if (result.accepted) {
          if (action.kind === "select_handover") acknowledgedHandover = action;
          else status = "update";
          clearQuote();
        } else {
          status = {
            refusal:
              result.reason === "unavailable"
                ? "ingredients_unavailable"
                : (result.reason ?? result.error ?? "unknown_rejection"),
          };
        }
      }
      await refresh();
    } catch {
      pending = action;
      status = "uncertain";
      connected = false;
    } finally {
      submitting = false;
    }
  }

  async function register(restore = false) {
    if (disabled || composing) return;
    try {
      await newDevice();
      if (restore)
        await submit("restore_device", { code: recoveryCode.trim() });
      else if (invitationCode.trim())
        await submit("join_with_invitation", {
          name: guestName,
          code: invitationCode.trim(),
        });
      else await submit("bootstrap_guest", { name: guestName });
      if (profile?.account["owner?"]) page = "business";
    } catch (error) {
      status = {
        refusal: error instanceof ApiError ? error.code : "network_error",
      };
    }
  }

  function inspect(stall: string) {
    stallId = stall;
    main = "";
    drink = "";
    clearQuote();
    page = "visit";
  }

  function clearQuote() {
    quote = null;
    quoteRequest = null;
  }

  function currentQuoteRequest(
    kind: QuoteRequest["kind"],
  ): QuoteRequest | null {
    const visit = profile?.visit;
    let fields: Record<string, string>;
    if (kind === "dessert") {
      if (visit?.dessert !== "offered" || view?.hall.access !== "open")
        return null;
      fields = { visit_id: visit.id };
    } else {
      if (
        visit ||
        !orderLocation ||
        !selectedStall ||
        !Object.hasOwn(selectedStall.menu, main) ||
        (drink && !Object.hasOwn(selectedStall.menu, drink)) ||
        !dietaryProfiles.includes(diet)
      )
        return null;
      fields = { stall_id: orderLocation, main, profile_id: diet };
      if (drink) fields.drink = drink;
    }
    return {
      kind,
      fields,
      key: JSON.stringify([kind, profile?.account.id ?? null, fields]),
    };
  }

  function isCurrentQuoteRequest(request: QuoteRequest) {
    return (
      quoteRequest === request &&
      request.key ===
        (request.kind === "tray" ? trayRequest : dessertRequest)?.key
    );
  }

  async function showQuote(request: QuoteRequest | null) {
    if (composing || !request) return;
    quote = null;
    // A fresh object also supersedes an earlier request for the same inputs.
    const sent = { ...request };
    quoteRequest = sent;
    status = null;
    try {
      const result = await getQuote(sent.fields);
      if (isCurrentQuoteRequest(sent)) quote = result;
    } catch (error) {
      if (!isCurrentQuoteRequest(sent)) return;
      if (error instanceof ApiError) {
        status = {
          // An unavailable ingredient bill is a 409. An unavailable hall returns 503.
          refusal:
            error.status === 409 && error.code === "unavailable"
              ? "ingredients_unavailable"
              : error.code,
        };
      } else {
        status = { refusal: "network_error" };
      }
    }
  }

  async function openStall(id: string) {
    await heartbeat();
    await submit("open_stall", { stall_id: id });
  }
</script>

<header>
  <div class="brand">
    <img class="brand-icon" src={appIcon} alt="" width="48" height="48" />
    <div><strong>Feud Hall</strong><small>{t("tagline")}</small></div>
  </div>
  <div class="header-end">
    {#if view}<span
        class:cleaning={view.hall.access === "cleaning"}
        class="clock"
        ><b>{clock(view.hall.now)}</b>
        {t(view.hall.access === "cleaning" ? "cleaning" : "online")}</span
      >{/if}
    <label class="locale"
      ><span class="sr-only">Language / 言語</span><select
        aria-label="Language / 言語"
        bind:value={locale}
        ><option value="en">English</option><option value="ja">日本語</option
        ></select
      ></label
    >
  </div>
</header>

<nav aria-label={t("hall")}>
  {#each navigation as section (section)}
    <button
      class:current={page === section}
      aria-current={page === section ? "page" : undefined}
      onclick={() => {
        page = section;
      }}>{t(section)}</button
    >
  {/each}
</nav>

<main>
  {#if !connected}<p class="banner" role="status">{t("offline")}</p>{/if}
  <span class="sr-only" role="status"
    >{status === "update" ? t("update") : ""}</span
  >
  {#if status === "update"}
    <div
      class="banner success-notice"
      out:fade={{
        duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches
          ? 0
          : 180,
      }}
    >
      <span aria-hidden="true">{t("update")}</span>
      <button
        class="notice-dismiss"
        type="button"
        aria-label={t("dismissNotification")}
        onfocus={() => (dismissFocused = true)}
        onblur={() => (dismissFocused = false)}
        onclick={() => (status = null)}>×</button
      >
    </div>
  {:else if status === "uncertain" || pending}<p class="banner" role="status">
      {t("uncertain")}
      {#if pending}<button
          disabled={!connected || submitting}
          onclick={() => pending && deliver(pending)}>{t("retry")}</button
        >{/if}
    </p>
  {:else if status}
    <div class="banner refusal-notice">
      <span role="status">{refusalMessage(locale, status.refusal)}</span>
      <button
        class="notice-dismiss"
        type="button"
        aria-label={t("dismissNotification")}
        onclick={() => (status = null)}>×</button
      >
    </div>
  {/if}
  {#if !view}
    <p>{t("loading")}</p>
  {:else if page === "hall"}
    <h1>{t("hall")}</h1>
    {#if !profile}<p>
        {t("guestHint")}
        <button
          onclick={() => {
            page = "profile";
          }}>{t("startGuest")}</button
        >
      </p>{/if}
    <div class="cards">
      {#each view.hall.stalls as stall (stall.stall_id)}
        <article class="stall">
          <p class="eyebrow">{stall.stall_id} · {title(stall.tier)}</p>
          <h2>{stall.name}</h2>
          <p>
            {title(stall.cuisine)}{stall.npc
              ? " · " + t("npcOperator")
              : ""}{stall.retiring ? " · " + t("npcRetiring") : ""}
          </p>
          {#each stall.awards ?? [] as award}
            {#if !award.cuisine || award.cuisine === stall.cuisine}
              <small>{title(award.distinction)}</small>
            {/if}
          {/each}
          <span class:good={stall["open?"] && view.hall.access === "open"}
            >{t(
              stall["open?"] && view.hall.access === "open" ? "open" : "closed",
            )}</span
          >
          <button onclick={() => inspect(stall.stall_id)}
            >{t("viewMenu")}</button
          >
        </article>
      {:else}<p>{t("emptyHall")}</p>{/each}
    </div>
    {#if view.hall.failed_ventures?.length}
      <details>
        <summary>{t("businessHistory")}</summary>
        <ul>
          {#each view.hall.failed_ventures as venture (venture.id)}
            <li>
              {venture.name}{venture.owner_name
                ? " · " + venture.owner_name
                : ""} · {venture.cuisines.map(title).join(", ")} ·
              {t("bankrupt")} · {t("diningDay").replace(
                "{day}",
                String(Math.floor(venture.ended_at / 86_400_000)),
              )}
            </li>
          {/each}
        </ul>
      </details>
    {/if}
  {:else if page === "business"}
    <h1>{restaurant?.name ?? t("createRestaurant")}</h1>
    {#if !profile?.account["owner?"]}<p>{t("needsLicense")}</p>
    {:else if !restaurant}
      <p>{t("setupHint")}</p>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          if (!selectedSlot) return;
          if (!profile?.draft)
            void submit("reserve_stall", { stall_id: selectedSlot.stall_id });
          else
            void submit("create_restaurant", {
              restaurant_id: crypto.randomUUID(),
              stall_id: selectedSlot.stall_id,
              name: restaurantName,
              cuisine: chosenCuisine,
            });
        }}
      >
        {#if profile.draft}
          <label
            >{t("restaurantName")}<input
              bind:value={restaurantName}
              required
              maxlength="48"
            /></label
          >
          <CuisinePicker
            cuisines={view.hall.cuisines}
            bind:value={chosenCuisine}
            label={t("cuisine")}
            overlapLabel={t("overlappingCuisines")}
            {title}
          />
        {:else}
          <label
            >{t("location")}<select
              aria-label={t("location")}
              bind:value={chosenSlot}
              required
              ><option value="">—</option
              >{#each profile.slots as slot (slot.stall_id)}<option
                  value={slot.stall_id}
                  >{slot.stall_id} · {title(slot.tier)} · {cash(
                    slot.rent,
                  )}</option
                >{/each}</select
            ></label
          >
        {/if}
        {#if selectedSlot}<p>
            {selectedSlot.stall_id} · {t("exposure")}
            {selectedSlot.exposure / 1000}× · {t("rent")}
            {cash(selectedSlot.rent)} · {t("holding")}
            {cash(selectedSlot.holding)} · {t("setupFee")}
            {cash(selectedSlot.setup_fee)}
          </p>{/if}
        <button disabled={disabled || !selectedSlot}
          >{t(profile.draft ? "confirmLease" : "reserveLease")}</button
        >
        {#if profile.draft}<button
            type="button"
            {disabled}
            onclick={() => submit("cancel_stall_draft")}
            >{t("releaseLease")}</button
          >{/if}
      </form>
      {#if !profile.draft && (profile.waitlisted || profile.slots.length === 0)}
        <button
          {disabled}
          onclick={() =>
            profile?.waitlisted
              ? submit("leave_waitlist")
              : submit("join_waitlist", { tiers: ["quiet", "standard"] })}
          >{t(profile.waitlisted ? "leaveWaitlist" : "joinWaitlist")}</button
        >
      {/if}
    {:else if restaurant.distress_deadline != null}
      <section>
        <h2>{t("businessDistress")}</h2>
        <p>{t("distressHint")}</p>
        <p>
          {t("unpaidCharges")}
          {cash(restaurant.unpaid ?? "0")} ·
          {t("recoveryEnds")}
          {serviceDuration(restaurant.distress_deadline - view.hall.now)}
        </p>
        <ul>
          {#each restaurant.salvage ?? [] as lot (lot.id)}
            <li>
              {title(lot.product)} · {lot.qty} · {cash(lot.amount)}
              <button
                {disabled}
                onclick={() =>
                  submit("salvage_stock", {
                    restaurant_id: restaurant?.id,
                    batch_id: lot.id,
                  })}
              >
                {t("salvage")}
              </button>
            </li>
          {/each}
        </ul>
        <ul>
          {#each restaurant.equipment_salvage ?? [] as asset (asset.stall_id + asset.technique)}
            <li>
              {asset.stall_id} · {title(asset.technique)} · {cash(asset.amount)}
              <button
                {disabled}
                onclick={() =>
                  submit("salvage_equipment", {
                    restaurant_id: restaurant?.id,
                    stall_id: asset.stall_id,
                    technique: asset.technique,
                  })}>{t("salvageEquipment")}</button
              >
            </li>
          {/each}
        </ul>
        {#if restaurant.stalls.length}
          <p>{t("surrenderDistressHint")}</p>
          <ul>
            {#each restaurant.stalls as stall (stall.id)}
              <li>
                {stall.id}
                <button
                  {disabled}
                  onclick={() =>
                    submit("surrender_location", {
                      restaurant_id: restaurant?.id,
                      stall_id: stall.id,
                    })}>{t("surrenderLocation")}</button
                >
              </li>
            {/each}
          </ul>
        {/if}
        <button
          {disabled}
          onclick={() =>
            submit("pay_arrears", { restaurant_id: restaurant?.id })}
        >
          {t("payArrears")}
        </button>
        <details>
          <summary>{t("acceptBankruptcy")}</summary>
          <button
            {disabled}
            onclick={() =>
              submit("accept_bankruptcy", { restaurant_id: restaurant?.id })}
          >
            {t("bankruptcyConfirm")}
          </button>
        </details>
      </section>
    {:else}
      {#if restaurant.stall_limit}
        <section>
          <h2>{t("currentLocations")}</h2>
          {#if ownerStall}
            <label
              >{t("location")}
              <select
                value={ownerStall.id}
                onchange={(event) => {
                  ownerStallId = event.currentTarget.value;
                  refitCuisine = "";
                }}
              >
                {#each restaurant.stalls as stall (stall.id)}
                  <option value={stall.id}
                    >{stall.id} · {title(
                      stall.cuisine ?? restaurant.cuisine,
                    )}</option
                  >
                {/each}
              </select>
            </label>
            {#if ownerStall.ready_at && ownerStall.ready_at > view.hall.now}
              <p>
                {t("readyIn")}
                {serviceDuration(ownerStall.ready_at - view.hall.now)}
              </p>
            {/if}
            {#if ownerStall.mode === "closed"}
              <details>
                <summary>{t("refitLocation")}</summary>
                <form
                  onsubmit={(event) => {
                    event.preventDefault();
                    if (restaurant && ownerStall && refitCuisine)
                      void submit("refit_location", {
                        restaurant_id: restaurant.id,
                        stall_id: ownerStall.id,
                        cuisine: refitCuisine,
                      });
                  }}
                >
                  <CuisinePicker
                    cuisines={view.hall.cuisines.filter(
                      (cuisine) => cuisine !== ownerStall?.cuisine,
                    )}
                    bind:value={refitCuisine}
                    label={t("chooseCuisine")}
                    overlapLabel={t("overlappingCuisines")}
                    {title}
                  />
                  <button
                    disabled={disabled ||
                      !refitCuisine ||
                      refitCuisine === ownerStall.cuisine}
                  >
                    {t("refitLocation")} · {cash(ownerStall.refit_cost ?? "0")}
                  </button>
                </form>
              </details>
              <p>{t("closedLocationHint")}</p>
              <button
                {disabled}
                onclick={() =>
                  submit("surrender_location", {
                    restaurant_id: restaurant?.id,
                    stall_id: ownerStall?.id,
                  })}
              >
                {t("surrenderLocation")}
              </button>
            {/if}
          {/if}
          {#if restaurant.stalls.length >= restaurant.stall_limit}
            <p>{t("noMoreLocations")}</p>
          {:else if profile.draft || profile.slots.length}
            <details>
              <summary
                >{t(
                  restaurant.stalls.length
                    ? "expandLocation"
                    : "reopenLocation",
                )}</summary
              >
              <form
                onsubmit={(event) => {
                  event.preventDefault();
                  if (restaurant && expansionSlot && expansionCuisine)
                    void submit("lease_location", {
                      restaurant_id: restaurant.id,
                      stall_id: expansionSlot.stall_id,
                      cuisine: expansionCuisine,
                    });
                }}
              >
                {#if !profile.draft}
                  <label
                    >{t("location")}
                    <select bind:value={expansionStallId} required>
                      <option value="">—</option>
                      {#each profile.slots as slot (slot.stall_id)}
                        <option value={slot.stall_id}
                          >{slot.stall_id} · {title(slot.tier)} · {cash(
                            slot.rent,
                          )}</option
                        >
                      {/each}
                    </select>
                  </label>
                {/if}
                {#if expansionSlot}
                  <p>
                    {expansionSlot.stall_id} · {t("exposure")}
                    {expansionSlot.exposure / 1000}× ·
                    {t("rent")}
                    {cash(expansionSlot.rent)} · {t("holding")}
                    {cash(expansionSlot.holding)} ·
                    {t("setupFee")}
                    {cash(expansionSlot.setup_fee)}
                  </p>
                {/if}
                <CuisinePicker
                  cuisines={view.hall.cuisines}
                  bind:value={expansionCuisine}
                  label={t("chooseCuisine")}
                  overlapLabel={t("overlappingCuisines")}
                  {title}
                />
                {#if expansionEstimate}
                  <p>
                    {t("dailyOverheadEstimate")}
                    {cash(expansionEstimate.overhead)}
                  </p>
                  {#if expansionEstimate.meals}
                    <p>
                      {t("breakEvenMeals").replace(
                        "{meals}",
                        expansionEstimate.meals,
                      )}
                    </p>
                  {:else}
                    <p>{t("noStarterMargin")}</p>
                  {/if}
                {/if}
                <button
                  disabled={disabled || !expansionSlot || !expansionCuisine}
                  >{t("leaseLocation")}</button
                >
              </form>
            </details>
          {/if}
          {#if !restaurant.stalls.length && !profile.draft && (profile.waitlisted || !profile.slots.length)}
            <button
              {disabled}
              onclick={() =>
                profile?.waitlisted
                  ? submit("leave_waitlist")
                  : submit("join_waitlist", {
                      tiers: ["quiet", "standard", "busy", "prime"],
                    })}
            >
              {t(profile.waitlisted ? "leaveWaitlist" : "joinWaitlist")}
            </button>
          {/if}
        </section>
        <section>
          <h2>{t("recognition")}</h2>
          <p>{t("reputation")} {(restaurant.reputation ?? 0) / 100}%</p>
          {#if restaurant.award_review_at != null}
            <p>
              {t("nextReview")}
              {t("diningDay").replace(
                "{day}",
                String(Math.floor(restaurant.award_review_at / 86_400_000)),
              )}
            </p>
          {/if}
          <h3>{t("milestones")}</h3>
          <ul>
            {#each restaurant.milestones ?? [] as milestone (milestone.milestone)}
              <li>{title(milestone.milestone)}</li>
            {/each}
          </ul>
          <h3>{t("awards")}</h3>
          <ul>
            {#each restaurant.awards ?? [] as award}
              <li>
                {title(award.distinction)}{award.cuisine
                  ? " · " + title(award.cuisine)
                  : ""}
              </li>
            {/each}
          </ul>
        </section>
      {/if}
      <div class="business-grid">
        <section>
          <h2>{t("viewMenu")}</h2>
          <p>
            {t("availableCash")}
            <strong>{cash(restaurant.available_cash)}</strong>
          </p>
          <ul>
            {#each Object.values(view.hall.recipes).filter((r) => r.cuisine === (ownerStall?.cuisine ?? restaurant?.cuisine)) as recipe (recipe.id)}
              {@const offer = ownerStall?.unlock_offers?.[recipe.id]}
              <li>
                {title(recipe.id)}
                {#if ownerMenu[recipe.id]}
                  <strong>{cash(ownerMenu[recipe.id])}</strong>
                  <button
                    {disabled}
                    onclick={() =>
                      submit("remove_menu_item", {
                        restaurant_id: restaurant?.id,
                        stall_id: ownerStall?.id,
                        recipe_id: recipe.id,
                      })}>{t("remove")}</button
                  >
                {/if}
                {#if offer}
                  <button
                    {disabled}
                    onclick={() =>
                      submit("unlock_recipe", {
                        restaurant_id: restaurant?.id,
                        stall_id: ownerStall?.id,
                        recipe_id: recipe.id,
                        max_cost: offer.cost,
                      })}
                  >
                    {t(offer.known ? "installEquipment" : "learn")} · {cash(
                      offer.cost,
                    )}
                  </button>
                  {#if offer.technique && offer.equipment !== "0"}
                    <small
                      >{t("equipmentCost")}
                      {title(offer.technique)} · {cash(offer.equipment)}</small
                    >
                  {/if}
                {/if}
              </li>
            {/each}
          </ul>
          <form
            onsubmit={(e) => {
              e.preventDefault();
              void submit("set_menu_price", {
                restaurant_id: restaurant?.id,
                stall_id: ownerStall?.id,
                recipe_id: recipeId,
                price,
              });
            }}
          >
            <label
              >{t("viewMenu")}<select bind:value={recipeId} required
                ><option value="">—</option
                >{#each restaurant.unlocked as id}<option value={id}
                    >{title(id)}</option
                  >{/each}</select
              ></label
            >
            <label
              >{t("price")}<input
                required
                pattern="[1-9][0-9]*"
                inputmode="numeric"
                bind:value={price}
              /></label
            >
            <button {disabled}>{t("setPrice")}</button>
          </form>
        </section>
        <section>
          <h2>{t("supply")}</h2>
          {#if starterStock && starterStock.items.length > 0}
            <details>
              <summary
                >{t("starterStock")} · {cash(starterStock.budget)}</summary
              >
              <ul>
                {#each starterStock.items as item (item.product)}<li>
                    {title(item.product)} · {item.qty}
                  </li>{/each}
              </ul>
              <button
                {disabled}
                onclick={() =>
                  restaurant &&
                  submit("request_starter_stock", {
                    restaurant_id: restaurant.id,
                    stall_id: ownerStall?.id,
                    budget: starterStock.budget,
                  })}>{t("buy")}</button
              >
            </details>
          {/if}

          <form
            onsubmit={(e) => {
              e.preventDefault();
              void submit("submit_purchase_request", {
                restaurant_id: restaurant?.id,
                product,
                qty: quantity,
                max_price_per_kunit: maxPrice,
              });
            }}
          >
            <label
              >{t("product")}<select bind:value={product} required
                ><option value="">—</option
                >{#each Object.entries(restaurant.market) as [id, item] (id)}<option
                    value={id}
                    >{title(id)} · {cash(item.price)} · {item.stock}</option
                  >{/each}</select
              ></label
            >
            <label
              >{t("quantity")}<input
                type="number"
                min="1"
                max="1000000"
                required
                bind:value={quantity}
              /></label
            >
            <label
              >{t("maxPrice")}<input
                inputmode="numeric"
                required
                pattern="[1-9][0-9]*"
                bind:value={maxPrice}
              /></label
            >
            <button {disabled}>{t("buy")}</button>
          </form>
          <details>
            <summary>{t("automation")}</summary>
            <form
              onsubmit={(event) => {
                event.preventDefault();
                void submit("set_restock_policy", {
                  restaurant_id: restaurant?.id,
                  product,
                  target: targetStock,
                  max_price_per_kunit: maxPrice,
                  daily_budget: restockBudget,
                });
              }}
            >
              <p>{t("restockHint")}</p>
              <label
                >{t("targetStock")}<input
                  type="number"
                  min="0"
                  max="1000000"
                  bind:value={targetStock}
                  required
                /></label
              >
              <label
                >{t("dailyBudget")}<input
                  inputmode="numeric"
                  bind:value={restockBudget}
                  required
                /></label
              >
              <button disabled={disabled || !product || !maxPrice}
                >{t("restockPolicy")}</button
              >
            </form>
            <form
              onsubmit={(event) => {
                event.preventDefault();
                void submit("set_pricing_policy", {
                  restaurant_id: restaurant?.id,
                  recipe_id: recipeId,
                  min_price: minimumPrice,
                  max_price: maximumPrice,
                  markup_permille: markup,
                  interval_hours: 1,
                });
              }}
            >
              <p>{t("pricingHint")}</p>
              <label
                >{t("minPrice")}<input
                  inputmode="numeric"
                  bind:value={minimumPrice}
                  required
                /></label
              >
              <label
                >{t("maxMenuPrice")}<input
                  inputmode="numeric"
                  bind:value={maximumPrice}
                  required
                /></label
              >
              <label
                >{t("markup")}<input
                  type="number"
                  min="0"
                  max="10000"
                  bind:value={markup}
                  required
                /></label
              >
              <button disabled={disabled || !recipeId}
                >{t("pricingPolicy")}</button
              >
            </form>
          </details>
          <h3>{t("stock")}</h3>
          <ul>
            {#each Object.entries(restaurant.inventory) as [id, qty] (id)}<li>
                {title(id)} · {qty}
              </li>{/each}
          </ul>
        </section>
        {#if ownerStall}
          <section>
            <h2>{t("staff")}</h2>
            <p>
              {ownerStall.id} · {ownerStall.lease.start_hour}:00–{ownerStall
                .lease.end_hour}:00
            </p>
            <div class="actions">
              <button
                {disabled}
                onclick={() =>
                  ownerStall &&
                  (ownerStall.mode === "open"
                    ? submit("close_stall", { stall_id: ownerStall.id })
                    : openStall(ownerStall.id))}
                >{t(
                  ownerStall.mode === "open"
                    ? "stopTrading"
                    : view.hall.access === "cleaning"
                      ? "queueOpening"
                      : "startTrading",
                )}</button
              >
              <button
                {disabled}
                onclick={() =>
                  ownerStall &&
                  submit("set_helper_offers", {
                    stall_id: ownerStall.id,
                    enabled: !ownerStall.lease.helper_offers,
                  })}
                >{t(
                  ownerStall.lease.helper_offers ? "helperOff" : "helperOn",
                )}</button
              >
            </div>
            <form
              onsubmit={(e) => {
                e.preventDefault();
                void submit("set_staff_schedule", {
                  stall_id: ownerStall?.id,
                  start_hour: startHour,
                  end_hour: endHour,
                });
              }}
            >
              <label
                >{t("from")}<input
                  type="number"
                  min="0"
                  max="23"
                  required
                  bind:value={startHour}
                /></label
              >
              <label
                >{t("until")}<input
                  type="number"
                  min="0"
                  max="24"
                  required
                  bind:value={endHour}
                /></label
              >
              <button {disabled}>{t("schedule")}</button>
            </form>
            <details>
              <summary>{t("roster")}</summary>
              <ul>
                {#each Object.values(ownerStall.lease.workers) as worker (worker.id)}
                  <li>
                    {title(worker.role)} · {worker.start_hour}:00–{worker.end_hour}:00
                    {#if worker.break_until}
                      · {t("protectiveBreak")}{:else if worker.tired}
                      · {t("tired")}{/if}
                    <button
                      {disabled}
                      onclick={() =>
                        ownerStall &&
                        submit("dismiss_staff", {
                          stall_id: ownerStall.id,
                          worker_id: worker.id,
                        })}>{t("dismiss")}</button
                    >
                    <button
                      {disabled}
                      onclick={() =>
                        ownerStall &&
                        submit("set_worker_schedule", {
                          stall_id: ownerStall.id,
                          worker_id: worker.id,
                          start_hour: startHour,
                          end_hour: endHour,
                        })}>{t("schedule")}</button
                    >
                  </li>
                {/each}
              </ul>
              <form
                onsubmit={(event) => {
                  event.preventDefault();
                  if (ownerStall)
                    void submit("hire_staff", {
                      stall_id: ownerStall.id,
                      role: workerRole,
                      start_hour: startHour,
                      end_hour: endHour,
                    });
                }}
              >
                <label
                  >{t("role")}<select bind:value={workerRole}
                    >{#each ["prep_cook", "finish_cook", "counter"] as role}<option
                        value={role}>{title(role)}</option
                      >{/each}</select
                  ></label
                >
                <p>{t("setupFee")} {cash("1000")}</p>
                <button {disabled}>{t("hire")}</button>
              </form>
            </details>
            <label
              >{t("cashFloor")}<input
                inputmode="numeric"
                bind:value={cashFloor}
              /></label
            >
            <button
              {disabled}
              onclick={() =>
                ownerStall &&
                submit("set_unattended_policy", {
                  stall_id: ownerStall.id,
                  enabled: !ownerStall.lease.unattended,
                  cash_floor: cashFloor,
                })}
              >{t(
                ownerStall.lease.unattended ? "unattendedOff" : "unattendedOn",
              )}</button
            >
          </section>
        {/if}
        <section>
          <h2>{t("performance")}</h2>
          <dl>
            {#each Object.entries(restaurant.ledger) as [id, amount] (id)}<dt>
                {title(id)}
              </dt>
              <dd>{cash(amount)}</dd>{/each}
          </dl>
          {#each restaurant.reports as report (report.day)}
            <details>
              <summary>{t("dayReview")} {report.day + 1}</summary>
              <dl>
                {#each Object.entries(report.delta) as [id, amount] (id)}<dt>
                    {title(id)}
                  </dt>
                  <dd>{cash(amount)}</dd>{/each}
              </dl>
            </details>
          {/each}
          <h3>{t("hall")}</h3>
          <ul>
            {#each view.hall.stalls as stall (stall.stall_id)}<li>
                {stall.name} · {t(stall["open?"] ? "open" : "closed")}
              </li>{/each}
          </ul>
        </section>
      </div>
    {/if}
  {:else if page === "visit"}
    <h1>{t("visit")}</h1>
    <p>{t("visitHint")}</p>
    {#if !profile}<p>
        {t("guestHint")}
        <button
          onclick={() => {
            page = "profile";
          }}>{t("startGuest")}</button
        >
      </p>
    {:else}
      <p>
        {t("balance")} <strong>{cash(profile.balance)}</strong>
        <button {disabled} onclick={() => submit("request_allowance")}
          >{t("allowance")}</button
        >
      </p>
      {#if profile.visit}
        <p>
          {t(profile.visit.tray_status === "served" ? "served" : "preparing")} · {profile
            .visit.stall}
        </p>
        {#if profile.visit.dessert === "offered"}
          <button
            disabled={disabled || !dessertRequest}
            onclick={() => showQuote(dessertRequest)}
            >{t("dessertQuote")}</button
          >
          <button
            {disabled}
            onclick={() =>
              submit("decline_dessert", { visit_id: profile?.visit?.id })}
            >{t("skip")}</button
          >
        {:else if profile.visit.tray_status === "accepted"}
          <button
            {disabled}
            onclick={() =>
              submit("cancel_tray", {
                tray_id: profile?.visit?.id.replace(/^V:/, "T:"),
              })}>{t("cancel")}</button
          >
        {/if}
      {/if}
    {/if}
    {#if !profile?.visit}
      {#if view.hall.access === "cleaning"}
        <p role="status">{t("cleaning")}</p>
      {:else if orderingStalls.length === 0}
        <p role="status">{t("noStallsServing")}</p>
      {:else}
        {#if selectedStall && !orderLocation}
          <p role="status">{t("selectedStallClosed")}</p>
        {/if}
        <label
          >{t("location")}<select
            value={orderLocation}
            onchange={(event) => inspect(event.currentTarget.value)}
            ><option value="">—</option
            >{#each orderingStalls as stall (stall.stall_id)}<option
                value={stall.stall_id}>{stall.name}</option
              >{/each}</select
          ></label
        >
      {/if}
      {#if selectedStall}
        {#if !orderLocation}<h2>{selectedStall.name}</h2>{/if}
        <form
          onsubmit={(e) => {
            e.preventDefault();
            void showQuote(trayRequest);
          }}
        >
          <label
            >{t("main")}<select bind:value={main} required onchange={clearQuote}
              ><option value="">—</option
              >{#each Object.entries(selectedStall.menu).filter(([id]) => view?.hall.recipes[id]?.kind === "main") as [id, value]}<option
                  value={id}>{title(id)} · {cash(value)}</option
                >{/each}</select
            ></label
          >
          <label
            >{t("drink")}<select bind:value={drink} onchange={clearQuote}
              ><option value="">{t("noDrink")}</option
              >{#each Object.entries(selectedStall.menu).filter(([id]) => view?.hall.recipes[id]?.kind === "drink") as [id, value]}<option
                  value={id}>{title(id)} · {cash(value)}</option
                >{/each}</select
            ></label
          >
          <label
            >{t("diet")}<select bind:value={diet} required onchange={clearQuote}
              ><option value="" disabled>—</option
              >{#each dietaryProfiles as id (id)}<option value={id}
                  >{title(id)}</option
                >{/each}</select
            ></label
          >
          <button disabled={disabled || !trayRequest}>{t("quote")}</button>
        </form>
      {:else if orderingStalls.length > 0}<p>{t("chooseStall")}</p>{/if}
    {/if}
    {#if currentQuote}
      <section class="quote">
        <p>
          <strong>{cash(currentQuote.total)}</strong> · {clock(
            currentQuote.earliest_completion,
          )}
        </p>
        <button
          disabled={disabled || !profile}
          onclick={() => {
            if (!profile || !currentQuote || !quoteRequest) return;
            const { kind, fields } = quoteRequest;
            const payload = { ...fields, confirmed: currentQuote.terms };
            if (kind === "dessert") void submit("accept_dessert", payload);
            else
              void submit("admit_visit", {
                ...payload,
                drink: fields.drink ?? null,
              });
          }}>{t("acceptOrder")}</button
        >
      </section>
    {/if}
    {#if profile}
      <section>
        <h2>{t("diningHistory")}</h2>
        {#if receipts}
          {#each receipts.receipts as receipt (receipt.visit_id)}
            <details>
              <summary>
                {receipt.stall_id} · {t("diningDay").replace(
                  "{day}",
                  String(Math.floor(receipt.at / 86_400_000)),
                )}
                {clock(receipt.at)} ·
                {t("diningCharged")}
                {cash(receipt.total)}
              </summary>
              <ul>
                {#each receipt.courses as course (course.kind)}
                  <li>
                    {title(course.recipe_id)} ·
                    {t(
                      course.outcome === "served"
                        ? "courseServed"
                        : "courseUnserved",
                    )} ·
                    {cash(course.charged)}
                  </li>
                {/each}
              </ul>
            </details>
          {:else}<p>{t("diningHistoryEmpty")}</p>{/each}
          {#if receipts.before}
            <button
              disabled={receiptLoading}
              onclick={() => loadReceipts(receipts?.before ?? undefined)}
            >
              {t("diningHistoryOlder")}
            </button>
          {/if}
        {/if}
        {#if receiptError}
          <p role="status">{t("diningHistoryUnavailable")}</p>
          {#if !receipts}
            <button onclick={() => loadReceipts()}
              >{t("diningHistoryRetry")}</button
            >
          {/if}
        {/if}
      </section>
    {/if}
  {:else if page === "work"}
    <h1>{t("work")}</h1>
    <p>{t("workHint")}</p>
    {#if !profile}<button
        onclick={() => {
          page = "profile";
        }}>{t("startGuest")}</button
      >
    {:else if selectedShift}
      <section>
        <h2>{t("support")} · {selectedShift.stall_id}</h2>
        <p>
          {t("tasks")}
          {selectedShift.tasks} ·
          <span role="timer"
            >{t("shiftTimeLeft").replace(
              "{duration}",
              serviceDuration(selectedShift.expires_at - view.hall.now),
            )}</span
          >
        </p>
        {#if selectedShift.handover}
          <p role="status">
            {t("handoverInProgress").replace(
              "{items}",
              selectedShift.handover.recipes.map(title).join(" + "),
            )}
          </p>
          <p role="timer">
            {t("shiftTimeLeft").replace(
              "{duration}",
              serviceDuration(selectedShift.handover.done_at - view.hall.now),
            )}
          </p>
        {:else if selectedHandover}
          <p role="status">
            {t("handoverSelected").replace(
              "{items}",
              selectedHandover.recipes.map(title).join(" + "),
            )}
          </p>
        {:else if selectedShift.selection}
          <h3>{t("selectTask")}</h3>
          <p role="timer">
            {t("shiftTimeLeft").replace(
              "{duration}",
              serviceDuration(selectedShift.selection.deadline - view.hall.now),
            )}
          </p>
          {#each selectedShift.selection.items as item (item.id)}
            <button
              {disabled}
              onclick={() =>
                submit("select_handover", {
                  shift_id: selectedShift?.shift_id,
                  selection_id: selectedShift?.selection?.id,
                  item_id: item.id,
                  recipes: item.recipes,
                })}>{item.recipes.map(title).join(" + ")}</button
            >
          {/each}
        {:else}<p>{t("standby")}</p>{/if}
        <button
          {disabled}
          onclick={() =>
            submit("leave_helper_shift", { shift_id: selectedShift?.shift_id })}
          >{t("leaveShift")}</button
        >
      </section>
    {:else}
      <div class="cards">
        {#each profile.work.offers as offer (offer.stall_id)}
          <article>
            <h2>{offer.stall_id} · {t("support")}</h2>
            <p>
              {t("wage")}
              {cash(offer.rate)} · {t("pay")}
              {cash(offer.estimated_pay)} · {t("shiftLength").replace(
                "{duration}",
                serviceDuration(offer.expires_at - offer.quoted_at),
              )}
            </p>

            <button
              {disabled}
              onclick={() =>
                submit("accept_helper_shift", {
                  stall_id: offer.stall_id,
                  rate: offer.rate,
                  expires_at: offer.expires_at,
                  quoted_at: offer.quoted_at,
                })}>{t("acceptShift")}</button
            >
          </article>
        {:else}<p>{t("noShifts")}</p>{/each}
      </div>
    {/if}
    {#if profile && profile.work.history.length}
      <h2>{t("history")}</h2>
      <ul>
        {#each profile.work.history as shift (shift.shift_id)}<li>
            {cash(shift.amount)} · {title(shift.reason)}
            {#if shift.qualified}· {t("qualified")}{/if}
            {#if shift.reason === "actionable_idle"}
              <details class="shift-help">
                <summary>
                  <span class="shift-help-icon" aria-hidden="true">?</span>
                  <span class="sr-only">{t("selectionWindowHelpLabel")}</span>
                </summary>
                <p>{t("selectionWindowHelp")}</p>
              </details>
            {/if}
          </li>{/each}
      </ul>
    {/if}
  {:else if page === "profile"}
    <h1>{t("profile")}</h1>
    {#if !profile}
      <p>{t("profileHint")}</p>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void register();
        }}
      >
        <label
          >{t("name")}<input
            bind:value={guestName}
            maxlength="40"
            required
          /></label
        >
        <label
          >{t("optionalInvite")}<input
            bind:value={invitationCode}
            maxlength="220"
          /></label
        ><button {disabled}>{t("startGuest")}</button>
      </form>
      <section>
        <h2>{t("restore")}</h2>
        <p id="restore-profile-hint">{t("restoreHint")}</p>
        <form
          onsubmit={(e) => {
            e.preventDefault();
            void register(true);
          }}
        >
          <label
            >{t("recoveryCode")}<input
              aria-describedby="restore-profile-hint"
              autocomplete="off"
              spellcheck="false"
              bind:value={recoveryCode}
              maxlength="220"
              required
            /></label
          ><button {disabled}>{t("restore")}</button>
        </form>
      </section>
    {:else}
      <h2>{profile.account.name}</h2>
      {#if profile.ventures?.length}
        <section>
          <h3>{t("businessHistory")}</h3>
          {#each profile.ventures as venture (venture.id)}
            <details>
              <summary>{venture.name} · {t("bankrupt")}</summary>
              <p>
                {venture.cuisines.map(title).join(", ")} · {t("unpaidCharges")}
                {cash(venture.unpaid ?? "0")}
              </p>
              <dl>
                {#each Object.entries(venture.final_ledger ?? {}) as [key, value] (key)}
                  <dt>{title(key)}</dt>
                  <dd>{cash(value)}</dd>
                {/each}
              </dl>
            </details>
          {/each}
        </section>
      {/if}
      <div class="business-grid">
        <section>
          <h3>{t("invitation")}</h3>
          {#if profile.account["owner?"]}
            <p>
              {t("quota")}
              {profile.account.quota} · {Math.floor(
                profile.account.progress / 6048000,
              )}%
            </p>
            <button
              disabled={disabled || profile.account.quota <= 0}
              onclick={() => submit("issue_invitation")}>{t("issue")}</button
            >
            <ul>
              {#each profile.invitations as invite (invite.id)}<li>
                  {title(invite.status)}
                  {#if invite.code}<code>{invite.code}</code><button
                      {disabled}
                      onclick={() =>
                        submit("revoke_invitation", {
                          invitation_id: invite.id,
                        })}>{t("revoke")}</button
                    >{/if}
                </li>{/each}
            </ul>
          {:else}
            <form
              onsubmit={(e) => {
                e.preventDefault();
                void submit("redeem_invitation", { code: invitationCode });
              }}
            >
              <label
                >{t("invitation")}<input
                  bind:value={invitationCode}
                  maxlength="220"
                  required
                /></label
              ><button {disabled}>{t("redeem")}</button>
            </form>
          {/if}
        </section>
        {#if !profile.account["owner?"]}
          <section>
            <h3>{t("application")}</h3>
            {#if profile.account.proof}
              {#if !profile.applications.some((app) => app.status === "pending")}
                <form
                  onsubmit={(e) => {
                    e.preventDefault();
                    void submit("apply_for_license", {
                      motivation: motivation || null,
                    });
                  }}
                >
                  <label
                    >{t("motivate")}<textarea
                      maxlength="500"
                      bind:value={motivation}></textarea></label
                  ><button {disabled}>{t("apply")}</button>
                </form>
              {/if}
            {:else}<p>{t("awaitingProof")}</p>{/if}
            <ul>
              {#each profile.applications as app (app.application_id)}<li>
                  {title(
                    app.status === "rejected" ? "rejectedStatus" : app.status,
                  )}
                  {app.reason ?? ""}{#if app.status === "pending"}
                    <button
                      {disabled}
                      onclick={() =>
                        submit("withdraw_license_application", {
                          application_id: app.application_id,
                        })}>{t("withdraw")}</button
                    >{/if}
                </li>{/each}
            </ul>
          </section>
        {/if}
        <section>
          <h3>{t("recovery")}</h3>
          <p>{t("saveRecovery")}</p>
          <button {disabled} onclick={() => submit("issue_recovery_code")}
            >{t("generate")}</button
          >
          {#each profile.recovery_codes as code (code)}<p>
              <code>{code}</code>
            </p>{/each}
          <button {disabled} onclick={() => submit("revoke_device")}
            >{t("signOut")}</button
          >
        </section>
        <section>
          <h3>{t("notices")}</h3>
          {#each profile.notices as notice}<p>
              {notice.status
                ? title(
                    notice.status === "rejected"
                      ? "rejectedStatus"
                      : notice.status,
                  )
                : t("redeemed")}
              {notice.reason ?? ""}
            </p>{:else}<p>{t("noNotices")}</p>{/each}
        </section>
      </div>
    {/if}
  {:else if page === "review" && profile?.account["reviewer?"]}
    <h1>{t("reviewQueue")}</h1>
    <div class="cards">
      {#each profile.reviewer_queue as app (app.application_id)}
        <article>
          <h2>{app.name}</h2>
          <p>{app.proof.stall_id} · {t("tasks")} {app.proof.tasks}</p>
          <p>{app.motivation ?? ""}</p>
          <label
            >{t("reason")}<textarea
              bind:value={reviewReasons[app.application_id]}
              maxlength="500"></textarea></label
          >
          <button
            {disabled}
            onclick={() => reviewApplication(app.application_id, "approved")}
            >{t("approve")}</button
          >
          <button
            disabled={disabled || !reviewReasons[app.application_id]?.trim()}
            onclick={() => reviewApplication(app.application_id, "rejected")}
            >{t("reject")}</button
          >
        </article>
      {:else}<p>{t("noApplications")}</p>{/each}
    </div>
  {/if}
</main>
