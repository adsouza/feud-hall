import * as T from "three";

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
// Every look's size lies in these ranges; the span calculation below uses them too.
const HEIGHT_MIN = 1.38;
const HEIGHT_MAX = 1.62;
const WIDTH_MIN = 0.9;
const WIDTH_MAX = 1.1;
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

// A serial for a stable identifier (FNV-1a over UTF-16 code units), so a
// look keyed to it is the same on every client and every mount.
export function serialFor(key: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    h ^= key.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

// A stall's owner, then one worker per staff spot. The owner is keyed to the
// business, so one owner is the same person at every stall they hold; the
// crew is keyed to the stall.
export function staffLooks(
  restaurantId: string,
  stallId: string,
  workers: number,
): Look[] {
  const crew = serialFor("staff:" + stallId);
  return [
    personLook(serialFor("owner:" + (restaurantId || stallId)), "owner"),
    ...Array.from({ length: workers }, (_, n) =>
      personLook(crew + n + 1, "worker"),
    ),
  ];
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
    height: HEIGHT_MIN + ((HEIGHT_MAX - HEIGHT_MIN) * field(bits, 20, 4)) / 15,
    width: WIDTH_MIN + ((WIDTH_MAX - WIDTH_MIN) * field(bits, 24, 4)) / 15,
  };
}

// ---------------------------------------------------------------------------
// Proportions. A figure is authored one unit tall; the root scales it by
// (height x width, height, height x width). Forward is +Z at yaw 0.
// ---------------------------------------------------------------------------

export const FIGURE = {
  hipY: 0.44,
  hipX: 0.065,
  thighLen: 0.22,
  shinLen: 0.2,
  thighR: 0.052,
  shinR: 0.043,
  torsoY: 0.6,
  torsoR: 0.115,
  torsoStraight: 0.17,
  torsoWide: 1.12,
  torsoDeep: 0.78,
  neckY: 0.82,
  headY: 0.92,
  headR: 0.1,
  headTall: 1.1,
  shoulderY: 0.745,
  shoulderX: 0.165,
  armOut: 0.12,
  upperArmLen: 0.18,
  forearmLen: 0.185,
  upperArmR: 0.04,
  forearmR: 0.034,
  handR: 0.04,
  hipSwing: 0.55,
  kneeBend: 0.9,
  armSwing: 0.5,
  bob: 0.015,
  // Parts the brief leaves unplaced.
  skirtY: 0.45,
  apronY: 0.56,
  apronZ: 0.09,
  footForward: 0.03,
  // Carrying: the upper arm hangs a little forward, the forearm points ahead.
  carryUpper: -0.35,
  carryFore: -1.45,
  // Sizes of the parts the renderer builds (unit figure).
  neckRTop: 0.035,
  neckRBottom: 0.04,
  neckLen: 0.06,
  skirtRTop: 0.11,
  skirtRBottom: 0.19,
  skirtLen: 0.26,
  skirtDeep: 0.85,
  apronW: 0.2,
  apronH: 0.32,
  apronT: 0.012,
  // Flatter than the brief's 0.045: the foot centre stands 0.02 above the floor.
  footW: 0.075,
  footH: 0.036,
  footLen: 0.15,
  hairCapR: 0.106,
  hairTilt: 0.35,
  hairLongR: 0.07,
  hairLongStraight: 0.12,
  hairLongWide: 1.3,
  hairLongDeep: 0.6,
  bunR: 0.046,
  brimW: 0.13,
  brimT: 0.012,
  brimLen: 0.1,
} as const;

const F = FIGURE;
// Outer shoulder-to-shoulder width of the tallest, widest look: the arms hang
// out by `armOut`, so the hands sit further from the body than the shoulders.
export const FIGURE_MAX_SPAN: number =
  2 *
  (F.shoulderX +
    F.upperArmR +
    (F.upperArmLen + F.forearmLen) * Math.sin(F.armOut)) *
  HEIGHT_MAX *
  WIDTH_MAX;

export type PartKind =
  | "torso"
  | "skirt"
  | "apron"
  | "neck"
  | "head"
  | "hairCap"
  | "hairLong"
  | "hairBun"
  | "hairBrim"
  | "upperLeg"
  | "lowerLeg"
  | "foot"
  | "upperArm"
  | "forearm"
  | "hand";
export const PART_KINDS: readonly PartKind[] = [
  "torso",
  "skirt",
  "apron",
  "neck",
  "head",
  "hairCap",
  "hairLong",
  "hairBun",
  "hairBrim",
  "upperLeg",
  "lowerLeg",
  "foot",
  "upperArm",
  "forearm",
  "hand",
];
export type Detail = "full" | "simple";
export type Pose = {
  x: number;
  z: number; // hall position of the feet
  yaw: number; // body heading; forward is +Z at yaw 0
  faceYaw: number; // extra head turn
  stride: number; // -1..1, sign picks the leading leg (positive: left leads)
  walking: boolean;
  carrying: boolean; // both hands hold a tray in front
};
type Emit = (kind: PartKind, matrix: T.Matrix4, colour: number) => void;

const APRON = 0xf3e6d0;
const SHOES = 0x2b2623;

// Scratch objects: posePerson allocates nothing per call.
const ROOT = new T.Matrix4();
const LOCAL = new T.Matrix4();
const OUT = new T.Matrix4();
const POS = new T.Vector3();
const SCALE = new T.Vector3();
const QUAT = new T.Quaternion();
const EULER = new T.Euler();
const REACH = { angle: 0, length: 0 };
const NOOP: Emit = () => {};
let sink: Emit = NOOP;

// Emits a part whose reference point is (px, py, pz) in the unit figure,
// turned about X then Z (limb swing, then arms-out), then about Y (head).
function place(
  kind: PartKind,
  colour: number,
  px: number,
  py: number,
  pz: number,
  rx: number,
  ry: number,
  rz: number,
  sx: number,
  sy: number,
  sz: number,
): void {
  LOCAL.compose(
    POS.set(px, py, pz),
    QUAT.setFromEuler(EULER.set(rx, ry, rz, "ZXY")),
    SCALE.set(sx, sy, sz),
  );
  OUT.multiplyMatrices(ROOT, LOCAL);
  sink(kind, OUT, colour);
}

// A limb hangs down at angle 0 and swings backward (towards -Z) as the angle
// grows. Two segments at angles a1, a2 reach the point a single straight
// segment of REACH.length at REACH.angle would; used for the simple figure.
function reach(a1: number, l1: number, a2: number, l2: number): void {
  const down = l1 * Math.cos(a1) + l2 * Math.cos(a2);
  const back = l1 * Math.sin(a1) + l2 * Math.sin(a2);
  REACH.length = Math.hypot(down, back);
  REACH.angle = Math.atan2(back, down);
}

function bobFor(stride: number): number {
  return -F.bob * Math.abs(stride); // the body dips as the legs spread
}

function poseParts(look: Look, pose: Pose, detail: Detail): void {
  const full = detail === "full";
  const stride = pose.walking ? T.MathUtils.clamp(pose.stride, -1, 1) : 0;
  const bob = bobFor(stride);
  const cap = look.hairStyle === "cap";

  place(
    "torso",
    look.shirt,
    0,
    F.torsoY + bob,
    0,
    0,
    0,
    0,
    F.torsoWide,
    1,
    F.torsoDeep,
  );
  if (look.skirt)
    place("skirt", look.shirt, 0, F.skirtY + bob, 0, 0, 0, 0, 1, 1, 1);
  if (look.apron)
    place("apron", APRON, 0, F.apronY + bob, F.apronZ, 0, 0, 0, 1, 1, 1);
  if (full) place("neck", look.skin, 0, F.neckY + bob, 0, 0, 0, 0, 1, 1, 1);

  const headY = F.headY + bob;
  place("head", look.skin, 0, headY, 0, 0, pose.faceYaw, 0, 1, F.headTall, 1);
  place(
    "hairCap",
    cap ? look.hat : look.hair,
    0,
    headY,
    0,
    0,
    pose.faceYaw,
    0,
    1,
    F.headTall,
    1,
  );
  if (full) {
    if (look.hairStyle === "long")
      place(
        "hairLong",
        look.hair,
        0,
        headY,
        0,
        0,
        pose.faceYaw,
        0,
        1,
        F.headTall,
        1,
      );
    else if (look.hairStyle === "bun")
      place(
        "hairBun",
        look.hair,
        0,
        headY,
        0,
        0,
        pose.faceYaw,
        0,
        1,
        F.headTall,
        1,
      );
    else if (cap)
      place(
        "hairBrim",
        look.hat,
        0,
        headY,
        0,
        0,
        pose.faceYaw,
        0,
        1,
        F.headTall,
        1,
      );
  }

  const legColour = look.skirt ? look.skin : look.trousers;
  const sleeveColour = look.shortSleeves ? look.skin : look.shirt;
  for (let side = 0; side < 2; side++) {
    const sx = side === 0 ? -1 : 1; // left (-X) first
    const lead = side === 0 ? stride : -stride; // the left leg leads for positive stride

    // Leg: the hip swings forward when leading; the trailing knee bends.
    const hip = -F.hipSwing * lead;
    const shin = hip + F.kneeBend * Math.max(0, -lead);
    const hx = sx * F.hipX;
    const hy = F.hipY + bob;
    if (full) {
      place("upperLeg", legColour, hx, hy, 0, hip, 0, 0, 1, 1, 1);
      const ky = hy - F.thighLen * Math.cos(hip);
      const kz = -F.thighLen * Math.sin(hip);
      place("lowerLeg", legColour, hx, ky, kz, shin, 0, 0, 1, 1, 1);
      place(
        "foot",
        SHOES,
        hx,
        ky - F.shinLen * Math.cos(shin),
        kz - F.shinLen * Math.sin(shin) + F.footForward,
        0,
        0,
        0,
        1,
        1,
        1,
      );
    } else {
      reach(hip, F.thighLen, shin, F.shinLen);
      place(
        "upperLeg",
        legColour,
        hx,
        hy,
        0,
        REACH.angle,
        0,
        0,
        1,
        REACH.length / F.thighLen,
        1,
      );
    }

    // Arm: counter-swings against the same-side leg, or holds the tray.
    const upper = pose.carrying ? F.carryUpper : F.armSwing * lead;
    const fore = pose.carrying ? F.carryFore : upper;
    const out = sx * F.armOut;
    const ax = sx * F.shoulderX;
    const ay = F.shoulderY + bob;
    const cos = Math.cos(out);
    const sin = Math.sin(out);
    if (full) {
      place("upperArm", look.shirt, ax, ay, 0, upper, 0, out, 1, 1, 1);
      const down = F.upperArmLen * Math.cos(upper);
      const ex = ax + down * sin;
      const ey = ay - down * cos;
      const ez = -F.upperArmLen * Math.sin(upper);
      place("forearm", sleeveColour, ex, ey, ez, fore, 0, out, 1, 1, 1);
      const lower = F.forearmLen * Math.cos(fore);
      place(
        "hand",
        look.skin,
        ex + lower * sin,
        ey - lower * cos,
        ez - F.forearmLen * Math.sin(fore),
        0,
        0,
        0,
        1,
        1,
        1,
      );
    } else {
      reach(upper, F.upperArmLen, fore, F.forearmLen);
      place(
        "upperArm",
        look.shirt,
        ax,
        ay,
        0,
        REACH.angle,
        0,
        out,
        1,
        REACH.length / F.upperArmLen,
        1,
      );
    }
  }
}

export function posePerson(
  look: Look,
  pose: Pose,
  detail: Detail,
  emit: Emit,
): void {
  sink = emit;
  const scale = look.height * look.width;
  ROOT.compose(
    POS.set(pose.x, 0, pose.z),
    QUAT.setFromEuler(EULER.set(0, pose.yaw, 0, "XYZ")),
    SCALE.set(scale, look.height, scale),
  );
  poseParts(look, pose, detail);
  sink = NOOP;
}

// Where the midpoint between the carrying hands sits at this stride, in world
// units from the feet (the walking bob included, so a tray stays in the hands).
export function carryPoint(
  look: Look,
  stride = 0,
): { y: number; forward: number } {
  const s = T.MathUtils.clamp(stride, -1, 1);
  const down =
    F.upperArmLen * Math.cos(F.carryUpper) +
    F.forearmLen * Math.cos(F.carryFore);
  const back =
    F.upperArmLen * Math.sin(F.carryUpper) +
    F.forearmLen * Math.sin(F.carryFore);
  return {
    y: (F.shoulderY + bobFor(s) - down * Math.cos(F.armOut)) * look.height,
    forward: -back * look.height * look.width,
  };
}
