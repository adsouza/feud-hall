import fc from "fast-check";
import { expect, test } from "./hall";
import { personLook } from "../../src/people";

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
