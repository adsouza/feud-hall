// The owner's draft cart for the wholesale market: pure, no DOM, no network.
// Money is a decimal integer string and goes through BigInt, never a float.

export type CartLine = {
  product: string;
  crates: number;
  limit: string;
  limitEdited: boolean;
};
export type Cart = { lines: CartLine[] };
export type Offer = {
  price: string;
  stock: number;
  crate: number;
  level: number;
};
export type Pending = {
  request_id: string;
  product: string;
  qty: number;
  max_price_per_kunit: string;
};
export type Outcome = {
  request_id: string;
  product: string;
  requested: number;
  filled: number;
  cost: string;
  short: number;
  reason: string | null;
};

export const MAX_CRATES = 99;
export const emptyCart: Cart = { lines: [] };

const LIMIT_FORMAT = /^[1-9][0-9]*$/;

/** Published price plus 10%, rounded up to a whole minor unit. Decimal strings in and out. */
export function defaultLimit(price: string): string {
  return ((BigInt(price) * 110n + 99n) / 100n).toString();
}

/**
 * The request ID the server gives a purchase request submitted under this
 * command ID. The server's decider defines the form; keep this in step with it.
 */
export function requestIdFor(commandId: string): string {
  return "PR:" + commandId;
}

const clampCrates = (n: number): number =>
  Math.min(MAX_CRATES, Math.max(0, Math.trunc(n)));

/** One more crate of the product; a new line takes the default limit from the offer. */
export function addCrate(cart: Cart, product: string, offer: Offer): Cart {
  const existing = cart.lines.find((l) => l.product === product);
  if (!existing) {
    return {
      lines: [
        ...cart.lines,
        {
          product,
          crates: 1,
          limit: defaultLimit(offer.price),
          limitEdited: false,
        },
      ],
    };
  }
  if (existing.crates >= MAX_CRATES) return { lines: [...cart.lines] };
  return {
    lines: cart.lines.map((l) =>
      l.product === product ? { ...l, crates: l.crates + 1 } : l,
    ),
  };
}

/** 0 removes the line; clamps to 0..MAX_CRATES. A product with no line is not added here. */
export function setCrates(cart: Cart, product: string, crates: number): Cart {
  if (!Number.isFinite(crates)) return { lines: [...cart.lines] };
  const n = clampCrates(crates);
  if (n === 0) {
    return { lines: cart.lines.filter((l) => l.product !== product) };
  }
  return {
    lines: cart.lines.map((l) =>
      l.product === product ? { ...l, crates: n } : l,
    ),
  };
}

/** Ignored unless the limit is a positive decimal integer string. */
export function setLimit(cart: Cart, product: string, limit: string): Cart {
  if (!LIMIT_FORMAT.test(limit)) return { lines: [...cart.lines] };
  return {
    lines: cart.lines.map((l) =>
      l.product === product ? { ...l, limit, limitEdited: true } : l,
    ),
  };
}

/** Keeps unedited limits at the default for the current price; drops lines whose product left the market. */
export function reprice(cart: Cart, market: Record<string, Offer>): Cart {
  const lines: CartLine[] = [];
  for (const l of cart.lines) {
    const offer = market[l.product];
    if (!offer) continue;
    lines.push(
      l.limitEdited ? { ...l } : { ...l, limit: defaultLimit(offer.price) },
    );
  }
  return { lines };
}

/** The payloads "Send order" submits, one per line, in cart order. */
export function requests(
  cart: Cart,
  market: Record<string, Offer>,
  restaurantId: string,
): {
  restaurant_id: string;
  product: string;
  qty: number;
  max_price_per_kunit: string;
}[] {
  const out: {
    restaurant_id: string;
    product: string;
    qty: number;
    max_price_per_kunit: string;
  }[] = [];
  for (const l of cart.lines) {
    const offer = market[l.product];
    if (!offer) continue;
    out.push({
      restaurant_id: restaurantId,
      product: l.product,
      qty: l.crates * offer.crate,
      max_price_per_kunit: l.limit,
    });
  }
  return out;
}

/** What a line would cost at the published price: ceil(qty * price / 1000). Decimal string. */
export function lineEstimate(line: CartLine, offer: Offer): string {
  const qty = BigInt(line.crates) * BigInt(offer.crate);
  return ((qty * BigInt(offer.price) + 999n) / 1000n).toString();
}

export type LineNote =
  "replaces_pending" | "price_above_limit" | "more_than_stock";

/** Things to tell the owner about a line before sending. */
export function lineNotes(
  line: CartLine,
  offer: Offer,
  pending: Pending[],
): LineNote[] {
  const notes: LineNote[] = [];
  if (pending.some((p) => p.product === line.product)) {
    notes.push("replaces_pending");
  }
  if (BigInt(offer.price) > BigInt(line.limit)) notes.push("price_above_limit");
  if (line.crates * offer.crate > offer.stock) notes.push("more_than_stock");
  return notes;
}

export type Tracked = {
  product: string;
  state: "pending" | "filled" | "short" | "rejected" | "settled";
  filled: number;
  short: number;
  reason: string | null;
  requestId: string;
};

/** "On its way": what became of the request IDs this device sent, newest first. */
export function track(
  sent: { requestId: string; product: string }[],
  pending: Pending[],
  recent: Outcome[],
): Tracked[] {
  const out: Tracked[] = [];
  for (const s of [...sent].reverse()) {
    const base = {
      product: s.product,
      requestId: s.requestId,
      filled: 0,
      short: 0,
      reason: null as string | null,
    };
    if (pending.some((p) => p.request_id === s.requestId)) {
      out.push({ ...base, state: "pending" });
      continue;
    }
    const o = recent.find((r) => r.request_id === s.requestId);
    if (!o) {
      out.push({ ...base, state: "settled" });
      continue;
    }
    const state =
      o.filled === 0 ? "rejected" : o.short === 0 ? "filled" : "short";
    out.push({
      ...base,
      state,
      filled: o.filled,
      short: o.short,
      reason: o.reason,
    });
  }
  return out;
}

/**
 * Crates to draw as arrived on the owner's cart: one entry per filled or short
 * line, ceil(filled / crate) at the product's current crate size. Lines in
 * any other state, and products without a usable crate size, add nothing.
 */
export function arrivedCrates(
  lines: { product: string; state: string; filled: number }[],
  market: Record<string, { crate?: number }>,
): { product: string; crates: number }[] {
  const out: { product: string; crates: number }[] = [];
  for (const line of lines) {
    if (line.state !== "filled" && line.state !== "short") continue;
    const crate = market[line.product]?.crate;
    if (typeof crate !== "number" || !Number.isInteger(crate) || crate <= 0)
      continue;
    if (!Number.isFinite(line.filled) || line.filled <= 0) continue;
    out.push({ product: line.product, crates: Math.ceil(line.filled / crate) });
  }
  return out;
}
