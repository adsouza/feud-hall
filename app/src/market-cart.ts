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
  /** Restock automation sent it; missing from an older server. */
  automated?: boolean;
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

/** Whether typed limit text cannot be a limit (not a positive decimal integer once trimmed). */
export function limitInvalid(text: string): boolean {
  return !LIMIT_FORMAT.test(text.trim());
}

/**
 * Whether "Send order" must wait: some line that would be sent (its offer is
 * usable) has limit text typed that cannot be a limit. An unavailable line is
 * skipped by sending, so its text never blocks; the text is kept for when the
 * product comes back.
 */
export function sendBlocked(
  cart: Cart,
  limitText: Record<string, string>,
  market: Record<string, Offer>,
): boolean {
  return cart.lines.some((l) => {
    const text = limitText[l.product];
    return (
      market[l.product] !== undefined &&
      text !== undefined &&
      limitInvalid(text)
    );
  });
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

/**
 * Keeps unedited limits at the default for the current price. A line whose
 * offer is unusable or gone stays as it is (shown unavailable, skipped when
 * sending); only the owner removes it.
 */
export function reprice(cart: Cart, market: Record<string, Offer>): Cart {
  return {
    lines: cart.lines.map((l) => {
      const offer = market[l.product];
      return !offer || l.limitEdited
        ? { ...l }
        : { ...l, limit: defaultLimit(offer.price) };
    }),
  };
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

/** What an outcome says: all of it arrived, some of it, or none. */
export function outcomeState(o: {
  filled: number;
  short: number;
}): "filled" | "short" | "rejected" {
  return o.filled === 0 ? "rejected" : o.short === 0 ? "filled" : "short";
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
    out.push({
      ...base,
      state: outcomeState(o),
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

// ---------------------------------------------------------------------------
// "On its way": the server's own pending requests and recent outcomes, plus
// what this session sent that the server does not list yet.
// ---------------------------------------------------------------------------

/** A line leaves this long after its outcome (or "settled") was first shown. */
export const WAY_LINGER_MS = 60_000;
/** Bounds on what the list remembers for the session. */
export const MAX_SESSION_SENDS = 40;
export const MAX_HIDDEN = 200;

/** A purchase request this session sent through the market. */
export type SessionSend = {
  commandId: string;
  product: string;
  /** The send's outcome is unknown; it is resolved by this command ID only. */
  uncertain: boolean;
  /**
   * The newest view request issued when the acceptance was known, or null
   * while uncertain. Only a view requested after it reflects the request.
   */
  acceptedStamp: number | null;
  /** When the acceptance was known (ms), or null while uncertain. */
  acceptedAt: number | null;
};

/** What the list remembers between views. Bounded; never stored. */
export type WayMemory = {
  /**
   * Outcomes seen, by request ID, with when each was first shown (ms), or null
   * while its line is still unconfirmed and the outcome is not shown yet.
   */
  seen: Record<string, { outcome: Outcome; at: number | null }>;
  /** When a session line was first shown as settled, by request ID. */
  settled: Record<string, number>;
  /** Request IDs whose line was dismissed or has had its minute, oldest first. */
  hidden: string[];
};
export const emptyWayMemory: WayMemory = { seen: {}, settled: {}, hidden: [] };

export type WayLine = {
  requestId: string;
  product: string;
  state:
    | "unconfirmed"
    | "sent"
    | "pending"
    | "filled"
    | "short"
    | "rejected"
    | "settled";
  filled: number;
  short: number;
  reason: string | null;
  cost: string | null;
  automated: boolean;
};

type PendingEntry = Pending & { automated?: boolean };

/**
 * Records a send's result. Uncertain: the line waits under its command ID.
 * Accepted: the line is confirmed as of `stamp`, and this session's earlier
 * accepted lines for the product go (the server replaced that request).
 */
export function recordSend(
  sent: SessionSend[],
  send: {
    commandId: string;
    product: string;
    outcome: "accepted" | "uncertain";
    stamp: number;
    now: number;
  },
): SessionSend[] {
  const accepted = send.outcome === "accepted";
  const line: SessionSend = {
    commandId: send.commandId,
    product: send.product,
    uncertain: !accepted,
    acceptedStamp: accepted ? send.stamp : null,
    acceptedAt: accepted ? send.now : null,
  };
  const others = sent.filter(
    (s) =>
      s.commandId !== send.commandId &&
      !(accepted && !s.uncertain && s.product === send.product),
  );
  return [...others, line].slice(-MAX_SESSION_SENDS);
}

/** Hides a line for the rest of the session. */
export function dismissWay(
  memory: WayMemory,
  sent: SessionSend[],
  requestId: string,
): { memory: WayMemory; sent: SessionSend[] } {
  return {
    memory: {
      ...memory,
      hidden: [
        ...memory.hidden.filter((id) => id !== requestId),
        requestId,
      ].slice(-MAX_HIDDEN),
    },
    sent: sent.filter((s) => requestIdFor(s.commandId) !== requestId),
  };
}

/**
 * The "On its way" list, newest first: this session's unconfirmed and
 * just-sent lines, then the server's pending requests, then outcomes and
 * settled lines. `purchases` is null from an older server, which reports no
 * outcomes: only this session's sends are listed, as "sent", for a minute.
 * `viewStamp` is the view request that produced `purchases`. Returns the
 * next memory and session list; calling again with them changes nothing.
 */
export function onItsWay(input: {
  purchases: { pending: PendingEntry[]; recent: Outcome[] } | null;
  sent: SessionSend[];
  viewStamp: number;
  memory: WayMemory;
  now: number;
}): { lines: WayLine[]; memory: WayMemory; sent: SessionSend[] } {
  const { purchases, viewStamp, now } = input;
  const hidden = new Set(input.memory.hidden);
  const hiddenList = [...input.memory.hidden];
  const hide = (id: string) => {
    if (hidden.has(id)) return;
    hidden.add(id);
    hiddenList.push(id);
  };
  const blank = { filled: 0, short: 0, reason: null, cost: null };
  const sessionLine = (
    s: SessionSend,
    state: "unconfirmed" | "sent" | "settled",
  ): WayLine => ({
    ...blank,
    requestId: requestIdFor(s.commandId),
    product: s.product,
    state,
    automated: false,
  });

  if (!purchases) {
    const kept = input.sent.filter(
      (s) =>
        s.uncertain ||
        (s.acceptedAt !== null &&
          now - s.acceptedAt < WAY_LINGER_MS &&
          !hidden.has(requestIdFor(s.commandId))),
    );
    return {
      lines: [...kept]
        .reverse()
        .map((s) => sessionLine(s, s.uncertain ? "unconfirmed" : "sent")),
      memory: input.memory,
      sent: kept,
    };
  }

  const pendingIds = new Set(purchases.pending.map((p) => p.request_id));
  const uncertainIds = new Set(
    input.sent.filter((s) => s.uncertain).map((s) => requestIdFor(s.commandId)),
  );
  // Outcomes: remembered from the first view that carried them. A line's
  // minute starts when its outcome is first shown, not while its send is
  // still unconfirmed (a late retry must still show what happened).
  const seen: WayMemory["seen"] = {};
  for (const [id, entry] of Object.entries(input.memory.seen))
    seen[id] =
      entry.at === null && !uncertainIds.has(id)
        ? { ...entry, at: now }
        : entry;
  for (const o of purchases.recent)
    if (!seen[o.request_id] && !hidden.has(o.request_id))
      seen[o.request_id] = {
        outcome: o,
        at: uncertainIds.has(o.request_id) ? null : now,
      };
  for (const [id, entry] of Object.entries(seen))
    if (entry.at !== null && now - entry.at >= WAY_LINGER_MS) hide(id);
  // A view older than an accepted send can still list the request it replaced.
  const replacing = input.sent.filter(
    (s) => s.acceptedStamp !== null && viewStamp <= s.acceptedStamp,
  );

  const settledAt: WayMemory["settled"] = {};
  const waiting: WayLine[] = [];
  const terminal: { line: WayLine; at: number }[] = [];
  const kept: SessionSend[] = [];
  for (const s of input.sent) {
    const id = requestIdFor(s.commandId);
    if (s.uncertain) {
      kept.push(s);
      waiting.push(sessionLine(s, "unconfirmed"));
    } else if (hidden.has(id)) {
      continue;
    } else if (pendingIds.has(id) || seen[id]) {
      kept.push(s); // The server's own line shows it.
    } else if (s.acceptedStamp === null || viewStamp <= s.acceptedStamp) {
      kept.push(s);
      waiting.push(sessionLine(s, "sent"));
    } else if (purchases.pending.some((p) => p.product === s.product)) {
      // Another request for the product is waiting: this one was replaced
      // (from here before the send was recorded, the text form, another
      // device or restock automation). It never settled.
      continue;
    } else {
      // A view newer than the acceptance has neither a pending entry nor an
      // outcome, and nothing replaced it.
      const at = input.memory.settled[id] ?? now;
      if (now - at >= WAY_LINGER_MS) {
        hide(id);
        continue;
      }
      settledAt[id] = at;
      kept.push(s);
      terminal.push({ line: sessionLine(s, "settled"), at });
    }
  }

  const pending: WayLine[] = purchases.pending
    .filter(
      (p) =>
        !hidden.has(p.request_id) &&
        !uncertainIds.has(p.request_id) &&
        !replacing.some(
          (s) =>
            s.product === p.product &&
            requestIdFor(s.commandId) !== p.request_id,
        ),
    )
    .map((p) => ({
      ...blank,
      requestId: p.request_id,
      product: p.product,
      state: "pending",
      automated: p.automated === true,
    }));

  for (const [id, { outcome: o, at }] of Object.entries(seen)) {
    if (hidden.has(id)) {
      delete seen[id];
      continue;
    }
    if (uncertainIds.has(id)) continue;
    terminal.push({
      at: at ?? now,
      line: {
        requestId: id,
        product: o.product,
        state: outcomeState(o),
        filled: o.filled,
        short: o.short,
        reason: o.reason,
        cost: o.cost,
        automated: o.automated === true,
      },
    });
  }
  terminal.sort((a, b) => b.at - a.at);

  return {
    lines: [...waiting.reverse(), ...pending, ...terminal.map((t) => t.line)],
    memory: { seen, settled: settledAt, hidden: hiddenList.slice(-MAX_HIDDEN) },
    sent: kept,
  };
}
