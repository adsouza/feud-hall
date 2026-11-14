import fc from "fast-check";
import { expect, test } from "./hall";
import * as T from "three";
import {
  FIGURE,
  FIGURE_MAX_SPAN,
  carryPoint,
  personLook,
  posePerson,
  type Detail,
  type Look,
  type PartKind,
  type Pose,
  type Role,
} from "../../src/people";

test("people: a look is a pure function of serial and role", () => {
  expect(personLook(42, "diner")).toEqual(personLook(42, "diner"));
  fc.assert(
    fc.property(
      fc.integer(),
      fc.constantFrom("diner", "owner", "worker"),
      (serial, role) => {
        const look = personLook(serial, role);
        expect(look.height).toBeGreaterThanOrEqual(1.38);
        expect(look.height).toBeLessThanOrEqual(1.62);
        expect(look.width).toBeGreaterThanOrEqual(0.9);
        expect(look.width).toBeLessThanOrEqual(1.1);
        for (const colour of [
          look.shirt,
          look.skin,
          look.hair,
          look.trousers,
          look.hat,
        ])
          expect(
            Number.isInteger(colour) && colour >= 0 && colour <= 0xffffff,
          ).toBe(true);
      },
    ),
  );
});

test("people: roles dress as the design says", () => {
  for (let serial = 0; serial < 200; serial++) {
    expect(personLook(serial, "owner")).toMatchObject({
      apron: true,
      shirt: 0xff9e57,
    });
    expect(personLook(serial, "worker")).toMatchObject({
      apron: false,
      shirt: 0x8de2d1,
    });
    expect(personLook(serial, "diner").apron).toBe(false);
  }
});

test("people: a queue of diners is not a row of clones", () => {
  const looks = Array.from({ length: 1000 }, (_, serial) =>
    personLook(serial, "diner"),
  );
  expect(new Set(looks.map((l) => l.shirt)).size).toBe(9);
  expect(new Set(looks.map((l) => l.skin)).size).toBe(6);
  expect(
    new Set(looks.map((l) => `${l.hairStyle}/${l.skirt}/${l.shortSleeves}`))
      .size,
  ).toBe(16);
  const twins = looks.filter(
    (l, i) =>
      i > 0 &&
      l.shirt === looks[i - 1].shirt &&
      l.hairStyle === looks[i - 1].hairStyle,
  ).length;
  expect(twins).toBeLessThan(100);
});

const stand: Pose = {
  x: 0,
  z: 0,
  yaw: 0,
  faceYaw: 0,
  stride: 0,
  walking: false,
  carrying: false,
};
function parts(look: Look, pose: Pose = stand, detail: Detail = "full") {
  const out: { kind: PartKind; at: T.Vector3; colour: number }[] = [];
  posePerson(look, pose, detail, (kind, matrix, colour) =>
    out.push({
      kind,
      at: new T.Vector3().setFromMatrixPosition(matrix),
      colour,
    }),
  );
  return out;
}
const count = (list: { kind: PartKind }[], kind: PartKind) =>
  list.filter((p) => p.kind === kind).length;
const lookWith = (wanted: Partial<Look>, role: Role = "diner") => {
  for (let serial = 0; serial < 5000; serial++) {
    const look = personLook(serial, role);
    if (Object.entries(wanted).every(([k, v]) => look[k as keyof Look] === v))
      return look;
  }
  throw new Error("no such look");
};

test("people: a full figure has every part once per side", () => {
  const plain = parts(lookWith({ hairStyle: "short", skirt: false }));
  expect(plain.map((p) => p.kind).sort()).toEqual(
    [
      "torso",
      "neck",
      "head",
      "hairCap",
      "upperLeg",
      "upperLeg",
      "lowerLeg",
      "lowerLeg",
      "foot",
      "foot",
      "upperArm",
      "upperArm",
      "forearm",
      "forearm",
      "hand",
      "hand",
    ].sort(),
  );
  expect(count(parts(lookWith({ skirt: true })), "skirt")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "bun" })), "hairBun")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "long" })), "hairLong")).toBe(1);
  expect(count(parts(lookWith({ hairStyle: "cap" })), "hairBrim")).toBe(1);
  expect(count(parts(personLook(3, "owner")), "apron")).toBe(1);
});

test("people: a simple figure keeps the silhouette and the owner's apron", () => {
  const simple = parts(
    lookWith({ hairStyle: "bun", skirt: false }, "owner"),
    stand,
    "simple",
  );
  expect(simple.map((p) => p.kind).sort()).toEqual(
    [
      "torso",
      "head",
      "hairCap",
      "apron",
      "upperLeg",
      "upperLeg",
      "upperArm",
      "upperArm",
    ].sort(),
  );
});

test("people: a figure stands on the floor at its own height", () => {
  const look = personLook(7, "diner");
  const list = parts(look);
  for (const part of list) expect(part.at.y).toBeGreaterThanOrEqual(0);
  const head = list.find((p) => p.kind === "head")!;
  expect(head.at.y).toBeCloseTo(look.height * FIGURE.headY, 6);
  expect(head.at.x).toBeCloseTo(0, 6);
  expect(head.at.z).toBeCloseTo(0, 6);
});

test("people: turning the body turns every part about the feet", () => {
  fc.assert(
    fc.property(
      fc.integer(),
      fc.double({ min: -Math.PI, max: Math.PI, noNaN: true }),
      fc.double({ min: -50, max: 50, noNaN: true }),
      fc.double({ min: -50, max: 50, noNaN: true }),
      (serial, yaw, x, z) => {
        const look = personLook(serial, "diner");
        const base = parts(look);
        const turned = parts(look, { ...stand, x, z, yaw });
        base.forEach((part, i) => {
          const want = part.at
            .clone()
            .applyAxisAngle(new T.Vector3(0, 1, 0), yaw)
            .add(new T.Vector3(x, 0, z));
          expect(turned[i].at.distanceTo(want)).toBeLessThan(1e-6);
        });
      },
    ),
  );
});

test("people: walking swings opposite legs and arms, and standing ignores stride", () => {
  const look = personLook(11, "diner");
  const walk = (stride: number) =>
    parts(look, { ...stand, stride, walking: true });
  const feet = (list: ReturnType<typeof parts>) =>
    list.filter((p) => p.kind === "foot");
  const hands = (list: ReturnType<typeof parts>) =>
    list.filter((p) => p.kind === "hand");
  const [left, right] = feet(walk(0.8));
  expect(Math.sign(left.at.z)).toBe(-Math.sign(right.at.z));
  expect(Math.sign(feet(walk(-0.8))[0].at.z)).toBe(-Math.sign(left.at.z));
  expect(Math.sign(hands(walk(0.8))[0].at.z)).toBe(-Math.sign(left.at.z));
  const [lead, trail] = left.at.z > right.at.z ? [left, right] : [right, left];
  expect(trail.at.y).toBeGreaterThan(lead.at.y);
  expect(parts(look, { ...stand, stride: 0.8, walking: false })).toEqual(
    parts(look),
  );
});

test("people: carrying holds both hands level in front, where carryPoint says", () => {
  const look = personLook(5, "diner");
  for (const stride of [0, 0.8, -0.8]) {
    const [left, right] = parts(look, {
      ...stand,
      stride,
      walking: true,
      carrying: true,
    }).filter((p) => p.kind === "hand");
    expect(left.at.y).toBeCloseTo(right.at.y, 6);
    expect(left.at.z).toBeCloseTo(right.at.z, 6);
    expect(left.at.z).toBeGreaterThan(0.15 * look.height);
    expect(carryPoint(look, stride).y).toBeCloseTo(left.at.y, 6);
    expect(carryPoint(look, stride).forward).toBeCloseTo(left.at.z, 6);
  }
});

test("people: every pose is finite, and no look is wider than the stated span", () => {
  fc.assert(
    fc.property(
      fc.integer(),
      fc.double({ min: -1, max: 1, noNaN: true }),
      fc.boolean(),
      fc.boolean(),
      fc.constantFrom<Detail>("full", "simple"),
      (serial, stride, walking, carrying, detail) => {
        const look = personLook(serial, "diner");
        posePerson(
          look,
          { ...stand, stride, walking, carrying },
          detail,
          (_kind, matrix) => {
            expect(matrix.elements.every(Number.isFinite)).toBe(true);
          },
        );
        const limit = FIGURE_MAX_SPAN / 2 + 1e-9;
        const reach = FIGURE.handR * look.height * look.width;
        const posed = { ...stand, stride, walking, carrying };
        for (const hand of parts(look, posed).filter((p) => p.kind === "hand"))
          expect(Math.abs(hand.at.x) + reach).toBeLessThanOrEqual(limit);
      },
    ),
  );

  // And the bound is tight, not loose.
  let widest: Look | undefined;
  for (let serial = 0; serial < 5000 && !widest; serial++) {
    const look = personLook(serial, "diner");
    if (look.height > 1.6 && look.width > 1.08) widest = look;
  }
  if (!widest) throw new Error("no such look");
  const [left, right] = parts(widest).filter((p) => p.kind === "hand");
  const reach = FIGURE.handR * widest.height * widest.width;
  const span = right.at.x - left.at.x + 2 * reach;
  expect(span).toBeGreaterThanOrEqual(0.95 * FIGURE_MAX_SPAN);
});
