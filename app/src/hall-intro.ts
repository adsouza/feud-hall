// The hall opening intro: a made-up room 1 built from the live hall's own
// parts and driven entirely by `introFrame`. It is decorative only: blank
// signs and shutters, no names, prices, counts or server data.
import * as T from "three";
import {
  INTRO_BEATS,
  INTRO_STOOLS_SET_MS,
  introFrame,
  type IntroFrame,
} from "./hall-intro-timeline";
import {
  createIntroFacade,
  lightboxTexture,
  signTint,
} from "./hall-intro-facade";
import { STAFF_SPOTS, queueSpot, toHall, toStall } from "./hall-layout";
import { createHallLights } from "./hall-lights";
import { createFurniture, createHallShell } from "./hall-shell";
import {
  SEAT_HEIGHT,
  personLook,
  stoolPushReach,
  type Detail,
  type Look,
  type Pose,
} from "./people";
import { createFaceTexture, createPeople } from "./people-mesh";
import {
  ROOM_SIDE,
  entrance,
  roomCentre,
  roomAt,
  routeAt,
  routeLength,
  routeWithin,
  seatSpots,
  spotPlacement,
  tableSpots,
  type Point,
  type SpotPlacement,
  SEAT_OFFSETS,
} from "./room-layout";
import { createStallKit, stallAccent, type StallParts } from "./stall-model";

const ROOM = 1;
/** Stall i stands at spot i. The IDs pick colours and canopies; no text. */
const CUISINES = [
  "persian",
  "japanese",
  "maori",
  "tamil",
  "cantonese",
  "ethiopian",
  "levantine",
  "sichuan",
  "peruvian",
];
const FRAME_MS = 32;
const PIXEL_RATIO_MAX = 1.65;
/** The shell hides its ceilings for a viewpoint this high. */
const ABOVE_CEILING = 10;
/** The shell keeps every wall up for a viewpoint inside the room. */
const INSIDE = ROOM_SIDE / 2 - 0.5;
/** Figures nearer the camera than this are drawn in full. */
const DETAIL_DISTANCE = 28;
/** How far out from its seat, away from the table, a stool starts. */
const STOOL_PULLED = 1.1;
/** The hands contact the near half of the stool's top. */
const STOOL_GRIP_INSET = 0.13;
/** The start and end of each push are spent bending down and straightening up. */
const STOOL_BEND_SHARE = 0.15;
/** A mover's share of the stools beat: push one stool, walk, push the next. */
const FIRST_PUSH_END = 0.35;
const SECOND_PUSH_START = 0.65;
/** Movers fade in over this long at the start of the stools beat. */
const MOVER_FADE_MS = 600;
/** With the stools set, the movers walk off from here. */
const STAFF_LEAVE_MS = INTRO_BEATS.stools + INTRO_STOOLS_SET_MS;
/** ...and every one has gone round the back of a stall by here. */
const STAFF_GONE_MS = INTRO_BEATS.hold - 500;
/** The movers' slowest pace off the floor, in metres per millisecond. */
const STAFF_WALK = 0.002;
/**
 * The way round the back of a stall, in stall-local coordinates: beside a
 * side wall, from in front of the counter to just behind the back wall.
 */
const ROUND_SIDE = 1.95;
const ROUND_FRONT = 1.7;
const ROUND_BACK = -1;
/** How far the way round keeps from the room's walls. */
const ROUND_WALL_CLEAR = 0.3;
/** How far it keeps from a neighbouring booth's side wall, and its depth. */
const BOOTH_HALF_WIDTH = 1.58;
const ROUND_BOOTH_CLEAR = 0.3;
const BOOTH_DEPTH = { back: -1.3, front: 1.5 };
/** At most this many movers take the same way round. */
const ROUND_SHARE = 2;
/** A mover fades out over the last of the way, behind the stall. */
const EXIT_FADE_METRES = 0.9;
const QUEUE_DEPTH = 4;
/** One diner comes in through the entrance this often. */
const ARRIVAL_MS = 1400;
/**
 * Diners start coming in while the stools are set out, so the first are
 * already crossing the floor when the camera rises to the overview.
 */
export const DINERS_START_MS = INTRO_BEATS.stools + 2000;
/** Metres per millisecond, as the live floor walks diners. */
const WALK_SPEED = 0.0016;
/** Stride phase per metre walked, as the live floor. */
const GAIT = (Math.PI * 2) / 1.2;
/** A diner fades in over this distance from the street point. */
const FADE_METRES = 0.5;
/** Each diner's queue is reached from this far in front of the counter. */
const APPROACH = 3.6;

type Exit = { route: Point[]; length: number; speed: number };

type Diner = {
  look: Look;
  route: Point[];
  length: number;
  arrive: number;
  restYaw: number;
};

export function createHallIntro(
  host: HTMLElement,
  onFail: () => void,
): { skip(): void; dispose(): void } | null {
  let renderer: T.WebGLRenderer;
  try {
    renderer = new T.WebGLRenderer({
      antialias: true,
      alpha: false,
      powerPreference: "low-power",
    });
  } catch {
    return null;
  }
  renderer.setClearColor("#111526");
  renderer.outputColorSpace = T.SRGBColorSpace;
  const canvas = renderer.domElement;
  canvas.setAttribute("aria-hidden", "true");
  canvas.style.display = "block";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  host.appendChild(canvas);

  const scene = new T.Scene();
  scene.fog = new T.FogExp2("#111526", 0.009);
  const camera = new T.PerspectiveCamera(42, 1, 0.25, 175);
  const lights = createHallLights(scene);
  const shell = createHallShell(scene, () => {}, { seats: false });
  shell.show([{ room: ROOM, detail: "full" }], 1);

  // The stalls: real spot positions, blank signs, unlabelled shutters.
  const box = new T.BoxGeometry();
  const kit = createStallKit(box);
  kit.paintShutters("");
  const placements = CUISINES.map((_, i) => spotPlacement(ROOM, i));
  const stalls: StallParts[] = CUISINES.map((cuisine, i) => {
    const parts = kit.build({ cuisine }, placements[i]!);
    parts.sign.material.map = lightboxTexture(stallAccent(cuisine));
    parts.sign.material.needsUpdate = true;
    scene.add(parts.root);
    return parts;
  });
  const facade = createIntroFacade(scene, roomCentre(ROOM));

  // Stools the staff slide into place; the shell draws the tables.
  const furniture = createFurniture();
  const seats = seatSpots(ROOM).map((seat) => {
    const dx = seat.x - seat.tableX;
    const dz = seat.z - seat.tableZ;
    const length = Math.hypot(dx, dz) || 1;
    const out = { x: dx / length, z: dz / length };
    return {
      seat: { x: seat.x, z: seat.z },
      start: {
        x: seat.x + out.x * STOOL_PULLED,
        z: seat.z + out.z * STOOL_PULLED,
      },
      out,
    };
  });
  const stools = new T.InstancedMesh(
    furniture.seatGeometry,
    furniture.seat,
    seats.length,
  );
  stools.frustumCulled = false;
  scene.add(stools);
  // Two movers per table, each taking neighbouring seats (SEAT_OFFSETS order).
  const seatsPerTable = SEAT_OFFSETS.length;
  const movers = tableSpots(ROOM).flatMap((_, t) => [
    {
      look: personLook(1100 + 2 * t, "worker"),
      pair: [seatsPerTable * t, seatsPerTable * t + 2],
    },
    {
      look: personLook(1101 + 2 * t, "worker"),
      pair: [seatsPerTable * t + 1, seatsPerTable * t + 3],
    },
  ]);
  const cooks = CUISINES.map((_, i) => personLook(1000 + i, "worker"));

  // Diners for the hold: through the entrance to a queue spot, four a stall.
  const door = entrance(ROOM);
  const diners: Diner[] = Array.from(
    { length: CUISINES.length * QUEUE_DEPTH },
    (_, n) => {
      // 4 shares no factor with the 9 stalls: each round visits every stall.
      const placement = placements[(n * 4) % CUISINES.length]!;
      const [qx, qz] = queueSpot(Math.floor(n / CUISINES.length));
      const spot = toHall(placement, qx, qz);
      const approach = toHall(placement, qx, APPROACH);
      const route = [
        door.outside,
        ...routeWithin(ROOM, door.inside, approach),
        spot,
      ];
      return {
        look: personLook(2000 + n, "diner"),
        route,
        length: routeLength(route),
        arrive: n * ARRIVAL_MS,
        restYaw: placement.yaw + Math.atan2(-qx, -qz),
      };
    },
  );

  const faces = createFaceTexture();
  // Movers fade in together; a few diners fade in at the entrance.
  const people = createPeople(
    cooks.length + movers.length + diners.length,
    faces,
    movers.length + 8,
  );
  scene.add(...people.meshes);
  const figure: Pose = {
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
  function addFigure(look: Look, opacity = 1) {
    const near =
      (camera.position.x - figure.x) ** 2 +
        (camera.position.z - figure.z) ** 2 +
        camera.position.y ** 2 <
      DETAIL_DISTANCE ** 2;
    const detail: Detail = near ? "full" : "simple";
    people.add(look, figure, detail, opacity);
  }
  function pose(
    x: number,
    z: number,
    yaw: number,
    metres = 0,
    walking = false,
  ) {
    figure.x = x;
    figure.z = z;
    figure.yaw = yaw;
    figure.faceYaw = 0;
    figure.stride = walking ? Math.sin(metres * GAIT) : 0;
    figure.walking = walking;
    figure.stoolPush = 0;
  }

  const stoolAt = (i: number, u: number): Point => {
    const { start, seat } = seats[i]!;
    return {
      x: T.MathUtils.lerp(start.x, seat.x, u),
      z: T.MathUtils.lerp(start.z, seat.z, u),
    };
  };
  /** Behind a stool, facing the table it is pushed towards. */
  const behind = (i: number, u: number, look: Look, stride = 0) => {
    const at = stoolAt(i, u);
    const { out } = seats[i]!;
    const distance = stoolPushReach(look, stride) + STOOL_GRIP_INSET;
    return {
      x: at.x + out.x * distance,
      z: at.z + out.z * distance,
      yaw: Math.atan2(-out.x, -out.z),
    };
  };
  const exits = staffExits(
    movers.map(({ pair, look }) => behind(pair[1]!, 1, look)),
    placements,
  );
  const firstPhase = (p: number) => p / FIRST_PUSH_END;
  const secondPhase = (p: number) =>
    (p - SECOND_PUSH_START) / (1 - SECOND_PUSH_START);
  const slide = (phase: number) =>
    T.MathUtils.smoothstep(phase, STOOL_BEND_SHARE, 1 - STOOL_BEND_SHARE);

  const placeTransform = new T.Object3D();
  let placedStools = -1;
  function placeStools(progress: number) {
    if (progress === placedStools) return;
    placedStools = progress;
    movers.forEach(({ pair: [a, b] }) => {
      for (const [i, u] of [
        [a!, slide(firstPhase(progress))],
        [b!, slide(secondPhase(progress))],
      ] as const) {
        const at = stoolAt(i, u);
        placeTransform.position.set(at.x, SEAT_HEIGHT / 2, at.z);
        placeTransform.updateMatrix();
        stools.setMatrixAt(i, placeTransform.matrix);
      }
    });
    stools.instanceMatrix.needsUpdate = true;
  }

  /** Behind the stool, facing the table, pushing it in; or walking between. */
  function poseMover(pair: number[], look: Look, p: number) {
    const [a, b] = [pair[0]!, pair[1]!];
    if (p < FIRST_PUSH_END || p >= SECOND_PUSH_START) {
      const i = p < FIRST_PUSH_END ? a : b;
      const phase = p < FIRST_PUSH_END ? firstPhase(p) : secondPhase(p);
      const u = slide(phase);
      const stride = Math.sin(u * 2 * Math.PI);
      const at = behind(i, u, look, stride);
      const moving = u > 0 && u < 1;
      pose(at.x, at.z, at.yaw);
      figure.walking = moving;
      figure.stride = stride;
      figure.stoolPush = Math.min(
        T.MathUtils.smoothstep(phase, 0, STOOL_BEND_SHARE),
        1 - T.MathUtils.smoothstep(phase, 1 - STOOL_BEND_SHARE, 1),
      );
      return;
    }
    const from = behind(a, 1, look);
    const to = behind(b, 0, look);
    const w = (p - FIRST_PUSH_END) / (SECOND_PUSH_START - FIRST_PUSH_END);
    const dx = to.x - from.x;
    const dz = to.z - from.z;
    pose(
      from.x + dx * w,
      from.z + dz * w,
      Math.atan2(dx, dz),
      Math.hypot(dx, dz) * w,
      true,
    );
  }

  /**
   * Draws everyone, with the movers only while the stools beat runs on from
   * `ms` (not after a skip). Returns how many movers are on the floor and how
   * many diners are inside the room.
   */
  function drawPeople(
    frame: IntroFrame,
    ms: number | null,
    dinersMs: number,
  ): { staff: number; inside: number } {
    let staff = 0;
    let inside = 0;
    people.begin();
    placements.forEach((placement, i) => {
      const [dx, dz] = STAFF_SPOTS[0]!;
      const at = toHall(placement, dx, dz);
      pose(at.x, at.z, placement.yaw);
      addFigure(cooks[i]!);
    });
    // Movers stay out of the walk from the door and fade in for their beat,
    // then walk round the back of a stall and fade out behind it.
    if (ms !== null && ms >= INTRO_BEATS.stools)
      movers.forEach((mover, i) => {
        if (ms < STAFF_LEAVE_MS) {
          poseMover(mover.pair, mover.look, frame.stoolProgress);
          const fade = (ms - INTRO_BEATS.stools) / MOVER_FADE_MS;
          addFigure(mover.look, Math.min(1, fade));
          staff += 1;
          return;
        }
        const exit = exits[i]!;
        const metres = (ms - STAFF_LEAVE_MS) * exit.speed;
        if (metres >= exit.length) return;
        const at = routeAt(exit.route, metres);
        pose(at.x, at.z, at.yaw, metres, true);
        addFigure(mover.look, (exit.length - metres) / EXIT_FADE_METRES);
        staff += 1;
      });
    for (const diner of diners) {
      const since = dinersMs - diner.arrive;
      if (since < 0) break;
      const metres = since * WALK_SPEED;
      const walking = metres < diner.length;
      const at = routeAt(diner.route, metres);
      pose(at.x, at.z, walking ? at.yaw : diner.restYaw, metres, walking);
      addFigure(diner.look, Math.min(1, metres / FADE_METRES));
      if (roomAt(at.x, at.z) === ROOM) inside += 1;
    }
    people.end();
    return { staff, inside };
  }

  const centre = roomCentre(ROOM);
  const viewpoint = new T.Vector3();
  /**
   * What the shell sees: always inside the room, so every wall stays up even
   * from the street, and above the ceiling until the lights come on. The
   * street shot sees the ceiling only through the doorway, so it comes on
   * there with the lightbox rather than as a change across the frame. Higher
   * than the ceiling, the shell hides it itself, so the rise sees the room.
   */
  function shellViewpoint(frame: IntroFrame) {
    const [x, y, z] = frame.camera;
    return viewpoint.set(
      T.MathUtils.clamp(x, centre.x - INSIDE, centre.x + INSIDE),
      frame.sign ? y : ABOVE_CEILING,
      T.MathUtils.clamp(z, centre.z - INSIDE, centre.z + INSIDE),
    );
  }

  let disposed = false;
  let failed = false;
  /** When the first frame finished drawing; intro time counts from here. */
  let origin: number | null = null;
  let hiddenAt: number | null = null;
  let pausedMs = 0;
  let skippedAt: number | undefined;
  let running = false;
  let frameRequest = 0;
  let lastFrame = -Infinity;
  let signOn: boolean | null = null;
  host.dataset.introBeat = "outside";

  function elapsed(now: number) {
    if (origin === null) return 0;
    return Math.max(0, (hiddenAt ?? now) - origin - pausedMs);
  }

  function fail() {
    if (failed || disposed) return;
    failed = true;
    stop();
    onFail();
  }

  /** Any throw while drawing ends the intro once; the loop stops with it. */
  function draw(now: number) {
    if (disposed || failed) return;
    try {
      drawFrame(now);
    } catch {
      fail();
      return;
    }
    origin ??= performance.now();
  }

  function drawFrame(now: number) {
    const ms = elapsed(now);
    const frame = introFrame(ms, stalls.length, skippedAt);
    if (host.dataset.introBeat !== frame.beat)
      host.dataset.introBeat = frame.beat;
    camera.position.set(...frame.camera);
    camera.lookAt(...frame.target);
    lights.setLevel(frame.light);
    shell.update(shellViewpoint(frame));
    stalls.forEach((parts, i) =>
      kit.applyShutter(parts, frame.shutterLevels[i] ?? 0),
    );
    if (frame.sign !== signOn) {
      signOn = frame.sign;
      for (const { sign } of stalls)
        sign.material.color.copy(signTint(frame.sign));
    }
    facade.update(ms, frame.light, frame.sign, skippedAt !== undefined);
    placeStools(frame.stoolProgress);
    // A skip goes straight to the hold: the stools are set, the staff gone,
    // and diners start coming in from then.
    const { staff, inside } = drawPeople(
      frame,
      skippedAt === undefined ? ms : null,
      ms - (skippedAt === undefined ? DINERS_START_MS : skippedAt),
    );
    if (host.dataset.introStaff !== String(staff))
      host.dataset.introStaff = String(staff);
    if (host.dataset.introDinersInside !== String(inside))
      host.dataset.introDinersInside = String(inside);
    renderer.render(scene, camera);
  }

  function animate(now: number) {
    if (!running) return;
    frameRequest = requestAnimationFrame(animate);
    if (now - lastFrame < FRAME_MS) return;
    lastFrame = now;
    draw(now);
  }
  function start() {
    if (running || disposed || failed || document.hidden) return;
    running = true;
    frameRequest = requestAnimationFrame(animate);
  }
  function stop() {
    running = false;
    cancelAnimationFrame(frameRequest);
  }

  function visibility() {
    if (document.hidden) {
      stop();
      if (origin !== null && hiddenAt === null) hiddenAt = performance.now();
      return;
    }
    if (hiddenAt !== null) {
      pausedMs += performance.now() - hiddenAt;
      hiddenAt = null;
    }
    start();
  }

  function lost() {
    fail();
  }

  const resize = new ResizeObserver(() => {
    if (!host.clientWidth || !host.clientHeight) return;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, PIXEL_RATIO_MAX));
    renderer.setSize(host.clientWidth, host.clientHeight, false);
    camera.aspect = host.clientWidth / host.clientHeight;
    camera.updateProjectionMatrix();
  });
  resize.observe(host);
  canvas.addEventListener("webglcontextlost", lost);
  document.addEventListener("visibilitychange", visibility);
  start();

  return {
    skip() {
      if (disposed || failed || skippedAt !== undefined) return;
      const now = performance.now();
      const ms = elapsed(now);
      if (ms >= INTRO_BEATS.hold) return;
      skippedAt = ms;
      host.dataset.introBeat = "hold";
      if (!document.hidden) draw(now);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      stop();
      resize.disconnect();
      document.removeEventListener("visibilitychange", visibility);
      canvas.removeEventListener("webglcontextlost", lost);
      for (const { sign } of stalls) {
        sign.material.map?.dispose();
        sign.material.dispose();
      }
      kit.dispose();
      box.dispose();
      facade.dispose();
      lights.dispose();
      shell.dispose();
      stools.dispose();
      furniture.dispose();
      people.dispose();
      faces?.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      canvas.remove();
      delete host.dataset.introBeat;
      delete host.dataset.introStaff;
      delete host.dataset.introDinersInside;
    },
  };
}

/**
 * Each mover's walk off the floor: to the nearest way round the back of a
 * stall, by route length, shared by at most `ROUND_SHARE` movers. A corner
 * stall, or a side too close to a wall or a neighbouring booth, has no way
 * round. Movers further away walk faster, so all are gone by `STAFF_GONE_MS`.
 */
function staffExits(starts: Point[], placements: SpotPlacement[]): Exit[] {
  const centre = roomCentre(ROOM);
  const inRoom = (p: Point) =>
    Math.abs(p.x - centre.x) < ROOM_SIDE / 2 - ROUND_WALL_CLEAR &&
    Math.abs(p.z - centre.z) < ROOM_SIDE / 2 - ROUND_WALL_CLEAR;
  const clearOf = (p: Point, own: number) =>
    placements.every((other, j) => {
      if (j === own) return true;
      const local = toStall(other, p.x, p.z);
      return !(
        Math.abs(local.x) < BOOTH_HALF_WIDTH + ROUND_BOOTH_CLEAR &&
        local.z > BOOTH_DEPTH.back &&
        local.z < BOOTH_DEPTH.front
      );
    });
  const ways = placements.flatMap((placement, i) =>
    [-1, 1]
      .map((side) => ({
        front: toHall(placement, side * ROUND_SIDE, ROUND_FRONT),
        back: toHall(placement, side * ROUND_SIDE, ROUND_BACK),
      }))
      .filter(({ front, back }) =>
        [front, back].every((p) => inRoom(p) && clearOf(p, i)),
      ),
  );
  if (!ways.length) throw new Error("no way round any intro stall");
  const routes = starts.map((start) =>
    ways.map(({ front, back }) => {
      const route = [...routeWithin(ROOM, start, front), back];
      return { route, length: routeLength(route) };
    }),
  );
  // Shortest remaining walk first, until every mover has a way round.
  const taken = ways.map(() => 0);
  const chosen: (Exit | undefined)[] = starts.map(() => undefined);
  const window = STAFF_GONE_MS - STAFF_LEAVE_MS;
  for (let left = starts.length; left > 0; left--) {
    let m = -1;
    let w = -1;
    for (let i = 0; i < starts.length; i++)
      for (let j = 0; j < ways.length; j++)
        if (
          !chosen[i] &&
          taken[j]! < ROUND_SHARE &&
          (m < 0 || routes[i]![j]!.length < routes[m]![w]!.length)
        ) {
          m = i;
          w = j;
        }
    if (m < 0) throw new Error("too few ways round the intro stalls");
    const { route, length } = routes[m]![w]!;
    taken[w] = taken[w]! + 1;
    chosen[m] = { route, length, speed: Math.max(STAFF_WALK, length / window) };
  }
  return chosen as Exit[];
}
