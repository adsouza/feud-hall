/*
 * The floor model: turns the change in the server's counts between two
 * snapshots into diner figures, and owns each one from the entrance to the
 * exit. Every figure stands for a diner the server committed: the model may
 * delay, route, simplify and thin, but it never adds a figure without a count
 * change that accounts for it. Each figure is a look plus a list of timed
 * legs, so where it is at any moment is a pure function of the time and the
 * inputs applied so far.
 */
import {
  PICKUP_SPOT,
  QUEUE_DRAW_MAX,
  collectMs,
  collectTray,
  queueSpot,
  toHall,
  toStall,
} from "./hall-layout";
import { personLook, serialFor, type Look } from "./people";
import {
  entrance,
  roomAt,
  routeAt,
  routeLength,
  routeWithin,
  seatSpots,
  spotPlacement,
  type Point,
  type Seat,
  type SpotPlacement,
} from "./room-layout";

export const EAT_MS = 60_000;
/** A gap between snapshots longer than this starts again from the counts. */
export const STALE_MS = 10_000;
/** Once service stops, the floor is empty this long afterwards. */
export const CLEAR_MS = 8_000;
/** The most figures the model keeps walking or seated in one room. */
export const ROOM_BUDGET = 96;

export type FloorStall = {
  id: string;
  room: number;
  position: number;
  waiting: number;
  lastService: string | null;
};
export type FloorInput = {
  now: number;
  serving: boolean; // hall.access === "open"
  today?: { arrivals: number; admitted: number; left: number };
  queueLimit?: number; // absent: 4
  openRooms: number;
  stalls: FloorStall[];
  animate: boolean; // motion on
  browse: boolean; // detail on
  /**
   * The identity of the server view the counts came from (the hall's committed
   * position). An apply with the same snapshot as the last one changes no
   * figure because of counts and does not count as a fresh snapshot for the
   * gap; absent, every apply is treated as a new snapshot.
   */
  snapshot?: number | string;
};
export type FloorActivity = "walking" | "queued" | "collecting" | "seated";
export type FloorFigure = {
  look: Look;
  room: number;
  x: number;
  z: number;
  yaw: number;
  faceYaw: number;
  stride: number;
  activity: FloorActivity;
  carrying: boolean; // tray in hands
  /**
   * Present for the whole collect, from the call to the counter until the tray
   * is in the hands: 0 while the tray is still on the counter (including the
   * walk to the pickup spot), rising to 1 as it passes into the hands; else
   * absent.
   */
  take?: number;
  /**
   * The stall whose counter the tray comes from, while `take` is present; the
   * stall whose queue the figure stands in, while queued.
   */
  stall?: string;
  /** Present while queued: the queue spot (0-based) the figure stands at. */
  spot?: number;
  /** Present while seated: where the tray rests on the table. */
  seat?: Seat;
  opacity: number;
};
export type FloorTally = {
  toQueue: number; // figures created for a rise in a stall's waiting count
  walkOut: number; // figures created for an arrival that was not admitted
  fromSeat: number; // waiting rises staged by a seated diner going back (dessert)
  thinned: number; // figures the budget declined to create
};

/** Diner walking speed, metres per millisecond (1.6 m/s). */
const SPEED = 0.0016;
/** Steps per metre, as the scene's leaving walk. */
const GAIT = (Math.PI * 8) / Math.hypot(1.18, 1.4);
/** Figures fade over this distance from the street point outside the entrance. */
const FADE = 0.5;
/** How far in front of a counter a browsing figure passes it. */
const PASS_DEPTH = 4.6;
/** A seated figure stands up to this far behind its seat, away from the table. */
const BEHIND = 1;

type Walk = {
  kind: "walk";
  start: number;
  end: number;
  route: Point[];
  length: number;
  carrying: boolean;
};
type Stand = {
  kind: "stand";
  start: number;
  end: number;
  x: number;
  z: number;
  yaw: number;
  /** The queue spot this stands at. */
  spot: number;
  /** Where a walk away from this spot starts routing. */
  out: Point;
};
type Collect = {
  kind: "collect";
  start: number;
  end: number;
  frame: SpotPlacement;
  fromX: number;
  fromZ: number;
  stall: string;
};
type Sit = { kind: "sit"; start: number; end: number; seat: Seat };
type Leg = Walk | Stand | Collect | Sit;

type Figure = {
  look: Look;
  serial: number;
  room: number;
  legs: Leg[];
  /** When the last leg ends; -Infinity once removed. */
  end: number;
  /** While bound for a queue: the stall and the spot. */
  stall: string | null;
  spot: number;
  /** The reserved seat, until `seatUntil`. */
  seat: Seat | null;
  seatUntil: number;
};
type StallState = {
  room: number;
  position: number;
  placement: SpotPlacement;
  /** The raw waiting count at the last snapshot. */
  waiting: number;
  lastService: string | null;
  /** Figures bound for the queue, by spot; the last is the one served. */
  queue: Figure[];
};
type Seating = { seats: Seat[]; holder: (Figure | null)[] };

/*
 * Routes between fixed points (entrance, queue spots, pass points, seats,
 * pickup spots, aisle points) are cached for every floor: routeWithin costs
 * about half a millisecond and one snapshot can start dozens of walks.
 */
const routes = new Map<string, Point[]>();
const ROUTE_CACHE_MAX = 50_000;
function cachedRoute(room: number, from: Point, to: Point): Point[] {
  const key = `${room}:${from.x.toFixed(3)},${from.z.toFixed(3)}>${to.x.toFixed(3)},${to.z.toFixed(3)}`;
  let route = routes.get(key);
  if (!route) {
    if (routes.size >= ROUTE_CACHE_MAX) routes.clear();
    route = routeWithin(room, from, to);
    routes.set(key, route);
  }
  return route;
}

/** Joins polylines, dropping repeated points where they meet. */
function join(...parts: Point[][]): Point[] {
  const out: Point[] = [];
  for (const part of parts)
    for (const p of part) {
      const last = out[out.length - 1];
      if (!last || Math.hypot(last.x - p.x, last.z - p.z) > 1e-9) out.push(p);
    }
  return out;
}

function walk(
  route: Point[],
  start: number,
  carrying: boolean,
  speed = SPEED,
): Walk {
  const length = routeLength(route);
  return {
    kind: "walk",
    start,
    end: start + length / speed,
    route,
    length,
    carrying,
  };
}

function walkedMetres(leg: Walk, now: number) {
  const span = leg.end - leg.start;
  if (span <= 0) return leg.length;
  return Math.min(Math.max((now - leg.start) / span, 0), 1) * leg.length;
}

function legAt(figure: Figure, now: number): Leg | null {
  for (const leg of figure.legs) if (now < leg.end) return leg;
  return null;
}

/** Where a figure stands up: a little behind its seat, clear of its table. */
function behind(seat: Seat): Point {
  const dx = seat.x - seat.tableX,
    dz = seat.z - seat.tableZ;
  const d = Math.hypot(dx, dz) || 1;
  return { x: seat.x + (dx / d) * BEHIND, z: seat.z + (dz / d) * BEHIND };
}

/*
 * routeWithin does not check a route's first and last metre, so a route that
 * started at a queue spot or the pickup spot could clip the corner of the
 * booth beside it. Routes join those spots by way of a point a step further
 * out from the counter, as they join seats by way of a point behind the seat.
 */
const STEP_OUT = 1.1;
const spotAt = (placement: SpotPlacement, n: number) =>
  toHall(placement, ...queueSpot(n));
const spotOut = (placement: SpotPlacement, n: number) => {
  const [x, z] = queueSpot(n);
  return toHall(placement, x, z + STEP_OUT);
};
const pickupAt = (placement: SpotPlacement) =>
  toHall(placement, ...PICKUP_SPOT);
const pickupOut = (placement: SpotPlacement) =>
  toHall(placement, PICKUP_SPOT[0], PICKUP_SPOT[1] + STEP_OUT);
const passAt = (placement: SpotPlacement) => toHall(placement, 0, PASS_DEPTH);

/** Close enough in front of the counter to collect straight from here. */
function inFront(local: Point) {
  return Math.abs(local.x) <= 2 && local.z >= 1.5 && local.z <= 4.6;
}

function standAt(placement: SpotPlacement, n: number, start: number): Stand {
  const [dx, dz] = queueSpot(n);
  const at = toHall(placement, dx, dz);
  return {
    kind: "stand",
    start,
    end: Infinity,
    x: at.x,
    z: at.z,
    yaw: placement.yaw + Math.atan2(-dx, -dz),
    spot: n,
    out: spotOut(placement, n),
  };
}

const streets: Point[] = [];
/** The street point outside a room's entrance, where figures fade. */
function streetOf(room: number): Point {
  return (streets[room] ??= entrance(room).outside);
}

/** Writes the figure's pose during `leg` at `now` into `out`. */
function place(figure: Figure, leg: Leg, now: number, out: FloorFigure) {
  out.look = figure.look;
  out.room = figure.room;
  out.faceYaw = 0;
  out.stride = 0;
  out.carrying = false;
  out.take = undefined;
  out.stall = undefined;
  out.spot = undefined;
  out.seat = undefined;
  if (leg.kind === "walk") {
    const metres = walkedMetres(leg, now);
    const at = routeAt(leg.route, metres);
    out.x = at.x;
    out.z = at.z;
    out.yaw = at.yaw;
    out.stride = Math.sin(metres * GAIT);
    out.activity = "walking";
    out.carrying = leg.carrying;
  } else if (leg.kind === "collect") {
    const step = collectTray(leg.fromX, leg.fromZ, now - leg.start);
    const at = toHall(leg.frame, step.x, step.z);
    out.x = at.x;
    out.z = at.z;
    out.yaw = leg.frame.yaw + step.yaw;
    out.stride = step.walking ? Math.sin(step.metres * GAIT) : 0;
    out.activity = "collecting";
    out.carrying = step.take > 0;
    out.take = step.take;
    out.stall = leg.stall;
  } else if (leg.kind === "stand") {
    out.x = leg.x;
    out.z = leg.z;
    out.yaw = leg.yaw;
    out.activity = "queued";
    out.stall = figure.stall ?? undefined;
    out.spot = leg.spot;
  } else {
    out.x = leg.seat.x;
    out.z = leg.seat.z;
    out.yaw = leg.seat.yaw;
    out.activity = "seated";
    out.seat = leg.seat;
  }
  const street = streetOf(figure.room);
  out.opacity = Math.min(
    1,
    Math.hypot(out.x - street.x, out.z - street.z) / FADE,
  );
}

function emptyPose(): FloorFigure {
  return {
    look: personLook(0, "diner"),
    room: 1,
    x: 0,
    z: 0,
    yaw: 0,
    faceYaw: 0,
    stride: 0,
    activity: "queued",
    carrying: false,
    opacity: 1,
  };
}

export function createDinerFloor(): {
  apply(input: FloorInput): void;
  /** Calls `visit` once per figure present at `now`; allocates no arrays. */
  figures(now: number, visit: (figure: FloorFigure) => void): void;
  /** How many figures are present at `now`. */
  count(now: number): number;
  /** True while any figure is walking or collecting at `now`. */
  moving(now: number): boolean;
  /** How many figures stand in or are bound for a stall's queue. */
  boundFor(stallId: string): number;
  readonly tally: FloorTally;
  clear(): void;
} {
  const tally: FloorTally = { toQueue: 0, walkOut: 0, fromSeat: 0, thinned: 0 };
  let figures: Figure[] = [];
  const stalls = new Map<string, StallState>();
  const seating = new Map<number, Seating>();
  let last: {
    /** When the last new snapshot was applied: the gap is measured from it. */
    now: number;
    serving: boolean;
    animate: boolean;
    today?: FloorInput["today"];
    snapshot?: number | string;
  } | null = null;
  let created = 0;
  const visited = emptyPose();
  const scratch = emptyPose();

  function seatsOf(room: number): Seating {
    let s = seating.get(room);
    if (!s) {
      const seats = seatSpots(room);
      s = { seats, holder: seats.map(() => null) };
      seating.set(room, s);
    }
    return s;
  }
  function releaseSeat(figure: Figure) {
    if (!figure.seat) return;
    const s = seatsOf(figure.room);
    if (s.holder[figure.seat.index] === figure)
      s.holder[figure.seat.index] = null;
    figure.seat = null;
    figure.seatUntil = 0;
  }
  /** Reserves a free seat in the figure's room, chosen from its serial. */
  function takeSeat(figure: Figure, now: number): Seat | null {
    const s = seatsOf(figure.room);
    const n = s.seats.length;
    for (let k = 0; k < n; k++) {
      const i = (figure.serial + k) % n;
      const holder = s.holder[i];
      if (holder && holder.seatUntil > now && holder.end > now) continue;
      s.holder[i] = figure;
      figure.seat = s.seats[i]!;
      return figure.seat;
    }
    return null;
  }
  function plan(figure: Figure, legs: Leg[]) {
    figure.legs = legs;
    figure.end = legs.length ? legs[legs.length - 1]!.end : -Infinity;
  }
  function remove(figure: Figure) {
    releaseSeat(figure);
    figure.stall = null;
    plan(figure, []);
  }
  function newFigure(room: number): Figure {
    const serial = serialFor("diner:" + created++);
    const figure: Figure = {
      look: personLook(serial, "diner"),
      serial,
      room,
      legs: [],
      end: -Infinity,
      stall: null,
      spot: 0,
      seat: null,
      seatUntil: 0,
    };
    figures.push(figure);
    return figure;
  }

  /**
   * The way from where a figure is to a fixed point it can route on from:
   * `lead` runs from its position to `anchor`, along a clear line.
   */
  function from(figure: Figure, now: number) {
    const leg = legAt(figure, now)!;
    place(figure, leg, now, scratch);
    const here = { x: scratch.x, z: scratch.z };
    const carrying = scratch.carrying;
    const inside = entrance(figure.room).inside;
    if (leg.kind === "stand")
      return { lead: [here, leg.out], anchor: leg.out, carrying };
    if (leg.kind === "sit") {
      const up = behind(leg.seat);
      return { lead: [here, up], anchor: up, carrying };
    }
    if (leg.kind === "collect") {
      const out = pickupOut(leg.frame);
      return { lead: [here, pickupAt(leg.frame), out], anchor: out, carrying };
    }
    if (roomAt(here.x, here.z) !== figure.room)
      return { lead: [here, inside], anchor: inside, carrying, outside: true };
    // Carry on to the next point of the current route, then route from there.
    const metres = walkedMetres(leg, now);
    const { route } = leg;
    let along = 0,
      i = 1;
    for (; i < route.length - 1; i++) {
      along += Math.hypot(
        route[i]!.x - route[i - 1]!.x,
        route[i]!.z - route[i - 1]!.z,
      );
      if (along > metres) break;
    }
    // A route's last point is a spot or a seat, joined by way of the point
    // before it: turn back to that point rather than route from the spot.
    let next = route[Math.min(i, route.length - 1)]!;
    if (i >= route.length - 1 && route.length > 1)
      next = route[route.length - 2]!;
    // Already on the way out: the rest of the current route.
    const street = streetOf(figure.room);
    const end = route[route.length - 1]!;
    const rest =
      end.x === street.x && end.z === street.z
        ? [here, ...route.slice(i)]
        : null;
    if (roomAt(next.x, next.z) !== figure.room) next = inside;
    return { lead: [here, next], anchor: next, carrying, rest };
  }
  function exitRoute(figure: Figure, now: number) {
    const way = from(figure, now);
    const { inside, outside } = entrance(figure.room);
    const route = way.outside
      ? [way.lead[0]!, outside]
      : "rest" in way && way.rest
        ? way.rest
        : join(way.lead, cachedRoute(figure.room, way.anchor, inside), [
            outside,
          ]);
    return { route, carrying: way.carrying };
  }

  /** Rule 6 and the end of every visit: to the entrance and out. */
  function leave(figure: Figure, now: number, animate: boolean) {
    figure.stall = null;
    releaseSeat(figure);
    if (!animate) return remove(figure);
    const { route } = exitRoute(figure, now);
    plan(figure, [walk(route, now, false)]);
  }

  /** Rule 5: the figure at the highest spot collects, eats, and leaves. */
  function serve(
    figure: Figure,
    state: StallState,
    id: string,
    now: number,
    input: FloorInput,
  ) {
    figure.stall = null;
    const legs: Leg[] = [];
    if (!input.animate) {
      const seat = takeSeat(figure, now);
      if (!seat) return remove(figure);
      figure.seatUntil = now + EAT_MS;
      return plan(figure, [
        { kind: "sit", start: now, end: now + EAT_MS, seat },
      ]);
    }
    const { placement, room } = state;
    let t = now,
      fromX: number,
      fromZ: number;
    const leg = legAt(figure, now)!;
    if (leg.kind === "stand") [fromX, fromZ] = queueSpot(figure.spot);
    else {
      place(figure, leg, now, scratch);
      const local = toStall(placement, scratch.x, scratch.z);
      if (roomAt(scratch.x, scratch.z) === room && inFront(local)) {
        fromX = local.x;
        fromZ = local.z;
      } else {
        // Still on the way in: carry on to the queue spot, then collect.
        const way = from(figure, now);
        const route = join(
          way.lead,
          cachedRoute(room, way.anchor, spotOut(placement, figure.spot)),
          [spotAt(placement, figure.spot)],
        );
        const approach = walk(route, t, false);
        legs.push(approach);
        t = approach.end;
        [fromX, fromZ] = queueSpot(figure.spot);
      }
    }
    const collect: Collect = {
      kind: "collect",
      start: t,
      end: t + collectMs(fromX, fromZ),
      frame: placement,
      fromX,
      fromZ,
      stall: id,
    };
    legs.push(collect);
    t = collect.end;
    const pickup = [pickupAt(placement), pickupOut(placement)];
    const seat = takeSeat(figure, now);
    if (seat && input.browse) {
      const up = behind(seat);
      const toSeat = walk(
        join(pickup, cachedRoute(room, pickup[1]!, up), [seat]),
        t,
        true,
      );
      const sit: Sit = {
        kind: "sit",
        start: toSeat.end,
        end: toSeat.end + EAT_MS,
        seat,
      };
      const { inside, outside } = entrance(room);
      const out = walk(
        join([seat, up], cachedRoute(room, up, inside), [outside]),
        sit.end,
        false,
      );
      legs.push(toSeat, sit, out);
      figure.seatUntil = sit.end;
    } else if (seat) {
      legs.push({ kind: "sit", start: t, end: t + EAT_MS, seat });
      figure.seatUntil = t + EAT_MS;
    } else {
      const { inside, outside } = entrance(room);
      legs.push(
        walk(
          join(pickup, cachedRoute(room, pickup[1]!, inside), [outside]),
          t,
          true,
        ),
      );
    }
    plan(figure, legs);
  }

  /** One or two pass points in a room, chosen from a serial. */
  function passes(room: number, serial: number, skip: string | null): Point[] {
    const others: SpotPlacement[] = [];
    for (const [id, s] of stalls)
      if (s.room === room && id !== skip) others.push(s.placement);
    if (others.length === 0) {
      const { inside } = entrance(room);
      return [{ x: inside.x, z: inside.z - 6 }];
    }
    const first = (serial >>> 7) % others.length;
    const out = [passAt(others[first]!)];
    if ((serial >>> 5) & 1 && others.length > 1) {
      const second =
        (first + 1 + ((serial >>> 13) % (others.length - 1))) % others.length;
      out.push(passAt(others[second]!));
    }
    return out;
  }
  function browseRoute(room: number, points: Point[]): Point[] {
    const parts: Point[][] = [];
    for (let i = 1; i < points.length; i++)
      parts.push(cachedRoute(room, points[i - 1]!, points[i]!));
    return join(...parts);
  }

  /** Rule 3, with rule 8: a new figure bound for the next spot of a queue. */
  function enqueue(
    state: StallState,
    id: string,
    now: number,
    input: FloorInput,
    load: Map<number, number>,
  ) {
    const figure = newFigure(state.room);
    figure.stall = id;
    figure.spot = state.queue.length;
    state.queue.push(figure);
    const stand = standAt(state.placement, figure.spot, now);
    if (!input.animate || !input.browse) return plan(figure, [stand]);
    const walking = load.get(state.room) ?? 0;
    if (walking + 1 > ROOM_BUDGET) {
      tally.thinned++;
      return plan(figure, [stand]);
    }
    load.set(state.room, walking + 1);
    const { inside, outside } = entrance(state.room);
    const route = join(
      [outside],
      browseRoute(state.room, [
        inside,
        ...passes(state.room, figure.serial, id),
        stand.out,
      ]),
      [{ x: stand.x, z: stand.z }],
    );
    const arrive = walk(route, now, false);
    stand.start = arrive.end;
    plan(figure, [arrive, stand]);
  }

  /** Rule 4: a seated figure in the room goes back to the queue. */
  function requeue(
    state: StallState,
    id: string,
    now: number,
    input: FloorInput,
  ): boolean {
    const figure = figures.find(
      (f) => f.room === state.room && legAt(f, now)?.kind === "sit",
    );
    if (!figure) return false;
    const seat = (legAt(figure, now) as Sit).seat;
    releaseSeat(figure);
    figure.stall = id;
    figure.spot = state.queue.length;
    state.queue.push(figure);
    const stand = standAt(state.placement, figure.spot, now);
    if (!input.animate || !input.browse) {
      plan(figure, [stand]);
      return true;
    }
    const up = behind(seat);
    const back = walk(
      join([seat, up], cachedRoute(state.room, up, stand.out), [
        { x: stand.x, z: stand.z },
      ]),
      now,
      false,
    );
    stand.start = back.end;
    plan(figure, [back, stand]);
    return true;
  }

  /** Rule 7: walks in by an open room's entrance, passes stalls, walks out. */
  function walkOut(now: number, input: FloorInput, load: Map<number, number>) {
    const serial = serialFor("diner:" + created);
    const room = 1 + (serial % input.openRooms);
    const walking = load.get(room) ?? 0;
    if (walking + 1 > ROOM_BUDGET) {
      created++;
      tally.thinned++;
      return;
    }
    load.set(room, walking + 1);
    const figure = newFigure(room);
    const { inside, outside } = entrance(room);
    const route = join(
      [outside],
      browseRoute(room, [inside, ...passes(room, serial, null), inside]),
      [outside],
    );
    plan(figure, [walk(route, now, false)]);
    tally.walkOut++;
  }

  /** Rule 1 for one stall: its queue stands at its spots, with no walk. */
  function settleQueue(
    state: StallState,
    id: string,
    target: number,
    now: number,
  ) {
    while (state.queue.length > target) remove(state.queue.pop()!);
    state.queue.forEach((f, n) => plan(f, [standAt(state.placement, n, now)]));
    while (state.queue.length < target) standing(state, id, now);
  }

  /** A figure standing at the next spot of a queue at once, with no walk. */
  function standing(state: StallState, id: string, now: number) {
    const figure = newFigure(state.room);
    figure.stall = id;
    figure.spot = state.queue.length;
    state.queue.push(figure);
    plan(figure, [standAt(state.placement, figure.spot, now)]);
  }

  function addState(stall: FloorStall): StallState {
    const state: StallState = {
      room: stall.room,
      position: stall.position,
      placement: spotPlacement(stall.room, stall.position),
      waiting: 0,
      lastService: stall.lastService,
      queue: [],
    };
    stalls.set(stall.id, state);
    return state;
  }

  /** Rule 10: stalls that went away or moved, and rooms that closed. */
  function removeGone(input: FloorInput, now: number) {
    const present = new Map(input.stalls.map((s) => [s.id, s]));
    for (const [id, state] of stalls) {
      const stall = present.get(id);
      if (
        stall &&
        stall.room === state.room &&
        stall.position === state.position &&
        stall.room <= input.openRooms
      )
        continue;
      for (const f of state.queue) remove(f);
      // Served diners still to collect there, whether collecting now or still
      // on the way: their tray would come from a counter that is gone.
      for (const f of figures)
        if (
          f.legs.some(
            (leg) => leg.kind === "collect" && leg.stall === id && leg.end > now,
          )
        )
          remove(f);
      stalls.delete(id);
    }
    for (const f of figures) if (f.room > input.openRooms) remove(f);
  }

  /** Rule 9: everyone walks out, arriving outside within CLEAR_MS. */
  function clearFloor(now: number, animate: boolean) {
    for (const state of stalls.values()) {
      state.queue.length = 0;
      state.waiting = 0;
    }
    for (const figure of figures) {
      if (figure.end <= now) continue;
      figure.stall = null;
      if (!animate) {
        remove(figure);
        continue;
      }
      const { route, carrying } = exitRoute(figure, now);
      releaseSeat(figure);
      const length = routeLength(route);
      if (length < 1e-6) remove(figure);
      else
        plan(figure, [
          walk(route, now, carrying, Math.max(SPEED, length / CLEAR_MS)),
        ]);
    }
  }

  /** Rule 11: motion turned off; walkers are placed or removed. */
  function stopMotion(now: number) {
    for (const state of stalls.values())
      state.queue.forEach((f, n) =>
        plan(f, [standAt(state.placement, n, now)]),
      );
    for (const figure of figures) {
      if (figure.stall !== null || figure.end <= now) continue;
      if (figure.seat && figure.seatUntil > now)
        plan(figure, [
          { kind: "sit", start: now, end: figure.seatUntil, seat: figure.seat },
        ]);
      else remove(figure);
    }
  }

  function walkingLoad(now: number) {
    const load = new Map<number, number>();
    for (const f of figures) {
      const kind = legAt(f, now)?.kind;
      if (kind === "walk" || kind === "sit")
        load.set(f.room, (load.get(f.room) ?? 0) + 1);
    }
    return load;
  }

  function apply(input: FloorInput) {
    const now = input.now;
    figures = figures.filter((f) => {
      if (f.end > now) return true;
      releaseSeat(f);
      return false;
    });
    if (
      last !== null &&
      input.snapshot !== undefined &&
      input.snapshot === last.snapshot &&
      input.serving === last.serving
    ) {
      // The same server view again (the scene re-applies it on selection,
      // tablet and label changes): no figure is created, removed or re-planned
      // because of counts, and the gap timer keeps the time of the snapshot's
      // first apply. Stalls that went away and a change of motion still apply.
      removeGone(input, now);
      if (!input.animate && last.animate) stopMotion(now);
      last.animate = input.animate;
      figures = figures.filter((f) => f.end > now);
      return;
    }
    const cap = Math.min(input.queueLimit ?? 4, QUEUE_DRAW_MAX);
    const fresh =
      last === null ||
      now - last.now > STALE_MS ||
      (input.serving && !last.serving);
    removeGone(input, now);
    const open = input.stalls.filter((s) => s.room <= input.openRooms);

    if (!input.serving) {
      if (last === null || last.serving) clearFloor(now, input.animate);
      for (const s of open)
        (stalls.get(s.id) ?? addState(s)).lastService = s.lastService;
    } else if (fresh) {
      if (!input.animate) stopMotion(now);
      for (const s of open) {
        const state = stalls.get(s.id) ?? addState(s);
        settleQueue(state, s.id, Math.min(s.waiting, cap), now);
        state.waiting = s.waiting;
        state.lastService = s.lastService;
      }
    } else {
      if (!input.animate && last!.animate) stopMotion(now);
      step(input, open, cap, now);
    }
    last = {
      now,
      serving: input.serving,
      animate: input.animate,
      today: input.today && { ...input.today },
      snapshot: input.snapshot,
    };
    figures = figures.filter((f) => f.end > now);
  }

  function step(
    input: FloorInput,
    open: FloorStall[],
    cap: number,
    now: number,
  ) {
    const before = last!.today,
      today = input.today;
    const totals =
      before &&
      today &&
      today.arrivals >= before.arrivals &&
      today.admitted >= before.admitted &&
      today.left >= before.left
        ? { before, today }
        : null;
    // Each stall's change, from the raw waiting counts: a service takes one
    // diner off the old count; the rest of the change is joiners or falls.
    const changes = new Map<
      string,
      { served: boolean; afterService: number; joined: number }
    >();
    let risen = 0;
    for (const s of open) {
      const state = stalls.get(s.id);
      if (!state) {
        // A stall new to the floor starts standing, like a first snapshot.
        const added = addState(s);
        settleQueue(added, s.id, Math.min(s.waiting, cap), now);
        added.waiting = s.waiting;
        continue;
      }
      const served =
        s.lastService !== null &&
        s.lastService !== state.lastService &&
        state.queue.length > 0;
      const afterService = served
        ? Math.max(0, state.waiting - 1)
        : state.waiting;
      const joined = Math.max(
        0,
        Math.min(s.waiting, cap) - Math.min(afterService, cap),
      );
      changes.set(s.id, { served, afterService, joined });
      risen += joined;
    }
    // Rule 4: joiners beyond the new admissions are desserts, in stall-ID order.
    let desserts = totals
      ? Math.max(0, risen - (totals.today.admitted - totals.before.admitted))
      : 0;
    const dessertsAt = new Map<string, number>();
    for (const id of [...changes.keys()].sort()) {
      const d = Math.min(desserts, changes.get(id)!.joined);
      dessertsAt.set(id, d);
      desserts -= d;
    }
    // Rule 5, then the tail advance, then rule 6.
    for (const s of open) {
      const change = changes.get(s.id);
      if (!change) continue;
      const state = stalls.get(s.id)!;
      if (change.served) serve(state.queue.pop()!, state, s.id, now, input);
      // Diners already waiting beyond the drawn queue (or newly drawable under
      // a raised limit) move up into view: standing at their spots, untallied.
      while (state.queue.length < Math.min(change.afterService, cap))
        standing(state, s.id, now);
      while (state.queue.length > Math.min(s.waiting, cap))
        leave(state.queue.pop()!, now, input.animate);
    }
    // Rules 3, 4 and 8: the joiners.
    const load = walkingLoad(now);
    for (const s of open) {
      const change = changes.get(s.id);
      if (!change) continue;
      const state = stalls.get(s.id)!;
      const dessert = dessertsAt.get(s.id)!;
      for (let i = 0; i < change.joined; i++) {
        if (i < dessert && requeue(state, s.id, now, input)) {
          tally.fromSeat++;
          continue;
        }
        tally.toQueue++;
        enqueue(state, s.id, now, input, load);
      }
      state.waiting = s.waiting;
      state.lastService = s.lastService;
    }
    // Rules 2 and 7.
    if (totals && input.browse && input.animate && input.openRooms >= 1) {
      const { before: a, today: b } = totals;
      const w = Math.max(
        0,
        b.arrivals - b.admitted - (a.arrivals - a.admitted),
      );
      for (let n = 0; n < w; n++) walkOut(now, input, load);
    }
  }

  return {
    apply,
    /** Calls `visit` once per figure present at `now`; allocates no arrays. */
    figures(now: number, visit: (figure: FloorFigure) => void) {
      for (const figure of figures) {
        const leg = legAt(figure, now);
        if (!leg) continue;
        place(figure, leg, now, visited);
        visit(visited);
      }
    },
    /** How many figures are present at `now`. */
    count(now: number) {
      let n = 0;
      for (const figure of figures) if (figure.end > now) n++;
      return n;
    },
    /** True while any figure is walking or collecting at `now`. */
    moving(now: number) {
      for (const figure of figures) {
        const kind = legAt(figure, now)?.kind;
        if (kind === "walk" || kind === "collect") return true;
      }
      return false;
    },
    /** How many figures stand in or are bound for a stall's queue. */
    boundFor(stallId: string) {
      return stalls.get(stallId)?.queue.length ?? 0;
    },
    tally,
    clear() {
      figures = [];
      stalls.clear();
      seating.clear();
      last = null;
      tally.toQueue = tally.walkOut = tally.fromSeat = tally.thinned = 0;
    },
  };
}
