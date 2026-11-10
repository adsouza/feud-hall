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
  tier: string;
  name: string;
  cuisine: string;
  menu: Record<string, Money>;
  "open?": boolean;
};
type Lease = {
  start_hour: number;
  end_hour: number;
  workers: Record<
    string,
    { id: string; role: string; start_hour: number; end_hour: number }
  >;
  helper_offers: boolean;
  unattended: boolean;
};
export type OwnerStall = {
  id: string;
  tier: string;
  mode: string;
  can_open: boolean;
  lease: Lease;
};
export type Slot = {
  stall_id: string;
  tier: string;
  exposure: number;
  rent: Money;
  holding: Money;
  setup_fee: Money;
};
export type Restaurant = {
  id: string;
  name: string;
  cuisine: string;
  unlocked: string[];
  menu: Record<string, Money>;
  ledger: Record<string, Money>;
  starter_stock: { budget: Money; items: { product: string; qty: number }[] };
  reports: { day: number; delta: Record<string, Money> }[];
  available_cash: Money;
  stalls: OwnerStall[];
  market: Record<string, { price: Money; stock: number }>;
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
type HandoverItem = { id: string; recipes: string[] };
type Shift = {
  shift_id: string;
  stall_id: string;
  tasks: number;
  expires_at: number;
  selection: {
    id: string;
    deadline: number;
    items: HandoverItem[];
    choice?: HandoverItem | null;
  } | null;
  handover?: (HandoverItem & { done_at: number }) | null;
};
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
  restaurant: Restaurant | null;
  slots: Slot[];
  draft: (Slot & { expires_at: number }) | null;
  waitlisted: boolean;
  visit: {
    id: string;
    stall: string;
    tray_status: string;
    dessert: string;
  } | null;
  work: {
    offers: ShiftOffer[];
    active: Shift | null;
    history: {
      shift_id: string;
      amount: Money;
      reason: string;
      qualified: boolean;
    }[];
  };
  applications: Application[];
  reviewer_queue: Application[];
  invitations: { id: string; status: string; code?: string }[];
  recovery_codes: string[];
  notices: { code: string; status?: string; reason?: string }[];
};
export type View = {
  hall: {
    now: number;
    access: string;
    stalls: Stall[];
    position: number;
    cuisines: string[];
    dietary_profiles?: string[];
    recipes: Record<string, Recipe>;
  };
  profile: Profile | null;
};
export type Quote = {
  total: Money;
  earliest_completion: number;
  terms: Record<string, unknown>;
};
export type Pending = {
  command_id: string;
  kind: string;
  payload: Record<string, unknown>;
};
export type Result = { accepted?: boolean; reason?: string; error?: string };
const headers = { "content-type": "application/json", "x-feud-command": "1" };

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
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw await responseError(response);
  return (await response.json()) as T;
}

export const getView = () => read<View>("/api/state");
export function getQuote(fields: Record<string, string>) {
  return read<Quote>(`/api/quote?${new URLSearchParams(fields)}`);
}
export async function newDevice() {
  const response = await fetch("/api/device", {
    method: "POST",
    headers,
    body: "{}",
  });
  if (!response.ok) throw await responseError(response);
}
export function command(
  kind: string,
  payload: Record<string, unknown> = {},
): Pending {
  return { command_id: crypto.randomUUID(), kind, payload };
}
export async function send(pending: Pending) {
  const response = await fetch("/api/commands", {
    method: "POST",
    headers,
    body: JSON.stringify(pending),
  });
  return (await response.json()) as Result;
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
