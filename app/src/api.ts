import { invoke, isTauri } from "@tauri-apps/api/core";

export type Money = string;
export type Page =
  "hall" | "business" | "visit" | "work" | "profile" | "review";
export type Recipe = {
  id: string;
  cuisine: string;
  kind: "main" | "drink" | "dessert";
  starter: boolean;
};
export type Stall = {
  stall_id: string;
  restaurant_id: string;
  restaurant_name?: string;
  tier: string;
  room?: number;
  position?: number;
  name: string;
  cuisine: string;
  menu: Record<string, Money>;
  "open?": boolean;
  sold_out?: boolean;
  reopens_at?: number | null;
  last_service?: string | null;
  npc?: boolean;
  retiring?: boolean;
  awards?: Award[];
  activity?: {
    waiting: number;
    cooking: number;
    handover: boolean;
    staffed: boolean;
    workers?: number;
    staging: boolean;
    paused: boolean;
  };
};
type Lease = {
  start_hour: number;
  end_hour: number;
  workers: Record<
    string,
    {
      id: string;
      role: string;
      start_hour: number;
      end_hour: number;
      break_until?: number | null;
      tired?: boolean;
    }
  >;
  helper_offers: boolean;
  unattended: boolean;
};
export type OwnerStall = {
  id: string;
  name?: string;
  tier: string;
  mode: string;
  can_open: boolean;
  off_duty_roles?: string[];
  ready_at?: number | null;
  refit_cost?: Money;
  cuisine?: string;
  /** This location's own menu and starter-stock offer, where the server sends them. */
  menu?: Record<string, Money>;
  starter_stock?: { budget: Money; items: { product: string; qty: number }[] };
  /** What learning a recipe, or installing its equipment here, would cost. */
  unlock_offers?: Record<
    string,
    { cost: Money; equipment: Money; technique?: string | null; known: boolean }
  >;
  lease: Lease;
};
export type Slot = {
  stall_id: string;
  tier: string;
  exposure: number;
  rent: Money;
  holding: Money;
  setup_fee: Money;
  room?: number;
  position?: number;
  base_rent?: Money;
  class_leased?: number;
  class_total?: number;
};
export type Vacancy = Slot;
type Award = {
  distinction: string;
  cuisine: string | null;
  expires_at: number;
};
type Milestone = { milestone: string; at: number };
type VentureHistory = {
  id: string;
  name: string;
  cuisines: string[];
  owner_name?: string | null;
  opened_at: number;
  ended_at: number;
  peak_stalls: number;
  unpaid?: Money;
  final_ledger?: Record<string, Money>;
};
export type PurchaseReason =
  | "price_above_limit"
  | "insufficient_cash"
  | "insufficient_storage"
  | "stock_exhausted";
export type PendingPurchase = {
  request_id: string;
  product: string;
  qty: number;
  max_price_per_kunit: Money;
  submitted_at: number;
  automated: boolean;
};
export type PurchaseOutcome = {
  request_id: string;
  batch: number;
  at: number;
  product: string;
  requested: number;
  filled: number;
  cost: Money;
  short: number;
  reason: PurchaseReason | null;
  /** Restock automation sent it; missing from an older server. */
  automated?: boolean;
};
/** A rival's filled purchases at one of the newest two clearings: nothing more is public. */
export type MarketTrip = {
  batch: number;
  restaurant_id: string;
  products: string[];
  size: "small" | "medium" | "large";
};
export type Restaurant = {
  id: string;
  name: string;
  cuisine: string;
  cuisines?: string[];
  stall_limit?: number | null;
  distress_deadline?: number | null;
  reputation?: number;
  unpaid?: Money;
  award_review_at?: number | null;
  awards?: Award[];
  milestones?: Milestone[];
  salvage?: { id: string; product: string; qty: number; amount: Money }[];
  equipment_salvage?: { stall_id: string; technique: string; amount: Money }[];
  unlocked: string[];
  menu: Record<string, Money>;
  /** Supplies the current menu uses (recipe lines and their substitutes); missing from an older server. */
  menu_products?: string[];
  ledger: Record<string, Money>;
  starter_stock: { budget: Money; items: { product: string; qty: number }[] };
  reports: { day: number; delta: Record<string, Money> }[];
  available_cash: Money;
  stalls: OwnerStall[];
  market: Record<
    string,
    { price: Money; stock: number; crate?: number; level?: number }
  >;
  purchases?: { pending: PendingPurchase[]; recent: PurchaseOutcome[] };
  inventory: Record<string, number>;
};
export type Application = {
  application_id: string;
  status: string;
  name?: string;
  motivation?: string;
  reason?: string;
  proof: { shift_id: string; stall_id: string; tasks: number };
};
export type ShiftOffer = {
  stall_id: string;
  rate: Money;
  expires_at: number;
  quoted_at: number;
  estimated_pay: Money;
};
type HandoverItem = {
  id: string;
  recipes: string[];
  number?: number;
  queued_at?: number;
  ready_at?: number;
  serve_by?: number;
};
type Shift = {
  shift_id: string;
  stall_id: string;
  tasks: number;
  staged?: number;
  expires_at: number;
  approaching?: HandoverItem[];
  waiting?: HandoverItem[];
  staging?: { id: string; shift_id: string; done_at: number } | null;
  staging_offer?: number | null;
  prepared?: boolean;
  selection: {
    id: string;
    deadline: number;
    items: HandoverItem[];
    choice?: HandoverItem | null;
    auto_item?: string | null;
  } | null;
  handover?: (HandoverItem & { done_at: number }) | null;
};
export type CounterPickup = { id: string; stall: string };
export type Profile = {
  account: {
    id: string;
    name: string;
    "owner?": boolean;
    "reviewer?": boolean;
    proof: unknown;
    quota: number;
    progress: number;
  };
  balance: Money;
  allowance_claimed?: boolean;
  restaurant: Restaurant | null;
  slots: Slot[];
  draft: (Slot & { expires_at: number }) | null;
  waitlisted: boolean;
  counter_pickups?: CounterPickup[];
  visit: {
    id: string;
    stall: string;
    tray_status: string;
    dessert: string;
    stage?: "queued" | "preparing" | "counter" | "served";
    estimate?: number | null;
    dessert_deadline?: number | null;
    can_cancel?: boolean;
    can_cancel_dessert?: boolean;
    recipes?: string[];
  } | null;
  work: {
    offers: ShiftOffer[];
    active: Shift | null;
    history: {
      shift_id: string;
      amount: Money;
      reason: string;
      qualified: boolean;
      staged?: number;
    }[];
  };
  applications: Application[];
  reviewer_queue: Application[];
  invitations: { id: string; status: string; code?: string }[];
  recovery_codes: string[];
  ventures?: VentureHistory[];
  notices: { code: string; status?: string; reason?: string }[];
};
export type CheckoutScope = { stall_id: string; profile_id: string };
export type View = {
  hall: {
    now: number;
    visitor_play?: boolean;
    access: string;
    stalls: Stall[];
    today?: { arrivals: number; admitted: number; left: number };
    queue_limit?: number;
    rooms?: { count: number; open: number };
    vacancies?: Vacancy[];
    position: number;
    cuisines: string[];
    dietary_profiles?: string[];
    recipes: Record<string, Recipe>;
    failed_ventures?: VentureHistory[];
    market_trips?: MarketTrip[];
    lease_forecast?: {
      trading_hours: number;
      wages: Money;
      starter_margins: Record<string, Money>;
    } | null;
  };
  profile: Profile | null;
  checkout_menu?: CheckoutScope & { mains: Record<string, string[]> };
};
export type Quote = {
  total: Money;
  earliest_completion: number;
  terms: Record<string, unknown>;
};
export type DiningOption = {
  stall_id: string;
  name: string;
  cuisine: string;
  main: string;
  drink: string | null;
  total: Money;
  completion: number;
};
export type DiningFilters = {
  profile: string;
  budget: string;
  drink: boolean;
  newOnly: boolean;
  onlySelected: boolean;
  sort: "wait" | "price";
};
export type DiningOptions = {
  at: number;
  options: DiningOption[];
  tasted: string[];
  matched: number;
  sold_out: string[];
};

export type DiningHistory = {
  before: string | null;
  receipts: {
    visit_id: string;
    stall_id: string;
    restaurant_id: string;
    at: number;
    reason: string;
    total: Money;
    courses: {
      kind: "main" | "drink" | "dessert";
      recipe_id: string;
      outcome: string;
      price: Money;
      charged: Money;
    }[];
  }[];
};
export type Pending = {
  command_id: string;
  kind: string;
  payload: Record<string, unknown>;
};
export type Result = { accepted?: boolean; reason?: string; error?: string };
// The server answers 426 when a client's protocol differs from its own; the
// desktop transport sends the same header from Rust.
const protocol = { "x-feud-protocol": "1" };
const commandHeaders = {
  ...protocol,
  "content-type": "application/json",
  "x-feud-command": "1",
};

export class ApiError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
  ) {
    super(code);
  }
}

async function responseError(response: Response) {
  const body: unknown = await response.json().catch(() => null);
  const code =
    body &&
    typeof body === "object" &&
    "error" in body &&
    typeof body.error === "string"
      ? body.error
      : response.status >= 500
        ? "unavailable"
        : "unknown_rejection";
  return new ApiError(code, response.status);
}

async function read<T>(url: string): Promise<T> {
  const response = await request(url);
  if (!response.ok) throw await responseError(response);
  return (await response.json()) as T;
}

export function getView(checkout?: CheckoutScope | null) {
  const query = checkout ? "?" + new URLSearchParams(checkout) : "";
  return read<View>("/api/state" + query);
}
export function compareDining(filters: DiningFilters, stall: string) {
  const params = new URLSearchParams({
    profile_id: filters.profile,
    sort: filters.sort,
    include_drink: filters.drink ? "1" : "0",
    new_to_me: filters.newOnly ? "1" : "0",
  });
  if (filters.budget) params.set("budget", filters.budget);
  if (stall) params.set("stall_id", stall);
  return read<DiningOptions>("/api/dining-options?" + params);
}
export function getDiningHistory(before?: string) {
  const query = before ? "?" + new URLSearchParams({ before }) : "";
  return read<DiningHistory>("/api/dining-history" + query);
}
export function getQuote(fields: Record<string, string>) {
  return read<Quote>(`/api/quote?${new URLSearchParams(fields)}`);
}
export async function newDevice() {
  const response = await request("/api/device", {});
  if (!response.ok) throw await responseError(response);
}
export function command(
  kind: string,
  payload: Record<string, unknown> = {},
): Pending {
  return { command_id: crypto.randomUUID(), kind, payload };
}
export async function send(pending: Pending) {
  const response = await request("/api/commands", pending);
  return (await response.json()) as Result;
}

async function request(path: string, body?: Pending | Record<string, never>) {
  const method = body === undefined ? "GET" : "POST";
  if (!isTauri())
    return fetch(path, {
      method,
      cache: "no-store",
      ...(body === undefined
        ? { headers: protocol }
        : { headers: commandHeaders, body: JSON.stringify(body) }),
    });

  try {
    const reply = await invoke<{ status: number; body: string }>(
      "hall_request",
      { request: { path, method, body } },
    );
    return new Response(reply.body || null, { status: reply.status });
  } catch (error) {
    throw new ApiError(
      typeof error === "string" ? error : "native_connection_unavailable",
      0,
    );
  }
}
export function cash(cents: Money) {
  const value = BigInt(cents);
  const magnitude = value < 0n ? -value : value;
  return `${value < 0n ? "-" : ""}$${magnitude / 100n}.${(magnitude % 100n).toString().padStart(2, "0")}`;
}
export function clock(ms: number) {
  const minutes = Math.floor(ms / 60_000);
  return `${Math.floor((minutes / 60) % 24)
    .toString()
    .padStart(2, "0")}:${(minutes % 60).toString().padStart(2, "0")}`;
}

export function serviceDuration(hallMs: number) {
  const seconds = Math.max(0, Math.ceil(hallMs / (24 * 1000)));
  return `${Math.floor(seconds / 60)}:${(seconds % 60).toString().padStart(2, "0")}`;
}
