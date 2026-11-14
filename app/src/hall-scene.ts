import * as T from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import type { Stall } from "./api";
import { createCuisineArt } from "./cuisine-art";
import { createHallShell } from "./hall-shell";
import { createPickupHands } from "./hall-pickup";
import type { PersonalTray } from "./diner-pickup";
import { createTabletScreen } from "./hall-tablet";
import type { TabletView, TabletAction } from "./hall-tablet";
import {
  layoutStalls,
  nextStallSlot,
  walkingEntrance,
  stallBlocks,
  type StallSlot,
  toHall,
  toStall,
  type StallPlacement,
  QUEUE_SPOTS,
  STAFF_SPOTS,
} from "./hall-layout";
import { carryPoint, personLook, type Look, type Pose } from "./people";
import { createPeople } from "./people-mesh";

type Point = [number, number, number];
type CameraPose = {
  position: Point;
  target: Point;
  fov?: number;
  walk?: { stall: string };
};
export type CameraState = CameraPose & {
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
  frame?: (drawMs: number) => void;
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
};
type Diner = {
  look: Look;
  faceYaw: number;
  arrivalStartedAt?: number;
};
type Departure = {
  diner: Diner;
  yaw: number;
  x: number;
  z: number;
  side: number;
  startedAt: number;
  trayFrom?: Point;
};
type Counter = {
  root: T.Group;
  trim: T.Group;
  hit: T.Mesh;
  edge: T.Mesh;
  shutters: T.Mesh;
  sign: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  tablet: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  reopening: T.Group;
  placard: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  reopeningLabel: string;
  plaque: T.Mesh;
  pickup: T.Mesh;
  serviceLamp: T.Mesh;
  index: number;
  placement: StallPlacement;
  name: string;
  cuisine: string;
  color: T.Color;
  staff: Look[]; // the owner, then one per staff spot
  queue: Diner[];
  visibleDiners: number;
  nextDiner: number;
  lastService?: string | null;
  activity?: Stall["activity"];
  open: boolean;
};

const SMALL_HALL = 4;
const STALL_LIMIT = 150;
const ORBIT_POLAR_LIMIT = 1.46;
const EYE_HEIGHT = 1.55;
const WALK_LOOK_DISTANCE = 6;
const WALK_SPEED = 3.2;
const TURN_SPEED = 1.8;
const LOOK_SPEED = 1.15;
const ARROW_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);
const WALK_MS = 1500;
const IDLE_FRAME_MS = 80;
const SHUTTER_SLATS = 9;
const SHUTTER_HEIGHT = 0.91;
const SHUTTER_FONT = '900 79px "Noto Sans JP", system-ui, sans-serif';
const QUEUE_LIMIT = STALL_LIMIT * QUEUE_SPOTS.length;
const ACTOR_LIMIT = STALL_LIMIT * (QUEUE_SPOTS.length + 1 + STAFF_SPOTS.length);
const hues = [
  "#ffba57",
  "#fc7988",
  "#62d9be",
  "#74bfff",
  "#ba98fb",
  "#ff9567",
  "#b6dd75",
  "#ed91cb",
];
const vec = (point: Point) => new T.Vector3(...point);
const point = (value: T.Vector3): Point => [value.x, value.y, value.z];
const hash = (value: string) =>
  [...value].reduce((sum, char) => (sum * 31 + char.charCodeAt(0)) >>> 0, 0);

function staffGlance(seconds: number, stallIndex: number, workerIndex: number) {
  const phase = (seconds + stallIndex * 0.61 + workerIndex * 1.37) % 5.2;
  const turn = Math.min(phase / 2.1, 1) * Math.PI;
  return 0.31 * Math.sin(turn * 2) * Math.sin(turn);
}

function shutterTexture(label: string) {
  const canvas = document.createElement("canvas");
  const width = (canvas.width = 512);
  const height = (canvas.height = 160);
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;

  const pitch = height / SHUTTER_SLATS;
  for (let slat = 0; slat < SHUTTER_SLATS; slat++) {
    const y = slat * pitch;
    const metal = ctx.createLinearGradient(0, y, 0, y + pitch);
    metal.addColorStop(0, "#34414e");
    metal.addColorStop(0.28, "#7c8a94");
    metal.addColorStop(0.52, "#65737e");
    metal.addColorStop(0.83, "#485561");
    metal.addColorStop(1, "#2c3642");
    ctx.fillStyle = metal;
    ctx.fillRect(0, Math.floor(y), width, Math.ceil(pitch));
  }

  ctx.save();
  ctx.translate(width / 2, height / 2);
  ctx.rotate(-0.09);
  ctx.font = SHUTTER_FONT;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#ffb980";
  ctx.shadowColor = "#f19959";
  ctx.shadowBlur = 7;
  ctx.globalAlpha = 0.72;
  ctx.fillText(label, 0, 0, 395);
  ctx.shadowBlur = 0;
  ctx.globalAlpha = 0.92;
  ctx.fillText(label, 0, 0, 395);
  ctx.restore();

  let seed = 41;
  const grain = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 2 ** 32;
  };
  for (let fleck = 0; fleck < 1800; fleck++) {
    ctx.fillStyle = fleck % 3 ? "#19242c" : "#d0d4d5";
    ctx.globalAlpha = grain() * 0.24;
    ctx.fillRect(grain() * width, grain() * height, 0.6 + grain() * 2.3, 1);
  }

  const texture = new T.CanvasTexture(canvas);
  texture.colorSpace = T.SRGBColorSpace;
  return texture;
}

function faceTexture() {
  const canvas = document.createElement("canvas");
  canvas.width = 256;
  canvas.height = 128;
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;

  // The front of a Three.js sphere (+Z) is at u = 0.25.
  const center = canvas.width / 4;
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = "#352720";
  for (const offset of [-11, 11]) {
    ctx.beginPath();
    ctx.ellipse(center + offset, 59, 3.3, 4.2, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.beginPath();
  ctx.moveTo(center - 7.5, 69);
  ctx.quadraticCurveTo(center, 76, center + 7.5, 69);
  ctx.strokeStyle = "#74413d";
  ctx.lineWidth = 3;
  ctx.lineCap = "round";
  ctx.stroke();

  const texture = new T.CanvasTexture(canvas);
  texture.colorSpace = T.SRGBColorSpace;
  return texture;
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
  const fog = new T.FogExp2("#111526", 0.012);
  scene.fog = fog;
  const camera = new T.PerspectiveCamera(42, 1, 0.25, 175);
  const orbit = new OrbitControls(camera, renderer.domElement);
  orbit.enableDamping = false;
  orbit.screenSpacePanning = true;
  orbit.minDistance = 3.5;
  orbit.maxDistance = 115;
  orbit.minPolarAngle = 0.25;
  orbit.maxPolarAngle = ORBIT_POLAR_LIMIT;
  orbit.mouseButtons.LEFT = T.MOUSE.ROTATE;
  orbit.touches.ONE = T.TOUCH.ROTATE;
  let walking: string | null = saved?.walk?.stall ?? null;
  let insideStall = saved?.inside?.stall ?? "";
  let hallView: CameraPose | undefined = saved?.inside?.hall;
  let radius = 15;
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

  const ambient = new T.HemisphereLight("#ffe8c9", "#7a72ac", 2.4);
  const key = new T.DirectionalLight("#fff3d9", 2.2);
  key.position.set(-6, 12, 8);
  const fill = new T.DirectionalLight("#8bbcff", 0.95);
  fill.position.set(9, 6, -10);
  scene.add(ambient, key, fill);

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
  const tileMat = new T.MeshStandardMaterial({
    color: "#252b40",
    roughness: 0.86,
  });
  const foundationMat = new T.MeshStandardMaterial({
    color: "#14172a",
    roughness: 0.94,
  });
  const wall = new T.MeshStandardMaterial({
    vertexColors: true,
    roughness: 0.75,
  });
  const interiorPaint = new T.Color("#a69e90");
  const exteriorPaint = new T.Color("#313853");

  function wallGeometry(inward: "x" | "z") {
    const geometry = box.clone();
    const normals = geometry.attributes.normal;
    const colors = new T.Float32BufferAttribute(normals.count * 3, 3);
    for (let i = 0; i < normals.count; i++) {
      const normal = inward === "x" ? normals.getX(i) : normals.getZ(i);
      const paint = normal > 0.5 ? interiorPaint : exteriorPaint;
      colors.setXYZ(i, paint.r, paint.g, paint.b);
    }
    geometry.setAttribute("color", colors);
    return geometry;
  }

  const backWall = wallGeometry("z");
  const sideWall = wallGeometry("x");
  const wood = new T.MeshStandardMaterial({
    color: "#826451",
    roughness: 0.75,
  });
  const slate = new T.MeshStandardMaterial({
    color: "#29233b",
    roughness: 0.77,
  });
  const shut = new T.MeshStandardMaterial({
    metalness: 0.24,
    roughness: 0.64,
    side: T.DoubleSide,
  });
  const shutterGeometry = new T.PlaneGeometry(
    3,
    SHUTTER_HEIGHT,
    1,
    SHUTTER_SLATS * 6,
  );
  const shutterVertices = shutterGeometry.attributes.position;
  for (let i = 0; i < shutterVertices.count; i++) {
    const slat =
      (shutterVertices.getY(i) / SHUTTER_HEIGHT + 0.5) * SHUTTER_SLATS;
    shutterVertices.setZ(i, 0.013 * (1 - Math.cos(slat * Math.PI * 2)));
  }
  shutterGeometry.computeVertexNormals();
  let shutterLabel = "";

  function paintShutters(label: string) {
    if (shutterLabel === label) return;
    shutterLabel = label;
    const applyTexture = () => {
      shut.map?.dispose();
      shut.map = shutterTexture(label);
      shut.needsUpdate = true;
    };
    applyTexture();
    if (!document.fonts.check(SHUTTER_FONT, label)) {
      void document.fonts
        .load(SHUTTER_FONT, label)
        .then(() => {
          if (disposed || shutterLabel !== label) return;
          applyTexture();
          draw();
        })
        .catch(() => {});
    }
  }
  const ivory = new T.MeshStandardMaterial({
    color: "#e6d4ae",
    roughness: 0.55,
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
  const accents = hues.map(
    (color) => new T.MeshStandardMaterial({ color, roughness: 0.7 }),
  );
  const awnings = hues.map(
    (color) =>
      new T.MeshStandardMaterial({
        color,
        emissive: color,
        emissiveIntensity: 0.06,
        roughness: 0.78,
      }),
  );
  const floor = new T.Group();
  const stalls = new Map<string, Counter>();
  let departures: Departure[] = [];
  const buildings = new T.Group();
  const cuisineArt = createCuisineArt(buildings, STALL_LIMIT, () => draw());
  const hallShell = createHallShell(scene, () => draw());
  scene.add(floor, buildings);

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

  const floorBase = brick(floor, foundationMat, 0, -0.32, 0, 1, 0.4, 1);
  const floorTop = brick(floor, tileMat, 0, -0.115, 0, 1, 0.1, 1);
  const laneMat = new T.MeshStandardMaterial({
    color: "#3a4359",
    roughness: 0.9,
  });
  const islandFloors = new T.InstancedMesh(
    box,
    laneMat,
    Math.ceil(STALL_LIMIT / 8),
  );
  islandFloors.count = 0;
  islandFloors.frustumCulled = false;
  floor.add(islandFloors);
  const islandTransform = new T.Object3D();
  const lines = new T.Group();
  floor.add(lines);
  let floorSignature = "";
  let centre = new T.Vector3();

  function resizeFloor(width: number, depth: number) {
    const signature = `${width}:${depth}`;
    if (signature === floorSignature) return;
    floorSignature = signature;
    centre = new T.Vector3();
    radius = Math.hypot(width, depth) * 0.91;
    // Keep the whole-room view readable as the rendered hall expands.
    fog.density = Math.min(0.012, 0.45 / radius);
    camera.far = Math.max(175, radius * 3);
    configureCamera();
    camera.updateProjectionMatrix();
    floorBase.position.set(0, -0.32, 0);
    floorBase.scale.set(width + 0.3, 0.4, depth + 0.3);
    floorTop.position.set(0, -0.09, 0);
    floorTop.scale.set(width, 0.1, depth);
    hallShell.resize(0, 0, width, depth);
    lines.clear();
    const insetX = width / 2 - 4.5,
      insetZ = depth / 2 - 4.5;
    for (const sign of [-1, 1]) {
      brick(lines, laneMat, sign * insetX, -0.028, 0, 0.065, 0.025, insetZ * 2);
      brick(lines, laneMat, 0, -0.028, sign * insetZ, insetX * 2, 0.025, 0.065);
    }
  }

  const signGeometry = new T.PlaneGeometry(2.9, 0.43);
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
    slot: StallSlot = nextStallSlot(
      [...stalls.values()].map((model) => model.placement),
    ),
  ): Counter {
    const root = new T.Group();
    const trim = new T.Group();
    root.add(trim);
    const placement = layoutStalls([
      ...[...stalls.values()]
        .filter((model) => model.index !== index)
        .map((model) => model.placement),
      slot,
    ]).placements.at(-1)!;
    root.position.set(placement.x, 0, placement.z);
    root.rotation.y = placement.yaw;
    const colorIndex = hash(stall.cuisine) % hues.length;
    const accent = accents[colorIndex];
    const canopy = awnings[colorIndex];
    const style = hash(stall.cuisine + ":shape") % 3;
    brick(root, wall, 0, 1.03, -0.87, 3.12, 2.06, 0.17).geometry = backWall;
    brick(root, slate, 0, 0.06, -0.18, 3.5, 0.12, 2.48);
    brick(root, wall, -1.52, 1.1, 0, 0.12, 2.2, 1.9).geometry = sideWall;
    const rightWall = brick(root, wall, 1.52, 1.1, 0, 0.12, 2.2, 1.9);
    rightWall.geometry = sideWall;
    rightWall.rotation.y = Math.PI;
    brick(root, canopy, 0, 2.24, -0.14, 3.4, 0.16, 2.27);
    if (style === 0) {
      for (let stripe = -2; stripe <= 2; stripe++) {
        brick(
          trim,
          stripe % 2 === 0 ? accent : ivory,
          stripe * 0.59,
          2.18,
          1.05,
          0.56,
          0.18,
          0.48,
        );
      }
    } else if (style === 1) {
      brick(trim, canopy, 0, 2.44, -0.48, 2.9, 0.12, 1.52);
      brick(trim, ivory, 0, 2.15, 1.1, 3.1, 0.09, 0.2);
    } else {
      for (const side of [-1, 1])
        brick(trim, ivory, side * 1.16, 2.13, 1.13, 0.2, 0.24, 0.25);
    }
    brick(root, wood, 0, 0.44, 0.69, 3.08, 0.76, 0.67);
    brick(root, ivory, 0, 0.87, 0.69, 3.26, 0.12, 0.83);
    brick(root, accent, 0, 0.35, 1.04, 2.78, 0.26, 0.07);
    brick(trim, wood, -0.93, 0.86, -0.69, 0.86, 0.13, 0.26);
    brick(trim, slate, 0.91, 0.89, -0.69, 0.89, 0.16, 0.26);
    brick(trim, ivory, 1.08, 0.99, 0.64, 0.5, 0.1, 0.33);
    const shutters = new T.Mesh(shutterGeometry, shut);
    shutters.position.set(0, 1.38, 0.8);
    root.add(shutters);
    const serviceLamp = brick(root, light, -1.23, 1.68, 0.91, 0.15, 0.2, 0.12);
    const edge = brick(root, highlight, 0, 0.032, 1.14, 3.47, 0.065, 0.11);
    const pickup = new T.Mesh(pickupGeometry, pickupMaterial);
    pickup.position.set(0, 0.93, 0.88);
    root.add(pickup);
    const plaque = brick(root, plaqueMat, 1.48, 1.2, 1.05, 0.25, 0.3, 0.05);
    const sign = new T.Mesh(
      signGeometry,
      new T.MeshBasicMaterial({ color: "#ffffff" }),
    );
    sign.position.set(0, 1.94, 1.035);
    root.add(sign);
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
      color: accent.color,
      staff: [
        personLook(index * 16, "owner"),
        ...STAFF_SPOTS.map((_, n) => personLook(index * 16 + n + 1, "worker")),
      ],
      queue: [],
      visibleDiners: 0,
      nextDiner: hash(stall.stall_id),
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

  const faces = faceTexture();
  const people = createPeople(ACTOR_LIMIT + QUEUE_LIMIT * 2, faces);
  const carriedGeometry = pickupGeometry.clone();
  const trayOpacity = new T.InstancedBufferAttribute(
    new Float32Array(QUEUE_LIMIT),
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
    QUEUE_LIMIT,
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
  const animatedMeshes = [steam, carriedTrays, ...people.meshes];
  for (const mesh of animatedMeshes) {
    mesh.frustumCulled = false;
    mesh.count = 0;
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
    scene.add(mesh);
  }
  const dummy = new T.Object3D();
  const figure: Pose = {
    x: 0,
    z: 0,
    yaw: 0,
    faceYaw: 0,
    stride: 0,
    walking: false,
    carrying: false,
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
    figure.walking = figure.carrying = false;
    people.add(look, figure, detailed ? "full" : "simple");
  }

  function queueSway(index: number, position: number, now: number) {
    return Math.sin(now / 500 + index + position) * 0.045;
  }

  function aisleDistance(diner: Diner, now: number) {
    return diner.arrivalStartedAt === undefined
      ? 0
      : T.MathUtils.clamp(1 - (now - diner.arrivalStartedAt) / WALK_MS, 0, 1);
  }

  function departDiner(
    model: Counter,
    index: number,
    now: number,
    carrying: boolean,
  ) {
    if (departures.length >= QUEUE_LIMIT) return false;
    const diner = model.queue[index];
    const distance = aisleDistance(diner, now);
    if (distance === 1) return false;
    const [dx, dz] = QUEUE_SPOTS[index];
    const { x, z } = toHall(
      model.placement,
      dx + queueSway(model.index, index, now),
      dz,
    );
    departures.push({
      diner,
      x,
      z,
      yaw: model.placement.yaw,
      side: index % 2 === 0 ? -1 : 1,
      // An interrupted arrival heads back from its current point in the aisle.
      startedAt: now - distance * WALK_MS,
      trayFrom: carrying
        ? point(model.root.localToWorld(new T.Vector3(0, 0.93, 0.88)))
        : undefined,
    });
    return true;
  }

  function updateQueue(
    model: Counter,
    waiting: number,
    now: number,
    served = false,
  ) {
    const count = Math.min(waiting, QUEUE_SPOTS.length);
    const animateQueue = appearance.motion && !document.hidden;
    if (animateQueue) {
      for (let n = count; n < model.visibleDiners; n++) {
        if (departDiner(model, n, now, served)) served = false;
      }
      // A completed customer can be replaced before the next view arrives.
      if (served && model.visibleDiners > 0) {
        const index = Math.min(model.visibleDiners, count) - 1;
        if (index >= 0 && departDiner(model, index, now, true)) {
          model.queue.splice(index, 1);
        }
      }
    }
    model.queue.length = Math.min(model.queue.length, count);
    model.visibleDiners = Math.min(model.visibleDiners, count);
    if (!animateQueue) {
      for (const diner of model.queue) diner.arrivalStartedAt = undefined;
    }
    while (model.queue.length < count) {
      const [dx, dz] = QUEUE_SPOTS[model.queue.length];
      model.queue.push({
        look: personLook(model.nextDiner++, "diner"),
        faceYaw: Math.atan2(-dx, -dz),
        arrivalStartedAt: animateQueue && hasHallView ? now : undefined,
      });
    }
  }

  function walkDiner(
    diner: Diner,
    x: number,
    z: number,
    side: number,
    distance: number,
    departing = false,
    trayFrom?: Point,
    yaw = 0,
  ) {
    const stride = Math.sin(distance * Math.PI * 8);
    const opacity = 1 - T.MathUtils.smoothstep(distance, 0.14, 1);
    const walking = toHall(
      { x, z, yaw },
      side * 1.18 * T.MathUtils.smoothstep(distance, 0.05, 1),
      distance * 1.4,
    );
    const heading = Math.atan2(side * 1.18, 1.4);
    figure.x = walking.x;
    figure.z = walking.z;
    figure.yaw = yaw + (departing ? heading : diner.faceYaw);
    figure.faceYaw = 0;
    figure.stride = stride;
    figure.walking = true;
    figure.carrying = Boolean(trayFrom);
    people.add(diner.look, figure, "full", opacity);
    if (trayFrom) {
      const carry = carryPoint(diner.look, stride);
      const handover = T.MathUtils.smoothstep(distance, 0, 0.16);
      dummy.rotation.set(0, figure.yaw, 0);
      dummy.scale.setScalar(0.75);
      dummy.position.set(
        T.MathUtils.lerp(
          trayFrom[0],
          walking.x + Math.sin(figure.yaw) * carry.forward,
          handover,
        ),
        T.MathUtils.lerp(trayFrom[1], carry.y, handover),
        T.MathUtils.lerp(
          trayFrom[2],
          walking.z + Math.cos(figure.yaw) * carry.forward,
          handover,
        ),
      );
      dummy.updateMatrix();
      const trayIndex = carriedTrays.count++;
      carriedTrays.setMatrixAt(trayIndex, dummy.matrix);
      trayOpacity.setX(trayIndex, opacity);
      dummy.rotation.set(0, 0, 0);
    }
  }

  function drawDepartures(now: number) {
    if (departures.length === 0) return;
    departures = departures.filter(
      ({ startedAt }) => now - startedAt < WALK_MS,
    );
    for (const { diner, x, z, side, startedAt, trayFrom, yaw } of departures) {
      walkDiner(
        diner,
        x,
        z,
        side,
        Math.max(0, now - startedAt) / WALK_MS,
        true,
        trayFrom,
        yaw,
      );
    }
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
  };
  let hover = "";
  let frame = 0;
  let animating = false;
  let frameInterval = 32;
  let disposed = false;
  let initialized = Boolean(saved);
  let hasHallView = false;
  let lastFrame = 0;
  let drawnPeople = -1;
  const heldArrows = new Set<string>();
  let shiftHeld = false;

  function draw(now = performance.now()) {
    if (disposed || document.hidden) return;
    const started = performance.now();
    hallShell.update(camera.position);
    let puffs = 0;
    carriedTrays.count = 0;
    people.begin();
    const time = appearance.motion ? now / 1000 : 0;
    for (const [id, model] of stalls) {
      const nearby =
        camera.position.distanceToSquared(model.root.position) < 28 ** 2;
      const inspected =
        id === appearance.selected || id === hover || id === appearance.pickup;
      const detailed = inspected || (appearance.detail && nearby);
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
      model.visibleDiners = Math.min(
        model.queue.length,
        detailed ? QUEUE_SPOTS.length : 1,
      );
      for (let n = 0; n < model.visibleDiners; n++) {
        const diner = model.queue[n];
        const [dx, dz] = QUEUE_SPOTS[n];
        const sway = appearance.motion ? queueSway(model.index, n, now) : 0;
        const distance = aisleDistance(diner, now);
        const position = toHall(model.placement, dx + sway, dz);
        if (distance > 0) {
          walkDiner(
            diner,
            position.x,
            position.z,
            n % 2 === 0 ? -1 : 1,
            distance,
            false,
            undefined,
            yaw,
          );
          continue;
        }
        stand(
          diner.look,
          position.x,
          position.z,
          yaw + diner.faceYaw,
          glance ? staffGlance(time, model.index, n + 10) : 0,
          detailed,
        );
      }
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
    drawDepartures(now);
    people.end();
    if (people.count !== drawnPeople) {
      drawnPeople = people.count;
      host.setAttribute("data-hall-people", String(drawnPeople));
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
    const activeMotion =
      pickupHands.active ||
      heldArrows.size > 0 ||
      (appearance.motion &&
        (departures.length > 0 || (appearance.detail && active)));
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
    const { x, z } = floorTop.position;
    const halfWidth = floorTop.scale.x / 2 - 0.3;
    const halfDepth = floorTop.scale.z / 2 - 0.3;
    const clampX = (value: number) =>
      T.MathUtils.clamp(value, x - halfWidth, x + halfWidth);
    const clampZ = (value: number) =>
      T.MathUtils.clamp(value, z - halfDepth, z + halfDepth);
    const position = camera.position;
    position.set(clampX(position.x), EYE_HEIGHT, clampZ(position.z));
    const blocked = blockingStall(position.x, position.z);
    if (blocked) {
      const local = toStall(blocked.placement, position.x, position.z);
      const exit = toHall(
        blocked.placement,
        T.MathUtils.clamp(local.x, -1.2, 1.2),
        1.5,
      );
      position.x = clampX(exit.x);
      position.z = clampZ(exit.z);
    }

    const nextX = clampX(position.x + dx);
    if (!blockingStall(nextX, position.z)) position.x = nextX;
    const nextZ = clampZ(position.z + dz);
    if (!blockingStall(position.x, nextZ)) position.z = nextZ;
  }

  function enterWalking() {
    const entrance = walkingEntrance(
      [...stalls.entries()].map(([id, model]) => ({
        id,
        open: model.open,
        placement: model.placement,
      })),
      appearance.selected,
      floorTop.scale.x,
      floorTop.scale.z,
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
    orbit.maxDistance = insideStall ? 0.01 : Math.max(115, radius * 2);
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
      orbit.target
        .copy(camera.position)
        .add(
          new T.Vector3(0, -0.0045, 0.01).applyAxisAngle(
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

  function reset() {
    readMenu("");
    setInside("");
    walking = null;
    orbit.maxPolarAngle = ORBIT_POLAR_LIMIT;
    orbit.target.copy(centre);
    camera.position
      .copy(centre)
      .add(new T.Vector3(radius * 0.5, radius * 0.75, radius * 0.85));
    orbit.update();
    draw();
  }

  function focus(id: string) {
    readMenu("");
    setInside("");
    const model = stalls.get(id);
    if (!model) return;
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
  function hit(event: PointerEvent) {
    const bounds = renderer.domElement.getBoundingClientRect();
    cursor.set(
      ((event.clientX - bounds.left) / bounds.width) * 2 - 1,
      (-(event.clientY - bounds.top) / bounds.height) * 2 + 1,
    );
    ray.setFromCamera(cursor, camera);
    const match = ray.intersectObjects(
      [...stalls.values()].map((stall) => stall.hit),
      false,
    )[0];
    return (match?.object.userData.stall as string | undefined) ?? "";
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
    const screen = ray.intersectObjects(
      [...stalls.values()].map((model) => model.tablet),
      false,
    )[0];
    const food = ray.intersectObjects(
      [...personalPickups.values()]
        .filter((item) => item.mesh.visible)
        .map((item) => item.mesh),
      false,
    )[0];
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
      departures = [];
      for (const model of stalls.values()) {
        for (const diner of model.queue) diner.arrivalStartedAt = undefined;
      }
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
        departures = [];
        if (pickupHands.active) {
          pickupHands.finish();
          actions.collected();
        }
      }
      paintShutters(next.closedLabel);
      const ids = new Set(next.stalls.map((stall) => stall.stall_id));
      for (const [id, model] of stalls) {
        if (!ids.has(id)) {
          updateQueue(model, 0, now);
          discardCounter(model);
          stalls.delete(id);
        }
      }
      const indices = new Set([...stalls.values()].map((model) => model.index));
      let index = 0;
      for (const stall of next.stalls) {
        let model = stalls.get(stall.stall_id);
        if (model && model.cuisine !== stall.cuisine) {
          const previous = model;
          discardCounter(previous);
          model = createCounter(stall, previous.index, previous.placement);
          model.queue = previous.queue;
          model.visibleDiners = previous.visibleDiners;
          model.nextDiner = previous.nextDiner;
          model.lastService = previous.lastService;
          stalls.set(stall.stall_id, model);
        }
        if (!model) {
          while (indices.has(index)) index++;
          model = createCounter(stall, index);
          indices.add(index);
          stalls.set(stall.stall_id, model);
        }
        paintSign(model, stall);
        model.tablet.material =
          next.tablet?.stall === stall.stall_id
            ? activeTablet.material
            : idleTablet.material;
        const served =
          model.lastService !== undefined &&
          Boolean(stall.last_service) &&
          stall.last_service !== model.lastService;
        updateQueue(model, stall.activity?.waiting ?? 0, now, served);
        model.lastService = stall.last_service ?? null;
        model.activity = stall.activity;
        model.open = stall["open?"];
        model.shutters.visible = !model.open;
        model.reopening.visible = !model.open;
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
      hasHallView = true;
      const models = [...stalls.values()];
      const layout = layoutStalls(models.map((model) => model.placement));
      const anchor = stalls.get(
        insideStall || readingMenu || walking || next.selected,
      );
      const before = anchor?.placement;
      for (const [i, model] of models.entries()) {
        const placement = layout.placements[i];
        model.placement = placement;
        model.root.position.set(placement.x, 0, placement.z);
        model.root.rotation.y = placement.yaw;
      }
      if (anchor && before) {
        const reframe = (position: T.Vector3) => {
          if (
            before.x === anchor.placement.x &&
            before.z === anchor.placement.z &&
            before.yaw === anchor.placement.yaw
          )
            return;
          const local = toStall(before, position.x, position.z);
          const moved = toHall(anchor.placement, local.x, local.z);
          position.x = moved.x;
          position.z = moved.z;
        };
        reframe(camera.position);
        reframe(orbit.target);
        for (const savedPose of [hallView, menuReturn])
          if (savedPose) {
            const position = vec(savedPose.position),
              target = vec(savedPose.target);
            reframe(position);
            reframe(target);
            savedPose.position = point(position);
            savedPose.target = point(target);
          }
      } else if (
        initialized &&
        (floorTop.scale.x !== layout.floorWidth ||
          floorTop.scale.z !== layout.floorDepth)
      ) {
        const ratio =
          Math.hypot(layout.floorWidth, layout.floorDepth) /
          Math.hypot(floorTop.scale.x, floorTop.scale.z);
        camera.position.multiplyScalar(ratio);
        orbit.target.multiplyScalar(ratio);
      }
      resizeFloor(layout.floorWidth, layout.floorDepth);
      islandFloors.count = layout.islands.length;
      for (const island of layout.islands) {
        islandTransform.position.set(island.x, -0.027, island.z);
        islandTransform.scale.set(island.side + 2.6, 0.025, island.side + 2.6);
        islandTransform.updateMatrix();
        islandFloors.setMatrixAt(island.id, islandTransform.matrix);
      }
      islandFloors.instanceMatrix.needsUpdate = true;
      orbit.update();
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
      cuisineArt.update(stalls.values(), next.cuisineLabel);
      if (detailChanged)
        renderer.setPixelRatio(
          Math.min(window.devicePixelRatio, next.detail ? 1.65 : 1),
        );
      if (!initialized) {
        initialized = true;
        reset();
      }
      schedule();
      draw(now);
    },
    focus,
    reset,
    setInside,
    readMenu,
    takePickup,
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
      islandFloors.dispose();
      cuisineArt.dispose();
      hallShell.dispose();
      shut.map?.dispose();
      faces?.dispose();
      people.dispose();
      for (const mesh of [steam, carriedTrays]) {
        mesh.material.dispose();
        mesh.dispose();
      }
      for (const material of [
        tileMat,
        foundationMat,
        wall,
        wood,
        slate,
        shut,
        ivory,
        light,
        dark,
        highlight,
        pickupMaterial,
        plaqueMat,
        hitMat,
        laneMat,
        ...accents,
        ...awnings,
      ])
        material.dispose();
      for (const geometry of [
        box,
        backWall,
        sideWall,
        signGeometry,
        placardGeometry,
        pickupGeometry,
        shutterGeometry,
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
