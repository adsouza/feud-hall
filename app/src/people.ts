export type Role = "diner" | "owner" | "worker";
export type HairStyle = "short" | "long" | "bun" | "cap";
export type Look = {
  shirt: number;
  skin: number;
  hair: number;
  trousers: number;
  hat: number; // 0xRRGGBB
  hairStyle: HairStyle;
  skirt: boolean;
  shortSleeves: boolean;
  apron: boolean;
  height: number; // world units
  width: number; // multiplier on body width
};

const SHIRTS = [
  0xe27158, 0x548bd3, 0xcca756, 0x5d9c79, 0x9766bd, 0xc36491, 0xaab6c0,
  0x3a807d, 0xad855f,
];
const SKINS = [0xf1c3a0, 0x9d6146, 0xc28a63, 0xe6ad79, 0x704331, 0xb57a57];
const HAIRS = [0x2a1d17, 0x4a3222, 0x111014, 0x8a5a2e, 0xb9b2aa, 0x5c2e1e];
const TROUSERS = [0x515068, 0x3b4252, 0x6b5a4a, 0x2f3440, 0x7a6f8a];
const HAIR_STYLES: readonly HairStyle[] = ["short", "long", "bun", "cap"];
const OWNER_SHIRT = 0xff9e57;
const WORKER_SHIRT = 0x8de2d1;

// Murmur3's 32-bit finaliser: every input bit affects every output bit.
function mix32(serial: number): number {
  let h = serial >>> 0;
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return h >>> 0;
}

// Reads `width` bits starting at bit `start`.
function field(bits: number, start: number, width: number): number {
  return (bits >>> start) & ((1 << width) - 1);
}

export function personLook(serial: number, role: Role): Look {
  const bits = mix32(serial);
  const shirtIndex = field(bits, 0, 4) % SHIRTS.length;
  // Offset 1 to 8 modulo the palette length, so the hat never matches the shirt.
  const hatIndex = (shirtIndex + 1 + (field(bits, 13, 3) % 8)) % SHIRTS.length;
  return {
    shirt:
      role === "owner"
        ? OWNER_SHIRT
        : role === "worker"
          ? WORKER_SHIRT
          : SHIRTS[shirtIndex],
    skin: SKINS[field(bits, 4, 3) % SKINS.length],
    hair: HAIRS[field(bits, 7, 3) % HAIRS.length],
    trousers: TROUSERS[field(bits, 10, 3) % TROUSERS.length],
    hat: SHIRTS[hatIndex],
    hairStyle: HAIR_STYLES[field(bits, 16, 2)],
    skirt: field(bits, 18, 1) === 1,
    shortSleeves: field(bits, 19, 1) === 1,
    apron: role === "owner",
    height: 1.5 * (0.92 + (0.16 * field(bits, 20, 4)) / 15),
    width: 0.9 + (0.2 * field(bits, 24, 4)) / 15,
  };
}
