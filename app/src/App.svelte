<script lang="ts">
  import { onMount, tick, untrack } from "svelte";
  import { isTauri } from "@tauri-apps/api/core";
  import { fade } from "svelte/transition";
  import appIcon from "../../assets/branding/feud-hall-icon.svg?no-inline";
  import CuisinePicker from "./CuisinePicker.svelte";
  import CuisineArtwork from "./CuisineArtwork.svelte";
  import DinerCompare from "./DinerCompare.svelte";
  import HallScene from "./HallScene.svelte";
  import type { CameraState, HallTarget } from "./hall-scene";
  import { splitTabletMessage } from "./tablet-text";
  import { CLIENT_CHECK_MS, newerClientServed } from "./client-version";
  import { servedTrays } from "./diner-pickup";
  import { assignSpots } from "./room-layout";
  import { rentExplanation } from "./rent";
  import type { TabletView, TabletAction, TabletRow } from "./hall-tablet";
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
  import type {
    DiningFilters,
    DiningHistory,
    DiningOption,
    DiningOptions,
    Page,
    Pending,
    Quote,
    Slot,
    Stall,
    View,
  } from "./api";
  import { refusalMessage } from "./refusals";
  import { contentLabel, label } from "./i18n";
  import type { Key, Locale } from "./i18n";

  let locale = $state<Locale>("en");
  let page = $state<Page>("hall");
  type BusinessSection =
    "locations" | "menu" | "supply" | "staff" | "performance" | "recognition";
  type PhoneRoute = {
    page: Page;
    detail: boolean;
    section: BusinessSection;
    stall: string;
    scroll: number;
  };
  const businessLabels: Record<BusinessSection, Key> = {
    locations: "currentLocations",
    menu: "viewMenu",
    supply: "supply",
    staff: "staff",
    performance: "performance",
    recognition: "recognition",
  };
  const navigationIcons: Record<Page, string> = {
    business: "M3 10h18M5 10v11h14V10M2 10l3-7h14l3 7M9 21v-7h6v7",
    hall: "M3 21V7l9-4 9 4v14M7 11h10M7 16h10M7 21h10",
    visit:
      "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z",
    work: "M8 7V3h8v4M3 7h18v14H3ZM3 12h18M10 12v3h4v-3",
    profile: "M12 13a5 5 0 1 0 0-10 5 5 0 0 0 0 10ZM3 22a9 9 0 0 1 18 0",
    review: "M5 3h14v18H5ZM8 8h8M8 13h8M8 18h5",
  };
  let phone = $state(false);
  let phoneDetail = $state(false);
  let businessSection = $state<BusinessSection>("menu");
  let stallInspector = $state<HTMLElement>();
  let hallPicker = $state<HTMLSelectElement>();
  let hallTrigger: HTMLElement | null = null;

  function route(): PhoneRoute {
    return {
      page,
      detail: phoneDetail,
      section: businessSection,
      stall: hallSelection,
      scroll: window.scrollY,
    };
  }
  function rememberRoute(push = false, scroll = window.scrollY) {
    const state = { ...history.state, feudHallUI: { ...route(), scroll } };
    if (push) history.pushState(state, "");
    else history.replaceState(state, "");
  }
  function readRoute(value: unknown): PhoneRoute | null {
    if (!value || typeof value !== "object") return null;
    const r = value as Record<string, unknown>;
    if (!(
      typeof r.page === "string" &&
      ["business", "hall", "visit", "work", "profile", "review"].includes(
        r.page,
      ) &&
      typeof r.detail === "boolean" &&
      typeof r.section === "string" &&
      Object.hasOwn(businessLabels, r.section) &&
      typeof r.stall === "string" &&
      typeof r.scroll === "number" &&
      Number.isFinite(r.scroll)
    ))
      return null;
    return {
      page: r.page as Page,
      detail: r.detail,
      section: r.section as BusinessSection,
      stall: r.stall,
      scroll: Math.max(0, r.scroll),
    };
  }
  function navigate(
    next: Page,
    detail = false,
    section = businessSection,
    stall = hallSelection,
  ) {
    if (
      next === page &&
      detail === phoneDetail &&
      section === businessSection &&
      stall === hallSelection
    )
      return;
    if (phone) rememberRoute();
    page = next;
    phoneDetail = detail;
    businessSection = section;
    hallSelection = stall;
    if (phone) {
      rememberRoute(true, 0);
      void tick().then(() => {
        window.scrollTo(0, 0);
        if (detail) stallInspector?.focus({ preventScroll: true });
      });
    }
  }
  function openStallDetails(id: string, trigger?: HTMLElement) {
    hallTrigger =
      trigger ??
      (document.activeElement instanceof HTMLElement &&
      document.activeElement !== document.body &&
      document.activeElement !== document.documentElement
        ? document.activeElement
        : null);
    hallSelection = id;
    if (phone) navigate("hall", true, businessSection, id);
  }
  function focusHall() {
    void tick().then(() => {
      if (hallTrigger?.isConnected && hallTrigger.getClientRects().length)
        hallTrigger.focus({ preventScroll: true });
      else if (phone) hallPicker?.focus({ preventScroll: true });
      else stallInspector?.focus({ preventScroll: true });
    });
  }
  function backToHall() {
    const current = readRoute(history.state?.feudHallUI);
    if (current?.page === "hall" && current.detail) history.back();
    else {
      phoneDetail = false;
      rememberRoute();
      focusHall();
    }
  }
  let view = $state<View | null>(null);
  let connected = $state(true);
  let updateRequired = $state(false);
  // A web tab reloads to fetch the client the hall now serves; the desktop
  // app bundles its client and needs a new package instead.
  const nativeClient = isTauri();
  const connectionProblem = $derived<Key>(
    !updateRequired
      ? "offline"
      : nativeClient
        ? "updateRequired"
        : "reloadRequired",
  );
  function reloadClient() {
    location.reload();
  }
  let updateAvailable = $state(false);
  let checkingClient = false;
  let lastClientCheck = Date.now();
  async function checkClient() {
    if (nativeClient || updateAvailable || checkingClient) return;
    checkingClient = true;
    lastClientCheck = Date.now();
    try {
      updateAvailable = await newerClientServed();
    } finally {
      checkingClient = false;
    }
  }
  let nextPoll = 0;
  let pollFailures = 0;
  let status = $state<"update" | "uncertain" | { refusal: string } | null>(
    null,
  );
  let dismissFocused = $state(false);
  let pending = $state<Pending | null>(null);
  let acknowledgedHandover = $state<Pending | null>(null);
  let submitting = $state(false);
  let hallMode = $state<"3d" | "list">("3d");
  let hallSelection = $state("");
  let immersiveHall = $state(false);
  let tabletStall = $state("");
  let tabletRegistering = $state(false);
  let tabletPage = $state<"menu" | "diets" | "drinks" | "review">("menu");

  function openTablet(id: string) {
    hallInteraction = null;
    hallSelection = id;
    tabletStall = id;
    tabletPage = "menu";
    immersiveHall = true;
    phoneDetail = false;
    if (stallId !== id) {
      stallId = id;
      main = "";
      drink = "";
      clearQuote();
    }
  }

  async function confirmCurrentQuote(token?: string) {
    if (!profile || !currentQuote || !quoteRequest || disabled) return;
    if (token && token !== JSON.stringify(currentQuote.terms)) return;
    const { kind, fields } = quoteRequest;
    const payload = { ...fields, confirmed: currentQuote.terms };
    if (kind === "dessert") await submit("accept_dessert", payload);
    else
      await submit("admit_visit", { ...payload, drink: fields.drink ?? null });
  }

  async function tabletAction(id: string, action: TabletAction) {
    if (action.kind === "open") {
      openTablet(id);
      return;
    }
    if (id !== tabletStall || id !== hallSelection) return;
    if (action.kind === "visit") {
      if (profile?.visit) openTablet(profile.visit.stall);
      return;
    }
    if (action.kind === "close") {
      tabletStall = "";
      return;
    }
    if (action.kind === "menu") {
      tabletPage = "menu";
      clearQuote();
      return;
    }
    if (action.kind === "diets") {
      tabletPage = "diets";
      return;
    }
    if (action.kind === "drinks") {
      tabletPage = "drinks";
      return;
    }
    if (action.kind === "retry") {
      if (pending && connected && !submitting) await deliver(pending);
      return;
    }
    if (disabled) return;
    switch (action.kind) {
      case "main":
        if (availableMains.includes(action.id)) {
          main = action.id;
          tabletPage = "menu";
          drink = "";
          clearQuote();
        }
        break;
      case "drink":
        if (!action.id || availableDrinks.includes(action.id)) {
          drink = action.id;
          clearQuote();
          tabletPage = "menu";
        }
        break;
      case "diet":
        if (dietaryProfiles.includes(action.id)) {
          diet = action.id;
          clearQuote();
          tabletPage = "menu";
        }
        break;
      case "review":
        tabletPage = "review";
        await showQuote(trayRequest);
        break;
      case "dessert":
        tabletPage = "review";
        await showQuote(dessertRequest);
        break;
      case "confirm":
        await confirmCurrentQuote(action.token);
        break;
      case "skip":
        await submit("decline_dessert", { visit_id: profile?.visit?.id });
        break;
      case "allowance":
        await submit("request_allowance");
        break;
      case "guest":
        if (tabletRegistering) return;
        tabletRegistering = true;
        try {
          await newDevice();
          await submit("bootstrap_guest", { name: t("tabletVisitorName") });
        } catch (error) {
          status = {
            refusal: error instanceof ApiError ? error.code : "network_error",
          };
        } finally {
          tabletRegistering = false;
        }
        break;
      case "cancel":
        if (profile?.visit?.can_cancel_dessert)
          await submit("cancel_dessert", { visit_id: profile.visit.id });
        else if (profile?.visit?.can_cancel)
          await submit("cancel_tray", {
            tray_id: profile.visit.id.replace(/^V:/, "T:"),
          });
        break;
    }
  }
  let hallInteraction = $state<{ stall: string; target: HallTarget } | null>(
    null,
  );
  let hallWorkbench = $state<HTMLElement>();
  let hallActionTrigger: HTMLElement | null = null;
  const targetLabels: Record<HallTarget, Key> = {
    menu: "hallMenuAction",
    counter: "hallCounterAction",
    staff: "hallStaffAction",
    supply: "hallSupplyAction",
  };

  function openHallInteraction(id: string, target: HallTarget) {
    const stall = view?.hall.stalls.find((stall) => stall.stall_id === id);
    if (
      hallMode === "3d" &&
      stall &&
      !ownStall(stall) &&
      (target === "menu" ||
        (target === "counter" && selectedShift?.stall_id !== id))
    ) {
      openTablet(id);
      return;
    }
    tabletStall = "";
    hallActionTrigger =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;
    hallSelection = id;
    hallInteraction = { stall: id, target };
    const owned = restaurant?.stalls.find((stall) => stall.id === id);
    if (owned) ownerStallId = id;
    if (stallId !== id) {
      stallId = id;
      main = "";
      drink = "";
      clearQuote();
    }
    void tick().then(() => {
      hallWorkbench?.focus({ preventScroll: true });
      if (!immersiveHall || window.innerWidth < 850)
        hallWorkbench?.scrollIntoView({ block: "nearest" });
    });
  }

  function closeHallInteraction() {
    hallInteraction = null;
    void tick().then(() => {
      if (
        hallActionTrigger?.isConnected &&
        hallActionTrigger.getClientRects().length
      )
        hallActionTrigger.focus({ preventScroll: true });
      else
        document
          .querySelector<HTMLElement>("[data-hall-canvas]")
          ?.focus({ preventScroll: true });
      if (
        window.innerWidth < 850 &&
        document.activeElement instanceof HTMLElement
      )
        document.activeElement.scrollIntoView({ block: "nearest" });
    });
  }
  let sceneError = $state(false);
  let camera = $state.raw<CameraState>();
  let comparison = $state<DiningOptions | null>(null);
  let compareFilters = $state<DiningFilters>({
    profile: "unrestricted",
    budget: "",
    drink: false,
    newOnly: false,
    onlySelected: false,
    sort: "wait",
  });
  let guestName = $state("");
  let restaurantName = $state("");
  let chosenCuisine = $state("");
  let chosenSlot = $state("");
  let ownerStallId = $state("");
  let expansionStallId = $state("");
  let expansionOpen = $state(false);
  let expansionDetails = $state<HTMLDetailsElement>();
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
  let receiptOwnerId = $state("");
  let takenTrayIds = $state<string[]>([]);
  let composing = false;
  let refreshRunning = false;
  let selectedLanding = false;

  let profile = $derived(view?.profile ?? null);
  let receiptScope = $derived(
    (page === "visit" || (page === "hall" && view?.hall.visitor_play)) &&
      profile
      ? JSON.stringify([
          page,
          profile.account.id,
          profile.visit?.id,
          profile.balance,
        ])
      : "",
  );
  let hallStall = $derived(
    view?.hall.stalls.find((stall) => stall.stall_id === hallSelection),
  );
  /** The vacant spot being viewed; exclusive with a selected stall. */
  let hallVacancy = $state("");
  /** A viewed spot that someone else took while its panel was open. */
  let spotTaken = $state("");
  let viewedSpot = $derived(
    view?.hall.vacancies?.find((vacancy) => vacancy.stall_id === hallVacancy),
  );
  /**
   * Stalls and vacant spots of each open room, for halls with the room rule;
   * stalls without room data take the scene's fallback rooms.
   */
  let hallGroups = $derived.by(() => {
    const hall = view?.hall;
    if (!hall?.rooms) return null;
    const spots = assignSpots(hall.stalls);
    return Array.from({ length: hall.rooms.open }, (_, i) => i + 1).map(
      (room) => ({
        room,
        stalls: hall.stalls.filter(
          (stall) => spots.get(stall.stall_id)?.room === room,
        ),
        vacancies: (hall.vacancies ?? []).filter(
          (vacancy) => vacancy.room === room,
        ),
      }),
    );
  });
  const hallRoomLabel = (room: number) =>
    t("hallRoom").replace("{n}", String(room));
  function viewSpot(id: string) {
    hallSelection = "";
    spotTaken = "";
    hallVacancy = id;
    // The panel lives in the inspector, which the immersive view hides.
    immersiveHall = false;
    if (phone) navigate("hall", true, businessSection, "");
  }
  function closeSpot() {
    hallVacancy = "";
    spotTaken = "";
    if (phone && phoneDetail) backToHall();
  }
  let recentPickup = $derived.by(() => {
    const newest = receipts?.receipts[0];
    if (!newest || !view || view.hall.now - newest.at > 720_000) return "";
    return newest.courses.some(
      (course) => course.kind === "main" && course.outcome === "served",
    )
      ? newest.stall_id
      : "";
  });
  let pickup = $derived(
    profile?.visit
      ? profile.visit.stage === "served"
        ? profile.visit.stall
        : ""
      : recentPickup,
  );
  let personalTrays = $derived(
    view?.hall.access === "open"
      ? servedTrays(
          profile,
          receiptOwnerId === profile?.account.id ? receipts : null,
          view.hall.now,
        ).filter((tray) => !takenTrayIds.includes(tray.id))
      : [],
  );
  function takePersonalTray(id: string) {
    if (!personalTrays.some((tray) => tray.id === id)) return false;
    takenTrayIds = [...takenTrayIds.slice(-79), id];
    return true;
  }
  let restaurant = $derived(profile?.restaurant ?? null);
  let ownerStall = $derived(
    restaurant?.stalls.find((stall) => stall.id === ownerStallId) ??
      restaurant?.stalls[0],
  );
  let businessSections = $derived<BusinessSection[]>([
    ...(restaurant?.stall_limit ? ["locations" as const] : []),
    "menu",
    "supply",
    ...(ownerStall ? ["staff" as const] : []),
    "performance",
    ...(restaurant?.stall_limit ? ["recognition" as const] : []),
  ]);
  let visibleBusinessSection = $derived(
    businessSections.includes(businessSection) ? businessSection : "menu",
  );
  let ownerMenu = $derived(ownerStall?.menu ?? restaurant?.menu ?? {});
  let starterStock = $derived(
    ownerStall?.starter_stock ?? restaurant?.starter_stock,
  );
  let expansionSlot = $derived(
    profile?.draft ??
      profile?.slots.find((slot) => slot.stall_id === expansionStallId),
  );
  let expansionRentLine = $derived.by(() =>
    expansionSlot ? rentLine(expansionSlot) : "",
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
  let visitStall = $derived(
    profile?.visit
      ? view?.hall.stalls.find(
          (stall) => stall.stall_id === profile.visit?.stall,
        )
      : selectedStall,
  );
  const ownStall = (stall: Stall) =>
    !!restaurant && stall.restaurant_id === restaurant.id;
  let servingStalls = $derived(
    view?.hall.access === "open"
      ? view.hall.stalls.filter((stall) => stall["open?"])
      : [],
  );
  let orderingStalls = $derived(
    servingStalls.filter((stall) => !ownStall(stall)),
  );
  let orderLocation = $derived(
    orderingStalls.find((stall) => stall.stall_id === stallId)?.stall_id ?? "",
  );
  let selectedSlot = $derived(
    profile?.draft ??
      profile?.slots.find((slot) => slot.stall_id === chosenSlot),
  );
  /** What the viewer can do with the viewed spot, or why they cannot. */
  let spotOffer = $derived.by(
    (): { action: "reserve" | "lease" } | { reason: string } | null => {
      if (!hallVacancy) return null;
      if (!profile) return { reason: t("guestHint") };
      if (!profile.account["owner?"]) return { reason: t("needsLicense") };
      if (
        restaurant &&
        (!restaurant.stall_limit ||
          restaurant.stalls.length >= restaurant.stall_limit)
      )
        return { reason: t("noMoreLocations") };
      if (restaurant?.distress_deadline != null)
        return { reason: refusalMessage(locale, "business_distressed") };
      if (
        profile.draft ||
        !profile.slots.some((slot) => slot.stall_id === hallVacancy)
      )
        return { reason: refusalMessage(locale, "slot_unavailable") };
      return { action: restaurant ? "lease" : "reserve" };
    },
  );
  function submitFirstBusiness() {
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
  }
  /** Choose the viewed spot in the existing location form and use it. */
  function takeSpot(offer: "reserve" | "lease", id: string) {
    hallVacancy = "";
    if (offer === "reserve") {
      chosenSlot = id;
      navigate("business");
      submitFirstBusiness();
    } else {
      expansionStallId = id;
      expansionOpen = true;
      navigate("business", false, "locations");
      void tick().then(() => {
        expansionDetails?.scrollIntoView({ block: "nearest" });
        expansionDetails?.querySelector("select")?.focus();
      });
    }
  }
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
          "profile",
          ...(profile.account["reviewer?"] ? ["review" as const] : []),
        ]
      : ["hall", "visit", "work", "profile"],
  );
  let disabled = $derived(!connected || submitting || pending !== null);

  const t = (key: Key) => label(locale, key);
  const title = (id: string) => contentLabel(locale, id);
  const rentLine = (slot: Slot & { expires_at?: number }) =>
    rentExplanation(slot, {
      t,
      tier: (tier) => title(tier).toLowerCase(),
      cash,
      clock,
    });

  function reopeningTime(stall: Stall) {
    const at = stall.reopens_at;
    if (at == null || !view || at <= view.hall.now)
      return t("reopeningUnscheduled");
    const dayLength = 24 * 60 * 60 * 1000;
    const day = Math.floor(at / dayLength);
    const today = Math.floor(view.hall.now / dayLength);
    const key =
      day === today
        ? "reopeningToday"
        : day === today + 1
          ? "reopeningTomorrow"
          : "reopeningDay";
    return t(key).replace("{day}", String(day)).replace("{time}", clock(at));
  }

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
  let checkoutScope = $derived(
    (page === "visit" ||
      (page === "hall" && tabletStall === hallSelection && !!tabletStall) ||
      (page === "hall" &&
        hallInteraction?.stall === hallSelection &&
        hallInteraction.target !== "staff" &&
        hallInteraction.target !== "supply")) &&
      !profile?.visit &&
      orderLocation &&
      dietaryProfiles.includes(diet)
      ? { stall_id: orderLocation, profile_id: diet }
      : null,
  );
  // `checkoutScope` is a new object whenever the view is refreshed. Anything
  // that fetches because the choice changed must watch this string instead,
  // or each refresh would trigger the next.
  let checkoutKey = $derived(
    checkoutScope
      ? JSON.stringify([checkoutScope.stall_id, checkoutScope.profile_id])
      : "",
  );
  let checkoutMenu = $derived(
    view?.checkout_menu?.stall_id === checkoutScope?.stall_id &&
      view?.checkout_menu?.profile_id === checkoutScope?.profile_id
      ? view?.checkout_menu
      : undefined,
  );
  let availableMains = $derived(Object.keys(checkoutMenu?.mains ?? {}));
  let availableDrinks = $derived(checkoutMenu?.mains[main] ?? []);
  let trayRequest = $derived(currentQuoteRequest("tray"));
  let dessertRequest = $derived(currentQuoteRequest("dessert"));
  let autoDessertKey = "";
  let observedVisitId = "";
  let dessertPreviewUnavailable = $state(false);
  let currentQuote = $derived(
    quoteRequest && isCurrentQuoteRequest(quoteRequest) ? quote : null,
  );

  let tabletView = $derived.by((): TabletView | null => {
    const stall = view?.hall.stalls.find(
      (item) => item.stall_id === tabletStall,
    );
    if (!view || !stall || !tabletStall) return null;
    const rows: TabletRow[] = [];
    const add = (
      text: string,
      action?: TabletAction,
      blocked = false,
      selected = false,
    ) =>
      rows.push({
        text,
        action,
        disabled: blocked || (!!action && disabled),
        selected,
      });
    let subtitle = t("tabletMenu");
    let notice = profile
      ? t("balance") + " " + cash(profile.balance)
      : t("tabletTap");
    const visit = profile?.visit;
    const problem = !connected
      ? t(connectionProblem)
      : status === "uncertain"
        ? t("uncertain")
        : status && typeof status === "object"
          ? refusalMessage(locale, status.refusal)
          : "";
    if (problem) {
      notice = t("tabletAttention");
      rows.push(
        ...splitTabletMessage(problem).map((text) => ({ text, error: true })),
      );
    }

    if (pending)
      rows.push({
        text: t("retry"),
        action: { kind: "retry" },
        disabled: !connected || submitting,
      });
    if (ownStall(stall)) {
      notice = t("ownStallDining");
      for (const [id, amount] of Object.entries(stall.menu))
        add(title(id) + " · " + cash(amount));
    } else if (tabletPage === "review" && currentQuote) {
      subtitle = t("quote");
      add(t("tabletTotal") + " " + cash(currentQuote.total));
      add(
        t("estimatedWait") +
          " " +
          serviceDuration(currentQuote.earliest_completion - view.hall.now),
      );
      const components = currentQuote.terms.components;
      let valid = Array.isArray(components) && components.length > 0;
      if (Array.isArray(components))
        for (const component of components) {
          if (
            !component ||
            typeof component !== "object" ||
            typeof component.recipe_id !== "string" ||
            typeof component.price !== "string" ||
            !/^[0-9]+$/.test(component.price) ||
            !Array.isArray(component.lines)
          ) {
            valid = false;
            break;
          }
          add(title(component.recipe_id) + " · " + cash(component.price));
          for (const line of component.lines) {
            if (
              !line ||
              typeof line !== "object" ||
              typeof line.product !== "string"
            ) {
              valid = false;
              break;
            }
          }
        }
      const expires = currentQuote.terms.deadline;
      add(
        t(quoteRequest?.kind === "dessert" ? "acceptDessert" : "acceptOrder"),
        { kind: "confirm", token: JSON.stringify(currentQuote.terms) },
        !valid ||
          !profile ||
          (typeof expires === "number" && view.hall.now >= expires),
      );
      add(t("tabletChange"), { kind: "menu" });
    } else if (visit) {
      subtitle = t("visit");
      add(
        t(
          visit.stage === "served"
            ? "served"
            : visit.stage === "queued"
              ? "queuedVisit"
              : visit.stage === "counter"
                ? "atCounter"
                : "preparing",
        ),
      );
      if (visit.stall !== stall.stall_id) {
        add(t("tabletOtherVisit"));
        add(t("viewVisit"), { kind: "visit" });
      }
      if (visit.stage !== "served" && visit.estimate != null)
        add(
          t("estimatedWait") +
            " " +
            serviceDuration(visit.estimate - view.hall.now),
        );
      if (visit.stall === stall.stall_id && visit.dessert === "offered") {
        add(t("dessertQuote"), { kind: "dessert" });
        add(t("skip"), { kind: "skip" });
      } else if (
        visit.stall === stall.stall_id &&
        (visit.can_cancel || visit.can_cancel_dessert)
      )
        add(t("cancel"), { kind: "cancel" });
    } else if (tabletPage === "diets") {
      subtitle = t("diet");
      for (const id of dietaryProfiles)
        add(title(id), { kind: "diet", id }, false, id === diet);
      add(t("tabletBack"), { kind: "menu" });
    } else if (tabletPage === "drinks") {
      subtitle = t("drink");
      add(t("noDrink"), { kind: "drink", id: "" }, false, !drink);
      for (const id of availableDrinks)
        add(
          title(id) + " · " + cash(stall.menu[id]),
          { kind: "drink", id },
          false,
          id === drink,
        );
      add(t("tabletBack"), { kind: "menu" });
    } else {
      if (!profile) add(t("startGuest"), { kind: "guest" }, tabletRegistering);
      else if (!profile.allowance_claimed)
        add(t("allowance"), { kind: "allowance" });
      if (view.hall.access !== "open") add(t("cleaning"));
      else if (!stall["open?"])
        add(t("reopeningExpected") + " · " + reopeningTime(stall));
      else {
        add(t("diet") + " · " + title(diet), { kind: "diets" });
        if (!checkoutMenu) add(t("tabletLoading"));
        else if (!availableMains.length) add(t("noMealsAvailable"));
        for (const id of availableMains)
          add(
            title(id) + " · " + cash(stall.menu[id]),
            { kind: "main", id },
            false,
            main === id,
          );
        if (main && availableDrinks.length)
          add(t("drink") + " · " + (drink ? title(drink) : t("noDrink")), {
            kind: "drinks",
          });
        add(t("quote"), { kind: "review" }, !profile || !trayRequest);
      }
      if (tabletPage === "review" && !currentQuote && !status)
        add(t("tabletLoading"));
    }
    return {
      stall: stall.stall_id,
      title: stall.name,
      subtitle,
      notice: problem ? t("tabletAttention") : notice,
      noticeError: !!problem,
      rows,
      previous: t("tabletPrevious"),
      next: t("tabletNext"),
      close: t("tabletClose"),
    };
  });

  let inWorldNotices = $derived(
    page === "hall" &&
      hallMode === "3d" &&
      !!tabletView &&
      !(phone && phoneDetail),
  );

  onMount(() => {
    locale = navigator.language.startsWith("ja") ? "ja" : "en";
    const media = window.matchMedia("(width < 400px)");
    const reflow = () => {
      if (media.matches) {
        const active = document.activeElement;
        const panel = active?.closest<HTMLElement>("[data-business-section]")
          ?.dataset.businessSection;
        if (panel && Object.hasOwn(businessLabels, panel))
          businessSection = panel as BusinessSection;
        if (active?.closest(".stall-inspector")) phoneDetail = true;
      }
      phone = media.matches;
    };
    reflow();
    rememberRoute();
    const scrollRestoration = history.scrollRestoration;
    history.scrollRestoration = "manual";
    const pop = (event: PopStateEvent) => {
      const saved = readRoute(event.state?.feudHallUI);
      if (!saved) return;
      page = navigation.includes(saved.page) ? saved.page : "hall";
      phoneDetail = saved.detail;
      businessSection = saved.section;
      hallSelection = saved.stall;
      void tick().then(() => {
        window.scrollTo(0, saved.scroll);
        if (page === "hall") {
          if (phoneDetail && phone)
            stallInspector?.focus({ preventScroll: true });
          else focusHall();
        }
      });
    };
    media.addEventListener("change", reflow);
    window.addEventListener("popstate", pop);
    void refresh();
    const timer = window.setInterval(() => {
      if (!document.hidden && Date.now() >= nextPoll) void refresh();
      if (!document.hidden && Date.now() - lastClientCheck >= CLIENT_CHECK_MS)
        void checkClient();
    }, 850);
    const resume = () => {
      if (document.hidden) return;
      void checkClient();
      void refresh();
    };
    document.addEventListener("visibilitychange", resume);
    window.addEventListener("online", resume);
    const presence = window.setInterval(() => {
      if (!document.hidden && connected && profile?.account["owner?"])
        void heartbeat();
      if (
        !document.hidden &&
        connected &&
        selectedShift &&
        !profile?.account["owner?"]
      ) {
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
    const closeWorkbenchOnEscape = (event: KeyboardEvent) => {
      if (
        event.key === "Escape" &&
        !event.isComposing &&
        !event.defaultPrevented &&
        event.target instanceof Node &&
        hallWorkbench?.contains(event.target)
      ) {
        event.preventDefault();
        closeHallInteraction();
      }
    };
    window.addEventListener("keydown", closeWorkbenchOnEscape);
    window.addEventListener("compositionstart", compositionStart, true);
    window.addEventListener("compositionend", compositionEnd, true);
    return () => {
      media.removeEventListener("change", reflow);
      window.removeEventListener("popstate", pop);
      history.scrollRestoration = scrollRestoration;
      window.clearInterval(timer);
      window.clearInterval(presence);
      document.removeEventListener("visibilitychange", resume);
      window.removeEventListener("online", resume);
      window.removeEventListener("keydown", closeWorkbenchOnEscape);
      window.removeEventListener("compositionstart", compositionStart, true);
      window.removeEventListener("compositionend", compositionEnd, true);
    };
  });

  $effect(() => {
    document.documentElement.lang = locale;
  });

  $effect(() => {
    // Only a new scope reloads receipts; what loadReceipts reads is not tracked.
    if (receiptScope) untrack(() => void loadReceipts());
    return () => {
      receiptRequest++;
      receipts = null;
      receiptOwnerId = "";
      receiptError = false;
      receiptLoading = false;
    };
  });

  async function loadReceipts(before?: string) {
    const request = ++receiptRequest;
    const principal = profile?.account.id ?? "";
    receiptLoading = true;
    receiptError = false;
    try {
      const next = await getDiningHistory(before);
      if (request === receiptRequest) {
        receiptOwnerId = principal;
        receipts = {
          ...next,
          receipts: before
            ? [...(receipts?.receipts ?? []), ...next.receipts]
            : next.receipts,
        };
      }
    } catch {
      if (request === receiptRequest) receiptError = true;
    } finally {
      if (request === receiptRequest) receiptLoading = false;
    }
  }

  $effect(() => {
    if (tabletStall && hallSelection !== tabletStall) tabletStall = "";
  });

  $effect(() => {
    if (hallSelection) {
      hallVacancy = "";
      spotTaken = "";
    }
  });

  $effect(() => {
    if (
      hallVacancy &&
      !view?.hall.vacancies?.some((vacancy) => vacancy.stall_id === hallVacancy)
    ) {
      // Keep the panel open to say so, unless the viewer took it.
      if (
        profile?.draft?.stall_id !== hallVacancy &&
        !restaurant?.stalls.some((stall) => stall.id === hallVacancy)
      )
        spotTaken = hallVacancy;
      hallVacancy = "";
    }
  });

  $effect(() => {
    const id = profile?.visit?.id ?? "";
    if (id) observedVisitId = id;
    else if (observedVisitId) {
      observedVisitId = "";
      tabletPage = "menu";
      main = "";
      drink = "";
      clearQuote();
    }
  });

  $effect(() => {
    if (quoteRequest && !isCurrentQuoteRequest(quoteRequest)) {
      clearQuote();
    }
  });

  $effect(() => {
    if (checkoutKey) untrack(() => void refresh());
  });

  $effect(() => {
    if (!checkoutMenu) return;
    if (main && !availableMains.includes(main)) main = "";
    if (drink && !availableDrinks.includes(drink)) drink = "";
  });

  $effect(() => {
    if (
      !view?.hall.visitor_play ||
      !(
        page === "visit" ||
        (page === "hall" && (hallInteraction || tabletStall))
      ) ||
      !connected ||
      !dessertRequest
    )
      return;
    const request = dessertRequest;
    if (autoDessertKey === request.key) return;
    autoDessertKey = request.key;
    untrack(() => void showQuote(request, true));
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
    const requested = checkoutKey;
    let stale = false;
    let recovered = false;
    try {
      const current = await getView(checkoutScope);
      if (!view || current.hall.position >= view.hall.position) {
        if (current.profile?.account.id !== profile?.account.id) {
          comparison = null;
          compareFilters.newOnly = false;
        }
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
          if (current.profile?.account["owner?"]) {
            page = "business";
            rememberRoute();
          }
        }
      }
      connected = true;
      updateRequired = false;
      // A deploy restarts the hall, so a returning connection may now be
      // served a newer client.
      recovered = pollFailures > 0;
      pollFailures = 0;
      nextPoll = 0;
      // The choice changed while this request was in flight, and the refresh
      // that change asked for was skipped above.
      stale = checkoutKey !== "" && checkoutKey !== requested;
    } catch (error) {
      connected = false;
      updateRequired =
        error instanceof ApiError && error.code === "client_update_required";
      pollFailures = Math.min(pollFailures + 1, 4);
      nextPoll = Date.now() + 850 * 2 ** pollFailures;
    } finally {
      refreshRunning = false;
    }
    if (recovered) void checkClient();
    if (stale) void refresh();
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
          if (
            ["admit_visit", "accept_dessert", "decline_dessert"].includes(
              action.kind,
            )
          ) {
            tabletPage = "menu";
            main = "";
            drink = "";
          }
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
      if (profile?.account["owner?"]) navigate("business");
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
    navigate("visit");
  }

  function chooseMeal(option: DiningOption, profileId: string) {
    inspect(option.stall_id);
    main = option.main;
    drink = option.drink ?? "";
    diet = profileId;
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
      if (
        visit?.dessert !== "offered" ||
        view?.hall.access !== "open" ||
        (visitStall && ownStall(visitStall))
      )
        return null;
      fields = { visit_id: visit.id };
    } else {
      if (
        !checkoutScope ||
        !availableMains.includes(main) ||
        (drink && !availableDrinks.includes(drink))
      )
        return null;
      fields = { ...checkoutScope, main };
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

  async function showQuote(request: QuoteRequest | null, automatic = false) {
    if (composing || !request) return;
    quote = null;
    // A fresh object also supersedes an earlier request for the same inputs.
    const sent = { ...request };
    quoteRequest = sent;
    dessertPreviewUnavailable = false;
    if (!automatic) status = null;
    try {
      const result = await getQuote(sent.fields);
      if (isCurrentQuoteRequest(sent)) quote = result;
    } catch (error) {
      if (!isCurrentQuoteRequest(sent)) return;
      if (automatic) {
        dessertPreviewUnavailable = true;
        return;
      }
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

{#snippet diningControls(locationPicker = true)}
  {#if view}
    {#if !profile}<p>
        {t("guestHint")}
        <button
          onclick={() => {
            navigate("profile");
          }}>{t("startGuest")}</button
        >
      </p>
    {:else}
      <p>
        {t("balance")} <strong>{cash(profile.balance)}</strong>
        {#if !profile.allowance_claimed}
          <button {disabled} onclick={() => submit("request_allowance")}
            >{t("allowance")}</button
          >
        {/if}
      </p>
      {#if profile.visit}
        {@render visitProgress()}
        {#if profile.visit.dessert === "offered"}
          {#if view.hall.visitor_play && profile.visit.dessert_deadline != null}
            <p>
              {t("dessertOfferLeft")}
              {serviceDuration(profile.visit.dessert_deadline - view.hall.now)}
            </p>
          {/if}
          {#if dessertPreviewUnavailable}
            <p role="status">{t("dessertPreviewUnavailable")}</p>
          {/if}
          {#if visitStall && ownStall(visitStall)}
            <p>{t("ownStallDining")}</p>
          {:else}
            <button
              disabled={disabled || !dessertRequest}
              onclick={() => showQuote(dessertRequest)}
              >{t("dessertQuote")}</button
            >
          {/if}
          <button
            {disabled}
            onclick={() =>
              submit("decline_dessert", { visit_id: profile?.visit?.id })}
            >{t("skip")}</button
          >
        {:else if view.hall.visitor_play && profile.visit.can_cancel_dessert}
          <button
            {disabled}
            onclick={() =>
              submit("cancel_dessert", { visit_id: profile?.visit?.id })}
            >{t("cancelDessert")}</button
          >
        {:else if view.hall.visitor_play ? profile.visit.can_cancel : profile.visit.tray_status === "accepted"}
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
        <p role="status">
          {t(servingStalls.length ? "noOtherStallsServing" : "noStallsServing")}
        </p>
      {:else}
        {#if selectedStall && ownStall(selectedStall)}
          <p role="status">{t("ownStallDining")}</p>
        {:else if selectedStall && !orderLocation}
          <p role="status">{t("selectedStallClosed")}</p>
        {/if}
        {#if locationPicker}
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
      {/if}
      {#if selectedStall && orderLocation}
        {#if checkoutMenu && availableMains.length === 0}
          <p role="status">{t("noMealsAvailable")}</p>
        {/if}
        <form
          onsubmit={(e) => {
            e.preventDefault();
            void showQuote(trayRequest);
          }}
        >
          <label
            >{t("main")}<select
              bind:value={main}
              disabled={availableMains.length === 0}
              required
              onchange={clearQuote}
              ><option value="">—</option
              >{#each availableMains as id (id)}<option value={id}
                  >{title(id)} · {cash(selectedStall.menu[id])}</option
                >{/each}</select
            ></label
          >
          <label
            >{t("drink")}<select
              bind:value={drink}
              disabled={availableDrinks.length === 0}
              onchange={clearQuote}
              ><option value="">{t("noDrink")}</option
              >{#each availableDrinks as id (id)}<option value={id}
                  >{title(id)} · {cash(selectedStall.menu[id])}</option
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
      {:else if !selectedStall && orderingStalls.length > 0}<p>
          {t("chooseStall")}
        </p>{/if}
    {/if}
    {#if currentQuote}
      <section class="quote">
        <p>
          <strong>{cash(currentQuote.total)}</strong> ·
          {#if quoteRequest?.kind === "dessert"}
            {t("estimatedWait")}
            {serviceDuration(currentQuote.earliest_completion - view.hall.now)}
          {:else}
            {clock(currentQuote.earliest_completion)}
          {/if}
        </p>
        <button
          disabled={disabled || !profile}
          onclick={() => confirmCurrentQuote()}
          >{t(
            quoteRequest?.kind === "dessert" ? "acceptDessert" : "acceptOrder",
          )}</button
        >
      </section>
    {/if}
  {/if}
{/snippet}

{#snippet helperControls(atStall = "")}
  {#if view}
    {#if profile?.account["owner?"]}<p>{t("ownerCannotWork")}</p>
    {:else if !profile}<button
        onclick={() => {
          navigate("profile");
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
        {#if view.hall.visitor_play}
          {#if selectedShift.approaching?.length}
            <details open>
              <summary>{t("approachingTrays")}</summary>
              <ul>
                {#each selectedShift.approaching as item (item.id)}
                  <li>
                    {item.recipes.map(title).join(" + ")} ·
                    {t("estimatedReadyIn")}
                    {serviceDuration(
                      (item.ready_at ?? view.hall.now) - view.hall.now,
                    )}
                  </li>
                {/each}
              </ul>
            </details>
          {/if}
          {#if selectedShift.prepared}<p>{t("preparedCounter")}</p>{/if}
          {#if selectedShift.staged}<p>
              {t("stagedTasks")}
              {selectedShift.staged}
            </p>{/if}
          {#if selectedShift.tasks && !selectedShift.handover}<p>
              {t("lastService")}
            </p>{/if}
        {/if}
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
          <ul class="counter-options">
            {#each selectedShift.selection.items as item (item.id)}
              <li>
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
                {#if view.hall.visitor_play && item.number != null}
                  <small>
                    {t("trayNumber").replace("{number}", String(item.number))} ·
                    {t("waited")}
                    {serviceDuration(
                      view.hall.now - (item.queued_at ?? view.hall.now),
                    )} ·
                    {t("serveBy")}
                    {serviceDuration(
                      (item.serve_by ?? view.hall.now) - view.hall.now,
                    )}
                    {#if selectedShift.selection.auto_item === item.id}
                      · {t("fifoChoice")}{/if}
                  </small>
                {/if}
              </li>
            {/each}
          </ul>
        {:else if selectedShift.staging}
          <p role="status">
            {t("stagingInProgress")} · {serviceDuration(
              selectedShift.staging.done_at - view.hall.now,
            )}
          </p>
          {#if selectedShift.waiting?.length}
            <ul>
              {#each selectedShift.waiting as item (item.id)}
                <li>
                  {item.recipes.map(title).join(" + ")} · {t("serveBy")}
                  {serviceDuration(
                    (item.serve_by ?? view.hall.now) - view.hall.now,
                  )}
                </li>
              {/each}
            </ul>
          {/if}
          <button
            {disabled}
            onclick={() =>
              submit("yield_counter_staging", {
                shift_id: selectedShift?.shift_id,
                task_id: selectedShift?.staging?.id,
              })}>{t("yieldToService")}</button
          >
        {:else}
          <p>{t("standby")}</p>
          {#if selectedShift.staging_offer}
            <button
              {disabled}
              onclick={() =>
                submit("start_counter_staging", {
                  shift_id: selectedShift?.shift_id,
                })}
            >
              {t("stagingOffer")}
            </button>
            <p>
              {t("stageWorkTime")}
              {serviceDuration(selectedShift.staging_offer - view.hall.now)} ·
              {t("setupSaving")}
            </p>
          {/if}
        {/if}
        <button
          {disabled}
          onclick={() =>
            submit("leave_helper_shift", { shift_id: selectedShift?.shift_id })}
          >{t("leaveShift")}</button
        >
      </section>
    {:else}
      <div class="cards">
        {#each profile.work.offers.filter((offer) => !atStall || offer.stall_id === atStall) as offer (offer.stall_id)}
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
  {/if}
{/snippet}

{#snippet managementPanel(
  section: "menu" | "supply" | "staff",
  embedded = false,
)}
  {#if view && restaurant}
    {#if section === "menu"}
      <section
        data-business-section="menu"
        class:phone-section-hidden={!embedded &&
          visibleBusinessSection !== "menu"}
      >
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
    {/if}
    {#if section === "supply"}
      <section
        data-business-section="supply"
        class:phone-section-hidden={!embedded &&
          visibleBusinessSection !== "supply"}
      >
        <h2>{t("supply")}</h2>
        {#if starterStock && starterStock.items.length > 0}
          <details>
            <summary>{t("starterStock")} · {cash(starterStock.budget)}</summary>
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
    {/if}
    {#if section === "staff" && ownerStall}
      <section
        data-business-section="staff"
        class:phone-section-hidden={!embedded &&
          visibleBusinessSection !== "staff"}
      >
        <h2>{t("staff")}</h2>
        <p>
          {ownerStall.id} · {ownerStall.lease.start_hour}:00–{ownerStall.lease
            .end_hour}:00
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
  {/if}
{/snippet}

{#snippet hallActions()}
  {#if view && hallStall && hallInteraction?.stall === hallStall.stall_id}
    <section
      class="hall-workbench"
      aria-label={t("hallActions")}
      tabindex="-1"
      bind:this={hallWorkbench}
    >
      <div class="hall-workbench-heading">
        <h2>{hallStall.name} · {t(targetLabels[hallInteraction.target])}</h2>
        <button
          onclick={closeHallInteraction}
          aria-label={t("closeHallActions")}>×</button
        >
      </div>
      <p class="eyebrow">{t("hallActionHint")}</p>
      <div class="actions" role="group" aria-label={t("hallStation")}>
        {#each ["menu", "counter", "staff", ...(ownStall(hallStall) ? ["supply"] : [])] as target}
          <button
            aria-pressed={hallInteraction.target === target}
            onclick={() =>
              openHallInteraction(hallStall.stall_id, target as HallTarget)}
            >{t(targetLabels[target as HallTarget])}</button
          >
        {/each}
      </div>
      {#if ownStall(hallStall) && ownerStall?.id === hallStall.stall_id}
        {@render managementPanel(
          hallInteraction.target === "menu"
            ? "menu"
            : hallInteraction.target === "supply"
              ? "supply"
              : "staff",
          true,
        )}
      {:else if hallInteraction.target === "staff" || (hallInteraction.target === "counter" && selectedShift?.stall_id === hallStall.stall_id)}
        {#if selectedShift && selectedShift.stall_id !== hallStall.stall_id}
          <p>
            {t("shiftElsewhere").replace("{stall}", selectedShift.stall_id)}
          </p>
          <button
            onclick={() =>
              openHallInteraction(selectedShift.stall_id, "counter")}
            >{t("goToShift")}</button
          >
        {:else}
          {@render helperControls(hallStall.stall_id)}
        {/if}
      {:else}
        <p>
          {title(hallStall.cuisine)} · {t(
            hallStall["open?"] ? "open" : "closed",
          )}
        </p>
        {#if !profile?.visit && recentPickup === hallStall.stall_id && receipts?.receipts[0]}
          {@const receipt = receipts.receipts[0]}
          <div class="hall-receipt">
            <p role="status">
              {t("pickupReady").replace("{stall}", hallStall.name)}
            </p>
            <p>{t("diningCharged")} {cash(receipt.total)}</p>
            <ul>
              {#each receipt.courses as course (course.kind)}
                <li>
                  {title(course.recipe_id)} · {t(
                    course.outcome === "served"
                      ? "courseServed"
                      : "courseUnserved",
                  )} · {cash(course.charged)}
                </li>
              {/each}
            </ul>
          </div>
        {/if}
        {@render diningControls(false)}
      {/if}
    </section>
  {/if}
{/snippet}

{#snippet workHistory()}
  {#if profile && profile.work.history.length}
    <h2>{t("workHistory")}</h2>
    <ul>
      {#each profile.work.history as shift (shift.shift_id)}<li>
          {cash(shift.amount)} · {title(shift.reason)}
          {#if shift.qualified}· {t("qualified")}{/if}
          {#if shift.staged}· {t("stagedTasks")} {shift.staged}{/if}
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
{/snippet}

{#snippet visitProgress()}
  {#if profile?.visit && view}
    {@const visit = profile.visit}
    {@const stage = view.hall.visitor_play ? visit.stage : undefined}
    <p role="status">
      {t(
        stage === "queued"
          ? "queuedVisit"
          : stage === "counter"
            ? "atCounter"
            : stage === "served" || (!stage && visit.tray_status === "served")
              ? "served"
              : "preparing",
      )}
      · {view.hall.stalls.find((stall) => stall.stall_id === visit.stall)
        ?.name ?? visit.stall}
    </p>
    {#if view.hall.visitor_play && visit.recipes?.length}
      <p>{visit.recipes.map(title).join(" + ")}</p>
    {/if}
    {#if view.hall.visitor_play && visit.estimate != null}
      <p>
        {t("estimatedWait")}
        {serviceDuration(visit.estimate - view.hall.now)} · {t(
          "visitEstimateHint",
        )}
      </p>
    {/if}
  {/if}
{/snippet}

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

<nav
  class="primary-navigation"
  aria-label={t("mainNavigation")}
  style:--nav-items={navigation.length}
>
  {#each navigation as section (section)}
    <button
      class:current={page === section}
      aria-current={page === section ? "page" : undefined}
      onclick={() => {
        if (phone && section === "hall" && page === "hall" && phoneDetail)
          backToHall();
        else navigate(section);
      }}
      ><svg
        class="nav-icon"
        aria-hidden="true"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"><path d={navigationIcons[section]} /></svg
      ><span>{t(section)}</span></button
    >
  {/each}
</nav>

<main>
  {#if !connected && !inWorldNotices}<p class="banner" role="status">
      {t(connectionProblem)}
      {#if updateRequired && !nativeClient}<button
          type="button"
          onclick={reloadClient}>{t("reload")}</button
        >{/if}
    </p>{/if}
  {#if updateAvailable && connected && !inWorldNotices}<p
      class="banner"
      role="status"
    >
      {t("newVersion")}
      <button type="button" onclick={reloadClient}>{t("reload")}</button>
    </p>{/if}
  <span class="sr-only" role="status">
    {inWorldNotices && tabletView?.noticeError
      ? tabletView.rows
          .filter((row) => row.error)
          .map((row) => row.text)
          .join(locale === "ja" ? "" : " ")
      : status === "update"
        ? t("update")
        : ""}
  </span>
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
  {:else if !inWorldNotices}
    {#if status === "uncertain" || pending}<p class="banner" role="status">
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
  {/if}
  {#if !view}
    <p>{t("loading")}</p>
  {:else if page === "hall"}
    {#snippet stallOptions()}
      {#if hallGroups}
        {#each hallGroups as group (group.room)}
          {#if group.stalls.length}
            <optgroup label={hallRoomLabel(group.room)}>
              {#each group.stalls as stall (stall.stall_id)}<option
                  value={stall.stall_id}>{stall.name} · {stall.stall_id}</option
                >{/each}
            </optgroup>
          {/if}
        {/each}
      {:else}
        {#each view?.hall.stalls ?? [] as stall (stall.stall_id)}<option
            value={stall.stall_id}>{stall.name} · {stall.stall_id}</option
          >{/each}
      {/if}
    {/snippet}
    {#snippet spotPanel()}
      <div class="spot-panel-live" aria-live="polite">
        {#if hallVacancy || spotTaken}
          <section class="spot-panel" aria-labelledby="spot-panel-title">
            <div class="spot-panel-heading">
              <h2 id="spot-panel-title" class="desktop-only">
                {t("spotPanelTitle")}
              </h2>
              <button type="button" onclick={closeSpot}>{t("closeSpot")}</button
              >
            </div>
            {#if viewedSpot}
              {@const spot = viewedSpot}
              {@const line = rentLine(spot)}
              <p class="eyebrow">
                {spot.stall_id}{spot.room
                  ? " · " + hallRoomLabel(spot.room)
                  : ""}
              </p>
              <p>
                {title(spot.tier)} · {t("exposure")}
                {spot.exposure / 1000}×
              </p>
              <p class="spot-rent">{t("rent")} {cash(spot.rent)}</p>
              {#if line}<p class="rent-explanation">{line}</p>{/if}
              <p>
                {t("holding")}
                {cash(spot.holding)} · {t("setupFee")}
                {cash(spot.setup_fee)}
              </p>
              {#if spotOffer && "action" in spotOffer}
                {@const offer = spotOffer.action}
                <button
                  {disabled}
                  onclick={() => takeSpot(offer, spot.stall_id)}
                  >{t(
                    offer === "reserve" ? "reserveThisSpot" : "leaseThisSpot",
                  )}</button
                >
              {:else if spotOffer}
                <p>{spotOffer.reason}</p>
              {/if}
            {:else}
              <p class="eyebrow">{spotTaken}</p>
              <p>{refusalMessage(locale, "slot_unavailable")}</p>
            {/if}
          </section>
        {/if}
      </div>
    {/snippet}
    <div class:phone-section-hidden={phoneDetail}>
      <h1>{t("hall")}</h1>
      {#if !profile}<p>
          {t("guestHint")}
          <button
            onclick={() => {
              navigate("profile");
            }}>{t("startGuest")}</button
          >
        </p>{/if}
      {#if view.hall.visitor_play}
        <div class="hall-mode" role="group" aria-label={t("hall")}>
          <button
            aria-pressed={hallMode === "3d"}
            onclick={() => {
              sceneError = false;
              hallMode = "3d";
            }}>{t("hall3d")}</button
          >
          <button
            aria-pressed={hallMode === "list"}
            onclick={() => (hallMode = "list")}>{t("hallList")}</button
          >
        </div>
        {#if sceneError}<p role="status">{t("sceneUnavailable")}</p>{/if}
        <div class="phone-only hall-phone-picker">
          <label
            >{t("location")}<select
              bind:this={hallPicker}
              value={hallSelection}
              onchange={(event) =>
                openStallDetails(
                  event.currentTarget.value,
                  event.currentTarget,
                )}
            >
              <option value="">—</option>
              {@render stallOptions()}
            </select></label
          >
          <button onclick={() => openStallDetails(hallSelection)}
            >{t(hallSelection ? "viewMenu" : "compareDining")}</button
          >
        </div>
      {/if}
    </div>
    {#if view.hall.visitor_play}
      <div
        class="hall-layout"
        class:list-mode={hallMode === "list"}
        class:phone-detail-open={phoneDetail}
        class:immersive-hall={immersiveHall &&
          hallMode === "3d" &&
          !(phone && phoneDetail)}
      >
        <div
          class="phone-only stall-detail-heading"
          class:phone-section-hidden={!phoneDetail}
        >
          <button onclick={backToHall}>{t("backToHall")}</button>
          <h1>
            {hallStall?.name ??
              t(hallVacancy || spotTaken ? "spotPanelTitle" : "stallDetails")}
          </h1>
        </div>
        {#if hallMode === "3d" && !(phone && phoneDetail)}
          <div class="hall-scene-pane">
            <HallScene
              stalls={view.hall.stalls}
              rooms={view.hall.rooms}
              vacancies={view.hall.vacancies}
              serving={view.hall.access === "open"}
              today={view.hall.today}
              queueLimit={view.hall.queue_limit}
              snapshot={view.hall.position}
              onVacancy={viewSpot}
              ownedStalls={view.hall.stalls.filter((stall) =>
                restaurant?.stalls.some((owned) => owned.id === stall.stall_id),
              )}
              selected={hallSelection}
              {pickup}
              pickups={personalTrays}
              onTakePickup={takePersonalTray}
              tablet={tabletView}
              onTabletAction={tabletAction}
              saved={camera}
              {t}
              {title}
              {reopeningTime}
              select={(id) => (hallSelection = id)}
              inspect={(id) => {
                if (immersiveHall) hallSelection = id;
                else openStallDetails(id);
              }}
              interact={openHallInteraction}
              immersive={immersiveHall}
              toggleImmersive={() => (immersiveHall = !immersiveHall)}
              saveCamera={(state) => (camera = state)}
              onUnavailable={() => {
                sceneError = true;
                hallMode = "list";
                if (tabletStall) {
                  hallInteraction = { stall: tabletStall, target: "menu" };
                  if (phone) phoneDetail = true;
                  tabletStall = "";
                }
              }}
            />
          </div>
        {/if}
        <div class="hall-workbench-slot">{@render hallActions()}</div>
        <section
          class="stall-inspector"
          class:phone-section-hidden={!phoneDetail}
          aria-label={t("viewMenu")}
          tabindex="-1"
          bind:this={stallInspector}
        >
          <label
            >{t("location")}
            <select bind:value={hallSelection}>
              <option value="">—</option>
              {@render stallOptions()}
            </select>
          </label>
          {#if hallStall}
            <h2 class="desktop-only">{hallStall.name}</h2>
            <p>
              {title(hallStall.cuisine)} · {t(
                hallStall["open?"] ? "open" : "closed",
              )}
            </p>
            {#if !hallStall["open?"]}
              <p>{t("reopeningExpected")} · {reopeningTime(hallStall)}</p>
            {/if}
            <p>{t("hallQueue")} {hallStall.activity?.waiting ?? 0}</p>
            {#if hallStall.activity?.paused}<p>{t("tradingPaused")}</p>{/if}
            <ul>
              {#each Object.entries(hallStall.menu) as [id, price] (id)}
                <li>{title(id)} · {cash(price)}</li>
              {/each}
            </ul>
            {#if ownStall(hallStall)}<p>{t("ownStallDining")}</p>{/if}
            {#if pickup === hallStall.stall_id}
              <button onclick={() => navigate("visit")}>{t("viewVisit")}</button
              >
            {:else if !profile?.visit && !ownStall(hallStall) && hallStall["open?"] && view.hall.access === "open"}
              <button
                onclick={() =>
                  hallMode === "3d" && !phoneDetail
                    ? openHallInteraction(hallSelection, "menu")
                    : inspect(hallSelection)}>{t("orderHere")}</button
              >
            {/if}
          {:else if !hallVacancy && !spotTaken}
            <p>{t("chooseStallToInspect")}</p>
          {/if}
          {@render spotPanel()}
          {#if hallStall}
            <div class="actions" role="group" aria-label={t("hallActions")}>
              {#each ["menu", "counter", "staff", ...(ownStall(hallStall) ? ["supply"] : [])] as target}
                <button
                  onclick={() =>
                    openHallInteraction(
                      hallStall.stall_id,
                      target as HallTarget,
                    )}>{t(targetLabels[target as HallTarget])}</button
                >
              {/each}
            </div>
          {/if}
          {#key profile?.account.id}
            <DinerCompare
              diets={dietaryProfiles}
              signedIn={!!profile}
              allowed={connected && view.hall.access === "open"}
              bind:filters={compareFilters}
              bind:result={comparison}
              stall={hallSelection}
              {t}
              {title}
              choose={chooseMeal}
            />
          {/key}
        </section>
      </div>
    {/if}
    {#snippet stallCard(stall: Stall, heading: "h2" | "h3")}
      <article class="stall">
        <p class="eyebrow">{stall.stall_id} · {title(stall.tier)}</p>
        <svelte:element this={heading}>{stall.name}</svelte:element>
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
        <span class:good={stall["open?"] && view?.hall.access === "open"}
          >{t(
            stall["open?"] && view?.hall.access === "open" ? "open" : "closed",
          )}</span
        >
        {#if !stall["open?"]}
          <p>{t("reopeningExpected")} · {reopeningTime(stall)}</p>
        {/if}
        <p>{t("hallQueue")} {stall.activity?.waiting ?? 0}</p>
        <button
          onclick={() =>
            view?.hall.visitor_play
              ? openStallDetails(stall.stall_id)
              : inspect(stall.stall_id)}
        >
          {t("viewMenu")}
        </button>
      </article>
    {/snippet}
    {#if !view.hall.visitor_play || hallMode === "list"}
      {#if !view.hall.visitor_play}{@render spotPanel()}{/if}
      {#if hallGroups}
        <div class:phone-section-hidden={phoneDetail}>
          {#each hallGroups as group (group.room)}
            <section
              class="hall-room"
              aria-labelledby={"hall-room-" + group.room}
            >
              <h2 id={"hall-room-" + group.room}>
                {hallRoomLabel(group.room)} · {t(
                  group.stalls.length === 1
                    ? "hallRoomStall"
                    : "hallRoomStalls",
                ).replace("{count}", String(group.stalls.length))}
              </h2>
              <div class="cards">
                {#each group.stalls as stall (stall.stall_id)}
                  {@render stallCard(stall, "h3")}
                {/each}
                {#each group.vacancies as spot (spot.stall_id)}
                  {@const line = rentLine(spot)}
                  <article
                    class="stall vacancy"
                    aria-current={hallVacancy === spot.stall_id
                      ? "true"
                      : undefined}
                  >
                    <p class="eyebrow">{spot.stall_id} · {title(spot.tier)}</p>
                    <h3>{t("toLet")}</h3>
                    <p class="spot-rent">{t("rent")} {cash(spot.rent)}</p>
                    {#if line}<p class="rent-explanation">{line}</p>{/if}
                    <button
                      aria-label={t("viewSpotNamed").replace(
                        "{id}",
                        spot.stall_id,
                      )}
                      onclick={() => viewSpot(spot.stall_id)}
                      >{t("viewSpot")}</button
                    >
                  </article>
                {/each}
              </div>
            </section>
          {/each}
        </div>
      {:else}
        <div class="cards" class:phone-section-hidden={phoneDetail}>
          {#each view.hall.stalls as stall (stall.stall_id)}
            {@render stallCard(stall, "h2")}
          {:else}<p>{t("emptyHall")}</p>{/each}
        </div>
      {/if}
    {/if}
    {#if view.hall.failed_ventures?.length}
      <details class:phone-section-hidden={phoneDetail}>
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
          submitFirstBusiness();
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
        {#if selectedSlot}
          {@const line = rentLine(selectedSlot)}
          <p>
            {selectedSlot.stall_id} · {t("exposure")}
            {selectedSlot.exposure / 1000}× · {t("rent")}
            {cash(selectedSlot.rent)} · {t("holding")}
            {cash(selectedSlot.holding)} · {t("setupFee")}
            {cash(selectedSlot.setup_fee)}
          </p>
          {#if line}<p class="rent-explanation">{line}</p>{/if}
        {/if}
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
      <div class="phone-only business-navigation">
        {#if ownerStall}
          <label
            >{t("location")}<select
              value={ownerStall.id}
              onchange={(event) => {
                ownerStallId = event.currentTarget.value;
                refitCuisine = "";
              }}
            >
              {#each restaurant.stalls as stall (stall.id)}<option
                  value={stall.id}
                  >{stall.id} · {title(
                    stall.cuisine ?? restaurant.cuisine,
                  )}</option
                >{/each}
            </select></label
          >
        {/if}
        <label
          >{t("businessSection")}<select
            value={visibleBusinessSection}
            onchange={(event) =>
              navigate(
                "business",
                false,
                event.currentTarget.value as BusinessSection,
              )}
          >
            {#each businessSections as section}<option value={section}
                >{t(businessLabels[section])}</option
              >{/each}
          </select></label
        >
      </div>
      {#if restaurant.stall_limit}
        <section
          data-business-section="locations"
          class:phone-section-hidden={visibleBusinessSection !== "locations"}
        >
          <h2>{t("currentLocations")}</h2>
          {#if ownerStall}
            <label class="desktop-only"
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
            <details bind:open={expansionOpen} bind:this={expansionDetails}>
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
                      // The rent shown; the server refuses if the quote has moved.
                      expected_rent: expansionSlot.rent,
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
                  <!-- With an estimate, the line explains the estimate's rent instead. -->
                  {#if !expansionEstimate && expansionRentLine}
                    <p class="rent-explanation">{expansionRentLine}</p>
                  {/if}
                {/if}
                <CuisinePicker
                  cuisines={view.hall.cuisines}
                  bind:value={expansionCuisine}
                  label={t("chooseCuisine")}
                  overlapLabel={t("overlappingCuisines")}
                  {title}
                />
                {#if expansionEstimate}
                  <div class="lease-estimate">
                    <p>
                      {t("dailyOverheadEstimate")}
                      {cash(expansionEstimate.overhead)}
                    </p>
                    {#if expansionRentLine}
                      <p class="rent-explanation">{expansionRentLine}</p>
                    {/if}
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
                  </div>
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
        <section
          data-business-section="recognition"
          class:phone-section-hidden={visibleBusinessSection !== "recognition"}
        >
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
        {@render managementPanel("menu")}
        {@render managementPanel("supply")}
        {#if ownerStall}
          {@render managementPanel("staff")}
        {/if}
        <section
          data-business-section="performance"
          class:phone-section-hidden={visibleBusinessSection !== "performance"}
        >
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
    <div class="visit-layout">
      <div class="visit-grid">
        <div class="visit-controls">
          {@render diningControls()}
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
        </div>
        {#if visitStall}
          <CuisineArtwork
            cuisine={visitStall.cuisine}
            name={title(visitStall.cuisine)}
          />
        {/if}
      </div>
    </div>
  {:else if page === "work"}
    <h1>{t("work")}</h1>
    <p>{t("workHint")}</p>
    {@render helperControls()}
    {@render workHistory()}
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
      {#if profile.account["owner?"] && profile.work.history.length}<section>
          {@render workHistory()}
        </section>{/if}
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
