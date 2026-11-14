import { expect, test } from "@playwright/test";
import { cash, clock, type Slot } from "../../src/api";
import { rentExplanation, type RentKey } from "../../src/rent";

// The catalogues' templates, as in src/i18n.ts (which this runner cannot load).
type Locale = "en" | "ja";
const messages: Record<Locale, Record<RentKey, string>> = {
  en: {
    rentScarcity:
      "{leased} of {total} {tier} spots are taken, so rent is {percent}% above the usual {base}.",
    rentUsual: "The usual rent for a {tier} spot.",
    rentHeld: "Held at this rent until {time}.",
  },
  ja: {
    rentScarcity:
      "{tier}区画は{total}区画中{leased}区画が埋まっているため、賃料は通常の{base}より{percent}%高くなっています。",
    rentUsual: "{tier}区画の通常の賃料です。",
    rentHeld: "{time}までこの賃料で確保されています。",
  },
};
const tiers: Record<Locale, Record<string, string>> = {
  en: { standard: "standard", busy: "busy" },
  ja: { standard: "標準", busy: "にぎやか" },
};

const standard: Slot = {
  stall_id: "s043",
  tier: "standard",
  exposure: 1000,
  rent: "12000",
  holding: "3000",
  setup_fee: "50000",
  room: 1,
  position: 3,
  base_rent: "10000",
  class_leased: 2,
  class_total: 6,
};

const explain = (slot: Slot & { expires_at?: number }, locale: Locale = "en") =>
  rentExplanation(slot, {
    t: (key) => messages[locale][key],
    tier: (tier) => tiers[locale][tier],
    cash,
    clock,
  });

test("rent: rent equal to the base reads as the usual rent", () => {
  expect(explain({ ...standard, rent: "10000", class_leased: 0 })).toBe(
    "The usual rent for a standard spot.",
  );
  expect(explain({ ...standard, rent: "10000" }, "ja")).toBe(
    "標準区画の通常の賃料です。",
  );
});

test("rent: rent above the base names the class and the rounded-down percent", () => {
  expect(explain(standard)).toBe(
    "2 of 6 standard spots are taken, so rent is 20% above the usual $100.00.",
  );
  expect(explain(standard, "ja")).toBe(
    "標準区画は6区画中2区画が埋まっているため、賃料は通常の$100.00より20%高くなっています。",
  );
  // 3 × 100 / 7 = 42.86: rounds down to 42.
  expect(
    explain({
      ...standard,
      tier: "busy",
      rent: "10",
      base_rent: "7",
      class_leased: 3,
      class_total: 4,
    }),
  ).toBe("3 of 4 busy spots are taken, so rent is 42% above the usual $0.07.");
  // 1 × 100 / 10000 = 0.01: rounds down to 0 while still above the base.
  expect(explain({ ...standard, rent: "10001" })).toBe(
    "2 of 6 standard spots are taken, so rent is 0% above the usual $100.00.",
  );
});

test("rent: values beyond 2^53 stay exact", () => {
  const base = "90071992547409930000";
  const rent = "135107988821114895001";
  expect(Number(rent) > Number.MAX_SAFE_INTEGER).toBe(true);
  // (rent - base) × 100 / base = 50.0000000000000001…: exactly 50.
  expect(explain({ ...standard, base_rent: base, rent })).toBe(
    "2 of 6 standard spots are taken, so rent is 50% above the usual $900719925474099300.00.",
  );
  // One minor unit less than half again: 49.
  expect(
    explain({
      ...standard,
      base_rent: base,
      rent: "135107988821114894999",
    }),
  ).toContain("rent is 49% above");
});

test("rent: a slot without a base rent has no explanation", () => {
  const {
    base_rent: _,
    class_leased: __,
    class_total: ___,
    ...plain
  } = standard;
  expect(explain(plain)).toBe("");
  expect(explain({ ...plain, expires_at: 3_600_000 })).toBe("");
});

test("rent: a held draft names the time its quoted rent is held until", () => {
  const draft = { ...standard, expires_at: (6 * 60 + 25) * 60_000 };
  expect(explain(draft)).toBe("Held at this rent until 06:25.");
  expect(explain(draft, "ja")).toBe("06:25までこの賃料で確保されています。");
});
