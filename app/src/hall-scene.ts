import * as T from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import type { Stall } from "./api";
import { createCuisineArt } from "./cuisine-art";
import { createHallLights } from "./hall-lights";
import { createHallShell } from "./hall-shell";
import { createStallKit, hash, stallAccent } from "./stall-model";
import { createPickupHands } from "./hall-pickup";
import type { PersonalTray } from "./diner-pickup";
import { createTabletScreen } from "./hall-tablet";
import type { TabletView, TabletAction } from "./hall-tablet";
import {
  stallBlocks,
  toHall,
  toStall,
  COUNTER_TRAY,
  QUEUE_DRAW_MAX,
  STAFF_SPOTS,
} from "./hall-layout";
import {
  ROOM_COUNT,
  ROOM_SIDE,
  SPOTS_PER_ROOM,
  assignSpots,
  roomAt,
  roomCentre,
  spotPlacement,
  walkable,
  walkingEntrance,
  type SpotPlacement,
} from "./room-layout";
import {
  carryPoint,
  seatedTrayPoint,
  staffLooks,
  type Detail,
  type Look,
  type Pose,
} from "./people";
import { ROOM_BUDGET, createDinerFloor, type FloorFigure } from "./diner-floor";
import {
  rollTo,
  rolling,
  shutterLevel,
  type ShutterRoll,
} from "./shutter-roll";
import { createFaceTexture, createPeople } from "./people-mesh";

type Point = [number, number, number];
type CameraPose = {
  position: Point;
  target: Point;
  fov?: number;
  walk?: { stall: string };
};
export type CameraState = CameraPose & {
  /** The room the viewer was in. */
  room?: number;
  inside?: { stall: string; hall: CameraPose };
  menu?: { stall: string; hall: CameraPose };
};
export type HallTarget = "menu" | "counter" | "staff" | "supply";
export type Actions = {
  select: (id: string) => void;
  interact: (id: string, target: HallTarget) => void;
  tablet: (id: string, action: TabletAction) => void;
  hover: (id: string | null) => void;
  fail: () => void;
  inside: (id: string) => void;
  walk: (id: string) => void;
  collect: (id: string) => boolean;
  collected: () => void;
  /** The room the viewer is in changed. */
  room: (room: number) => void;
  /** A "to let" bay was selected. */
  vacancy: (stallId: string) => void;
  frame?: (drawMs: number) => void;
};
export type HallVacancy = {
  stall_id: string;
  tier: string;
  /** Absent from halls without the room rule; such a spot gets no bay. */
  room?: number;
  position?: number;
};
export type Appearance = {
  stalls: Stall[];
  ownedStalls: string[];
  selected: string;
  pickup: string;
  pickups: PersonalTray[];
  closedLabel: string;
  cuisineLabel: (id: string) => string;
  reopeningHeading: string;
  reopeningTime: (stall: Stall) => string;
  detail: boolean;
  motion: boolean;
  tablet: TabletView | null;
  tabletLabel: string;
  tabletHint: string;
  /** Absent for halls without the room rule: every room in use is open. */
  rooms?: { count: number; open: number };
  /** Vacant spots of open rooms; drawn as "to let" bays. */
  vacancies?: HallVacancy[];
  toLetLabel: string;
  /** The hall is open to diners (`hall.access === "open"`). */
  serving: boolean;
  /** Today's diner totals; absent from servers that do not send them. */
  today?: { arrivals: number; admitted: number; left: number };
  /** How many may wait at one stall; absent: four are drawn. */
  queueLimit?: number;
  /**
   * The identity of the server view these counts came from (`hall.position`);
   * an update with the same value re-applies no counts to the floor.
   */
  snapshot?: number;
};
type Counter = {
  root: T.Group;
  trim: T.Group;
  hit: T.Mesh;
  edge: T.Mesh;
  shutters: T.Mesh;
  roll?: ShutterRoll;
  sign: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  tablet: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  reopening: T.Group;
  placard: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  reopeningLabel: string;
  plaque: T.Mesh;
  pickup: T.Mesh;
  serviceLamp: T.Mesh;
  index: number; // stable per stall, for animation phase only
  placement: SpotPlacement;
  name: string;
  cuisine: string;
  color: T.Color;
  restaurant: string; // the business the owner look is keyed to
  staff: Look[]; // the owner, then one per staff spot
  /** Drawn in detail in the last frame; a stall drawn simply draws its queue simply. */
  detailed: boolean;
  activity?: Stall["activity"];
  open: boolean;
};

const SMALL_HALL = 4;
const STALL_LIMIT = 150;
const ORBIT_POLAR_LIMIT = 1.46;
/** The room overview: from the south, high enough to frame the whole room. */
const OVERVIEW: Point = [4.8, 29.8, 37.4];
const MAX_DISTANCE = 90;
const HALF_ROOM = ROOM_SIDE / 2;
const ROOM_PITCH = roomCentre(2).x - roomCentre(1).x;
/** Keep the walker's eye this far from walls and booths. */
const WALK_MARGIN = 0.3;
const EYE_HEIGHT = 1.55;
const WALK_LOOK_DISTANCE = 6;
const WALK_SPEED = 3.2;
const TURN_SPEED = 1.8;
const LOOK_SPEED = 1.15;
const ARROW_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);
const IDLE_FRAME_MS = 80;
/** Owners and staff behind every counter. */
const STAFF_LIMIT = STALL_LIMIT * (1 + STAFF_SPOTS.length);
/** Floor figures in the three rooms drawn at once: full queues and the budget. */
const FLOOR_LIMIT = 3 * (SPOTS_PER_ROOM * QUEUE_DRAW_MAX + ROOM_BUDGET);
const vec = (point: Point) => new T.Vector3(...point);
const point = (value: T.Vector3): Point => [value.x, value.y, value.z];

function staffGlance(seconds: number, stallIndex: number, workerIndex: number) {
  const phase = (seconds + stallIndex * 0.61 + workerIndex * 1.37) % 5.2;
  const turn = Math.min(phase / 2.1, 1) * Math.PI;
  return 0.31 * Math.sin(turn * 2) * Math.sin(turn);
}

function pickupTrayGeometry(box: T.BoxGeometry) {
  const dish = new T.CylinderGeometry(1, 0.87, 1, 16);
  const food = new T.SphereGeometry(1, 8, 5);
  const parts: T.BufferGeometry[] = [];
  const tray = "#f3e6cd";
  const rim = "#decca9";

  function part(
    shape: T.BufferGeometry,
    paint: string,
    position: Point,
    size: Point,
  ) {
    const geometry = shape
      .clone()
      .scale(...size)
      .translate(...position);
    const colors = new T.Float32BufferAttribute(
      geometry.attributes.position.count * 3,
      3,
    );
    const color = new T.Color(paint);
    for (let i = 0; i < colors.count; i++)
      colors.setXYZ(i, color.r, color.g, color.b);
    geometry.setAttribute("color", colors);
    parts.push(geometry);
  }

  part(box, tray, [0, 0.02, 0], [0.78, 0.04, 0.4]);
  for (const side of [-1, 1]) {
    part(box, rim, [0, 0.045, side * 0.185], [0.78, 0.035, 0.03]);
    part(box, rim, [side * 0.375, 0.045, 0], [0.03, 0.035, 0.34]);
  }
  part(dish, "#fff6e4", [-0.12, 0.059, 0], [0.155, 0.039, 0.155]);
  part(food, "#f3d69d", [-0.19, 0.092, 0.03], [0.07, 0.05, 0.067]);
  part(food, "#a9512a", [-0.075, 0.097, -0.047], [0.078, 0.047, 0.062]);
  part(food, "#608a38", [-0.065, 0.09, 0.061], [0.063, 0.034, 0.043]);
  part(food, "#d97637", [-0.023, 0.111, 0.066], [0.019, 0.017, 0.02]);
  part(dish, "#fff6e4", [0.21, 0.068, 0.015], [0.081, 0.055, 0.081]);
  part(food, "#c88238", [0.21, 0.096, 0.015], [0.068, 0.018, 0.068]);

  const geometry = mergeGeometries(parts);
  for (const piece of [dish, food, ...parts]) piece.dispose();
  return geometry;
}

export function createHallScene(
  host: HTMLDivElement,
  actions: Actions,
  saved?: CameraState,
) {
  const renderer = new T.WebGLRenderer({
    antialias: true,
    alpha: false,
    powerPreference: "low-power",
  });
  renderer.setClearColor("#111526");
  renderer.outputColorSpace = T.SRGBColorSpace;
  renderer.domElement.setAttribute("aria-hidden", "true");
  host.appendChild(renderer.domElement);

  const scene = new T.Scene();
  const fog = new T.FogExp2("#111526", 0.009);
  scene.fog = fog;
  const camera = new T.PerspectiveCamera(42, 1, 0.25, 175);
  const orbit = new OrbitControls(camera, renderer.domElement);
  orbit.enableDamping = false;
  orbit.screenSpacePanning = true;
  orbit.minDistance = 3.5;
  orbit.maxDistance = MAX_DISTANCE;
  orbit.minPolarAngle = 0.25;
  orbit.maxPolarAngle = ORBIT_POLAR_LIMIT;
  orbit.mouseButtons.LEFT = T.MOUSE.ROTATE;
  orbit.touches.ONE = T.TOUCH.ROTATE;
  let walking: string | null = saved?.walk?.stall ?? null;
  let insideStall = saved?.inside?.stall ?? "";
  let hallView: CameraPose | undefined = saved?.inside?.hall;
  let readingMenu = saved?.menu?.stall ?? "";
  let menuReturn: CameraPose | undefined = saved?.menu?.hall;
  const tabletGeometry = new T.PlaneGeometry(0.62, 0.93);
  const idleTablet = createTabletScreen(() => draw());
  const activeTablet = createTabletScreen(() => draw());
  configureCamera();
  if (saved) {
    camera.position.copy(vec(saved.position));
    camera.fov = saved.fov ?? 42;
    camera.updateProjectionMatrix();
    orbit.target.copy(vec(saved.target));
    const offset = camera.position.clone().sub(orbit.target);
    orbit.maxPolarAngle = insideStall
      ? Math.PI - 0.25
      : Math.max(
          ORBIT_POLAR_LIMIT,
          new T.Spherical().setFromVector3(offset).phi,
        );
    orbit.update();
  }

  const lights = createHallLights(scene);

  const box = new T.BoxGeometry();
  const pickupGeometry = pickupTrayGeometry(box);
  const pickupMaterial = new T.MeshStandardMaterial({
    vertexColors: true,
    roughness: 0.75,
  });
  const pickupHands = createPickupHands(
    scene,
    camera,
    pickupGeometry,
    pickupMaterial,
  );
  const personalMaterial = pickupMaterial.clone();
  personalMaterial.emissive.set("#684724");
  personalMaterial.emissiveIntensity = 0.2;
  const personalPickups = new Map<string, { mesh: T.Mesh; stall: string }>();
  const collectedPickups = new Set<string>();
  const stallKit = createStallKit(box, () => draw());
  const wood = new T.MeshStandardMaterial({
    color: "#826451",
    roughness: 0.75,
  });
  const slate = new T.MeshStandardMaterial({
    color: "#29233b",
    roughness: 0.77,
  });
  const light = new T.MeshBasicMaterial({ color: "#fff7bd" });
  const dark = new T.MeshBasicMaterial({ color: "#4e5570" });
  const highlight = new T.MeshBasicMaterial({ color: "#ffcb67" });
  const plaqueMat = new T.MeshStandardMaterial({
    color: "#ffca69",
    metalness: 0.35,
    roughness: 0.36,
  });
  const hitMat = new T.MeshBasicMaterial({ visible: false });
  const stalls = new Map<string, Counter>();
  // Every diner drawn stands for one the server committed; see diner-floor.ts.
  const floor = createDinerFloor();
  const buildings = new T.Group();
  const cuisineArt = createCuisineArt(buildings, STALL_LIMIT, () => draw());
  const hallShell = createHallShell(scene, () => draw());
  scene.add(buildings);

  function brick(
    parent: T.Object3D,
    material: T.Material,
    x: number,
    y: number,
    z: number,
    w: number,
    h: number,
    d: number,
  ) {
    const mesh = new T.Mesh(box, material);
    mesh.position.set(x, y, z);
    mesh.scale.set(w, h, d);
    parent.add(mesh);
    return mesh;
  }

  const bayMat = new T.MeshStandardMaterial({
    color: "#3a4359",
    roughness: 0.9,
  });
  const toLetMat = new T.MeshBasicMaterial({ color: "#ffffff" });
  const toLetGeometry = new T.PlaneGeometry(1.5, 0.62);
  let toLetLabel = "";

  function paintToLet(label: string, repaint = false) {
    if (!repaint && label === toLetLabel) return;
    toLetLabel = label;
    const canvas = document.createElement("canvas");
    canvas.width = 384;
    canvas.height = 160;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "#fff0cd";
    ctx.fillRect(0, 0, 384, 160);
    ctx.fillStyle = "#b8443c";
    ctx.fillRect(10, 10, 364, 140);
    ctx.fillStyle = "#fff6e3";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const font = '900 64px "Noto Sans JP", system-ui, sans-serif';
    ctx.font = font;
    ctx.fillText(label, 192, 82, 340);
    const map = new T.CanvasTexture(canvas);
    map.colorSpace = T.SRGBColorSpace;
    toLetMat.map?.dispose();
    toLetMat.map = map;
    toLetMat.needsUpdate = true;
    if (!repaint && !document.fonts.check(font, label)) {
      void document.fonts
        .load(font, label)
        .then(() => {
          if (disposed || toLetLabel !== label) return;
          paintToLet(label, true);
          draw();
        })
        .catch(() => {});
    }
  }

  type Bay = { root: T.Group; hit: T.Mesh; placement: SpotPlacement };
  const bays = new Map<string, Bay>();

  /** An empty spot: a marked floor and a "to let" sign facing the room. */
  function createBay(id: string, placement: SpotPlacement): Bay {
    const root = new T.Group();
    root.position.set(placement.x, 0, placement.z);
    root.rotation.y = placement.yaw;
    brick(root, bayMat, 0, -0.02, 0.08, 3.5, 0.03, 2.5);
    for (const side of [-1, 1])
      brick(root, highlight, side * 1.72, -0.005, 0.08, 0.06, 0.012, 2.5);
    brick(root, wood, 0, 0.62, 0.55, 0.08, 1.24, 0.08);
    brick(root, wood, 0, 0.02, 0.55, 0.6, 0.04, 0.4);
    const sign = new T.Mesh(toLetGeometry, toLetMat);
    sign.position.set(0, 1.42, 0.6);
    root.add(sign);
    const hit = brick(root, hitMat, 0, 1.06, 0.07, 3.5, 2.2, 2.25);
    hit.userData.vacancy = id;
    buildings.add(root);
    return { root, hit, placement };
  }

  function discardBay(bay: Bay) {
    buildings.remove(bay.root);
  }

  /** One bay per vacant spot; halls without the room rule have none. */
  function updateBays(next: Appearance) {
    const vacant = new Map<string, { room: number; position: number }>();
    for (const { stall_id, room, position } of next.rooms
      ? (next.vacancies ?? [])
      : [])
      if (room !== undefined && position !== undefined)
        vacant.set(stall_id, { room, position });
    for (const [id, bay] of bays) {
      const vacancy = vacant.get(id);
      if (
        !vacancy ||
        vacancy.room !== bay.placement.room ||
        vacancy.position !== bay.placement.position
      ) {
        discardBay(bay);
        bays.delete(id);
      }
    }
    for (const [id, vacancy] of vacant)
      if (!bays.has(id))
        bays.set(
          id,
          createBay(id, spotPlacement(vacancy.room, vacancy.position)),
        );
  }

  const placardGeometry = new T.PlaneGeometry(0.86, 0.3);

  function paintPlacard(
    counter: Counter,
    stall: Stall,
    heading: string,
    value: string,
    repaint = false,
  ) {
    const text = heading + "\n" + value;
    if (!repaint && text === counter.reopeningLabel) return;
    counter.reopeningLabel = text;

    const canvas = document.createElement("canvas");
    canvas.width = 512;
    canvas.height = 180;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "#403044";
    ctx.fillRect(0, 0, 512, 180);
    ctx.fillStyle = "#fff0cd";
    ctx.fillRect(9, 9, 494, 162);
    ctx.fillStyle = "#282035";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const font = '900 58px "Noto Sans JP", system-ui, sans-serif';
    ctx.font = '900 38px "Noto Sans JP", system-ui, sans-serif';
    ctx.fillText(heading, 256, 57, 456);
    ctx.font = font;
    ctx.fillText(value, 256, 120, 456);

    const map = new T.CanvasTexture(canvas);
    map.colorSpace = T.SRGBColorSpace;
    counter.placard.material.map?.dispose();
    counter.placard.material.map = map;
    counter.placard.material.needsUpdate = true;

    if (!repaint && !document.fonts.check(font, text)) {
      void document.fonts
        .load(font, text)
        .then(() => {
          if (
            disposed ||
            stalls.get(stall.stall_id) !== counter ||
            counter.reopeningLabel !== text
          )
            return;
          paintPlacard(counter, stall, heading, value, true);
          draw();
        })
        .catch(() => {});
    }
  }

  function paintSign(counter: Counter, stall: Stall, repaint = false) {
    const text = stall.name + " · " + stall.stall_id;
    if (!repaint && text === counter.name) return;
    counter.name = text;
    const canvas = document.createElement("canvas");
    canvas.width = 512;
    canvas.height = 80;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "#191828";
    ctx.fillRect(0, 0, 512, 80);
    ctx.fillStyle = "#" + counter.color.getHexString();
    ctx.fillRect(0, 0, 512, 4);
    ctx.fillRect(0, 76, 512, 4);
    ctx.fillStyle = "#fff6e3";
    ctx.font = '400 31px "Noto Sans JP", system-ui, sans-serif';
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, 256, 40, 482);
    const map = new T.CanvasTexture(canvas);
    map.colorSpace = T.SRGBColorSpace;
    counter.sign.material.map?.dispose();
    counter.sign.material.map = map;
    counter.sign.material.needsUpdate = true;
    if (
      !repaint &&
      /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u.test(text)
    ) {
      void document.fonts
        .load('400 31px "Noto Sans JP"', text)
        .then(() => {
          if (stalls.get(stall.stall_id) === counter && counter.name === text) {
            paintSign(counter, stall, true);
            draw();
          }
        })
        .catch(() => {});
    }
  }

  function createCounter(
    stall: Stall,
    index: number,
    placement: SpotPlacement,
  ): Counter {
    const { root, trim, shutters, sign } = stallKit.build(
      { cuisine: stall.cuisine },
      placement,
    );
    const serviceLamp = brick(root, light, -1.23, 1.68, 0.91, 0.15, 0.2, 0.12);
    const edge = brick(root, highlight, 0, 0.032, 1.14, 3.47, 0.065, 0.11);
    const pickup = new T.Mesh(pickupGeometry, pickupMaterial);
    pickup.position.set(0, 0.93, 0.88);
    root.add(pickup);
    const plaque = brick(root, plaqueMat, 1.48, 1.2, 1.05, 0.25, 0.3, 0.05);
    const reopening = new T.Group();
    reopening.position.set(-0.83, 0.93, 0.94);
    reopening.visible = false;
    root.add(reopening);
    brick(reopening, wood, 0, 0.012, 0, 0.9, 0.024, 0.16);
    const placard = new T.Mesh(placardGeometry, new T.MeshBasicMaterial());
    placard.position.y = 0.16;
    placard.rotation.x = -0.16;
    reopening.add(placard);
    brick(root, dark, 1.04, 0.91, 0.96, 0.42, 0.07, 0.3);
    brick(root, slate, 1.04, 1.04, 1.02, 0.08, 0.27, 0.08);
    brick(root, dark, 1.04, 1.43, 1.17, 0.68, 1.0, 0.065);
    const tablet = new T.Mesh(tabletGeometry, idleTablet.material);
    tablet.position.set(1.04, 1.43, 1.207);
    tablet.userData.stall = stall.stall_id;
    root.add(tablet);
    const hit = brick(root, hitMat, 0, 1.06, 0.07, 3.5, 2.2, 2.25);
    hit.userData.stall = stall.stall_id;
    buildings.add(root);
    const result = {
      root,
      trim,
      hit,
      edge,
      shutters,
      sign,
      tablet,
      reopening,
      placard,
      reopeningLabel: "",
      plaque,
      pickup,
      serviceLamp,
      index,
      placement,
      name: "",
      cuisine: stall.cuisine,
      color: stallAccent(stall.cuisine),
      restaurant: stall.restaurant_id,
      staff: staffLooks(
        stall.restaurant_id,
        stall.stall_id,
        STAFF_SPOTS.length,
      ),
      detailed: false,
      open: false,
    };
    paintSign(result, stall);
    return result;
  }

  function discardCounter(counter: Counter) {
    buildings.remove(counter.root);
    counter.sign.material.map?.dispose();
    counter.sign.material.dispose();
    counter.placard.material.map?.dispose();
    counter.placard.material.dispose();
  }

  const faces = createFaceTexture();
  // Walkers are the only people who fade.
  const people = createPeople(STAFF_LIMIT + FLOOR_LIMIT, faces, FLOOR_LIMIT);
  const carriedGeometry = pickupGeometry.clone();
  const trayOpacity = new T.InstancedBufferAttribute(
    new Float32Array(FLOOR_LIMIT),
    1,
  ).setUsage(T.DynamicDrawUsage);
  carriedGeometry.setAttribute("instanceTrayOpacity", trayOpacity);
  const carriedMaterial = pickupMaterial.clone();
  carriedMaterial.transparent = true;
  carriedMaterial.depthWrite = false;
  carriedMaterial.onBeforeCompile = (shader) => {
    shader.vertexShader = shader.vertexShader
      .replace(
        "#include <common>",
        "#include <common>\nattribute float instanceTrayOpacity;\nvarying float vTrayOpacity;",
      )
      .replace(
        "#include <begin_vertex>",
        "#include <begin_vertex>\nvTrayOpacity = instanceTrayOpacity;",
      );
    shader.fragmentShader = shader.fragmentShader
      .replace(
        "#include <common>",
        "#include <common>\nvarying float vTrayOpacity;",
      )
      .replace(
        "#include <color_fragment>",
        "#include <color_fragment>\ndiffuseColor.a *= vTrayOpacity;",
      );
  };
  const carriedTrays = new T.InstancedMesh(
    carriedGeometry,
    carriedMaterial,
    FLOOR_LIMIT,
  );
  const steamGeometry = new T.SphereGeometry(0.115, 6, 4);
  const steam = new T.InstancedMesh(
    steamGeometry,
    new T.MeshBasicMaterial({
      color: "#ffe8c4",
      transparent: true,
      opacity: 0.35,
      depthWrite: false,
    }),
    STALL_LIMIT * 2,
  );
  // The people meshes come from createPeople already set up for this.
  for (const mesh of [steam, carriedTrays]) {
    mesh.frustumCulled = false;
    mesh.count = 0;
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
  }
  scene.add(steam, carriedTrays, ...people.meshes);
  const dummy = new T.Object3D();
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

  function stand(
    look: Look,
    x: number,
    z: number,
    yaw: number,
    faceYaw: number,
    detailed: boolean,
  ) {
    figure.x = x;
    figure.z = z;
    figure.yaw = yaw;
    figure.faceYaw = faceYaw;
    figure.stride = 0;
    figure.walking = figure.carrying = figure.seated = false;
    people.add(look, figure, detailed ? "full" : "simple");
  }

  // Draws a tray for the figure just posed: on the counter at `take` 0, in
  // their hands at 1, and passing between the two in a straight line; or, for
  // a seated figure, resting on the table in front of them.
  function holdTray(look: Look, opacity: number, from?: Point, take = 1) {
    if (carriedTrays.count >= FLOOR_LIMIT) return;
    const carry = figure.seated
      ? seatedTrayPoint(look)
      : carryPoint(look, figure.stride);
    const x = figure.x + Math.sin(figure.yaw) * carry.forward;
    const z = figure.z + Math.cos(figure.yaw) * carry.forward;
    dummy.rotation.set(0, figure.yaw, 0);
    dummy.scale.setScalar(0.75);
    if (from)
      dummy.position.set(
        T.MathUtils.lerp(from[0], x, take),
        T.MathUtils.lerp(from[1], carry.y, take),
        T.MathUtils.lerp(from[2], z, take),
      );
    else dummy.position.set(x, carry.y, z);
    dummy.updateMatrix();
    const trayIndex = carriedTrays.count++;
    carriedTrays.setMatrixAt(trayIndex, dummy.matrix);
    trayOpacity.setX(trayIndex, opacity);
    dummy.rotation.set(0, 0, 0);
  }

  // Per frame: what drawFloorFigure counts, and the clock it glances by.
  let floorTime = 0;
  let floorWalking = 0;
  let floorSeated = 0;
  let drawnWalking = -1;
  let drawnSeated = -1;
  const trayFrom: Point = [0, 0, 0];

  /**
   * Draws one figure the floor model reports, if its room is shown. The
   * viewer's room shows every figure, a stall's queued diners in full when the
   * stall is drawn in detail and simply otherwise. A neighbouring room shows
   * only seated diners and the first in each queue, simply.
   */
  function drawFloorFigure(diner: FloorFigure) {
    const level = shown.get(diner.room);
    if (!level) return;
    const { activity } = diner;
    const model =
      diner.stall === undefined ? undefined : stalls.get(diner.stall);
    let detail: Detail = appearance.detail ? "full" : "simple";
    let faceYaw = diner.faceYaw;
    if (level === "simple") {
      if (activity !== "seated" && !(activity === "queued" && diner.spot === 0))
        return;
      detail = "simple";
    } else if (activity === "queued") {
      const detailed = model?.detailed ?? false;
      detail = detailed ? "full" : "simple";
      if (detailed && appearance.motion && model)
        faceYaw += staffGlance(floorTime, model.index, (diner.spot ?? 0) + 10);
    }
    figure.x = diner.x;
    figure.z = diner.z;
    figure.yaw = diner.yaw;
    figure.faceYaw = faceYaw;
    figure.stride = diner.stride;
    figure.walking =
      activity === "walking" || (activity === "collecting" && diner.take === 0);
    figure.carrying = diner.carrying;
    figure.seated = activity === "seated";
    const before = people.count;
    people.add(diner.look, figure, detail, diner.opacity);
    if (people.count === before) return; // faded out, or no room left
    if (activity === "walking" || activity === "collecting") floorWalking++;
    else if (activity === "seated") floorSeated++;
    if (activity === "collecting" && diner.take !== undefined && model) {
      const counter = toHall(model.placement, COUNTER_TRAY[0], COUNTER_TRAY[1]);
      trayFrom[0] = counter.x;
      trayFrom[1] = 0.93;
      trayFrom[2] = counter.z;
      holdTray(diner.look, diner.opacity, trayFrom, diner.take);
    } else if (diner.carrying || figure.seated)
      holdTray(diner.look, diner.opacity);
  }

  let appearance: Appearance = {
    stalls: [],
    ownedStalls: [],
    selected: "",
    pickup: "",
    pickups: [],
    closedLabel: "",
    cuisineLabel: (id) => id,
    reopeningHeading: "",
    reopeningTime: () => "",
    detail: true,
    motion: true,
    tablet: null,
    tabletLabel: "",
    tabletHint: "",
    toLetLabel: "",
    serving: false,
  };
  let hover = "";
  // The room the viewer is in, the open rooms, and how each drawn room is drawn.
  let currentRoom =
    saved?.room && Number.isInteger(saved.room)
      ? T.MathUtils.clamp(saved.room, 1, ROOM_COUNT)
      : 1;
  let openRooms = 1;
  const shown = new Map<number, "full" | "simple">([[1, "full"]]);
  let drawnBays = -1;
  let frame = 0;
  let animating = false;
  let frameInterval = 32;
  let disposed = false;
  let initialized = Boolean(saved);
  let hasHallView = false;
  let lastFrame = 0;
  let drawnPeople = -1;
  let drawnShutters = -1;
  const heldArrows = new Set<string>();
  let shiftHeld = false;

  function draw(now = performance.now()) {
    if (disposed || document.hidden) return;
    const started = performance.now();
    trackRoom();
    hallShell.update(camera.position);
    let puffs = 0;
    carriedTrays.count = 0;
    people.begin();
    const time = appearance.motion ? now / 1000 : 0;
    let shuttersMoving = 0;
    for (const [id, model] of stalls) {
      const level = shown.get(model.placement.room);
      if (!level) {
        model.detailed = false;
        continue;
      }
      if (model.roll) {
        // The shutter hangs from the canopy: its bottom edge rolls down.
        const lowered = shutterLevel(model.roll, now);
        stallKit.applyShutter(model, lowered);
        model.reopening.visible = lowered >= 1 && !model.open;
        if (rolling(model.roll, now)) shuttersMoving++;
      }
      const nearby =
        camera.position.distanceToSquared(model.root.position) < 28 ** 2;
      const inspected =
        id === appearance.selected || id === hover || id === appearance.pickup;
      // Rooms next door are drawn simply.
      const detailed =
        level === "full" && (inspected || (appearance.detail && nearby));
      model.trim.visible = detailed;
      model.sign.visible = detailed || stalls.size <= SMALL_HALL;
      model.edge.visible = inspected;
      model.pickup.visible =
        Boolean(model.activity?.handover) &&
        ![...personalPickups.values()].some(
          (tray) => tray.stall === id && tray.mesh.visible,
        );
      const activity = model.activity;
      const yaw = model.placement.yaw;
      const owner = toHall(model.placement, -0.61, 0.08);
      const glance = appearance.motion && detailed;
      if (model.open) {
        if (insideStall !== id)
          stand(
            model.staff[0],
            owner.x,
            owner.z,
            yaw,
            glance ? staffGlance(time, model.index, 0) : 0,
            detailed,
          );
        const workers = activity?.workers ?? Number(Boolean(activity?.staffed));
        const count = Math.min(workers, detailed ? STAFF_SPOTS.length : 1);
        for (let n = 0; n < count; n++) {
          const [dx, dz] = STAFF_SPOTS[n];
          const sway = appearance.motion
            ? Math.sin(time * 2 + model.index + n) * 0.045
            : 0;
          const worker = toHall(model.placement, dx + sway, dz);
          stand(
            model.staff[n + 1],
            worker.x,
            worker.z,
            yaw,
            (n % 2 ? 1 : -1) * 0.22 +
              (glance ? staffGlance(time, model.index, n + 1) : 0),
            detailed,
          );
        }
      }
      model.detailed = detailed;
      if (!activity) continue;
      if (detailed && activity.cooking > 0) {
        for (let n = 0; n < Math.min(2, activity.cooking); n++) {
          const progress = (time * 0.7 + model.index * 0.27 + n * 0.42) % 1;
          const puff = toHall(
            model.placement,
            0.82 + n * 0.26 + progress * 0.13,
            -0.45,
          );
          dummy.position.set(puff.x, 1.1 + progress * 0.52, puff.z);
          dummy.scale.setScalar(0.8 + progress * 0.75);
          dummy.updateMatrix();
          steam.setMatrixAt(puffs++, dummy.matrix);
        }
      }
    }
    steam.count = puffs;
    floorTime = time;
    floorWalking = floorSeated = 0;
    floor.figures(now, drawFloorFigure);
    people.end();
    if (people.count !== drawnPeople) {
      drawnPeople = people.count;
      host.setAttribute("data-hall-people", String(drawnPeople));
    }
    if (shuttersMoving !== drawnShutters) {
      drawnShutters = shuttersMoving;
      host.setAttribute("data-hall-shutters-moving", String(drawnShutters));
    }
    if (floorWalking !== drawnWalking) {
      drawnWalking = floorWalking;
      host.setAttribute("data-hall-walking", String(drawnWalking));
    }
    if (floorSeated !== drawnSeated) {
      drawnSeated = floorSeated;
      host.setAttribute("data-hall-seated", String(drawnSeated));
    }
    if (carriedTrays.count > 0) trayOpacity.needsUpdate = true;
    steam.instanceMatrix.needsUpdate = true;
    carriedTrays.instanceMatrix.needsUpdate = true;
    const wasTaking = pickupHands.active;
    pickupHands.update(now);
    if (wasTaking && !pickupHands.active) actions.collected();
    try {
      renderer.render(scene, camera);
    } catch {
      actions.fail();
    }
    actions.frame?.(performance.now() - started);
  }

  function animate(now: number) {
    if (!animating || disposed) return;
    if (now - lastFrame >= frameInterval) {
      const seconds = Math.min((now - lastFrame) / 1000, 0.05);
      lastFrame = now;
      if (heldArrows.size === 0 || !navigate(seconds)) draw(now);
      schedule();
    }
    if (animating) frame = requestAnimationFrame(animate);
  }

  function schedule() {
    const active = appearance.stalls.some(
      (stall) =>
        stall.activity &&
        (stall.activity.waiting > 0 || stall.activity.staging),
    );
    const now = performance.now();
    const activeMotion =
      pickupHands.active ||
      heldArrows.size > 0 ||
      // One more frame after the last roll ends draws the settled shutter.
      drawnShutters > 0 ||
      appearance.stalls.some((stall) =>
        rolling(stalls.get(stall.stall_id)?.roll, now),
      ) ||
      (appearance.motion &&
        (floor.moving(now) || (appearance.detail && active)));
    const idleMotion =
      !activeMotion &&
      appearance.motion &&
      appearance.detail &&
      appearance.stalls.some((stall) => stall["open?"]);
    const next = !document.hidden && (activeMotion || idleMotion);
    frameInterval = activeMotion ? 32 : IDLE_FRAME_MS;
    if (animating === next) return;
    animating = next;
    if (next) {
      lastFrame = performance.now();
      frame = requestAnimationFrame(animate);
    } else cancelAnimationFrame(frame);
  }

  function blockingStall(x: number, z: number) {
    for (const model of stalls.values()) {
      if (stallBlocks(model.placement, x, z)) return model;
    }
  }

  function walk(dx: number, dz: number) {
    const booth = stalls.get(insideStall);
    if (booth) {
      const local = toStall(
        booth.placement,
        camera.position.x + dx,
        camera.position.z + dz,
      );
      const next = toHall(
        booth.placement,
        T.MathUtils.clamp(local.x, -1.2, 1.2),
        T.MathUtils.clamp(local.z, -0.5, 0.16),
      );
      camera.position.set(next.x, EYE_HEIGHT, next.z);
      return;
    }
    const placements = [...stalls.values()]
      .filter((model) => shown.has(model.placement.room))
      .map((model) => model.placement);
    const free = (x: number, z: number) =>
      walkable(x, z, openRooms, placements);
    // Clear of walls and booths by a margin, so the eye never enters one.
    const clear = (x: number, z: number) =>
      free(x, z) &&
      free(x + WALK_MARGIN, z) &&
      free(x - WALK_MARGIN, z) &&
      free(x, z + WALK_MARGIN) &&
      free(x, z - WALK_MARGIN);
    const position = camera.position;
    position.y = EYE_HEIGHT;
    const blocked = blockingStall(position.x, position.z);
    if (blocked) {
      const local = toStall(blocked.placement, position.x, position.z);
      const exit = toHall(
        blocked.placement,
        T.MathUtils.clamp(local.x, -1.2, 1.2),
        1.5,
      );
      if (free(exit.x, exit.z)) {
        position.x = exit.x;
        position.z = exit.z;
      }
    }
    // Moving out of a tight spot is allowed as long as it stays walkable.
    const step = (x: number, z: number) =>
      clear(x, z) || (!clear(position.x, position.z) && free(x, z));
    const nextX = position.x + dx;
    if (step(nextX, position.z)) position.x = nextX;
    const nextZ = position.z + dz;
    if (step(position.x, nextZ)) position.z = nextZ;
  }

  function enterWalking() {
    const entrance = walkingEntrance(
      [...stalls.entries()].map(([id, model]) => ({
        id,
        open: model.open,
        placement: model.placement,
      })),
      appearance.selected,
      currentRoom,
    );
    walking = entrance.stall;
    camera.position.set(entrance.position.x, EYE_HEIGHT, entrance.position.z);
    orbit.target.set(entrance.target.x, EYE_HEIGHT, entrance.target.z);
    camera.fov = 42;
    configureCamera();
    camera.updateProjectionMatrix();
    orbit.update();
    if (entrance.stall) actions.walk(entrance.stall);
  }

  function navigate(seconds: number) {
    const vertical =
      Number(heldArrows.has("ArrowUp")) - Number(heldArrows.has("ArrowDown"));
    const horizontal =
      Number(heldArrows.has("ArrowRight")) -
      Number(heldArrows.has("ArrowLeft"));
    if (vertical === 0 && horizontal === 0) return false;

    const heading = orbit.target.clone().sub(camera.position);
    const yaw =
      Math.atan2(heading.x, heading.z) -
      (shiftHeld ? 0 : horizontal * TURN_SPEED * seconds);
    const pitch = T.MathUtils.clamp(
      Math.atan2(heading.y, Math.hypot(heading.x, heading.z)) +
        (shiftHeld ? vertical * LOOK_SPEED * seconds : 0),
      orbit.minPolarAngle - Math.PI / 2,
      0.85,
    );
    const forwardX = Math.sin(yaw);
    const forwardZ = Math.cos(yaw);
    const forward = shiftHeld ? 0 : vertical;
    const strafe = shiftHeld ? horizontal : 0;
    if (forward || strafe) {
      const step = WALK_SPEED * seconds;
      walk(
        (forwardX * forward - forwardZ * strafe) * step,
        (forwardZ * forward + forwardX * strafe) * step,
      );
    }
    const distance =
      forward || strafe
        ? Math.min(heading.length(), WALK_LOOK_DISTANCE)
        : heading.length();
    const reach = Math.cos(pitch) * distance;
    orbit.target
      .copy(camera.position)
      .add(
        heading.set(
          forwardX * reach,
          Math.sin(pitch) * distance,
          forwardZ * reach,
        ),
      );
    orbit.maxPolarAngle = insideStall
      ? Math.PI - 0.25
      : Math.max(ORBIT_POLAR_LIMIT, Math.PI / 2 + pitch);
    return orbit.update();
  }

  function takePickup(id: string) {
    const item = personalPickups.get(id);
    if (pickupHands.active || !item?.mesh.visible || collectedPickups.has(id))
      return;
    const model = stalls.get(item.stall);
    if (!model || !actions.collect(id)) return;
    const from = item.mesh.getWorldPosition(new T.Vector3());
    const rotation = item.mesh.getWorldQuaternion(new T.Quaternion());
    collectedPickups.add(id);
    item.mesh.visible = false;
    stopWalking();
    if (readingMenu) {
      actions.tablet(readingMenu, { kind: "close" });
      readMenu("");
    }
    setInside("");
    if (appearance.motion) {
      walking = item.stall;
      const position = toHall(model.placement, 0, 2.2);
      camera.position.set(position.x, EYE_HEIGHT, position.z);
      orbit.target.copy(camera.position).add(
        new T.Vector3(0, -0.28, -1)
          .normalize()
          .multiplyScalar(6)
          .applyAxisAngle(new T.Vector3(0, 1, 0), model.placement.yaw),
      );
      camera.fov = 42;
      configureCamera();
      camera.updateProjectionMatrix();
      orbit.update();
      actions.walk(item.stall);
      pickupHands.begin(from, rotation, performance.now());
    } else actions.collected();
    schedule();
    draw();
  }

  function keyDown(event: KeyboardEvent) {
    if (
      !event.isComposing &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey
    ) {
      if (event.key === "Escape" && pickupHands.active) {
        event.preventDefault();
        pickupHands.finish();
        actions.collected();
        draw();
        schedule();
        return;
      }
      if (event.key.toLowerCase() === "f" && !event.repeat) {
        const available = appearance.pickups.find(
          (tray) =>
            tray.stall === (readingMenu || walking || appearance.selected) &&
            !collectedPickups.has(tray.id),
        );
        if (available) {
          event.preventDefault();
          takePickup(available.id);
          return;
        }
      }
      if (pickupHands.active && ARROW_KEYS.has(event.key)) {
        event.preventDefault();
        return;
      }
    }
    if (
      readingMenu &&
      !event.isComposing &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      [
        "Tab",
        "ArrowUp",
        "ArrowDown",
        "ArrowLeft",
        "ArrowRight",
        "Enter",
        " ",
        "Escape",
        "Home",
        "End",
      ].includes(event.key)
    ) {
      event.preventDefault();
      const action = activeTablet.key(event.key, event.shiftKey);
      if (action) actions.tablet(readingMenu, action);
      return;
    }
    if (
      event.key.toLowerCase() === "e" &&
      !event.repeat &&
      !event.isComposing &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey
    ) {
      const id = insideStall || walking || appearance.selected;
      if (id) {
        event.preventDefault();
        actions.interact(id, "counter");
      }
      return;
    }
    if (
      (event.key === "[" || event.key === "]") &&
      !event.isComposing &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey
    ) {
      // The previous or next open room.
      event.preventDefault();
      if (!pickupHands.active)
        showRoom(currentRoom + (event.key === "]" ? 1 : -1));
      return;
    }
    shiftHeld = event.shiftKey;
    if (
      !ARROW_KEYS.has(event.key) ||
      event.isComposing ||
      event.altKey ||
      event.ctrlKey ||
      event.metaKey
    )
      return;
    event.preventDefault();
    if (heldArrows.has(event.key)) return;
    if (!insideStall && walking === null) enterWalking();
    heldArrows.add(event.key);
    navigate(1 / 30);
    schedule();
  }

  function keyUp(event: KeyboardEvent) {
    shiftHeld = event.shiftKey;
    if (heldArrows.delete(event.key)) schedule();
  }

  function stopWalking() {
    heldArrows.clear();
    shiftHeld = false;
    schedule();
  }

  function pose(): CameraPose {
    return {
      position: point(camera.position),
      target: point(orbit.target),
      fov: camera.fov,
      ...(walking !== null ? { walk: { stall: walking } } : {}),
    };
  }

  function configureCamera() {
    // A tiny orbit pivot turns the owner's head in place. Panning or dollying
    // would take the camera through the booth walls or the counter.
    orbit.minDistance = insideStall ? 0.01 : readingMenu ? 0.5 : 3.5;
    orbit.maxDistance = insideStall ? 0.01 : MAX_DISTANCE;
    orbit.enablePan = !insideStall;
    orbit.enableZoom = !insideStall;
    orbit.maxPolarAngle =
      insideStall || readingMenu || walking !== null
        ? Math.PI - 0.25
        : ORBIT_POLAR_LIMIT;
  }

  function setInside(id: string) {
    if (id && readingMenu) readMenu("");
    if (id && (!appearance.ownedStalls.includes(id) || !stalls.has(id))) return;
    if (id === insideStall) return;
    stopWalking();
    if (id) {
      hallView ??= pose();
      walking = null;
      insideStall = id;
      configureCamera();
      const root = stalls.get(id)!.root;
      camera.position
        .copy(root.position)
        .add(
          new T.Vector3(-0.61, EYE_HEIGHT, 0.08).applyAxisAngle(
            new T.Vector3(0, 1, 0),
            root.rotation.y,
          ),
        );
      // About 12° down: the counter's front edge (top 0.93 m, 1.03 m ahead of
      // the eye) sits 31° below level, so the 42° view keeps a sliver of it.
      orbit.target
        .copy(camera.position)
        .add(
          new T.Vector3(0, -0.0022, 0.01).applyAxisAngle(
            new T.Vector3(0, 1, 0),
            root.rotation.y,
          ),
        );
      camera.fov = 42;
    } else {
      insideStall = "";
      configureCamera();
      if (hallView) {
        camera.position.copy(vec(hallView.position));
        orbit.target.copy(vec(hallView.target));
        camera.fov = hallView.fov ?? 42;
        walking = hallView.walk?.stall ?? null;
        const phi = new T.Spherical().setFromVector3(
          camera.position.clone().sub(orbit.target),
        ).phi;
        orbit.maxPolarAngle = Math.max(ORBIT_POLAR_LIMIT, phi);
      }
      hallView = undefined;
    }
    camera.updateProjectionMatrix();
    orbit.update();
    actions.inside(id);
    draw();
  }

  /** Frame a room's overview. */
  function frameRoom(room: number) {
    const c = roomCentre(room);
    walking = null;
    orbit.maxPolarAngle = ORBIT_POLAR_LIMIT;
    orbit.target.set(c.x, 0, c.z);
    camera.position.set(c.x + OVERVIEW[0], OVERVIEW[1], c.z + OVERVIEW[2]);
    orbit.update();
    setRoom(room);
    draw();
  }

  function reset() {
    const room = currentRoom;
    readMenu("");
    setInside("");
    frameRoom(Math.min(room, openRooms));
  }

  /** Move to an open room's overview; a closed or missing room is ignored. */
  function showRoom(room: number) {
    if (!Number.isInteger(room) || room < 1 || room > openRooms) return;
    stopWalking();
    readMenu("");
    setInside("");
    frameRoom(room);
  }

  /** The room the camera is looking into, before limiting it to open rooms. */
  function roomOfView() {
    const model = stalls.get(insideStall || readingMenu);
    if (model) return model.placement.room;
    if (walking !== null)
      return roomAt(camera.position.x, camera.position.z) ?? currentRoom;
    return T.MathUtils.clamp(
      Math.round((orbit.target.x - roomCentre(1).x) / ROOM_PITCH) + 1,
      1,
      ROOM_COUNT,
    );
  }

  function trackRoom() {
    if (hasHallView) setRoom(Math.min(roomOfView(), openRooms));
  }

  function setRoom(room: number) {
    if (room === currentRoom && host.hasAttribute("data-hall-room")) return;
    const changed = room !== currentRoom;
    currentRoom = room;
    host.setAttribute("data-hall-room", String(room));
    applyRooms();
    if (changed) actions.room(room);
  }

  /** Draw the current room in full, open rooms next door simply, nothing else. */
  function applyRooms() {
    shown.clear();
    shown.set(currentRoom, "full");
    for (const room of [currentRoom - 1, currentRoom + 1])
      if (room >= 1 && room <= openRooms) shown.set(room, "simple");
    hallShell.show(
      [...shown].map(([room, detail]) => ({ room, detail })),
      openRooms,
    );
    const visible: Counter[] = [];
    for (const model of stalls.values()) {
      model.root.visible = shown.has(model.placement.room);
      if (model.root.visible) visible.push(model);
    }
    cuisineArt.update(visible, appearance.cuisineLabel);
    let count = 0;
    for (const bay of bays.values()) {
      const room = bay.placement.room;
      bay.root.visible = shown.has(room) && room <= openRooms;
      if (bay.root.visible) count++;
    }
    if (count !== drawnBays) {
      drawnBays = count;
      host.setAttribute("data-hall-bays", String(count));
    }
  }

  /** Keep the orbit's target over the open rooms: closed rooms are never shown. */
  function limitTarget() {
    if (walking !== null || insideStall || readingMenu) return;
    const target = orbit.target;
    const x = T.MathUtils.clamp(
      target.x,
      roomCentre(1).x - HALF_ROOM,
      roomCentre(openRooms).x + HALF_ROOM,
    );
    const z = T.MathUtils.clamp(target.z, -HALF_ROOM, HALF_ROOM);
    if (x === target.x && z === target.z) return;
    const shift = new T.Vector3(x - target.x, 0, z - target.z);
    target.add(shift);
    camera.position.add(shift);
  }

  function focus(id: string) {
    readMenu("");
    setInside("");
    const model = stalls.get(id);
    if (!model || model.placement.room > openRooms) return;
    walking = null;
    orbit.target.copy(model.root.localToWorld(new T.Vector3(0, 0.75, 0.35)));
    const offset = new T.Vector3(0.7, 1.65, 7.8).applyAxisAngle(
      new T.Vector3(0, 1, 0),
      model.placement.yaw,
    );
    camera.position.copy(orbit.target).add(offset);
    orbit.maxPolarAngle = ORBIT_POLAR_LIMIT;
    orbit.update();
    draw();
  }

  function readMenu(id: string, refit = false) {
    if (id === readingMenu && !refit) return;
    if (id) {
      const model = stalls.get(id);
      if (!model) return;
      stopWalking();
      setInside("");
      menuReturn ??= pose();
      walking = null;
      readingMenu = id;
      const target = model.tablet.getWorldPosition(new T.Vector3());
      const tangent = Math.tan(T.MathUtils.degToRad(camera.fov / 2));
      const distance =
        Math.max(0.5 / tangent, 0.34 / (tangent * camera.aspect)) * 1.08;
      orbit.target.copy(target);
      camera.position
        .copy(target)
        .add(
          new T.Vector3(0, 0, distance).applyAxisAngle(
            new T.Vector3(0, 1, 0),
            model.placement.yaw,
          ),
        );
    } else {
      readingMenu = "";
      if (menuReturn) {
        camera.position.copy(vec(menuReturn.position));
        orbit.target.copy(vec(menuReturn.target));
        camera.fov = menuReturn.fov ?? 42;
        walking = menuReturn.walk?.stall ?? null;
      }
      menuReturn = undefined;
    }
    configureCamera();
    camera.updateProjectionMatrix();
    orbit.update();
    draw();
  }

  const ray = new T.Raycaster();
  const cursor = new T.Vector2();
  let press: [number, number] | null = null;
  // How far along the last pointer ray the stall it found, and the first
  // wall, were.
  let stallDistance = Infinity;
  let wallDistance = Infinity;
  function hit(event: PointerEvent) {
    const bounds = renderer.domElement.getBoundingClientRect();
    cursor.set(
      ((event.clientX - bounds.left) / bounds.width) * 2 - 1,
      (-(event.clientY - bounds.top) / bounds.height) * 2 + 1,
    );
    ray.setFromCamera(cursor, camera);
    // Walls, shut doors and the street view stop the pointer.
    wallDistance =
      ray.intersectObjects(hallShell.occluders(), true)[0]?.distance ??
      Infinity;
    const match = nearest(
      [...stalls.values()]
        .filter((stall) => stall.root.visible)
        .map((stall) => stall.hit),
    );
    stallDistance = match?.distance ?? Infinity;
    return (match?.object.userData.stall as string | undefined) ?? "";
  }
  /** The first of these meshes along the pointer ray, unless a wall is nearer. */
  function nearest(meshes: T.Object3D[]) {
    const match = ray.intersectObjects(meshes, false)[0];
    return match && match.distance < wallDistance ? match : undefined;
  }
  function down(event: PointerEvent) {
    host.focus({ preventScroll: true });
    press = [event.clientX, event.clientY];
  }
  function up(event: PointerEvent) {
    if (
      !press ||
      event.button !== 0 ||
      Math.hypot(event.clientX - press[0], event.clientY - press[1]) > 5
    )
      return;
    if (pickupHands.active) return;
    // Test the real tray and screen meshes before the coarse stall hit box.
    const selected = hit(event);
    const screen = nearest(
      [...stalls.values()]
        .filter((model) => model.root.visible)
        .map((model) => model.tablet),
    );
    // A tray is taken only from a stall in a room that is drawn.
    const food = nearest(
      [...personalPickups.values()]
        .filter(
          (item) => item.mesh.visible && stalls.get(item.stall)?.root.visible,
        )
        .map((item) => item.mesh),
    );
    if (food && (!screen || food.distance < screen.distance)) {
      const id = food.object.userData.pickupId as string;
      if (!selected || selected === personalPickups.get(id)?.stall) {
        takePickup(id);
        return;
      }
    }
    if (
      screen?.uv &&
      (!selected || selected === screen.object.userData.stall)
    ) {
      const id = screen.object.userData.stall as string;
      if (readingMenu !== id) actions.tablet(id, { kind: "open" });
      else {
        const action = activeTablet.hit(screen.uv.x, 1 - screen.uv.y);
        if (action) actions.tablet(id, action);
      }
      return;
    }
    const bay = nearest(
      [...bays.values()]
        .filter((item) => item.root.visible)
        .map((item) => item.hit),
    );
    if (bay && bay.distance < stallDistance) {
      actions.vacancy(bay.object.userData.vacancy as string);
      return;
    }
    if (selected) actions.select(selected);
  }
  function pointerMove(event: PointerEvent) {
    if (event.pointerType !== "mouse" || event.buttons !== 0) return;
    const next = hit(event);
    if (next === hover) return;
    hover = next;
    renderer.domElement.classList.toggle("hovering-stall", Boolean(next));
    actions.hover(next || null);
    draw();
  }
  function pointerLeave() {
    hover = "";
    renderer.domElement.classList.remove("hovering-stall");
    actions.hover(null);
    draw();
  }
  function lost(event: Event) {
    event.preventDefault();
    actions.fail();
  }

  renderer.domElement.addEventListener("pointerdown", down);
  renderer.domElement.addEventListener("pointerup", up);
  renderer.domElement.addEventListener("pointermove", pointerMove);
  renderer.domElement.addEventListener("pointerleave", pointerLeave);
  renderer.domElement.addEventListener("webglcontextlost", lost);
  host.addEventListener("keydown", keyDown);
  host.addEventListener("keyup", keyUp);
  host.addEventListener("blur", stopWalking);
  window.addEventListener("blur", stopWalking);
  function orbitChanged() {
    limitTarget();
    draw(performance.now());
  }
  orbit.addEventListener("change", orbitChanged);
  let gestureStart: { position: T.Vector3; target: T.Vector3 } | null = null;
  orbit.addEventListener("start", () => {
    gestureStart =
      walking !== null && !insideStall && !readingMenu
        ? { position: camera.position.clone(), target: orbit.target.clone() }
        : null;
  });
  orbit.addEventListener("end", () => {
    if (
      gestureStart &&
      (gestureStart.position.distanceToSquared(camera.position) > 1e-8 ||
        gestureStart.target.distanceToSquared(orbit.target) > 1e-8)
    )
      walking = null;
    gestureStart = null;
  });
  const resize = new ResizeObserver(() => {
    if (!host.clientWidth || !host.clientHeight) return;
    renderer.setPixelRatio(
      Math.min(window.devicePixelRatio, appearance.detail ? 1.65 : 1),
    );
    renderer.setSize(host.clientWidth, host.clientHeight, false);
    camera.aspect = host.clientWidth / host.clientHeight;
    camera.updateProjectionMatrix();
    if (readingMenu) readMenu(readingMenu, true);
    draw();
  });
  resize.observe(host);
  function visibility() {
    if (document.hidden) {
      stopWalking();
      // Nothing is applied while hidden: the next view is a fresh baseline.
      floor.clear();
    }
    schedule();
    if (!document.hidden) draw();
  }
  document.addEventListener("visibilitychange", visibility);

  return {
    update(next: Appearance) {
      const detailChanged = appearance.detail !== next.detail;
      const now = performance.now();
      appearance = next;
      idleTablet.update({
        standby: true,
        stall: "",
        title: next.tabletLabel,
        subtitle: next.tabletHint,
        notice: "",
        rows: [],
        previous: "",
        next: "",
        close: "",
      });
      if (next.tablet) activeTablet.update(next.tablet);
      if (!next.motion) {
        if (pickupHands.active) {
          pickupHands.finish();
          actions.collected();
        }
      }
      stallKit.paintShutters(next.closedLabel);
      const ids = new Set(next.stalls.map((stall) => stall.stall_id));
      for (const [id, model] of stalls) {
        if (!ids.has(id)) {
          discardCounter(model);
          stalls.delete(id);
        }
      }
      const spots = assignSpots(next.stalls);
      // Without the room rule every room in use is open.
      openRooms = T.MathUtils.clamp(
        next.rooms?.open ??
          Math.max(1, ...[...spots.values()].map((spot) => spot.room)),
        1,
        ROOM_COUNT,
      );
      for (const stall of next.stalls) {
        const spot = spots.get(stall.stall_id)!;
        let model = stalls.get(stall.stall_id);
        if (model && model.cuisine !== stall.cuisine) {
          const previous = model;
          discardCounter(previous);
          model = createCounter(stall, previous.index, previous.placement);
          stalls.set(stall.stall_id, model);
        }
        if (!model) {
          model = createCounter(
            stall,
            hash(stall.stall_id) % 997,
            spotPlacement(spot.room, spot.position),
          );
          stalls.set(stall.stall_id, model);
        }
        if (
          model.placement.room !== spot.room ||
          model.placement.position !== spot.position
        ) {
          // Only the fallback for halls without room data can move a stall.
          const placement = spotPlacement(spot.room, spot.position);
          model.placement = placement;
          model.root.position.set(placement.x, 0, placement.z);
          model.root.rotation.y = placement.yaw;
        }
        if (model.restaurant !== stall.restaurant_id) {
          // The stall changed hands: the new business's owner stands there.
          model.restaurant = stall.restaurant_id;
          model.staff = staffLooks(
            stall.restaurant_id,
            stall.stall_id,
            STAFF_SPOTS.length,
          );
        }
        paintSign(model, stall);
        model.tablet.material =
          next.tablet?.stall === stall.stall_id
            ? activeTablet.material
            : idleTablet.material;
        model.activity = stall.activity;
        model.open = stall["open?"];
        // A counter seen for the first time, or any counter under reduced
        // motion, rests at its committed state; otherwise the shutter rolls.
        model.roll = rollTo(
          next.motion ? model.roll : undefined,
          !model.open,
          now,
        );
        if (!model.open) {
          paintPlacard(
            model,
            stall,
            next.reopeningHeading,
            next.reopeningTime(stall),
          );
        }
        model.serviceLamp.material = stall.activity?.paused
          ? highlight
          : model.open && stall.activity?.staffed
            ? light
            : dark;
        model.plaque.visible = Boolean(
          stall.awards?.some(
            (award) => !award.cuisine || award.cuisine === stall.cuisine,
          ),
        );
      }
      if (
        insideStall &&
        (!next.ownedStalls.includes(insideStall) || !stalls.has(insideStall))
      )
        setInside("");
      if (walking && !stalls.has(walking)) walking = null;
      if (readingMenu && !stalls.has(readingMenu)) readMenu("");
      hasHallView = true;
      if (!document.hidden)
        floor.apply({
          now,
          serving: next.serving,
          today: next.today,
          queueLimit: next.queueLimit,
          openRooms,
          stalls: next.stalls.map((stall) => {
            const spot = spots.get(stall.stall_id)!;
            return {
              id: stall.stall_id,
              room: spot.room,
              position: spot.position,
              waiting: stall.activity?.waiting ?? 0,
              lastService: stall.last_service ?? null,
            };
          }),
          animate: next.motion,
          browse: next.detail,
          snapshot: next.snapshot,
        });
      updateBays(next);
      paintToLet(next.toLetLabel);
      // A room that closes, with the viewer in it: go to the highest open room
      // below it. Otherwise follow the view, with doors to match the open rooms.
      const viewRoom = roomOfView();
      if (initialized && viewRoom > openRooms) showRoom(openRooms);
      else {
        const room = Math.min(viewRoom, openRooms);
        if (room !== currentRoom || !host.hasAttribute("data-hall-room"))
          setRoom(room);
        else applyRooms();
      }
      const available = new Set(
        next.pickups
          .filter((tray) => !collectedPickups.has(tray.id))
          .map((tray) => tray.id),
      );
      for (const [id, item] of personalPickups)
        if (!available.has(id) || !stalls.has(item.stall)) {
          item.mesh.removeFromParent();
          personalPickups.delete(id);
        }
      const stacked = new Map<string, number>();
      for (const tray of next.pickups) {
        if (collectedPickups.has(tray.id)) continue;
        const model = stalls.get(tray.stall);
        if (!model) continue;
        let item = personalPickups.get(tray.id);
        if (!item) {
          const mesh = new T.Mesh(pickupGeometry, personalMaterial);
          mesh.name = "personal-pickup:" + tray.id;
          mesh.userData.pickupId = tray.id;
          item = { mesh, stall: tray.stall };
          personalPickups.set(tray.id, item);
        }
        if (item.mesh.parent !== model.root) model.root.add(item.mesh);
        const index = stacked.get(tray.stall) ?? 0;
        stacked.set(tray.stall, index + 1);
        item.mesh.position.set(0, 0.93 + index * 0.13, 0.88);
      }
      if (detailChanged)
        renderer.setPixelRatio(
          Math.min(window.devicePixelRatio, next.detail ? 1.65 : 1),
        );
      if (!initialized) {
        // A first view: an owner's first stall's room, otherwise Hall 1.
        initialized = true;
        const first = next.ownedStalls
          .map((id) => spots.get(id)?.room)
          .find((room) => room !== undefined);
        readMenu("");
        setInside("");
        frameRoom(Math.min(first ?? 1, openRooms));
      }
      schedule();
      draw(now);
    },
    focus,
    reset,
    setInside,
    readMenu,
    takePickup,
    showRoom,
    room: () => currentRoom,
    tilt(angle: number) {
      if (!insideStall) return;
      const spherical = new T.Spherical().setFromVector3(
        camera.position.clone().sub(orbit.target),
      );
      spherical.phi = T.MathUtils.clamp(
        spherical.phi - angle,
        orbit.minPolarAngle,
        orbit.maxPolarAngle,
      );
      camera.position
        .copy(orbit.target)
        .add(new T.Vector3().setFromSpherical(spherical));
      orbit.update();
      draw();
    },
    zoom(factor: number) {
      if (insideStall) {
        camera.fov = T.MathUtils.clamp(camera.fov * factor, 30, 70);
        camera.updateProjectionMatrix();
        draw();
        return;
      }
      if (!readingMenu) walking = null;
      const delta = camera.position.clone().sub(orbit.target);
      delta.setLength(
        T.MathUtils.clamp(
          delta.length() * factor,
          orbit.minDistance,
          orbit.maxDistance,
        ),
      );
      camera.position.copy(orbit.target).add(delta);
      orbit.update();
      draw();
    },
    rotate(angle: number) {
      if (!insideStall && !readingMenu) walking = null;
      const delta = camera.position.clone().sub(orbit.target);
      delta.applyAxisAngle(new T.Vector3(0, 1, 0), angle);
      camera.position.copy(orbit.target).add(delta);
      orbit.update();
      draw();
    },
    camera(): CameraState {
      return {
        ...pose(),
        room: currentRoom,
        ...(readingMenu && menuReturn
          ? { menu: { stall: readingMenu, hall: menuReturn } }
          : {}),
        ...(insideStall && hallView
          ? { inside: { stall: insideStall, hall: hallView } }
          : {}),
      };
    },
    audioPosition(id: string) {
      const model = stalls.get(id);
      if (!model) return { pan: 0, level: 1 };
      const position = model.root.position.clone();
      position.y = 1;
      const distance = position.distanceTo(camera.position);
      const projected = position.project(camera);
      return {
        pan: T.MathUtils.clamp(projected.x, -0.9, 0.9),
        level: T.MathUtils.clamp(12 / distance, 0.2, 1),
      };
    },
    dispose() {
      disposed = true;
      cancelAnimationFrame(frame);
      resize.disconnect();
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("blur", stopWalking);
      host.removeEventListener("keydown", keyDown);
      host.removeEventListener("keyup", keyUp);
      host.removeEventListener("blur", stopWalking);
      renderer.domElement.removeEventListener("webglcontextlost", lost);
      orbit.dispose();
      for (const model of stalls.values()) discardCounter(model);
      pickupHands.dispose();
      personalMaterial.dispose();
      idleTablet.dispose();
      activeTablet.dispose();
      tabletGeometry.dispose();
      for (const bay of bays.values()) discardBay(bay);
      toLetMat.map?.dispose();
      cuisineArt.dispose();
      hallShell.dispose();
      stallKit.dispose();
      lights.dispose();
      faces?.dispose();
      people.dispose();
      for (const mesh of [steam, carriedTrays]) {
        mesh.material.dispose();
        mesh.dispose();
      }
      for (const material of [
        wood,
        slate,
        light,
        dark,
        highlight,
        pickupMaterial,
        plaqueMat,
        hitMat,
        bayMat,
        toLetMat,
      ])
        material.dispose();
      for (const geometry of [
        box,
        placardGeometry,
        toLetGeometry,
        pickupGeometry,
        steamGeometry,
        carriedGeometry,
      ])
        geometry.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      renderer.domElement.remove();
    },
  };
}
