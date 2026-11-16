import fc from "fast-check";
import { expect, test } from "./hall";
import {
  MAX_CRATES,
  addCrate,
  arrivedCrates,
  defaultLimit,
  dismissWay,
  emptyCart,
  emptyWayMemory,
  limitInvalid,
  lineEstimate,
  lineNotes,
  onItsWay,
  recordSend,
  reprice,
  requestIdFor,
  requests,
  sendBlocked,
  setCrates,
  setLimit,
  track,
  WAY_LINGER_MS,
  MAX_HIDDEN,
  MAX_SESSION_SENDS,
  type Cart,
  type Offer,
  type Outcome,
  type Pending,
  type SessionSend,
  type WayMemory,
} from "../../src/market-cart";

const offer = (over: Partial<Offer> = {}): Offer => ({
  price: "1000",
  stock: 100000,
  crate: 2000,
  level: 3,
  ...over,
});

test("cart: the default limit is the price plus ten per cent, rounded up, as a decimal string", () => {
  expect(defaultLimit("1000")).toBe("1100");
  expect(defaultLimit("1001")).toBe("1102"); // 1101.1 rounds up
  expect(defaultLimit("1")).toBe("2");
  expect(defaultLimit("123456789012345678901234567890")).toBe(
    "135802467913580246791358024679",
  );
});

test("cart: one click is one crate", () => {
  const first = addCrate(emptyCart, "rice_long", offer({ price: "1000" }));
  const second = addCrate(first, "rice_long", offer({ price: "5000" }));
  expect(second.lines).toEqual([
    { product: "rice_long", crates: 2, limit: "1100", limitEdited: false },
  ]);
  // Inputs are not mutated.
  expect(first.lines[0].crates).toBe(1);
  expect(emptyCart.lines).toEqual([]);
});

test("cart: a line at the crate maximum takes no more", () => {
  let cart: Cart = emptyCart;
  for (let i = 0; i < MAX_CRATES + 5; i++) cart = addCrate(cart, "a", offer());
  expect(cart.lines[0].crates).toBe(MAX_CRATES);
  expect(addCrate(cart, "a", offer())).toEqual(cart);
});

test("cart: requests carry whole crates and exact strings", () => {
  let cart = addCrate(emptyCart, "rice_long", offer({ crate: 2000 }));
  cart = setCrates(cart, "rice_long", 3);
  cart = setLimit(cart, "rice_long", "1234");
  cart = addCrate(cart, "lamb", offer({ crate: 500, price: "9000" }));
  const market = {
    rice_long: offer({ crate: 2000 }),
    lamb: offer({ crate: 500, price: "9000" }),
    absent_from_cart: offer(),
  };
  const out = requests(cart, market, "R1");
  expect(out).toEqual([
    {
      restaurant_id: "R1",
      product: "rice_long",
      qty: 6000,
      max_price_per_kunit: "1234",
    },
    {
      restaurant_id: "R1",
      product: "lamb",
      qty: 500,
      max_price_per_kunit: "9900",
    },
  ]);
  expect(Object.keys(out[0]).sort()).toEqual([
    "max_price_per_kunit",
    "product",
    "qty",
    "restaurant_id",
  ]);
  expect(typeof out[0].qty).toBe("number");
  expect(typeof out[0].max_price_per_kunit).toBe("string");
});

test("cart: a line whose product left the market is not requested", () => {
  const cart = addCrate(emptyCart, "gone", offer());
  expect(requests(cart, {}, "R1")).toEqual([]);
});

test("cart: an unedited limit follows the price and an edited one does not", () => {
  let cart = addCrate(emptyCart, "a", offer({ price: "1000" }));
  cart = addCrate(cart, "b", offer({ price: "1000" }));
  cart = addCrate(cart, "c", offer({ price: "1000" }));
  cart = setLimit(cart, "b", "1500");
  const next = reprice(cart, {
    a: offer({ price: "2000" }),
    b: offer({ price: "2000" }),
  });
  expect(next.lines).toEqual([
    { product: "a", crates: 1, limit: "2200", limitEdited: false },
    { product: "b", crates: 1, limit: "1500", limitEdited: true },
    // c left the market: it stays, untouched, until the owner removes it.
    { product: "c", crates: 1, limit: "1100", limitEdited: false },
  ]);
  expect(cart.lines[0].limit).toBe("1100");
});

test("cart: invalid limits and crate counts are refused", () => {
  const cart = addCrate(emptyCart, "a", offer());
  for (const bad of ["0", "", "1.5", "-3", "abc", "01", " 5", "5 "]) {
    expect(setLimit(cart, "a", bad)).toEqual(cart);
  }
  const edited = setLimit(cart, "a", "777");
  expect(edited.lines[0]).toMatchObject({ limit: "777", limitEdited: true });
  expect(setCrates(cart, "a", -1).lines).toEqual([]);
  expect(setCrates(cart, "a", 0).lines).toEqual([]);
  expect(setCrates(cart, "a", 500).lines[0].crates).toBe(99);
  expect(setCrates(cart, "a", 7).lines[0].crates).toBe(7);
  expect(setCrates(cart, "a", Number.NaN)).toEqual(cart);
  expect(setCrates(cart, "other", 5)).toEqual(cart);
});

test("cart: notes", () => {
  const line = (over = {}) => ({
    product: "a",
    crates: 1,
    limit: "1200",
    limitEdited: false,
    ...over,
  });
  const pend: Pending = {
    request_id: "PR:x",
    product: "a",
    qty: 1,
    max_price_per_kunit: "1",
  };
  expect(lineNotes(line(), offer({ price: "1300" }), [])).toEqual([
    "price_above_limit",
  ]);
  expect(lineNotes(line(), offer({ price: "1200" }), [])).toEqual([]);
  expect(lineNotes(line(), offer({ price: "1000" }), [pend])).toEqual([
    "replaces_pending",
  ]);
  expect(
    lineNotes(line(), offer({ price: "1000" }), [{ ...pend, product: "b" }]),
  ).toEqual([]);
  expect(
    lineNotes(line({ crates: 3 }), offer({ crate: 2000, stock: 5999 }), []),
  ).toEqual(["more_than_stock"]);
  expect(
    lineNotes(line({ crates: 3 }), offer({ crate: 2000, stock: 6000 }), []),
  ).toEqual([]);
  expect(
    lineNotes(
      line({ crates: 3 }),
      offer({ price: "1300", crate: 2000, stock: 10 }),
      [pend],
    ),
  ).toEqual(["replaces_pending", "price_above_limit", "more_than_stock"]);
  // Compared as BigInt, beyond float precision.
  const big = "123456789012345678901234567891";
  expect(
    lineNotes(
      line({ limit: big }),
      offer({ price: "123456789012345678901234567892" }),
      [],
    ),
  ).toEqual(["price_above_limit"]);
});

test("cart: the estimate rounds up like the server", () => {
  const l = { product: "a", crates: 3, limit: "1", limitEdited: false };
  expect(lineEstimate(l, offer({ crate: 500, price: "333" }))).toBe("500"); // 499.5 up
  expect(lineEstimate(l, offer({ crate: 1000, price: "7" }))).toBe("21");
});

test("cart: the request ID is the server's PR: form", () => {
  expect(requestIdFor("cmd-1")).toBe("PR:cmd-1");
});

test("cart: tracking", () => {
  const pending: Pending[] = [
    { request_id: "PR:p", product: "p", qty: 1, max_price_per_kunit: "1" },
    // Also recent: pending wins.
    {
      request_id: "PR:both",
      product: "both",
      qty: 1,
      max_price_per_kunit: "1",
    },
  ];
  const out = (
    request_id: string,
    product: string,
    filled: number,
    short: number,
    reason: string | null,
  ): Outcome => ({
    request_id,
    product,
    requested: filled + short,
    filled,
    cost: "5",
    short,
    reason,
  });
  const recent: Outcome[] = [
    out("PR:f", "f", 100, 0, null),
    out("PR:s", "s", 60, 40, "stock_exhausted"),
    out("PR:r", "r", 0, 100, "price_above_limit"),
    out("PR:both", "both", 100, 0, null),
  ];
  const sent = ["p", "f", "s", "r", "z", "both"].map((product) => ({
    requestId: "PR:" + product,
    product,
  }));
  expect(track(sent, pending, recent)).toEqual([
    {
      product: "both",
      requestId: "PR:both",
      state: "pending",
      filled: 0,
      short: 0,
      reason: null,
    },
    {
      product: "z",
      requestId: "PR:z",
      state: "settled",
      filled: 0,
      short: 0,
      reason: null,
    },
    {
      product: "r",
      requestId: "PR:r",
      state: "rejected",
      filled: 0,
      short: 100,
      reason: "price_above_limit",
    },
    {
      product: "s",
      requestId: "PR:s",
      state: "short",
      filled: 60,
      short: 40,
      reason: "stock_exhausted",
    },
    {
      product: "f",
      requestId: "PR:f",
      state: "filled",
      filled: 100,
      short: 0,
      reason: null,
    },
    {
      product: "p",
      requestId: "PR:p",
      state: "pending",
      filled: 0,
      short: 0,
      reason: null,
    },
  ]);
  expect(track([], pending, recent)).toEqual([]);
});

test("cart: arithmetic never passes through a float", () => {
  const bad: string[] = [];
  fc.assert(
    fc.property(fc.bigInt({ min: 1n, max: 10n ** 40n }), (p) => {
      const limit = BigInt(defaultLimit(p.toString()));
      if (limit !== (p * 110n + 99n) / 100n) bad.push(p.toString());
      // Never below the price plus ten per cent, and less than a cent above it.
      if (limit * 100n < p * 110n) bad.push("low " + p);
      if (!(limit * 100n < p * 110n + 100n)) bad.push("high " + p);
    }),
  );
  expect(bad).toEqual([]);
});

test("cart: arrived crates are ceil(filled / crate) for filled and short lines only", () => {
  const market = {
    a: { crate: 500 },
    b: { crate: 200 },
    c: {},
    d: { crate: 0 },
  };
  expect(
    arrivedCrates(
      [
        { product: "a", state: "filled", filled: 1000 },
        { product: "b", state: "short", filled: 201 },
        { product: "a", state: "short", filled: 1 },
        { product: "a", state: "rejected", filled: 0 },
        { product: "a", state: "pending", filled: 0 },
        { product: "a", state: "settled", filled: 0 },
        { product: "a", state: "sent", filled: 0 },
        { product: "a", state: "unconfirmed", filled: 0 },
        { product: "c", state: "filled", filled: 500 },
        { product: "d", state: "filled", filled: 500 },
        { product: "gone", state: "filled", filled: 500 },
      ],
      market,
    ),
  ).toEqual([
    { product: "a", crates: 2 },
    { product: "b", crates: 2 },
    { product: "a", crates: 1 },
  ]);
});

test("cart: limit text is invalid unless it is a positive whole number of cents", () => {
  for (const bad of ["2.50", "", " ", "0", "-3", "abc", "01", "1e3"])
    expect(limitInvalid(bad), bad).toBe(true);
  for (const good of ["250", " 250 ", "1"])
    expect(limitInvalid(good), good).toBe(false);
});

// ---------------------------------------------------------------------------
// "On its way"
// ---------------------------------------------------------------------------
const outcome = (
  request_id: string,
  product: string,
  filled: number,
  short: number,
  reason: string | null = null,
  automated = false,
): Outcome => ({
  request_id,
  product,
  requested: filled + short,
  filled,
  cost: "5",
  short,
  reason,
  automated,
});
const pendingOf = (request_id: string, product: string, automated = false) => ({
  request_id,
  product,
  qty: 1,
  max_price_per_kunit: "1",
  automated,
});
type Step = {
  pending?: ReturnType<typeof pendingOf>[];
  recent?: Outcome[];
  viewStamp: number;
  now: number;
};
/** Runs the list over a sequence of views, threading memory and the session list. */
function runWay(sent: SessionSend[], steps: Step[], memory = emptyWayMemory) {
  let state = { sent, memory };
  const shown: ReturnType<typeof onItsWay>["lines"][] = [];
  for (const step of steps) {
    const out = onItsWay({
      purchases: { pending: step.pending ?? [], recent: step.recent ?? [] },
      sent: state.sent,
      viewStamp: step.viewStamp,
      memory: state.memory,
      now: step.now,
    });
    // Calling again with the result changes nothing.
    const again = onItsWay({
      purchases: { pending: step.pending ?? [], recent: step.recent ?? [] },
      sent: out.sent,
      viewStamp: step.viewStamp,
      memory: out.memory,
      now: step.now,
    });
    expect(again).toEqual(out);
    state = { sent: out.sent, memory: out.memory };
    shown.push(out.lines);
  }
  return { shown, ...state };
}
const states = (lines: { requestId: string; state: string }[]) =>
  lines.map((l) => `${l.requestId}=${l.state}`);

test("way: lists the server's pending requests and outcomes this page never sent", () => {
  const { shown } = runWay(
    [],
    [
      {
        pending: [
          pendingOf("PR:auto", "rice", true),
          pendingOf("PR:text", "salt"),
        ],
        recent: [outcome("PR:other", "fish", 0, 50, "price_above_limit")],
        viewStamp: 1,
        now: 0,
      },
    ],
  );
  expect(shown[0]).toEqual([
    {
      requestId: "PR:auto",
      product: "rice",
      state: "pending",
      filled: 0,
      short: 0,
      reason: null,
      cost: null,
      automated: true,
    },
    {
      requestId: "PR:text",
      product: "salt",
      state: "pending",
      filled: 0,
      short: 0,
      reason: null,
      cost: null,
      automated: false,
    },
    {
      requestId: "PR:other",
      product: "fish",
      state: "rejected",
      filled: 0,
      short: 50,
      reason: "price_above_limit",
      cost: "5",
      automated: false,
    },
  ]);
});

test("way: a just-accepted send is 'sent' until a newer view, and never 'settled' from a stale one", () => {
  const sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 5,
    now: 0,
  });
  const { shown } = runWay(sent, [
    // Views requested before the acceptance do not list it yet.
    { viewStamp: 4, now: 100 },
    { viewStamp: 5, now: 200 },
    // A newer view lists it pending.
    { pending: [pendingOf("PR:a", "rice")], viewStamp: 6, now: 300 },
    { recent: [outcome("PR:a", "rice", 100, 0)], viewStamp: 7, now: 400 },
  ]);
  expect(shown.map(states)).toEqual([
    ["PR:a=sent"],
    ["PR:a=sent"],
    ["PR:a=pending"],
    ["PR:a=filled"],
  ]);
});

test("way: settled only when a newer view has neither a pending entry nor an outcome", () => {
  const sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 5,
    now: 0,
  });
  const {
    shown,
    sent: left,
    memory,
  } = runWay(sent, [
    { viewStamp: 6, now: 1_000 },
    { viewStamp: 7, now: 1_000 + WAY_LINGER_MS - 1 },
    { viewStamp: 8, now: 1_000 + WAY_LINGER_MS },
  ]);
  expect(shown.map(states)).toEqual([["PR:a=settled"], ["PR:a=settled"], []]);
  expect(left).toEqual([]);
  expect(memory.hidden).toEqual(["PR:a"]);
  expect(memory.settled).toEqual({});
});

test("way: an outcome is remembered for its minute after the server drops it", () => {
  const sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 1,
    now: 0,
  });
  const filled = outcome("PR:a", "rice", 100, 0);
  const { shown, memory } = runWay(sent, [
    { recent: [filled], viewStamp: 2, now: 10_000 },
    // The server's six clearings move on: the outcome is gone from the view.
    { viewStamp: 3, now: 20_000 },
    { viewStamp: 4, now: 10_000 + WAY_LINGER_MS - 1 },
    { viewStamp: 5, now: 10_000 + WAY_LINGER_MS },
    // Still listed by the server after its minute: stays hidden.
    { recent: [filled], viewStamp: 6, now: 10_000 + 2 * WAY_LINGER_MS },
  ]);
  expect(shown.map(states)).toEqual([
    ["PR:a=filled"],
    ["PR:a=filled"],
    ["PR:a=filled"],
    [],
    [],
  ]);
  expect(memory.seen).toEqual({});
});

test("way: two sends of one product show one line and never 'settled'", () => {
  let sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 1,
    now: 0,
  });
  const first = runWay(sent, [
    { pending: [pendingOf("PR:a", "rice")], viewStamp: 2, now: 100 },
  ]);
  expect(first.shown.map(states)).toEqual([["PR:a=pending"]]);
  sent = recordSend(first.sent, {
    commandId: "b",
    product: "rice",
    outcome: "accepted",
    stamp: 3,
    now: 200,
  });
  expect(sent.map((s) => s.commandId)).toEqual(["b"]);
  const second = runWay(
    sent,
    [
      // A view from before the second acceptance still lists the replaced request.
      { pending: [pendingOf("PR:a", "rice")], viewStamp: 3, now: 300 },
      { pending: [pendingOf("PR:b", "rice")], viewStamp: 4, now: 400 },
    ],
    first.memory,
  );
  expect(second.shown.map(states)).toEqual([["PR:b=sent"], ["PR:b=pending"]]);
  for (const lines of [...first.shown, ...second.shown]) {
    expect(lines).toHaveLength(1);
    expect(lines.some((l) => l.state === "settled")).toBe(false);
  }
});

test("way: a send replaced before this page recorded the next one is dropped, not settled", () => {
  // The next send's acceptance and a fresh view listing it arrive before the
  // panel records that send: the earlier line must not read "settled".
  const sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 1,
    now: 0,
  });
  const { shown, sent: left } = runWay(sent, [
    { pending: [pendingOf("PR:a", "rice")], viewStamp: 2, now: 100 },
    { pending: [pendingOf("PR:b", "rice")], viewStamp: 3, now: 200 },
  ]);
  expect(shown.map(states)).toEqual([["PR:a=pending"], ["PR:b=pending"]]);
  expect(left).toEqual([]);
});

test("way: an uncertain send is unconfirmed until its command ID resolves", () => {
  const sent = recordSend([], {
    commandId: "u",
    product: "rice",
    outcome: "uncertain",
    stamp: 1,
    now: 0,
  });
  // Even when the server lists it, it stays one unconfirmed line.
  const { shown, sent: left } = runWay(sent, [
    { viewStamp: 9, now: 100 },
    { pending: [pendingOf("PR:u", "rice")], viewStamp: 10, now: 200 },
    { viewStamp: 11, now: 100 + 5 * WAY_LINGER_MS },
  ]);
  expect(shown.map(states)).toEqual([
    ["PR:u=unconfirmed"],
    ["PR:u=unconfirmed"],
    ["PR:u=unconfirmed"],
  ]);
  const resolved = recordSend(left, {
    commandId: "u",
    product: "rice",
    outcome: "accepted",
    stamp: 12,
    now: 300,
  });
  expect(resolved).toEqual([
    {
      commandId: "u",
      product: "rice",
      uncertain: false,
      acceptedStamp: 12,
      acceptedAt: 300,
    },
  ]);
});

test("way: an outcome's minute starts when it is shown, not while the send is unconfirmed", () => {
  const sent = recordSend([], {
    commandId: "u",
    product: "rice",
    outcome: "uncertain",
    stamp: 1,
    now: 0,
  });
  const rejected = outcome("PR:u", "rice", 0, 50, "price_above_limit");
  // The server rejected it; the outcome ages 90 seconds while the line is unconfirmed.
  const waiting = runWay(sent, [
    { recent: [rejected], viewStamp: 2, now: 1_000 },
    { recent: [rejected], viewStamp: 3, now: 91_000 },
  ]);
  expect(waiting.shown.map(states)).toEqual([
    ["PR:u=unconfirmed"],
    ["PR:u=unconfirmed"],
  ]);
  // The retry resolves the command ID as accepted.
  const resolved = recordSend(waiting.sent, {
    commandId: "u",
    product: "rice",
    outcome: "accepted",
    stamp: 4,
    now: 92_000,
  });
  const after = runWay(
    resolved,
    [
      { viewStamp: 5, now: 92_000 },
      { viewStamp: 6, now: 92_000 + WAY_LINGER_MS - 1 },
      { viewStamp: 7, now: 92_000 + WAY_LINGER_MS },
    ],
    waiting.memory,
  );
  expect(after.shown[0]).toEqual([
    {
      requestId: "PR:u",
      product: "rice",
      state: "rejected",
      filled: 0,
      short: 50,
      reason: "price_above_limit",
      cost: "5",
      automated: false,
    },
  ]);
  expect(after.shown.map(states)).toEqual([
    ["PR:u=rejected"],
    ["PR:u=rejected"],
    [],
  ]);
});

test("way: a dismissed line stays hidden for the session", () => {
  const sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 1,
    now: 0,
  });
  const before = runWay(sent, [
    { pending: [pendingOf("PR:a", "rice")], viewStamp: 2, now: 0 },
  ]);
  const dismissed = dismissWay(before.memory, before.sent, "PR:a");
  expect(dismissed.sent).toEqual([]);
  const after = runWay(
    dismissed.sent,
    [
      { pending: [pendingOf("PR:a", "rice")], viewStamp: 3, now: 10 },
      { recent: [outcome("PR:a", "rice", 1, 0)], viewStamp: 4, now: 20 },
    ],
    dismissed.memory,
  );
  expect(after.shown.map(states)).toEqual([[], []]);
});

test("way: an older server lists only this session's sends, as 'sent', for a minute", () => {
  let sent = recordSend([], {
    commandId: "a",
    product: "rice",
    outcome: "accepted",
    stamp: 1,
    now: 0,
  });
  sent = recordSend(sent, {
    commandId: "u",
    product: "salt",
    outcome: "uncertain",
    stamp: 1,
    now: 0,
  });
  const at = (now: number) =>
    onItsWay({
      purchases: null,
      sent,
      viewStamp: 9,
      memory: emptyWayMemory,
      now,
    });
  expect(states(at(1).lines)).toEqual(["PR:u=unconfirmed", "PR:a=sent"]);
  expect(states(at(WAY_LINGER_MS).lines)).toEqual(["PR:u=unconfirmed"]);
  expect(at(WAY_LINGER_MS).sent.map((s) => s.commandId)).toEqual(["u"]);
});

test("way: what it remembers stays bounded", () => {
  let memory: WayMemory = emptyWayMemory;
  let sent: SessionSend[] = [];
  for (let i = 0; i < 500; i++) {
    sent = recordSend(sent, {
      commandId: `c${i}`,
      product: `p${i}`,
      outcome: "accepted",
      stamp: i,
      now: i * 1000,
    });
    const out = onItsWay({
      purchases: {
        pending: [],
        recent: [outcome(`PR:c${i}`, `p${i}`, 1, 0)],
      },
      sent,
      viewStamp: i + 1,
      memory,
      now: i * 1000,
    });
    ({ memory, sent } = out);
    if (i % 7 === 0) ({ memory, sent } = dismissWay(memory, sent, `PR:c${i}`));
  }
  expect(sent.length).toBeLessThanOrEqual(MAX_SESSION_SENDS);
  expect(memory.hidden.length).toBeLessThanOrEqual(MAX_HIDDEN);
  // Only outcomes inside their minute are remembered.
  expect(Object.keys(memory.seen).length).toBeLessThanOrEqual(
    WAY_LINGER_MS / 1000 + 1,
  );
});

test("cart: invalid limit text blocks sending only on a line that would be sent", () => {
  let cart = addCrate(emptyCart, "a", offer());
  cart = addCrate(cart, "b", offer());
  const both = { a: offer(), b: offer() };
  expect(sendBlocked(cart, {}, both)).toBe(false);
  expect(sendBlocked(cart, { a: "250" }, both)).toBe(false);
  expect(sendBlocked(cart, { a: "2.50" }, both)).toBe(true);
  // "a" becomes unavailable: it is skipped by sending, so it no longer blocks
  // "b"; its text is kept and blocks again when "a" comes back.
  const text = { a: "2.50" };
  expect(sendBlocked(cart, text, { b: offer() })).toBe(false);
  expect(text).toEqual({ a: "2.50" });
  expect(sendBlocked(cart, text, both)).toBe(true);
  // Text for a product no longer in the cart never blocks.
  expect(sendBlocked(setCrates(cart, "a", 0), text, both)).toBe(false);
});
