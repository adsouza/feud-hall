import fc from "fast-check";
import { expect, test } from "./hall";
import {
  MAX_CRATES,
  addCrate,
  arrivedCrates,
  defaultLimit,
  emptyCart,
  lineEstimate,
  lineNotes,
  reprice,
  requestIdFor,
  requests,
  setCrates,
  setLimit,
  track,
  type Cart,
  type Offer,
  type Outcome,
  type Pending,
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
  ]); // c left the market
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
      // Never below the price plus ten per cent.
      if (limit * 100n < p * 110n) bad.push("low " + p);
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
