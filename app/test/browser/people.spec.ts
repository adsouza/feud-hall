import fc from "fast-check";
import { expect, test } from "./hall";
import * as T from "three";
import {
  FIGURE,
  CART_HANDLE_HEIGHT,
  FIGURE_MAX_SPAN,
  SEAT_HEIGHT,
  carryPoint,
  cartHandlePoint,
  seatedTrayPoint,
  stoolPushReach,
  personLook,
  posePerson,
  serialFor,
  staffLooks,
  type Detail,
  type Look,
  PART_KINDS,
  type PartKind,
  type Pose,
  type Role,
} from "../../src/people";
import { createPeople } from "../../src/people-mesh";
import {
  COUNTER_TRAY,
  PICKUP_SPOT,
  QUEUE_SPOTS,
  STAFF_SPOTS,
  TAKE_MS,
  collectMs,
  collectTray,
} from "../../src/hall-layout";

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

test("people: a serial for a key is a stable unsigned 32-bit hash", () => {
  expect(serialFor("staff:stall-1")).toBe(serialFor("staff:stall-1"));
  const keys = [
    "",
    "owner:r-1",
    "owner:r-2",
    "staff:stall-1",
    "staff:stall-2",
    "staff:stall-10",
  ];
  for (const key of keys) {
    const serial = serialFor(key);
    expect(Number.isInteger(serial)).toBe(true);
    expect(serial).toBeGreaterThanOrEqual(0);
    expect(serial).toBeLessThan(2 ** 32);
  }
  expect(new Set(keys.map(serialFor)).size).toBe(keys.length);
});

test("people: staff looks follow the stall and the business, not a scene slot", () => {
  const crew = (looks: Look[]) => looks.slice(1);
  const a = staffLooks("r-1", "stall-1", 9);
  expect(a.length).toBe(10);
  expect(staffLooks("r-1", "stall-1", 9)).toEqual(a);
  const b = staffLooks("r-1", "stall-2", 9);
  expect(crew(b)).not.toEqual(crew(a));
  // Not a row of clones: the nine workers at one stall are not all alike.
  expect(new Set(crew(a).map((look) => JSON.stringify(look))).size).toBe(9);
  // One business's owner is the same person at each of its stalls.
  expect(b[0]).toEqual(a[0]);
  expect(a[0].apron).toBe(true);
  expect(staffLooks("r-2", "stall-1", 9)[0]).not.toEqual(a[0]);
  expect(crew(staffLooks("r-2", "stall-1", 9))).toEqual(crew(a));
  // Without a business, the owner is keyed to the stall.
  expect(staffLooks("", "stall-1", 0)[0]).toEqual(
    staffLooks("", "stall-1", 0)[0],
  );
  expect(staffLooks("", "stall-1", 0)[0]).not.toEqual(
    staffLooks("", "stall-2", 0)[0],
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
  pushing: false,
  seated: false,
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

test("people: each part takes its colour from the look", () => {
  const looks = [
    lookWith({ skirt: false, shortSleeves: false, hairStyle: "short" }),
    lookWith({ skirt: true, shortSleeves: true, hairStyle: "long" }),
    lookWith({ skirt: false, shortSleeves: true, hairStyle: "bun" }),
    lookWith({ skirt: true, shortSleeves: false, hairStyle: "cap" }),
    lookWith({ hairStyle: "cap", skirt: false }, "owner"),
    lookWith({ hairStyle: "short", skirt: true }, "worker"),
  ];
  for (const look of looks) {
    const want: Record<PartKind, number> = {
      torso: look.shirt,
      upperArm: look.shirt,
      skirt: look.shirt,
      forearm: look.shortSleeves ? look.skin : look.shirt,
      upperLeg: look.skirt ? look.skin : look.trousers,
      lowerLeg: look.skirt ? look.skin : look.trousers,
      head: look.skin,
      neck: look.skin,
      hand: look.skin,
      hairCap: look.hairStyle === "cap" ? look.hat : look.hair,
      hairLong: look.hair,
      hairBun: look.hair,
      hairBrim: look.hat,
      apron: 0xf3e6d0,
      foot: 0x2b2623,
    };
    const list = parts(look);
    expect(list.length).toBeGreaterThan(0);
    for (const part of list)
      expect(part.colour, part.kind).toBe(want[part.kind]);
    // The simple figure keeps the same colour rules for the parts it draws.
    for (const part of parts(look, stand, "simple"))
      expect(part.colour, part.kind).toBe(want[part.kind]);
  }
  // The skirt, apron and every hair style above were all drawn and checked.
  const kinds = new Set(
    looks.flatMap((look) => parts(look).map((p) => p.kind)),
  );
  expect([...kinds].sort()).toEqual([...PART_KINDS].sort());
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
      seated: false,
    }).filter((p) => p.kind === "hand");
    expect(left.at.y).toBeCloseTo(right.at.y, 6);
    expect(left.at.z).toBeCloseTo(right.at.z, 6);
    expect(left.at.z).toBeGreaterThan(0.15 * look.height);
    expect(carryPoint(look, stride).y).toBeCloseTo(left.at.y, 6);
    expect(carryPoint(look, stride).forward).toBeCloseTo(left.at.z, 6);
  }
});

const base = personLook(7, "owner");
const pushLooks = () => [
  personLook(1, "owner"),
  personLook(2, "owner"),
  personLook(3, "owner"),
  personLook(99, "owner"),
  personLook(4096, "owner"),
  { ...base, height: 1.38, width: 0.9 },
  { ...base, height: 1.62, width: 1.1 },
];
const pushPose = (stride: number): Pose => ({
  ...stand,
  pushing: true,
  walking: true,
  stride,
});
const positionsOf = (
  list: { kind: PartKind; at: T.Vector3 }[],
  kinds: PartKind[],
) =>
  list
    .filter((p) => kinds.includes(p.kind))
    .map((p) => [p.kind, p.at.x, p.at.y, p.at.z]);

test("people: a figure pushing a cart holds the handle with both hands at handle height", () => {
  expect(CART_HANDLE_HEIGHT).toBe(0.9);
  for (const look of pushLooks()) {
    const pushing = parts(look, pushPose(0.5), "full");
    const hands = pushing.filter((p) => p.kind === "hand");
    expect(hands).toHaveLength(2);
    for (const hand of hands) {
      expect(Math.abs(hand.at.y - CART_HANDLE_HEIGHT)).toBeLessThan(0.01);
      expect(hand.at.z).toBeGreaterThan(0.15 * look.height);
    }
    // Arms do not swing while pushing; legs do.
    const back = parts(look, pushPose(-0.5), "full");
    expect(positionsOf(pushing, ["upperArm", "forearm", "hand"])).toEqual(
      positionsOf(back, ["upperArm", "forearm", "hand"]),
    );
    expect(positionsOf(pushing, ["lowerLeg", "foot"])).not.toEqual(
      positionsOf(back, ["lowerLeg", "foot"]),
    );
  }
});

test("people: the simple figure's single-piece arms end at the handle height", () => {
  const end = new T.Vector3();
  for (const look of pushLooks()) {
    const ends: T.Vector3[] = [];
    posePerson(look, pushPose(0.5), "simple", (kind, matrix) => {
      // The arm hangs from its origin, scaled along Y to the reach.
      if (kind === "upperArm")
        ends.push(
          end.set(0, -FIGURE.upperArmLen, 0).applyMatrix4(matrix).clone(),
        );
    });
    expect(ends).toHaveLength(2);
    for (const e of ends) {
      expect(Math.abs(e.y - CART_HANDLE_HEIGHT)).toBeLessThan(0.01);
      expect(e.z).toBeGreaterThan(0.15 * look.height);
    }
  }
});

test("people: both hands of a pushing figure meet at cartHandlePoint", () => {
  for (const look of pushLooks()) {
    for (const stride of [0, 0.5, -0.5, 1]) {
      const hands = parts(look, pushPose(stride)).filter(
        (p) => p.kind === "hand",
      );
      const handle = cartHandlePoint(look, stride);
      expect(handle.y).toBeCloseTo(CART_HANDLE_HEIGHT, 6);
      expect(handle.forward).toBeGreaterThan(0);
      expect((hands[0].at.y + hands[1].at.y) / 2).toBeCloseTo(handle.y, 6);
      expect((hands[0].at.z + hands[1].at.z) / 2).toBeCloseTo(
        handle.forward,
        6,
      );
    }
    expect(cartHandlePoint(look).forward).toBeCloseTo(
      cartHandlePoint(look, 0).forward,
      9,
    );
  }
});

test("people: stool pushers bend and meet the stool's top with both hands", () => {
  for (const look of pushLooks()) {
    for (const stride of [-1, -0.5, 0, 0.5, 1]) {
      // The intro positions the worker so the hands land 13 cm from the middle.
      const pose: Pose = {
        ...stand,
        z: -0.13 - stoolPushReach(look, stride),
        stride,
        walking: true,
        stoolPush: 1,
      };
      const figure = parts(look, pose);
      const hands = figure.filter((part) => part.kind === "hand");
      expect(hands).toHaveLength(2);
      for (const { at } of hands) {
        expect(at.y).toBeGreaterThan(SEAT_HEIGHT);
        expect(at.y - FIGURE.handR * look.height).toBeLessThan(SEAT_HEIGHT);
        expect(Math.hypot(at.x, at.z)).toBeLessThan(0.24);
      }
      const head = figure.find((part) => part.kind === "head")!.at;
      expect(head.y).toBeLessThan(look.height * 0.75);
      expect(head.z).toBeGreaterThan(pose.z + 0.4);
    }
  }
});

test("people: pushing and carrying are exclusive, pushing wins; seated still wins over both", () => {
  const look = personLook(5, "owner");
  for (const detail of ["full", "simple"] as const) {
    const both = { ...pushPose(0.5), carrying: true };
    expect(parts(look, both, detail)).toEqual(
      parts(look, pushPose(0.5), detail),
    );
    expect(parts(look, { ...both, seated: true }, detail)).toEqual(
      parts(look, { ...stand, seated: true }, detail),
    );
  }
});

const heightOf = (list: { at: T.Vector3 }[]) => list.map((p) => p.at.y);
const hipHeight = (list: { kind: PartKind; at: T.Vector3 }[]) => {
  const hips = list.filter((p) => p.kind === "upperLeg");
  return hips.reduce((sum, p) => sum + p.at.y, 0) / hips.length;
};
const lowestPoint = (list: { at: T.Vector3 }[]) => Math.min(...heightOf(list));
const headHeight = (list: { kind: PartKind; at: T.Vector3 }[]) =>
  list.find((p) => p.kind === "head")!.at.y;

test("people: a seated figure sits on the seat with feet on the floor", () => {
  for (const serial of [1, 2, 3, 99, 4096]) {
    const look = personLook(serial, "diner");
    for (const detail of ["full", "simple"] as const) {
      const seated = parts(look, { ...stand, seated: true }, detail);
      // The hips are at seat height, whatever the figure's height.
      expect(hipHeight(seated)).toBeCloseTo(SEAT_HEIGHT, 2);
      // Nothing is below the floor and the head is lower than when standing.
      expect(lowestPoint(seated)).toBeGreaterThanOrEqual(-0.005);
      expect(headHeight(seated)).toBeLessThan(
        headHeight(parts(look, stand, detail)),
      );
    }
  }
});

test("people: seated hands rest on the table where seatedTrayPoint says", () => {
  for (const serial of [1, 2, 3, 99, 4096]) {
    const look = personLook(serial, "diner");
    const hands = parts(look, { ...stand, seated: true }).filter(
      (p) => p.kind === "hand",
    );
    const tray = seatedTrayPoint(look);
    for (const hand of hands) {
      expect(hand.at.y).toBeCloseTo(tray.y, 2);
      expect(hand.at.z).toBeCloseTo(tray.forward, 2);
    }
    // Feet reach the floor: the ankle is as low as when standing.
    const feet = parts(look, { ...stand, seated: true }).filter(
      (p) => p.kind === "foot",
    );
    for (const foot of feet)
      expect(foot.at.y).toBeCloseTo(
        parts(look).find((p) => p.kind === "foot")!.at.y,
        2,
      );
  }
});

test("people: seated ignores walking and stride", () => {
  const look = personLook(7, "diner");
  const a = parts(look, { ...stand, seated: true });
  const b = parts(look, {
    ...stand,
    seated: true,
    walking: true,
    stride: 0.8,
    carrying: true,
  });
  expect(b).toEqual(a);
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
  expect(span).toBeLessThanOrEqual(FIGURE_MAX_SPAN + 1e-9);
});

test("people: every limb hangs down from its joint", () => {
  const people = createPeople(1, null);
  for (const [kind, radius] of [
    ["upperLeg", FIGURE.thighR],
    ["lowerLeg", FIGURE.shinR],
    ["upperArm", FIGURE.upperArmR],
    ["forearm", FIGURE.forearmR],
  ] as const) {
    const geometry = people.mesh(kind).geometry;
    geometry.computeBoundingBox();
    const box = geometry.boundingBox as T.Box3;
    // The joint is the origin: the limb's top is there, its bottom below.
    expect(box.max.y, kind).toBeLessThanOrEqual(radius + 1e-9);
    expect(box.max.y, kind).toBeGreaterThanOrEqual(-1e-9);
    expect(box.min.y, kind).toBeLessThan(-0.05);
  }
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

test("people: the pickup spot is beside the queue and off the pickup view's centre line", () => {
  expect(PICKUP_SPOT[0] - FIGURE_MAX_SPAN / 2).toBeGreaterThanOrEqual(0.1);
  // The tray's whole trip, counter to pickup spot, stays clear of everyone waiting.
  for (let n = 0; n <= 20; n++) {
    const x = T.MathUtils.lerp(COUNTER_TRAY[0], PICKUP_SPOT[0], n / 20);
    const z = T.MathUtils.lerp(COUNTER_TRAY[1], PICKUP_SPOT[1], n / 20);
    for (const spot of QUEUE_SPOTS)
      expect(Math.hypot(x - spot[0], z - spot[1])).toBeGreaterThanOrEqual(
        FIGURE_MAX_SPAN / 2 + 0.3,
      );
  }
});

test("people: a diner called for a tray walks to the counter without brushing the queue", () => {
  // The last diner in the queue is the one served; everyone before them waits.
  for (const [served, from] of QUEUE_SPOTS.entries()) {
    const total = collectMs(from[0], from[1]);
    const start = collectTray(from[0], from[1], 0);
    expect([start.x, start.z]).toEqual([from[0], from[1]]);
    const end = collectTray(from[0], from[1], total);
    expect(end.x).toBeCloseTo(PICKUP_SPOT[0], 9);
    expect(end.z).toBeCloseTo(PICKUP_SPOT[1], 9);
    let last = start;
    for (let ms = 0; ms <= total; ms += 10) {
      const pose = collectTray(from[0], from[1], ms);
      // No jumps: a 10 ms step is a few centimetres at most.
      expect(Math.hypot(pose.x - last.x, pose.z - last.z)).toBeLessThan(0.05);
      last = pose;
      for (const waiting of QUEUE_SPOTS.slice(0, served))
        expect(
          Math.hypot(pose.x - waiting[0], pose.z - waiting[1]),
        ).toBeGreaterThanOrEqual(FIGURE_MAX_SPAN);
    }
  }
});

test("people: the tray leaves the counter only once the diner stands at the pickup spot", () => {
  fc.assert(
    fc.property(
      fc.double({ min: -3, max: 1, noNaN: true }),
      fc.double({ min: 1.5, max: 4, noNaN: true }),
      fc.double({ min: 0, max: 1, noNaN: true }),
      (fromX, fromZ, part) => {
        const total = collectMs(fromX, fromZ);
        expect(Number.isFinite(total)).toBe(true);
        expect(total).toBeGreaterThanOrEqual(TAKE_MS);
        const pose = collectTray(fromX, fromZ, total * part);
        const there =
          Math.hypot(pose.x - PICKUP_SPOT[0], pose.z - PICKUP_SPOT[1]) < 1e-9;
        for (const value of [pose.x, pose.z, pose.yaw, pose.metres, pose.take])
          expect(Number.isFinite(value)).toBe(true);
        expect(pose.take).toBeGreaterThanOrEqual(0);
        expect(pose.take).toBeLessThanOrEqual(1);
        if (!there) expect(pose.take).toBe(0);
        if (pose.take > 0) {
          expect(pose.walking).toBe(false);
          // Taking the tray, the diner faces it.
          expect(pose.yaw).toBeCloseTo(
            Math.atan2(
              COUNTER_TRAY[0] - PICKUP_SPOT[0],
              COUNTER_TRAY[1] - PICKUP_SPOT[1],
            ),
            9,
          );
        }
        // The hands close on the tray steadily, and hold it by the end.
        const later = collectTray(fromX, fromZ, total * part + 20);
        expect(later.take).toBeGreaterThanOrEqual(pose.take);
        expect(collectTray(fromX, fromZ, total).take).toBe(1);
        expect(collectTray(fromX, fromZ, total - TAKE_MS).take).toBeCloseTo(
          0,
          9,
        );
      },
    ),
  );
});

test("people: a walking diner faces the way they are going", () => {
  const [fromX, fromZ] = QUEUE_SPOTS[2];
  const along = collectTray(fromX, fromZ, 100);
  expect(along.walking).toBe(true);
  expect(along.z).toBe(fromZ); // along their own row first
  expect(along.x).toBeGreaterThan(fromX);
  expect(along.yaw).toBeCloseTo(Math.PI / 2, 9); // +x
  const total = collectMs(fromX, fromZ);
  const forward = collectTray(fromX, fromZ, total - TAKE_MS - 100);
  expect(forward.walking).toBe(true);
  expect(forward.x).toBeCloseTo(PICKUP_SPOT[0], 9); // then up the pickup lane
  expect(forward.z).toBeLessThan(fromZ);
  expect(Math.abs(forward.yaw)).toBeCloseTo(Math.PI, 9); // toward the counter
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
