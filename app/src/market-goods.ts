import goodsJson from "./market-goods.json" with { type: "json" };

export type VendorId =
  | "greengrocer"
  | "butcher"
  | "fishmonger"
  | "dairy"
  | "grains"
  | "spices"
  | "pantry";
export type ShapeId =
  | "round"
  | "leafy"
  | "root"
  | "cut"
  | "fish"
  | "shellfish"
  | "sack"
  | "jar"
  | "bottle"
  | "loaf"
  | "block"
  | "carton";
export type VariantId = "plain" | "frozen" | "value" | "shelf";
export type Good = {
  vendor: VendorId;
  shape: ShapeId;
  colour: number;
  variant: VariantId;
  beside?: string;
};

/** Vendors in display order. */
export const VENDORS: readonly VendorId[] = [
  "greengrocer",
  "butcher",
  "fishmonger",
  "dairy",
  "grains",
  "spices",
  "pantry",
];
const SHAPES: readonly ShapeId[] = [
  "round",
  "leafy",
  "root",
  "cut",
  "fish",
  "shellfish",
  "sack",
  "jar",
  "bottle",
  "loaf",
  "block",
  "carton",
];
const VARIANTS: readonly VariantId[] = ["plain", "frozen", "value", "shelf"];

const FALLBACK: Good = {
  vendor: "pantry",
  shape: "carton",
  colour: 0xb89a6a,
  variant: "plain",
};

function pick<T extends string>(
  allowed: readonly T[],
  value: unknown,
): T | undefined {
  return allowed.find((candidate) => candidate === value);
}

function parseGood(raw: unknown): Good | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const entry = raw as Record<string, unknown>;
  const vendor = pick(VENDORS, entry.vendor);
  const shape = pick(SHAPES, entry.shape);
  const variant = pick(VARIANTS, entry.variant);
  const colour =
    typeof entry.colour === "string" && /^#[0-9a-f]{6}$/.test(entry.colour)
      ? parseInt(entry.colour.slice(1), 16)
      : undefined;
  if (!vendor || !shape || !variant || colour === undefined) return undefined;
  return typeof entry.beside === "string"
    ? { vendor, shape, colour, variant, beside: entry.beside }
    : { vendor, shape, colour, variant };
}

const goods = new Map<string, Good>();
for (const [id, raw] of Object.entries(goodsJson)) {
  const good = parseGood(raw);
  if (good) goods.set(id, good);
}

export function hasGood(productId: string): boolean {
  return goods.has(productId);
}

/** The entry for a product, or the fallback: a plain carton at the pantry. */
export function goodFor(productId: string): Good {
  return { ...(goods.get(productId) ?? FALLBACK) };
}

/** Products grouped by vendor in display order; a substitute directly after its primary. */
export function shelves(
  productIds: string[],
): { vendor: VendorId; products: string[] }[] {
  const given = new Set(productIds);
  const byVendor = new Map<VendorId, string[]>();
  for (const id of [...given].sort()) {
    const { vendor } = goodFor(id);
    byVendor.set(vendor, [...(byVendor.get(vendor) ?? []), id]);
  }
  const result: { vendor: VendorId; products: string[] }[] = [];
  for (const vendor of VENDORS) {
    const ids = byVendor.get(vendor);
    if (!ids) continue;
    // A substitute whose primary is not on offer stands as a primary itself.
    const primaryOf = (id: string): string | undefined => {
      const beside = goodFor(id).beside;
      return beside !== undefined && given.has(beside) ? beside : undefined;
    };
    const products: string[] = [];
    for (const id of ids) {
      if (primaryOf(id) !== undefined) continue;
      products.push(id, ...ids.filter((other) => primaryOf(other) === id));
    }
    result.push({ vendor, products });
  }
  return result;
}
