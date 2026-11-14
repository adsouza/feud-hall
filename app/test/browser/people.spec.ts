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
  PART_KINDS,
  type PartKind,
  type Pose,
  type Role,
} from "../../src/people";
import { createPeople } from "../../src/people-mesh";
import { QUEUE_SPOTS, STAFF_SPOTS } from "../../src/hall-layout";

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

test("people: each person fills one batch slot per part, and a frame starts empty", () => {
  // Solid, fading colour and fading depth: one of each per part kind.
  expect(createPeople(1, null).meshes.length).toBe(45);
  expect(createPeople(500, null, 3).meshes.length).toBe(45);
  const people = createPeople(4, null);
  people.begin();
  people.add(lookWith({ hairStyle: "short", skirt: false }), stand, "full");
  people.end();
  expect(people.count).toBe(1);
  expect(people.mesh("head").count).toBe(1);
  expect(people.mesh("upperLeg").count).toBe(2);
  expect(people.mesh("skirt").count).toBe(0);
  people.begin();
  people.end();
  expect(people.count).toBe(0);
  for (const mesh of people.meshes) expect(mesh.count).toBe(0);
});

test("people: someone who does not fit, or has faded out, is skipped whole", () => {
  const people = createPeople(1, null);
  people.begin();
  people.add(personLook(1, "diner"), stand, "full", 0);
  expect(people.count).toBe(0);
  people.add(personLook(1, "diner"), stand, "full");
  people.add(personLook(2, "diner"), stand, "full");
  people.end();
  expect(people.count).toBe(1);
  expect(people.mesh("head").count).toBe(1);
  expect(people.mesh("hand").count).toBe(2);

  // A fading person who does not fit the fading capacity is skipped whole,
  // while solid people still fit.
  const mixed = createPeople(2, null, 1);
  mixed.begin();
  mixed.add(personLook(3, "diner"), stand, "full", 0.5);
  mixed.add(personLook(4, "diner"), stand, "full", 0.5);
  expect(mixed.count).toBe(1);
  mixed.add(personLook(5, "diner"), stand, "full");
  mixed.add(personLook(6, "diner"), stand, "full");
  mixed.end();
  expect(mixed.count).toBe(3);
  expect(mixed.fadingMesh("head").count).toBe(1);
  expect(mixed.fadingDepthMesh("head").count).toBe(1);
  expect(mixed.fadingMesh("hand").count).toBe(2);
  expect(mixed.mesh("head").count).toBe(2);
  expect(mixed.mesh("hand").count).toBe(4);
});

test("people: colour and opacity are written per person", () => {
  const people = createPeople(2, null);
  const look = personLook(9, "diner");
  people.begin();
  people.add(look, stand, "full", 0.4);
  people.end();
  const skin = new T.Color(look.skin);
  const fading = people.fadingMesh("head");
  const colour = fading.geometry.getAttribute("color");
  expect(colour.getX(0)).toBeCloseTo(skin.r, 5);
  expect(colour.getY(0)).toBeCloseTo(skin.g, 5);
  expect(colour.getZ(0)).toBeCloseTo(skin.b, 5);
  expect(colour.getW(0)).toBeCloseTo(0.4, 5);
  expect(fading.count).toBe(1);
  expect(people.fadingDepthMesh("head").count).toBe(fading.count);
  expect(people.mesh("head").count).toBe(0);

  people.begin();
  people.add(look, stand, "full", 1);
  people.end();
  const solid = people.mesh("head");
  const solidColour = solid.geometry.getAttribute("color");
  expect(solid.count).toBe(1);
  expect(solidColour.getX(0)).toBeCloseTo(skin.r, 5);
  expect(solidColour.getW(0)).toBe(1);
  expect(people.fadingMesh("head").count).toBe(0);
  expect(people.fadingDepthMesh("head").count).toBe(0);
});

test("people: disposing releases every geometry and material once", () => {
  const people = createPeople(2, null);
  const released = new Map<object, number>();
  const watch = (target: T.EventDispatcher<{ dispose: object }>) => {
    if (released.has(target)) return; // a shared geometry is watched once
    released.set(target, 0);
    target.addEventListener("dispose", () =>
      released.set(target, (released.get(target) ?? 0) + 1),
    );
  };
  for (const mesh of people.meshes) {
    watch(mesh.geometry);
    watch(mesh.material as T.Material);
  }
  people.dispose();
  // 15 kinds x (solid geometry + solid material + shared fading geometry
  // + fading colour material + fading depth material) = 75.
  expect(released.size).toBe(75);
  for (const count of released.values()) expect(count).toBe(1);
});

test("people: feet rest on the floor and do not sink through it", () => {
  const picks: Look[] = [];
  let tall: Look | undefined;
  let short: Look | undefined;
  for (let serial = 0; serial < 5000; serial++) {
    const look = personLook(serial, "diner");
    if (!tall || look.height * look.width > tall.height * tall.width)
      tall = look;
    if (!short || look.height * look.width < short.height * short.width)
      short = look;
  }
  if (tall && short) picks.push(tall, short);
  for (let serial = 0; serial < 6; serial++)
    picks.push(personLook(serial, "diner"));
  const people = createPeople(1, null);
  const feet = people.mesh("foot");
  feet.geometry.computeBoundingBox();
  const box = feet.geometry.boundingBox as T.Box3;
  const matrix = new T.Matrix4();
  const world = new T.Box3();
  for (const look of picks) {
    people.begin();
    people.add(look, stand, "full");
    people.end();
    expect(feet.count).toBe(2);
    for (let i = 0; i < feet.count; i++) {
      feet.getMatrixAt(i, matrix);
      world.copy(box).applyMatrix4(matrix);
      expect(world.min.y).toBeGreaterThanOrEqual(-0.005);
      expect(world.min.y).toBeLessThanOrEqual(0.03);
    }
  }
});

test("people: queue spots are far enough apart for the widest figure", () => {
  for (const [i, a] of QUEUE_SPOTS.entries())
    for (const b of QUEUE_SPOTS.slice(i + 1))
      expect(Math.hypot(a[0] - b[0], a[1] - b[1])).toBeGreaterThanOrEqual(
        FIGURE_MAX_SPAN,
      );
  expect(STAFF_SPOTS.length).toBe(9);
});

test("people: the queue stands clear of the tray pickup lane", () => {
  // The pickup view looks along the stall's centre line (x = 0) at the tray.
  for (const spot of QUEUE_SPOTS)
    expect(spot[0] + FIGURE_MAX_SPAN / 2).toBeLessThanOrEqual(-0.1);
});

test("people: a frame uploads only the slots in use", () => {
  const people = createPeople(100, null);
  const hands = people.mesh("hand");
  const colours = hands.geometry.getAttribute(
    "color",
  ) as T.InstancedBufferAttribute;
  people.begin();
  people.add(personLook(1, "diner"), stand, "full");
  people.add(personLook(2, "diner"), stand, "full");
  people.end();
  expect(hands.count).toBe(4);
  expect(hands.instanceMatrix.updateRanges).toEqual([{ start: 0, count: 64 }]);
  expect(colours.updateRanges).toEqual([{ start: 0, count: 16 }]);
  // Fewer people next frame: the ranges shrink to the slots now in use.
  people.begin();
  people.add(personLook(1, "diner"), stand, "full");
  people.end();
  expect(hands.instanceMatrix.updateRanges).toEqual([{ start: 0, count: 32 }]);
  expect(colours.updateRanges).toEqual([{ start: 0, count: 8 }]);

  // The fading set: one shared matrix buffer, flagged with its own range.
  const fadingHands = people.fadingMesh("hand");
  const fadingColours = fadingHands.geometry.getAttribute(
    "color",
  ) as T.InstancedBufferAttribute;
  people.begin();
  for (const serial of [3, 4, 5])
    people.add(personLook(serial, "diner"), stand, "full", 0.5);
  people.end();
  expect(fadingHands.instanceMatrix.updateRanges).toEqual([
    { start: 0, count: 96 },
  ]);
  expect(fadingColours.updateRanges).toEqual([{ start: 0, count: 24 }]);
  people.begin();
  people.add(personLook(3, "diner"), stand, "full", 0.5);
  people.end();
  expect(fadingHands.instanceMatrix.updateRanges).toEqual([
    { start: 0, count: 32 },
  ]);
  expect(fadingColours.updateRanges).toEqual([{ start: 0, count: 8 }]);
  expect(people.fadingDepthMesh("hand").instanceMatrix.updateRanges).toEqual([
    { start: 0, count: 32 },
  ]);

  // An empty kind is not flagged for upload at all.
  const bun = people.mesh("hairBun").instanceMatrix;
  bun.clearUpdateRanges();
  const version = bun.version;
  people.begin();
  people.end();
  expect(bun.version).toBe(version);
  expect(bun.updateRanges).toEqual([]);
});

test("people: fading people are drawn with a depth pre-pass", () => {
  const people = createPeople(2, null);
  for (const kind of PART_KINDS) {
    const solid = people.mesh(kind);
    const colour = people.fadingMesh(kind);
    const depth = people.fadingDepthMesh(kind);
    expect(depth.geometry).toBe(colour.geometry);
    expect(depth.instanceMatrix).toBe(colour.instanceMatrix);
    const depthMaterial = depth.material as T.Material;
    expect(depthMaterial.colorWrite).toBe(false);
    expect(depthMaterial.depthWrite).toBe(true);
    expect(depthMaterial.transparent).toBe(false);
    // Laid down after every other opaque object, so it hides nothing behind.
    expect(depth.renderOrder).toBeGreaterThan(solid.renderOrder);
    const colourMaterial = colour.material as T.Material;
    expect(colourMaterial.transparent).toBe(true);
    expect(colourMaterial.depthWrite).toBe(false);
    const solidMaterial = solid.material as T.Material;
    expect(solidMaterial.transparent).toBe(false);
    expect(solidMaterial.alphaHash).toBe(false);
    for (const mesh of [solid, colour, depth])
      expect(people.meshes).toContain(mesh);
  }
});
