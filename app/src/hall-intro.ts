// The hall opening intro: a made-up room 1 built from the live hall's own
// parts and driven entirely by `introFrame`. It is decorative only: blank
// signs and shutters, no names, prices, counts or server data.
import * as T from "three";
import {
  INTRO_BEATS,
  introFrame,
  type IntroFrame,
} from "./hall-intro-timeline";
import {
  createIntroFacade,
  lightboxTexture,
  signTint,
} from "./hall-intro-facade";
import { STAFF_SPOTS, queueSpot, toHall } from "./hall-layout";
import { createHallLights } from "./hall-lights";
import { createFurniture, createHallShell } from "./hall-shell";
import { personLook, type Detail, type Look, type Pose } from "./people";
import { createFaceTexture, createPeople } from "./people-mesh";
import {
  ROOM_SIDE,
  entrance,
  roomCentre,
  routeAt,
  routeLength,
  routeWithin,
  seatSpots,
  spotPlacement,
  tableSpots,
  type Point,
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
/** A stool's centre height, as the shell draws its seats. */
const STOOL_Y = 0.23;
/** How far out from its seat, away from the table, a stool starts. */
const STOOL_PULLED = 1.1;
/** Where a mover stands behind the stool they push. */
const BEHIND_STOOL = 0.55;
/** A mover's share of the stools beat: push one stool, walk, push the next. */
const FIRST_PUSH_END = 0.35;
const SECOND_PUSH_START = 0.65;
/** Movers fade in over this long at the start of the stools beat. */
const MOVER_FADE_MS = 600;
const QUEUE_DEPTH = 4;
/** One diner comes in through the entrance this often during the hold. */
const ARRIVAL_MS = 1400;
/** Metres per millisecond, as the live floor walks diners. */
const WALK_SPEED = 0.0016;
/** Stride phase per metre walked, as the live floor. */
const GAIT = (Math.PI * 2) / 1.2;
/** A diner fades in over this distance from the street point. */
const FADE_METRES = 0.5;
/** Each diner's queue is reached from this far in front of the counter. */
const APPROACH = 3.6;

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
  const movers = tableSpots(ROOM).flatMap((_, t) => [
    { look: personLook(1100 + 2 * t, "worker"), pair: [4 * t, 4 * t + 2] },
    { look: personLook(1101 + 2 * t, "worker"), pair: [4 * t + 1, 4 * t + 3] },
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
    carrying = false,
  ) {
    figure.x = x;
    figure.z = z;
    figure.yaw = yaw;
    figure.faceYaw = 0;
    figure.stride = walking ? Math.sin(metres * GAIT) : 0;
    figure.walking = walking;
    figure.carrying = carrying;
    figure.seated = false;
  }

  const stoolAt = (i: number, u: number): Point => {
    const { start, seat } = seats[i]!;
    return {
      x: T.MathUtils.lerp(start.x, seat.x, u),
      z: T.MathUtils.lerp(start.z, seat.z, u),
    };
  };
  const firstPush = (p: number) => T.MathUtils.smoothstep(p, 0, FIRST_PUSH_END);
  const secondPush = (p: number) =>
    T.MathUtils.smoothstep(p, SECOND_PUSH_START, 1);

  const placeTransform = new T.Object3D();
  let placedStools = -1;
  function placeStools(progress: number) {
    if (progress === placedStools) return;
    placedStools = progress;
    movers.forEach(({ pair: [a, b] }) => {
      for (const [i, u] of [
        [a!, firstPush(progress)],
        [b!, secondPush(progress)],
      ] as const) {
        const at = stoolAt(i, u);
        placeTransform.position.set(at.x, STOOL_Y, at.z);
        placeTransform.updateMatrix();
        stools.setMatrixAt(i, placeTransform.matrix);
      }
    });
    stools.instanceMatrix.needsUpdate = true;
  }

  /** Behind the stool, facing the table, pushing it in; or walking between. */
  function poseMover(pair: number[], p: number) {
    const [a, b] = [pair[0]!, pair[1]!];
    const behind = (i: number, u: number) => {
      const at = stoolAt(i, u);
      const { out } = seats[i]!;
      return {
        x: at.x + out.x * BEHIND_STOOL,
        z: at.z + out.z * BEHIND_STOOL,
        yaw: Math.atan2(-out.x, -out.z),
      };
    };
    if (p < FIRST_PUSH_END || p >= SECOND_PUSH_START) {
      const i = p < FIRST_PUSH_END ? a : b;
      const u = p < FIRST_PUSH_END ? firstPush(p) : secondPush(p);
      const at = behind(i, u);
      const moving = u > 0 && u < 1;
      pose(at.x, at.z, at.yaw, u * STOOL_PULLED, moving, moving);
      return;
    }
    const from = behind(a, 1);
    const to = behind(b, 0);
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

  function drawPeople(frame: IntroFrame, moverOpacity: number, holdMs: number) {
    people.begin();
    placements.forEach((placement, i) => {
      const [dx, dz] = STAFF_SPOTS[0]!;
      const at = toHall(placement, dx, dz);
      pose(at.x, at.z, placement.yaw);
      addFigure(cooks[i]!);
    });
    for (const mover of movers) {
      poseMover(mover.pair, frame.stoolProgress);
      addFigure(mover.look, moverOpacity);
    }
    for (const diner of diners) {
      const since = holdMs - diner.arrive;
      if (since < 0) break;
      const metres = since * WALK_SPEED;
      const walking = metres < diner.length;
      const at = routeAt(diner.route, metres);
      pose(at.x, at.z, walking ? at.yaw : diner.restYaw, metres, walking);
      addFigure(diner.look, Math.min(1, metres / FADE_METRES));
    }
    people.end();
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
    // Movers stay out of the walk from the door and fade in for their beat.
    const moverOpacity =
      skippedAt === undefined
        ? T.MathUtils.clamp((ms - INTRO_BEATS.stools) / MOVER_FADE_MS, 0, 1)
        : 1;
    drawPeople(
      frame,
      moverOpacity,
      ms - (skippedAt === undefined ? INTRO_BEATS.hold : skippedAt),
    );
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
    },
  };
}
