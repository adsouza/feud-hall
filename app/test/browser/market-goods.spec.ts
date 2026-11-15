import { readFileSync } from "node:fs";
import { expect, test } from "./hall";
import {
  VENDORS,
  goodFor,
  hasGood,
  shelves,
  type Good,
} from "../../src/market-goods";

const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");
const goodsJson: Record<string, { colour: string }> = JSON.parse(
  read("../../src/market-goods.json"),
);
const ids = Object.keys(goodsJson).sort();

test("goods: an unknown product is a plain carton at the pantry", () => {
  expect(hasGood("no_such_product")).toBe(false);
  expect(goodFor("no_such_product")).toEqual({
    vendor: "pantry",
    shape: "carton",
    colour: 0xb89a6a,
    variant: "plain",
  });
  expect(hasGood("rice_long")).toBe(true);
  expect(goodFor("rice_long")).toMatchObject({
    vendor: "grains",
    shape: "sack",
    variant: "plain",
  });
});

test("goods: colours come back as numbers and a substitute names its primary", () => {
  const good: Good = goodFor("rice_broken");
  expect(good.beside).toBe("rice_long");
  expect(good.variant).toBe("value");
  expect(good.vendor).toBe(goodFor("rice_long").vendor);
  expect(good.shape).toBe(goodFor("rice_long").shape);
  expect(typeof good.colour).toBe("number");
  expect(goodFor("rice_long").beside).toBeUndefined();
  expect(goodFor("salmon").colour).toBe(
    parseInt(goodsJson["salmon"]!.colour.slice(1), 16),
  );
});

test("goods: shelves follow the vendor order and put a substitute after its primary", () => {
  const all = shelves(ids);
  // The order does not depend on the order the products are given in.
  expect(shelves([...ids].reverse())).toEqual(all);
  const order = all.map((shelf) => VENDORS.indexOf(shelf.vendor));
  expect(order).toEqual([...order].sort((a, b) => a - b));
  expect(new Set(order).size).toBe(order.length);
  expect(all.flatMap((shelf) => shelf.products).sort()).toEqual(ids);

  for (const shelf of all) {
    expect(shelf.products.length).toBeGreaterThan(0);
    for (const id of shelf.products) {
      expect(goodFor(id).vendor).toBe(shelf.vendor);
      const primary = goodFor(id).beside;
      if (primary === undefined) continue;
      // Directly after its primary or after another substitute of it.
      const at = shelf.products.indexOf(id);
      const earlier = shelf.products.slice(0, at);
      expect(earlier).toContain(primary);
      const between = earlier.slice(earlier.indexOf(primary) + 1);
      for (const other of between) expect(goodFor(other).beside).toBe(primary);
    }
  }
  // Primaries are in product ID order within a vendor.
  const grains = all.find((shelf) => shelf.vendor === "grains")!.products;
  const primaries = grains.filter((id) => goodFor(id).beside === undefined);
  expect(primaries).toEqual([...primaries].sort());
  expect(grains.indexOf("rice_broken")).toBe(grains.indexOf("rice_long") + 1);
});

test("goods: a vendor with no listed product is absent, and an orphaned substitute stands alone", () => {
  expect(shelves([])).toEqual([]);
  expect(shelves(["salmon"])).toEqual([
    { vendor: "fishmonger", products: ["salmon"] },
  ]);
  expect(shelves(["rice_broken"])).toEqual([
    { vendor: "grains", products: ["rice_broken"] },
  ]);
  expect(shelves(["rice_broken", "no_such_product", "rice_long"])).toEqual([
    { vendor: "grains", products: ["rice_long", "rice_broken"] },
    { vendor: "pantry", products: ["no_such_product"] },
  ]);
});

test("goods: every vendor has an English and a Japanese name", () => {
  // src/i18n.ts cannot be loaded by this runner, so read its catalogues as text.
  const source = read("../../src/i18n.ts");
  const split = source.indexOf("const ja: Record<Key, string>");
  expect(split).toBeGreaterThan(0);
  const catalogues = { en: source.slice(0, split), ja: source.slice(split) };
  const names: Record<string, string> = {};
  for (const vendor of VENDORS) {
    for (const [locale, text] of Object.entries(catalogues)) {
      const found = text.match(
        new RegExp(`^  vendor_${vendor}: "([^"]+)",$`, "m"),
      );
      expect(found, `vendor_${vendor} in ${locale}`).not.toBeNull();
      names[`${locale}:${vendor}`] = found![1]!;
    }
    expect(names[`ja:${vendor}`]).not.toBe(names[`en:${vendor}`]);
  }
  expect(names["en:dairy"]).toBe("Dairy and eggs");
  expect(names["ja:greengrocer"]).toBe("青果店");
});
