import type { Money, Slot } from "./api";

export type RentKey = "rentScarcity" | "rentUsual" | "rentHeld";

export type RentFormat = {
  /** The locale's template for a message key. */
  t: (key: RentKey) => string;
  /** A quality class as it reads inside a sentence. */
  tier: (tier: string) => string;
  cash: (amount: Money) => string;
  clock: (ms: number) => string;
};

function fill(template: string, values: Record<string, string>) {
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    Object.hasOwn(values, name) ? values[name] : match,
  );
}

/**
 * One plain line explaining a quoted rent, or "" for halls without the room
 * rule. A draft holds the rent it was quoted until it expires.
 */
export function rentExplanation(
  slot: Slot & { expires_at?: number },
  format: RentFormat,
): string {
  if (slot.base_rent == null) return "";
  if (slot.expires_at != null)
    return fill(format.t("rentHeld"), { time: format.clock(slot.expires_at) });
  const rent = BigInt(slot.rent);
  const base = BigInt(slot.base_rent);
  const tier = format.tier(slot.tier);
  if (rent === base) return fill(format.t("rentUsual"), { tier });
  if (
    rent < base ||
    base <= 0n ||
    slot.class_leased == null ||
    slot.class_total == null
  )
    return "";
  return fill(format.t("rentScarcity"), {
    leased: String(slot.class_leased),
    total: String(slot.class_total),
    tier,
    percent: (((rent - base) * 100n) / base).toString(),
    base: format.cash(slot.base_rent),
  });
}
