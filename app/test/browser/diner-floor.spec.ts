import fc from "fast-check";
import { expect, test } from "./hall";
import {
  CLEAR_MS,
  EAT_MS,
  ROOM_BUDGET,
  STALE_MS,
  createDinerFloor,
  type FloorFigure,
  type FloorInput,
  type FloorStall,
} from "../../src/diner-floor";
import { stallBlocks } from "../../src/hall-layout";
import {
  entrance,
  roomAt,
  seatSpots,
  spotPlacement,
} from "../../src/room-layout";

type Floor = ReturnType<typeof createDinerFloor>;
type Over = Partial<Omit<FloorInput, "stalls">> & {
  waiting?: Record<string, number>;
  served?: Record<string, string | null>;
  stalls?: FloorStall[];
};

const ID = (n: number) => `s${String(n).padStart(2, "0")}`;
const IDS = Array.from({ length: 15 }, (_, i) => ID(i + 1));
const STEP = 850;

function input(over: Over = {}): FloorInput {
  const { waiting = {}, served = {}, stalls, ...rest } = over;
  return {
    now: 0,
    serving: true,
    animate: true,
    browse: true,
    openRooms: 1,
    queueLimit: 6,
    today: { arrivals: 0, admitted: 0, left: 0 },
    stalls:
      stalls ??
      IDS.map((id, position) => ({
        id,
        room: 1,
        position,
        waiting: waiting[id] ?? 0,
        lastService: served[id] ?? null,
      })),
    ...rest,
  };
}

function all(floor: Floor, now: number): FloorFigure[] {
  const out: FloorFigure[] = [];
  floor.figures(now, (f) => out.push({ ...f }));
  return out;
}

/** Re-applies the same input every STEP ms from `from` up to `to`, inclusive. */
function hold(floor: Floor, base: FloorInput, from: number, to: number) {
  for (let now = from; now <= to; now += STEP) floor.apply({ ...base, now });
}

const walkingOrSeated = (figures: FloorFigure[], room: number) =>
  figures.filter(
    (f) =>
      f.room === room && (f.activity === "walking" || f.activity === "seated"),
  ).length;

test("floor: the first snapshot fills queues standing, with no walkers", () => {
  const floor = createDinerFloor();
  floor.apply(
    input({
      waiting: { s03: 3, s07: 9 },
      today: { arrivals: 500, admitted: 300, left: 220 },
    }),
  );
  const figures = all(floor, 0);
  expect(figures).toHaveLength(3 + 6); // s07 is capped at the queue limit
  expect(figures.every((f) => f.activity === "queued")).toBe(true);
  expect(floor.tally).toEqual({
    toQueue: 0,
    walkOut: 0,
    fromSeat: 0,
    thinned: 0,
  });
});

/** Independent oracles for the property below. */
function queueRises(previous: FloorInput, step: FloorInput) {
  const cap = Math.min(step.queueLimit ?? 4, 8);
  let rises = 0;
  for (const stall of step.stalls) {
    const before = previous.stalls.find((s) => s.id === stall.id)!;
    rises += Math.max(
      0,
      Math.min(stall.waiting, cap) - Math.min(before.waiting, cap),
    );
  }
  return rises;
}
function walkOutRise(previous: FloorInput, step: FloorInput) {
  const a = previous.today,
    b = step.today;
  if (!a || !b) return 0;
  if (b.arrivals < a.arrivals || b.admitted < a.admitted || b.left < a.left)
    return 0;
  return Math.max(0, b.arrivals - b.admitted - (a.arrivals - a.admitted));
}

/**
 * 2-30 snapshots 850 ms apart: each stall's waiting moves by -2..+2 within
 * 0..8, lastService sometimes changes, totals only rise, and admitted rises by
 * at least the queue rises (so no dessert is staged).
 */
function snapshots() {
  const stallSteps = fc.array(
    fc.record({ move: fc.integer({ min: -2, max: 2 }), serve: fc.nat(3) }),
    { minLength: 15, maxLength: 15 },
  );
  return fc
    .record({
      start: fc.array(fc.integer({ min: 0, max: 8 }), {
        minLength: 15,
        maxLength: 15,
      }),
      steps: fc.array(
        fc.record({
          stalls: stallSteps,
          extraAdmitted: fc.nat(3),
          walkOuts: fc.nat(3),
          left: fc.nat(3),
        }),
        { minLength: 1, maxLength: 29 },
      ),
    })
    .map(({ start, steps }) => {
      let current = input({
        waiting: Object.fromEntries(IDS.map((id, i) => [id, start[i]!])),
        today: { arrivals: 40, admitted: 30, left: 10 },
      });
      const out = [current];
      steps.forEach((step, n) => {
        const stalls = current.stalls.map((s, i) => {
          const change = step.stalls[i]!;
          return {
            ...s,
            waiting: Math.min(8, Math.max(0, s.waiting + change.move)),
            lastService: change.serve === 0 ? `t${n}:${i}` : s.lastService,
          };
        });
        const next: FloorInput = {
          ...current,
          now: current.now + STEP,
          stalls,
        };
        const admitted = queueRises(current, next) + step.extraAdmitted;
        const today = current.today!;
        next.today = {
          admitted: today.admitted + admitted,
          arrivals: today.arrivals + admitted + step.walkOuts,
          left: today.left + step.left,
        };
        out.push(next);
        current = next;
      });
      return out;
    });
}

test("floor: figures created equal the count changes received", () => {
  let runsWithRise = 0,
    runsWithWalkOut = 0,
    runsWithCollect = 0;
  fc.assert(
    fc.property(snapshots(), (steps) => {
      const floor = createDinerFloor();
      const expected = { toQueue: 0, walkOut: 0 };
      let previous = steps[0]!,
        collected = false;
      floor.apply(previous);
      for (const step of steps.slice(1)) {
        floor.apply(step);
        expected.toQueue += queueRises(previous, step);
        expected.walkOut += walkOutRise(previous, step);
        const t = floor.tally;
        expect(t.toQueue + t.fromSeat).toBe(expected.toQueue);
        expect(t.fromSeat).toBe(0);
        expect(t.walkOut + t.thinned).toBeGreaterThanOrEqual(expected.walkOut);
        expect(t.walkOut).toBeLessThanOrEqual(expected.walkOut);
        for (const stall of step.stalls)
          expect(floor.boundFor(stall.id)).toBeLessThanOrEqual(
            Math.min(stall.waiting, 6),
          );
        floor.figures(step.now, (f) => {
          if (f.activity === "collecting") collected = true;
        });
        previous = step;
      }
      if (expected.toQueue > 0) runsWithRise++;
      if (expected.walkOut > 0) runsWithWalkOut++;
      if (collected) runsWithCollect++;
    }),
    { numRuns: 200 },
  );
  // Progress floor over the whole run: the property saw real work.
  expect(runsWithRise).toBeGreaterThanOrEqual(100);
  expect(runsWithWalkOut).toBeGreaterThanOrEqual(100);
  expect(runsWithCollect).toBeGreaterThanOrEqual(50);
});

test("floor: nothing appears without a change", () => {
  const floor = createDinerFloor();
  const base = input({
    waiting: { s02: 2, s09: 4 },
    today: { arrivals: 50, admitted: 40, left: 5 },
  });
  for (let n = 0; n < 20; n++) {
    floor.apply({ ...base, now: n * STEP });
    expect(floor.count(n * STEP)).toBe(6);
    expect(floor.moving(n * STEP)).toBe(false);
  }
  expect(floor.tally).toEqual({
    toQueue: 0,
    walkOut: 0,
    fromSeat: 0,
    thinned: 0,
  });
});

test("floor: a walk-out enters and leaves by an open room's entrance", () => {
  const floor = createDinerFloor();
  const stalls = [1, 2].flatMap((room) =>
    IDS.map((_, position) => ({
      id: ID((room - 1) * 15 + position + 1),
      room,
      position,
      waiting: 0,
      lastService: null,
    })),
  );
  const base = input({ stalls, openRooms: 2 });
  floor.apply(base);
  const before = floor.count(0);
  const next = { ...base, today: { arrivals: 1, admitted: 0, left: 0 } };
  floor.apply({ ...next, now: STEP });
  expect(floor.tally.walkOut).toBe(1);
  const first = all(floor, STEP);
  expect(first).toHaveLength(before + 1);
  const walker = first[0]!;
  expect(walker.activity).toBe("walking");
  expect(walker.room).toBeLessThanOrEqual(2);
  const door = entrance(walker.room).outside;
  expect(walker.x).toBeCloseTo(door.x, 6);
  expect(walker.z).toBeCloseTo(door.z, 6);
  expect(walker.opacity).toBe(0);
  let last: FloorFigure | undefined;
  let gone = -1;
  for (let now = STEP; now <= STEP + 60_000; now += 100) {
    if (now % STEP === 0) floor.apply({ ...next, now });
    const figures = all(floor, now);
    if (figures.length === before) {
      gone = now;
      break;
    }
    last = figures[0];
  }
  expect(gone).toBeGreaterThan(0);
  expect(last!.room).toBe(walker.room);
  expect(Math.hypot(last!.x - door.x, last!.z - door.z)).toBeLessThan(0.2);
  expect(last!.opacity).toBeLessThan(0.5);
});

test("floor: walk-outs come from arrivals minus admitted, not from left", () => {
  const floor = createDinerFloor();
  floor.apply(input({ today: { arrivals: 10, admitted: 8, left: 2 } }));
  floor.apply(
    input({ now: STEP, today: { arrivals: 10, admitted: 8, left: 7 } }),
  );
  expect(floor.tally.walkOut).toBe(0);
  expect(floor.count(STEP)).toBe(0);
  floor.apply(
    input({ now: 2 * STEP, today: { arrivals: 13, admitted: 9, left: 7 } }),
  );
  expect(floor.tally.walkOut).toBe(2);
});

/** The activities one figure passes through, sampled every 100 ms. */
function trace(
  floor: Floor,
  base: FloorInput,
  from: number,
  to: number,
  pick: (figures: FloorFigure[]) => FloorFigure | undefined,
) {
  const phases: { activity: string; carrying: boolean; at: number }[] = [];
  const seats: FloorFigure[] = [];
  for (let now = from; now <= to; now += 100) {
    if ((now - from) % STEP === 0) floor.apply({ ...base, now });
    const f = pick(all(floor, now));
    const activity = f ? f.activity : "gone";
    const carrying = f ? f.carrying : false;
    const prev = phases[phases.length - 1];
    if (!prev || prev.activity !== activity || prev.carrying !== carrying)
      phases.push({ activity, carrying, at: now });
    if (f?.activity === "seated") seats.push(f);
  }
  return { phases, seats };
}

test("floor: a served diner collects, sits for EAT_MS, then leaves", () => {
  const floor = createDinerFloor();
  floor.apply(input({ waiting: { s04: 1 } }));
  const served = input({ now: STEP, served: { s04: "t1" } });
  const { phases, seats } = trace(
    floor,
    served,
    STEP,
    STEP + EAT_MS + 60_000,
    (figures) => figures[0],
  );
  expect(phases[0]).toMatchObject({ activity: "collecting", carrying: false });
  expect(phases.map((p) => `${p.activity}:${p.carrying}`)).toEqual([
    "collecting:false",
    "collecting:true",
    "walking:true",
    "seated:false",
    "walking:false",
    "gone:false",
  ]);
  const sat = phases.find((p) => p.activity === "seated")!;
  const left = phases[phases.indexOf(sat) + 1]!;
  expect(Math.abs(left.at - sat.at - EAT_MS)).toBeLessThanOrEqual(100);
  const seat = seats[0]!.seat!;
  expect(seat).toBeTruthy();
  expect(
    seatSpots(1).some(
      (s) => Math.abs(s.x - seat.x) < 0.01 && Math.abs(s.z - seat.z) < 0.01,
    ),
  ).toBe(true);
  expect(seats.every((f) => f.x === seat.x && f.z === seat.z)).toBe(true);
  expect(floor.boundFor("s04")).toBe(0);
});

test("floor: with every seat taken the served diner leaves carrying", () => {
  const floor = createDinerFloor();
  const waiting = (n: number) => Object.fromEntries(IDS.map((id) => [id, n]));
  floor.apply(input({ waiting: waiting(3) }));
  const serve = (n: number) =>
    Object.fromEntries(IDS.map((id) => [id, String(n)]));
  // 15 served, then 15, then 3: 33 inside one EAT_MS.
  const s1 = input({ now: STEP, waiting: waiting(2), served: serve(1) });
  const s2 = input({ now: 2 * STEP, waiting: waiting(1), served: serve(2) });
  const third = Object.fromEntries(IDS.map((id, i) => [id, i < 3 ? "3" : "2"]));
  const w3 = Object.fromEntries(IDS.map((id, i) => [id, i < 3 ? 0 : 1]));
  const s3 = input({ now: 3 * STEP, waiting: w3, served: third });
  floor.apply(s1);
  floor.apply(s2);
  floor.apply(s3);
  let most = 0;
  for (let now = 3 * STEP; now <= 40_000; now += 100) {
    if (now % STEP === 0) floor.apply({ ...s3, now });
    const seated = all(floor, now).filter((f) => f.activity === "seated");
    most = Math.max(most, seated.length);
  }
  expect(most).toBe(32);
  const at = all(floor, 40_000);
  expect(at.filter((f) => f.activity === "seated")).toHaveLength(32);
  expect(at.filter((f) => f.activity === "queued")).toHaveLength(12);
  expect(at).toHaveLength(44); // the 33rd left carrying and is gone
});

test("floor: a dessert order is staged from a seated diner", () => {
  const floor = createDinerFloor();
  const today = { arrivals: 10, admitted: 10, left: 0 };
  floor.apply(input({ waiting: { s01: 1 }, today }));
  const served = input({ now: STEP, served: { s01: "a" }, today });
  hold(floor, served, STEP, 30 * STEP);
  const now = 30 * STEP;
  expect(all(floor, now).filter((f) => f.activity === "seated")).toHaveLength(
    1,
  );
  const before = floor.count(now);
  const tally = { ...floor.tally };
  floor.apply({
    ...served,
    now: now + STEP,
    stalls: served.stalls.map((s) =>
      s.id === "s06" ? { ...s, waiting: 1 } : s,
    ),
  });
  expect(floor.tally.fromSeat).toBe(1);
  expect(floor.tally.toQueue).toBe(tally.toQueue);
  expect(floor.count(now + STEP)).toBe(before);
  expect(floor.boundFor("s06")).toBe(1);
  expect(
    all(floor, now + STEP).filter((f) => f.activity === "seated"),
  ).toHaveLength(0);
});

test("floor: a long gap starts again from the counts", () => {
  const floor = createDinerFloor();
  floor.apply(input({ waiting: { s01: 1 } }));
  const waiting = Object.fromEntries(
    IDS.map((id) => [id, (id === "s01" ? 1 : 0) + 5]),
  );
  const now = STALE_MS + 1;
  floor.apply(
    input({ now, waiting, today: { arrivals: 400, admitted: 0, left: 0 } }),
  );
  const figures = all(floor, now);
  expect(figures).toHaveLength(6 + 14 * 5);
  expect(figures.every((f) => f.activity === "queued")).toBe(true);
  expect(floor.moving(now)).toBe(false);
  expect(floor.tally).toEqual({
    toQueue: 0,
    walkOut: 0,
    fromSeat: 0,
    thinned: 0,
  });
});

test("floor: midnight stages no walk-outs", () => {
  const floor = createDinerFloor();
  floor.apply(input({ today: { arrivals: 100, admitted: 80, left: 70 } }));
  floor.apply(
    input({ now: STEP, today: { arrivals: 0, admitted: 0, left: 0 } }),
  );
  expect(floor.tally.walkOut).toBe(0);
  expect(floor.count(STEP)).toBe(0);
  floor.apply(
    input({ now: 2 * STEP, today: { arrivals: 2, admitted: 1, left: 0 } }),
  );
  expect(floor.tally.walkOut).toBe(1);
});

test("floor: a server without totals stages queues only, four deep", () => {
  const floor = createDinerFloor();
  floor.apply(input({ today: undefined, queueLimit: undefined }));
  const next = input({
    now: STEP,
    waiting: { s01: 6 },
    today: undefined,
    queueLimit: undefined,
  });
  hold(floor, next, STEP, 60_000);
  expect(floor.tally).toEqual({
    toQueue: 4,
    walkOut: 0,
    fromSeat: 0,
    thinned: 0,
  });
  expect(floor.boundFor("s01")).toBe(4);
  const figures = all(floor, 60_000);
  expect(figures).toHaveLength(4);
  expect(figures.every((f) => f.activity === "queued")).toBe(true);
});

test("floor: served before reaching the queue", () => {
  const floor = createDinerFloor();
  floor.apply(input());
  floor.apply(
    input({
      now: STEP,
      waiting: { s01: 1 },
      today: { arrivals: 1, admitted: 1, left: 0 },
    }),
  );
  expect(floor.boundFor("s01")).toBe(1);
  const [walker] = all(floor, STEP);
  expect(walker!.activity).toBe("walking");
  const served = input({
    now: STEP + 400,
    served: { s01: "x" },
    today: { arrivals: 1, admitted: 1, left: 0 },
  });
  floor.apply(served);
  expect(floor.boundFor("s01")).toBe(0);
  let collected = false;
  for (let now = STEP + 400; now <= STEP + 60_000; now += 100) {
    if ((now - STEP - 400) % STEP === 0) floor.apply({ ...served, now });
    const figures = all(floor, now);
    expect(figures.length).toBeLessThanOrEqual(1);
    if (figures[0]) expect(figures[0].look).toEqual(walker!.look);
    if (figures[0]?.activity === "collecting") collected = true;
    expect(floor.boundFor("s01")).toBe(0);
  }
  expect(collected).toBe(true);
});

test("floor: a stall that goes away takes its figures with it", () => {
  const floor = createDinerFloor();
  const base = input({ waiting: { s03: 3, s05: 2 } });
  floor.apply(base);
  floor.apply({
    ...base,
    now: STEP,
    stalls: base.stalls.filter((s) => s.id !== "s03"),
  });
  expect(floor.count(STEP)).toBe(2);
  expect(floor.boundFor("s03")).toBe(0);
  expect(floor.boundFor("s05")).toBe(2);
  // Moved to another position: removed at once, then placed standing again.
  const moved = base.stalls.map((s) =>
    s.id === "s05" ? { ...s, position: 3 } : s,
  );
  floor.apply({ ...base, now: 2 * STEP, stalls: moved });
  expect(floor.tally.toQueue).toBe(0);
  expect(floor.boundFor("s05")).toBeLessThanOrEqual(2);
});

test("floor: a closed room's figures are removed", () => {
  const floor = createDinerFloor();
  const stalls = [1, 2].flatMap((room) =>
    IDS.map((_, position) => {
      const id = ID((room - 1) * 15 + position + 1);
      return {
        id,
        room,
        position,
        waiting: id === "s01" ? 2 : id === "s16" ? 3 : 0,
        lastService: null,
      };
    }),
  );
  floor.apply(input({ stalls, openRooms: 2 }));
  expect(floor.count(0)).toBe(5);
  floor.apply(input({ stalls, openRooms: 1, now: STEP }));
  expect(floor.count(STEP)).toBe(2);
  expect(floor.boundFor("s16")).toBe(0);
  expect(floor.boundFor("s01")).toBe(2);
  expect(all(floor, STEP).every((f) => f.room === 1)).toBe(true);
});

test("floor: the cleaning window clears the floor", () => {
  const floor = createDinerFloor();
  floor.apply(input({ waiting: { s01: 2, s08: 3, s12: 1 } }));
  // A diner sits down, others walk in and walk out.
  const busy = input({
    now: STEP,
    waiting: { s01: 1, s08: 3, s12: 1 },
    served: { s01: "a" },
    today: { arrivals: 3, admitted: 0, left: 0 },
  });
  hold(floor, busy, STEP, 40 * STEP);
  const rising = input({
    now: 41 * STEP,
    waiting: { s01: 2, s08: 5, s12: 2, s14: 3 },
    served: { s01: "a" },
    today: { arrivals: 13, admitted: 7, left: 0 },
  });
  floor.apply(rising);
  const now = 41 * STEP;
  const figures = all(floor, now);
  expect(figures.some((f) => f.activity === "seated")).toBe(true);
  expect(figures.some((f) => f.activity === "walking")).toBe(true);
  expect(figures.some((f) => f.activity === "queued")).toBe(true);
  const closed = { ...rising, now: now + STEP, serving: false };
  floor.apply(closed);
  expect(floor.count(now + STEP)).toBeGreaterThan(0);
  expect(floor.count(now + STEP + CLEAR_MS)).toBe(0);
  const tally = { ...floor.tally };
  for (let n = 2; n < 20; n++) {
    const t = now + n * STEP;
    floor.apply({
      ...closed,
      now: t,
      stalls: closed.stalls.map((s) => ({ ...s, waiting: s.waiting + n })),
      today: { arrivals: 13 + n, admitted: 7, left: 0 },
    });
    if (t >= now + STEP + CLEAR_MS) expect(floor.count(t)).toBe(0);
  }
  expect(floor.tally).toEqual(tally);
});

test("floor: reduced motion and reduced detail", () => {
  const floor = createDinerFloor();
  const today = { arrivals: 0, admitted: 0, left: 0 };
  const still = { animate: false, today };
  floor.apply(input({ ...still, waiting: { s01: 2, s02: 1 } }));
  const steps = [
    input({
      ...still,
      now: STEP,
      waiting: { s01: 2, s02: 1, s03: 1 },
      today: { arrivals: 4, admitted: 1, left: 0 },
    }),
    input({
      ...still,
      now: 2 * STEP,
      waiting: { s01: 1, s02: 0, s03: 1 },
      served: { s01: "a" },
      today: { arrivals: 4, admitted: 1, left: 0 },
    }),
  ];
  floor.apply(steps[0]!);
  expect(floor.count(STEP)).toBe(4);
  expect(floor.tally.walkOut).toBe(0);
  floor.apply(steps[1]!);
  const now = 2 * STEP;
  // s01: one served and seated, one still queued; s02's diner is gone.
  const figures = all(floor, now);
  expect(figures.filter((f) => f.activity === "seated")).toHaveLength(1);
  expect(figures.filter((f) => f.activity === "queued")).toHaveLength(2);
  expect(floor.count(now)).toBe(3);
  for (let t = now; t <= now + EAT_MS + 2_000; t += 100) {
    if ((t - now) % STEP === 0) floor.apply({ ...steps[1]!, now: t });
    expect(floor.moving(t)).toBe(false);
    for (const f of all(floor, t)) {
      expect(f.activity).not.toBe("walking");
      expect(f.activity).not.toBe("collecting");
    }
    expect(floor.count(t)).toBe(t < now + EAT_MS ? 3 : 2);
  }

  const plain = createDinerFloor();
  const flat = { browse: false, today };
  plain.apply(input({ ...flat, waiting: { s01: 1 } }));
  plain.apply(
    input({
      ...flat,
      now: STEP,
      waiting: { s01: 1, s05: 1 },
      today: { arrivals: 4, admitted: 1, left: 0 },
    }),
  );
  expect(plain.tally).toMatchObject({ walkOut: 0, toQueue: 1 });
  expect(all(plain, STEP).every((f) => f.activity === "queued")).toBe(true);
  plain.apply(
    input({
      ...flat,
      now: 2 * STEP,
      waiting: { s01: 0, s05: 1 },
      served: { s01: "b" },
      today: { arrivals: 4, admitted: 1, left: 0 },
    }),
  );
  const servedNow = all(plain, 2 * STEP);
  expect(servedNow.filter((f) => f.activity === "collecting")).toHaveLength(1);
  expect(servedNow.filter((f) => f.activity === "queued")).toHaveLength(1);
});

test("floor: animate turning off places walkers at their destination", () => {
  const floor = createDinerFloor();
  floor.apply(input());
  const moving = input({
    now: STEP,
    waiting: { s02: 2 },
    today: { arrivals: 5, admitted: 2, left: 0 },
  });
  floor.apply(moving);
  expect(floor.moving(STEP)).toBe(true);
  floor.apply({ ...moving, now: 2 * STEP, animate: false });
  const figures = all(floor, 2 * STEP);
  expect(figures).toHaveLength(2);
  expect(figures.every((f) => f.activity === "queued")).toBe(true);
  expect(floor.moving(2 * STEP)).toBe(false);
});

test("floor: the budget thins walk-outs, never queues", () => {
  const floor = createDinerFloor();
  const waiting = { s01: 3, s09: 6 };
  floor.apply(input({ waiting }));
  const surge = input({
    now: STEP,
    waiting,
    today: { arrivals: 500, admitted: 0, left: 0 },
  });
  floor.apply(surge);
  expect(floor.tally.thinned + floor.tally.walkOut).toBe(500);
  expect(floor.tally.walkOut).toBe(ROOM_BUDGET);
  for (let now = STEP; now <= 60_000; now += 100) {
    if ((now - STEP) % STEP === 0) floor.apply({ ...surge, now });
    expect(walkingOrSeated(all(floor, now), 1)).toBeLessThanOrEqual(
      ROOM_BUDGET,
    );
    expect(floor.boundFor("s01")).toBe(3);
    expect(floor.boundFor("s09")).toBe(6);
  }
  expect(
    all(floor, 60_000).filter((f) => f.activity === "queued"),
  ).toHaveLength(9);
});

/** A deterministic busy run: rises, services, walk-outs and desserts. */
function scripted(until: number): FloorInput[] {
  let seed = 12345;
  const random = (n: number) => {
    seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
    return (seed >>> 8) % n;
  };
  let current = input({ today: { arrivals: 0, admitted: 0, left: 0 } });
  const out = [current];
  for (let now = STEP; now <= until; now += STEP) {
    let rises = 0;
    const stalls = current.stalls.map((s, i) => {
      const waiting = Math.min(8, Math.max(0, s.waiting + random(5) - 2));
      rises += Math.max(0, Math.min(waiting, 6) - Math.min(s.waiting, 6));
      const served = random(4) === 0 && s.waiting > 0;
      return {
        ...s,
        waiting,
        lastService: served ? `${now}:${i}` : s.lastService,
      };
    });
    const today = current.today!;
    const admitted = Math.max(0, rises - random(2));
    current = {
      ...current,
      now,
      stalls,
      today: {
        admitted: today.admitted + admitted,
        arrivals: today.arrivals + admitted + random(3),
        left: today.left + random(2),
      },
    };
    out.push(current);
  }
  return out;
}

test("floor: looks are stable", () => {
  const a = createDinerFloor(),
    b = createDinerFloor();
  const run = scripted(30_000);
  for (const step of run) {
    a.apply(step);
    b.apply(step);
    for (const t of [step.now, step.now + 400]) {
      const la = all(a, t).map((f) => f.look);
      const lb = all(b, t).map((f) => f.look);
      expect(la).toEqual(lb);
    }
  }
  expect(a.tally.toQueue + a.tally.walkOut).toBeGreaterThan(20);
});

test("floor: figures walk on the floor", () => {
  const floor = createDinerFloor();
  const run = scripted(120_000);
  const placements = IDS.map((_, p) => spotPlacement(1, p));
  let index = 0,
    checked = 0;
  const activities = new Set<string>();
  const blocked: string[] = [];
  for (let now = 0; now <= 120_000; now += 100) {
    while (index < run.length && run[index]!.now <= now)
      floor.apply(run[index++]!);
    floor.figures(now, (f) => {
      activities.add(f.activity);
      if (roomAt(f.x, f.z) !== f.room) return;
      checked++;
      if (placements.some((p) => stallBlocks(p, f.x, f.z)))
        blocked.push(
          `${f.activity} at ${f.x.toFixed(2)},${f.z.toFixed(2)} t=${now}`,
        );
    });
  }
  expect(blocked).toEqual([]);
  expect(checked).toBeGreaterThan(10_000);
  expect([...activities].sort()).toEqual([
    "collecting",
    "queued",
    "seated",
    "walking",
  ]);
  expect(floor.tally.fromSeat).toBeGreaterThan(0);
});
