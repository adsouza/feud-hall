<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { fade } from "svelte/transition";
  import type { MarketTrip, Restaurant, Stall } from "./api";
  import type { Key } from "./i18n";
  import { goodFor, shelves, type VendorId } from "./market-goods";
  import {
    addCrate,
    arrivedCrates,
    dismissWay,
    lineEstimate,
    lineNotes,
    limitInvalid,
    sendBlocked,
    onItsWay,
    recordSend,
    reprice,
    requests,
    setCrates,
    setLimit,
    type LineNote,
    type Offer,
    type WayLine,
  } from "./market-cart";
  import {
    forRestaurant,
    market as draft,
    views,
    webglAvailable,
    type Delivery,
  } from "./market-state.svelte";
  import type {
    MarketActions,
    MarketAppearance,
    MarketScene,
  } from "./market-scene";

  let {
    restaurant,
    trips,
    stalls,
    visible,
    disabled,
    submit,
    title,
    cash,
    t,
    reasonText,
  }: {
    restaurant: Restaurant;
    trips: MarketTrip[];
    stalls: Stall[];
    /** The Supply section is shown; the scene draws only then. */
    visible: boolean;
    disabled: boolean;
    submit: (
      kind: string,
      payload: Record<string, unknown>,
    ) => Promise<Delivery>;
    title: (id: string) => string;
    cash: (amount: string) => string;
    t: (key: Key) => string;
    reasonText: (code: string) => string;
  } = $props();

  const PRICE = /^[0-9]+$/;
  const STAR_NOTE_KEY = "feudhall.market.starNote";
  const STAR_NOTE_MS = 8000;
  const LOW_LEVEL = 300;
  const SCENE_MIN_WIDTH = 720;

  $effect.pre(() => forRestaurant(restaurant.id));

  const fill = (key: Key, values: Record<string, string | number>) =>
    Object.entries(values).reduce(
      (text, [name, value]) => text.replaceAll(`{${name}}`, String(value)),
      t(key),
    );
  const money = (amount: unknown) =>
    typeof amount === "string" && PRICE.test(amount)
      ? cash(amount)
      : t("priceUnavailable");
  const vendorName = (vendor: VendorId) => t(`vendor_${vendor}` as Key);
  const crateText = (crate: number) => fill("crateOf", { quantity: crate });
  const levelOf = (product: string): number | null => {
    const level = restaurant.market[product]?.level;
    return typeof level === "number" && Number.isFinite(level)
      ? Math.min(1000, Math.max(0, level))
      : null;
  };

  /** Offers the cart can use: a well-formed price and a crate size. */
  let offers = $derived.by(() => {
    const out: Record<string, Offer> = {};
    for (const [id, entry] of Object.entries(restaurant.market)) {
      const crate = entry?.crate;
      if (
        typeof entry?.price === "string" &&
        PRICE.test(entry.price) &&
        typeof crate === "number" &&
        Number.isInteger(crate) &&
        crate > 0 &&
        Number.isFinite(entry.stock)
      )
        out[id] = {
          price: entry.price,
          stock: entry.stock,
          crate,
          level: levelOf(id) ?? 1000,
        };
    }
    return out;
  });
  let starred = $derived(new Set(restaurant.menu_products ?? []));
  let rows = $derived(shelves(Object.keys(restaurant.market)));
  let vendorProducts = $derived(
    rows.find((row) => row.vendor === draft.vendor)?.products ?? [],
  );
  let pendingRequests = $derived(restaurant.purchases?.pending ?? []);

  // Unedited limits follow the price; a line whose offer became unusable
  // stays, shown as unavailable, until the owner removes it.
  $effect(() => {
    const current = offers;
    untrack(() => {
      const next = reprice(draft.cart, current);
      if (JSON.stringify(next) !== JSON.stringify(draft.cart))
        draft.cart = next;
      if (draft.vendor && !rows.some((row) => row.vendor === draft.vendor))
        draft.vendor = null;
    });
  });

  function addToCart(product: string) {
    const offer = offers[product];
    if (!offer) return;
    draft.cart = addCrate(draft.cart, product, offer);
    delete draft.refused[product];
  }
  function changeCrates(product: string, crates: number) {
    draft.cart = setCrates(draft.cart, product, crates);
    delete draft.refused[product];
    if (!draft.cart.lines.some((line) => line.product === product))
      delete draft.limitText[product];
  }
  function editLimit(product: string, text: string) {
    draft.limitText[product] = text;
    draft.cart = setLimit(draft.cart, product, text.trim());
    delete draft.refused[product];
  }
  /** Typed limit text that cannot be sent; it stays in the field until fixed. */
  const badLimit = (product: string) => {
    const text = draft.limitText[product];
    return text !== undefined && limitInvalid(text);
  };
  let anyBadLimit = $derived(sendBlocked(draft.cart, draft.limitText, offers));
  function removeLine(product: string) {
    changeCrates(product, 0);
  }
  function chooseVendor(vendor: VendorId | null) {
    draft.vendor = vendor;
    if (
      draft.selected &&
      (vendor === null || goodFor(draft.selected).vendor !== vendor)
    )
      draft.selected = "";
  }
  function select(product: string) {
    if (draft.selected !== product) draft.selected = product;
  }
  function emptyTheCart() {
    draft.cart = { lines: [] };
    draft.limitText = {};
    draft.refused = {};
  }

  // ---------------------------------------------------------------------
  // Sending: one request per line, in cart order, through the app's path.
  // ---------------------------------------------------------------------
  let sending = $state(false);
  async function sendOrder() {
    if (sending || disabled || anyBadLimit) return;
    sending = true;
    try {
      for (const product of draft.cart.lines.map((line) => line.product)) {
        const line = draft.cart.lines.find((l) => l.product === product);
        if (!line) continue;
        // An unavailable line stays in the cart and is not sent.
        const [payload] = requests({ lines: [line] }, offers, restaurant.id);
        if (!payload || badLimit(product)) continue;
        const result = await submit("submit_purchase_request", payload);
        if (result.outcome === "skipped") break;
        if (result.outcome === "refused") {
          draft.refused[product] = result.reason ?? "unknown_rejection";
          continue;
        }
        draft.cart = {
          lines: draft.cart.lines.filter((l) => l.product !== product),
        };
        delete draft.refused[product];
        delete draft.limitText[product];
        if (result.commandId)
          draft.sent = recordSend(draft.sent, {
            commandId: result.commandId,
            product,
            outcome: result.outcome === "uncertain" ? "uncertain" : "accepted",
            stamp: result.viewStamp,
            now: Date.now(),
          });
        // The app holds one uncertain command at a time.
        if (result.outcome === "uncertain") break;
      }
    } finally {
      sending = false;
    }
  }

  // ---------------------------------------------------------------------
  // On its way: the server's pending requests and recent outcomes, and this
  // session's sends it does not list yet (see onItsWay in market-cart.ts).
  // ---------------------------------------------------------------------
  let now = $state(Date.now());
  let way = $derived(
    onItsWay({
      purchases: restaurant.purchases ?? null,
      sent: draft.sent,
      viewStamp: views.shown,
      memory: draft.way,
      now,
    }),
  );
  // What the list remembers moves on with each view and each second.
  $effect(() => {
    const next = way;
    untrack(() => {
      if (JSON.stringify(next.memory) !== JSON.stringify(draft.way))
        draft.way = next.memory;
      if (JSON.stringify(next.sent) !== JSON.stringify(draft.sent))
        draft.sent = next.sent;
    });
  });
  // Crates the server filled, on the cart while their line is listed.
  let arrived = $derived(
    arrivedCrates([...way.lines].reverse(), restaurant.market),
  );
  function dismiss(requestId: string) {
    const next = dismissWay(draft.way, draft.sent, requestId);
    draft.way = next.memory;
    draft.sent = next.sent;
  }
  function statusText(item: WayLine) {
    const reason = item.reason ? reasonText(item.reason) : "";
    switch (item.state) {
      case "unconfirmed":
        return t("orderUnconfirmed");
      case "pending":
        return t("fillsAtNextClearing");
      case "filled":
        return fill("orderFilled", {
          units: item.filled,
          cost: money(item.cost),
        });
      case "short":
        return fill("orderShort", {
          arrived: item.filled,
          missing: item.short,
          reason,
        });
      case "rejected":
        return fill("orderRejected", { reason });
      case "sent":
        return t("orderSent");
      default:
        return t("orderSettled");
    }
  }
  const noteKeys: Record<LineNote, Key> = {
    replaces_pending: "noteReplacesPending",
    price_above_limit: "notePriceAboveLimit",
    more_than_stock: "noteMoreThanStock",
  };

  // ---------------------------------------------------------------------
  // The scene, when WebGL and the width allow; the list is always there.
  // ---------------------------------------------------------------------
  let panelWidth = $state(0);
  let webgl = $state(webglAvailable());
  let failed = $state(false);
  let motion = $state(true);
  let host = $state<HTMLDivElement>();
  let scene = $state.raw<MarketScene | null>(null);
  let hoverProduct = $state("");
  let rival = $state("");
  let showScene = $derived(webgl && !failed && panelWidth >= SCENE_MIN_WIDTH);
  let detailProduct = $derived(hoverProduct || draft.selected);
  const restaurantName = (id: string) =>
    stalls.find((stall) => stall.restaurant_id === id)?.name ?? "";
  const actions: MarketActions = {
    add: (product) => addToCart(product),
    focusVendor: (vendor) => chooseVendor(vendor),
    hover: (product) => (hoverProduct = product),
    hoverShopper: (name) => (rival = name),
    fail: () => (failed = true),
  };

  // The scene is created the first time its host comes on screen and draws
  // only while it is on screen (and the Supply section is shown).
  let onScreen = $state(false);
  $effect(() => {
    const element = host;
    if (!element) return;
    let live = true;
    let started = false;
    let created: MarketScene | null = null;
    const start = () => {
      if (started) return;
      started = true;
      void import("./market-scene")
        .then(({ createMarketScene }) => {
          if (!live) return;
          try {
            created = createMarketScene(element, actions);
            lastKey = "";
            scene = created;
          } catch {
            webgl = false;
          }
        })
        .catch(() => {
          if (live) webgl = false;
        });
    };
    const observer = new IntersectionObserver((entries) => {
      const entry = entries[entries.length - 1];
      if (!entry) return;
      onScreen = entry.isIntersecting;
      if (onScreen) start();
    });
    observer.observe(element);
    return () => {
      live = false;
      observer.disconnect();
      created?.dispose();
      scene = null;
      onScreen = false;
      hoverProduct = "";
      rival = "";
    };
  });

  let appearance = $derived<MarketAppearance>({
    market: restaurant.market,
    starred: [...starred],
    cart: draft.cart.lines.map((line) => ({
      product: line.product,
      crates: line.crates,
    })),
    arrived,
    focusedVendor: draft.vendor,
    selected: draft.selected,
    trips,
    ownRestaurant: restaurant.id,
    restaurantName,
    vendorLabel: vendorName,
    priceLabel: (price) => money(price),
    crateLabel: crateText,
    motion,
  });
  // The scene re-lays its containers on every update: only on a real change.
  let lastKey = "";
  $effect(() => {
    const next = appearance;
    if (!scene) return;
    const key = JSON.stringify([
      next.market,
      next.starred,
      next.cart,
      next.arrived,
      next.focusedVendor,
      next.selected,
      next.trips,
      next.ownRestaurant,
      next.motion,
      crateText(1),
      vendorName("pantry"),
      money("1000"),
      stalls.map((stall) => [stall.restaurant_id, stall.name]),
    ]);
    if (key === lastKey) return;
    lastKey = key;
    scene.update(next);
  });
  $effect(() => {
    scene?.setVisible(visible && onScreen);
  });

  // ---------------------------------------------------------------------
  // The first-visit note about stars.
  // ---------------------------------------------------------------------
  let starNote = $state(false);
  let noteDecided = false;
  let noteTimer: ReturnType<typeof setTimeout> | undefined;
  $effect(() => {
    if (!visible || noteDecided) return;
    noteDecided = true;
    let seen = false;
    try {
      seen = localStorage.getItem(STAR_NOTE_KEY) === "1";
      if (!seen) localStorage.setItem(STAR_NOTE_KEY, "1");
    } catch {
      // Without storage the note cannot be remembered; show it.
    }
    if (seen) return;
    starNote = true;
    noteTimer = setTimeout(() => (starNote = false), STAR_NOTE_MS);
  });

  onMount(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => (motion = !reduce.matches);
    update();
    reduce.addEventListener("change", update);
    const clock = setInterval(() => (now = Date.now()), 1000);
    return () => {
      reduce.removeEventListener("change", update);
      clearInterval(clock);
      clearTimeout(noteTimer);
    };
  });
</script>

{#snippet star(id?: string)}
  <span
    class="market-star"
    {id}
    role="img"
    aria-label={t("starredSupply")}
    title={t("starredSupply")}>★</span
  >
{/snippet}

<div class="market-panel" data-market-panel bind:clientWidth={panelWidth}>
  <h3 class="market-heading" tabindex="-1">{t("market")}</h3>
  <div class="market-note-slot" role="status">
    {#if starNote}
      <p class="market-note" transition:fade={{ duration: motion ? 400 : 0 }}>
        <span aria-hidden="true" class="market-star">★</span>
        {t("starNote")}
        <button
          type="button"
          class="market-small"
          onclick={() => {
            starNote = false;
            clearTimeout(noteTimer);
          }}>{t("marketDismiss")}</button
        >
      </p>
    {/if}
  </div>
  <div class="market-body">
    <div class="market-shop">
      {#if showScene}
        <div class="market-scene" data-market-scene bind:this={host}></div>
        <p class="market-detail">
          {#if detailProduct && restaurant.market[detailProduct]}
            {@const entry = restaurant.market[detailProduct]}
            {@const level = levelOf(detailProduct)}
            <strong>{title(detailProduct)}</strong>
            · {fill("perThousand", { price: money(entry.price) })}
            {#if typeof entry.crate === "number"}· {crateText(entry.crate)}{/if}
            {#if level !== null}· {fill("stockLevel", {
                percent: Math.round(level / 10),
              })}{/if}
          {/if}
        </p>
        <p class="market-rival" class:quiet={!rival} aria-live="polite">
          {rival ? fill("rivalShopping", { name: rival }) : ""}
        </p>
      {:else if panelWidth > 0 || failed || !webgl}
        <!-- Only once the panel is measured: no flash of the list-only note. -->
        <p class="market-mode" data-market-list-only>
          {t(failed ? "marketSceneFailed" : "marketListOnly")}
        </p>
      {/if}
      <div class="market-vendors" role="group" aria-label={t("marketVendors")}>
        <button
          type="button"
          aria-pressed={draft.vendor === null}
          onclick={() => chooseVendor(null)}>{t("wholeMarket")}</button
        >
        {#each rows as row (row.vendor)}
          <button
            type="button"
            aria-pressed={draft.vendor === row.vendor}
            onclick={() => chooseVendor(row.vendor)}
            >{vendorName(row.vendor)}</button
          >
        {/each}
      </div>
      {#if draft.vendor === null}
        <p class="market-hint">{t("pickVendor")}</p>
      {:else}
        <ul class="market-goods" aria-label={vendorName(draft.vendor)}>
          {#each vendorProducts as id (id)}
            {@const entry = restaurant.market[id]}
            {@const level = levelOf(id)}
            {@const variant = goodFor(id).variant}
            <li
              class:selected={draft.selected === id}
              data-market-product={id}
              onfocusin={() => select(id)}
              onmouseenter={() => select(id)}
            >
              <span class="market-name">
                {#if starred.has(id)}{@render star(`market-star-${id}`)}{/if}
                {title(id)}
              </span>
              <span class="market-tag">
                {PRICE.test(entry.price)
                  ? fill("perThousand", { price: money(entry.price) })
                  : t("priceUnavailable")}
                {#if typeof entry.crate === "number"}· {crateText(
                    entry.crate,
                  )}{/if}
              </span>
              <span class="market-stock">
                {#if level !== null}
                  <meter
                    min="0"
                    max="1000"
                    low={LOW_LEVEL}
                    optimum="1000"
                    value={level}
                    aria-label={fill("stockLevel", {
                      percent: Math.round(level / 10),
                    })}
                  ></meter>
                  {#if entry.stock === 0}
                    <span class="market-flag market-empty"
                      >{t("outOfStock")}</span
                    >
                  {:else if level < LOW_LEVEL}
                    <span class="market-flag market-low">{t("lowStock")}</span>
                  {/if}
                {/if}
                {#if variant !== "plain"}
                  <span class="market-variant"
                    >{t(`variant_${variant}` as Key)}</span
                  >
                {/if}
              </span>
              <button
                type="button"
                class="market-add"
                disabled={!offers[id]}
                aria-label={fill("addCrateOf", { name: title(id) })}
                aria-describedby={starred.has(id)
                  ? `market-star-${id}`
                  : undefined}
                onclick={() => addToCart(id)}>{t("addCrate")}</button
              >
            </li>
          {/each}
        </ul>
      {/if}
      <div class="market-legend">
        <h4>{t("legend")}</h4>
        <ul>
          <li>
            <span class="market-star" aria-hidden="true">★</span>
            {t("starredSupply")}
          </li>
          {#if showScene}
            <li>
              <span class="swatch swatch-arrived" aria-hidden="true"></span>
              {t("legendArrived")}
            </li>
          {/if}
          <li>
            <span class="swatch swatch-low" aria-hidden="true"></span>
            {t("legendLow")}
          </li>
          <li>
            <span class="swatch swatch-empty" aria-hidden="true"></span>
            {t("legendEmpty")}
          </li>
          <li>
            <span class="swatch swatch-frozen" aria-hidden="true"></span>
            {t("legendFrozen")}
          </li>
          <li>
            <span class="swatch swatch-value" aria-hidden="true"></span>
            {t("legendValue")}
          </li>
          <li>
            <span class="swatch swatch-shelf" aria-hidden="true"></span>
            {t("legendShelf")}
          </li>
        </ul>
      </div>
    </div>
    <div class="market-side">
      <div class="market-cart">
        <h4>{t("cart")}</h4>
        {#if draft.cart.lines.length === 0}
          <p class="market-hint">{t("cartEmpty")}</p>
        {:else}
          <ul aria-label={t("cart")}>
            {#each draft.cart.lines as line (line.product)}
              {@const offer = offers[line.product]}
              {@const name = title(line.product)}
              <li
                data-cart-line={line.product}
                data-cart-unavailable={offer ? undefined : ""}
              >
                <strong>{name}</strong>
                {#if !offer}
                  <p class="market-line-note" data-cart-note="unavailable">
                    {t("cartLineUnavailable")}
                  </p>
                  <button
                    type="button"
                    class="market-small"
                    aria-label={fill("removeLineOf", { name })}
                    onclick={() => removeLine(line.product)}
                    >{t("removeLine")}</button
                  >
                {:else}
                  <div class="market-line">
                    <span class="market-stepper">
                      <button
                        type="button"
                        class="market-small"
                        aria-label={fill("oneFewerCrate", { name })}
                        onclick={() =>
                          changeCrates(line.product, line.crates - 1)}>−</button
                      >
                      <span
                        >{t("crates")}
                        <strong data-cart-crates>{line.crates}</strong></span
                      >
                      <button
                        type="button"
                        class="market-small"
                        aria-label={fill("oneMoreCrate", { name })}
                        onclick={() =>
                          changeCrates(line.product, line.crates + 1)}>+</button
                      >
                    </span>
                    <span
                      >{t("quantity")}
                      <strong data-cart-qty>{line.crates * offer.crate}</strong
                      ></span
                    >
                  </div>
                  {@const invalid = badLimit(line.product)}
                  <label class="market-limit"
                    >{t("priceLimit")}<input
                      inputmode="numeric"
                      autocomplete="off"
                      aria-label={fill("priceLimitOf", { name })}
                      aria-invalid={invalid}
                      aria-describedby={invalid
                        ? `market-limit-error-${line.product}`
                        : undefined}
                      value={draft.limitText[line.product] ?? line.limit}
                      oninput={(event) =>
                        editLimit(line.product, event.currentTarget.value)}
                      onblur={() => {
                        // Valid text is the line's limit now; invalid text stays to be fixed.
                        if (!badLimit(line.product))
                          delete draft.limitText[line.product];
                      }}
                    /></label
                  >
                  {#if invalid}
                    <p
                      class="market-refused"
                      id={`market-limit-error-${line.product}`}
                      data-cart-limit-invalid
                    >
                      {t("limitInvalid")}
                    </p>
                  {/if}
                  <p class="market-estimate">
                    {t("estimate")}
                    <strong>{cash(lineEstimate(line, offer))}</strong>
                  </p>
                  {#each lineNotes(line, offer, pendingRequests) as note (note)}
                    <p class="market-line-note" data-cart-note={note}>
                      {t(noteKeys[note])}
                    </p>
                  {/each}
                {/if}
                {#if draft.refused[line.product]}
                  <p class="market-refused" data-cart-refused>
                    {reasonText(draft.refused[line.product])}
                  </p>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
        <div class="market-cart-actions">
          <button
            type="button"
            disabled={disabled ||
              sending ||
              anyBadLimit ||
              draft.cart.lines.length === 0}
            onclick={sendOrder}>{t("sendOrder")}</button
          >
          <button
            type="button"
            disabled={sending || draft.cart.lines.length === 0}
            onclick={emptyTheCart}>{t("emptyCart")}</button
          >
        </div>
      </div>
      <div class="market-way">
        <h4>{t("onItsWay")}</h4>
        <ul aria-label={t("onItsWay")} aria-live="polite">
          {#each way.lines as item (item.requestId)}
            <li
              data-way-state={item.state}
              data-way-request={item.requestId}
              data-way-automated={item.automated ? "" : undefined}
            >
              <span
                ><strong
                  >{title(item.product)}{#if item.automated}
                    <span class="market-variant">{t("marketAutomatic")}</span
                    >{/if}</strong
                >
                {statusText(item)}</span
              >
              {#if item.state !== "unconfirmed"}
                <button
                  type="button"
                  class="market-small"
                  aria-label={fill("dismissLineOf", {
                    name: title(item.product),
                  })}
                  onclick={() => dismiss(item.requestId)}>×</button
                >
              {/if}
            </li>
          {/each}
        </ul>
      </div>
    </div>
  </div>
</div>

<style>
  .market-panel {
    container-type: inline-size;
    margin-bottom: 1rem;
  }
  .market-heading {
    margin-top: 0;
  }
  .market-heading:focus {
    outline: none;
  }
  .market-body {
    display: grid;
    gap: 1rem;
  }
  .market-body > * {
    min-width: 0;
  }
  @container (min-width: 1000px) {
    .market-body {
      grid-template-columns: minmax(0, 1fr) minmax(17rem, 22rem);
      align-items: start;
    }
  }
  .market-scene {
    position: relative;
    width: 100%;
    aspect-ratio: 16 / 9;
    border-radius: 0.6rem;
    overflow: hidden;
    background: #e8dcc6;
  }
  .market-detail,
  .market-rival {
    min-height: 1.55em;
    margin: 0.35rem 0;
  }
  .market-rival {
    color: var(--text-muted);
  }
  .market-rival.quiet {
    min-height: 0;
    margin: 0;
  }
  .market-mode,
  .market-hint {
    color: var(--text-muted);
  }
  .market-note {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem;
    margin: 0 0 0.75rem;
    padding: 0.4rem 0.75rem;
    border: 1px solid var(--accent);
    border-radius: 0.6rem;
  }
  .market-vendors {
    display: flex;
    flex-wrap: wrap;
    margin: 0.5rem 0;
  }
  .market-vendors button[aria-pressed="true"] {
    border-color: var(--accent);
    color: var(--accent);
  }
  .market-goods,
  .market-cart ul,
  .market-way ul,
  .market-legend ul {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  /* A long stall scrolls in place so the legend stays under the shelves. */
  @container (min-width: 641px) {
    .market-goods {
      max-height: 30rem;
      overflow-y: auto;
    }
  }
  .market-goods li {
    display: grid;
    grid-template-columns:
      minmax(8rem, 1.4fr) minmax(8rem, 1fr) minmax(7rem, 1fr)
      auto;
    gap: 0.25rem 0.75rem;
    align-items: center;
    padding: 0.3rem 0.5rem;
    border-bottom: 1px solid var(--line);
  }
  .market-goods li.selected {
    background: #2b3150;
  }
  @container (max-width: 640px) {
    .market-goods li {
      grid-template-columns: minmax(0, 1fr) auto;
    }
    .market-tag,
    .market-stock {
      grid-column: 1;
    }
    .market-add {
      grid-column: 2;
      grid-row: 1 / span 3;
    }
  }
  .market-tag {
    font-variant-numeric: tabular-nums;
  }
  .market-stock {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.4rem;
  }
  .market-stock meter {
    width: 4.5rem;
  }
  .market-star {
    color: #ffc93a;
    margin-inline-end: 0.25rem;
  }
  .market-flag,
  .market-variant {
    font-size: 0.85rem;
    padding: 0 0.4rem;
    border-radius: 0.3rem;
  }
  .market-low {
    background: #e2412b;
    color: #fff;
  }
  .market-empty {
    background: #d8d2c8;
    color: #3a332c;
  }
  .market-variant {
    border: 1px solid var(--line);
    color: var(--text-muted);
  }
  .market-legend {
    margin-top: 0.75rem;
    font-size: 0.9rem;
    color: var(--text-muted);
  }
  .market-legend h4 {
    margin: 0 0 0.25rem;
  }
  .market-legend ul {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem 1rem;
  }
  .market-legend li {
    display: flex;
    align-items: center;
    gap: 0.35rem;
  }
  .swatch {
    display: inline-block;
    width: 1.1rem;
    height: 0.8rem;
    border-radius: 0.2rem;
    border: 2px solid #4a3626;
    background: #fff8e8;
  }
  .swatch-arrived {
    background: #b07a3c;
    border-color: #4a3626;
    border-top: 4px solid #2fbf5f;
  }
  .swatch-low {
    border-color: #e2412b;
    border-width: 3px;
  }
  .swatch-empty {
    background: #d8d2c8;
  }
  .swatch-frozen {
    background: #d6ecf8;
    border-color: #2f74b5;
  }
  .swatch-value {
    background: #b89d6c;
    border-radius: 0.5rem 0.5rem 0.25rem 0.25rem;
  }
  .swatch-shelf {
    background: #cfae80;
    border-radius: 0;
  }
  .market-side {
    display: grid;
    gap: 1rem;
    align-content: start;
  }
  .market-cart h4,
  .market-way h4 {
    margin: 0 0 0.4rem;
  }
  .market-cart li,
  .market-way li {
    padding: 0.4rem 0;
    border-bottom: 1px solid var(--line);
  }
  .market-line {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.25rem 1rem;
  }
  .market-stepper {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
  }
  .market-small {
    min-width: 2.75rem;
    margin: 0;
  }
  .market-limit input {
    max-width: 10rem;
  }
  .market-estimate,
  .market-line-note,
  .market-refused {
    margin: 0.2rem 0;
  }
  .market-line-note {
    color: var(--accent);
  }
  .market-refused {
    color: #ff9f8f;
  }
  .market-way li strong {
    display: block;
  }
  .market-way li {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 0.5rem;
  }
</style>
