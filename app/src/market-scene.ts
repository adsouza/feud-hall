import * as T from "three";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import {
  goodFor,
  type Good,
  type ShapeId,
  type VariantId,
  type VendorId,
} from "./market-goods";
import {
  BASE_Y,
  CAMERA_FOV,
  SIGN_BOTTOM,
  SIGN_MAX_H,
  STALL_GAP,
  TIER_RISE,
  TIER_DEPTH,
  PITCH_X,
  cartGoods,
  clickOutcome,
  containerFill,
  outOfStock,
  hoveredProduct,
  marketLayout,
  overviewPose,
  stageTrips,
  standingSpot,
  STAND_SPACING,
  tripRoute,
  vendorPose,
  type CameraPose,
  type MarketLayout,
  type Placed,
  type PointerTarget,
  type Stall,
} from "./market-layout";
import {
  CART_HANDLE_HEIGHT,
  cartHandlePoint,
  personLook,
  serialFor,
  type Look,
  type Pose,
} from "./people";
import { createFaceTexture, createPeople } from "./people-mesh";

export type MarketAppearance = {
  /** The owner's view of the market; `crate` and `level` may be missing from an older server. */
  market: Record<
    string,
    { price: string; stock: number; crate?: number; level?: number }
  >;
  starred: string[]; // products the owner's menu uses
  cart: { product: string; crates: number }[]; // the draft
  /** Crates the server filled for the owner, drawn closed on the cart. */
  arrived: { product: string; crates: number }[];
  focusedVendor: VendorId | null; // null: the row
  selected: string; // product highlighted from the list, or ""
  trips: {
    batch: number;
    restaurant_id: string;
    products: string[];
    size: "small" | "medium" | "large";
  }[];
  ownRestaurant: string;
  restaurantName: (id: string) => string;
  vendorLabel: (vendor: VendorId) => string;
  priceLabel: (price: string) => string;
  crateLabel: (crate: number) => string;
  motion: boolean;
};
export type MarketActions = {
  add(product: string): void; // a container was clicked
  focusVendor(vendor: VendorId | null): void;
  hover(product: string): void; // "" when nothing
  hoverShopper(name: string): void; // "" when nothing; the restaurant's name only
  fail(): void;
};
export type MarketScene = {
  update(next: MarketAppearance): void;
  setVisible(visible: boolean): void; // stops drawing while the Supply section is hidden
  dispose(): void;
};

/** Most rival shoppers in the market at once; a new one sends the oldest home. */
export const MAX_SHOPPERS = 8;
/** Crates of one line drawn on the owner's cart. */
export const CART_CRATES_PER_LINE = 12;
/** Below this level (of 1000) a container's tag is marked low. */
export const LOW_LEVEL = 300;
/** Goods drawn in a full container. */
export const GOODS_PER_CONTAINER = 6;
/** How long a shopper stands at a stall when motion is off. */
export const STILL_SHOPPER_MS = 20_000;

const SHAPES: readonly ShapeId[] = [
  "round",
  "leafy",
  "root",
  "cut",
  "fish",
  "shellfish",
  "sack",
  "jar",
  "bottle",
  "loaf",
  "block",
  "carton",
];

// Container proportions, metres. A crate stands on its step a little forward
// of the step's centre; its price tag stands on a stake behind it.
const CRATE_W = 0.54;
const CRATE_D = 0.34;
const CRATE_H = 0.12;
const CRATE_FORWARD = 0.07;
const FLOOR_Y = 0.016; // inside floor of a crate
const BED_MAX = 0.05; // depth of loose goods under the pieces when full
const TAG_W = 0.6;
const TAG_H = 0.3;
const TAG_BOTTOM = 0.15;
const TAG_BACK = CRATE_D / 2 + 0.025; // behind the crate's centre
const TAG_TILT = -0.22; // leans back towards the camera
const GOOD_SLOTS: readonly [number, number][] = [
  [0, 0.075],
  [-0.165, 0.075],
  [0.165, 0.075],
  [0, -0.075],
  [-0.165, -0.075],
  [0.165, -0.075],
];

// Tag atlas cell, canvas pixels; the tag keeps the same 2:1 shape.
const CELL_W = 192;
const CELL_H = 96;
const TAG_FONT = '"Noto Sans JP", system-ui, sans-serif';

const WALK_SPEED = 1.25; // metres per second
const PAUSE_MS = 2400;
const GAIT = (Math.PI * 2) / 1.2; // stride phase per metre walked
const EASE_MS = 650;
const STAGGER_MS = 1700;
const LANE_OFFSET = 0.6;
const FRAME_MS = 32;

const VENDOR_COLOURS: Record<VendorId, number> = {
  greengrocer: 0x4f9a46,
  butcher: 0xb8423a,
  fishmonger: 0x3f7fbf,
  dairy: 0xe2c25a,
  grains: 0xb07a3c,
  spices: 0xd9682a,
  pantry: 0x7b5aa6,
};
const CRATE_COLOURS: Record<VariantId, number> = {
  plain: 0x9c6a3e,
  frozen: 0xd6ecf8,
  value: 0xb89d6c,
  shelf: 0xcfae80,
};
const OWNER_CART = 0xff9e57;
/** The lid on a crate that arrived, so it is not taken for the draft. */
const ARRIVED_LID = 0x2fbf5f;
const RIVAL_CART = 0x8b96a3;

const SCRATCH = new T.Color();
const WHITE = new T.Color(0xffffff);

/** The piece a good is drawn as: value lines are plain sacks, shelf-stable lines boxes. */
function pieceShape(good: Good): ShapeId {
  if (good.variant === "value") return "sack";
  if (good.variant === "shelf") return "carton";
  return good.shape;
}

/** The colour a good is drawn in: frozen paler and icy, value duller, shelf boxed. */
function pieceColour(good: Good): number {
  SCRATCH.setHex(good.colour);
  if (good.variant === "frozen") SCRATCH.lerp(new T.Color(0xe4f3ff), 0.5);
  else if (good.variant === "value") SCRATCH.lerp(new T.Color(0xb7a27c), 0.45);
  else if (good.variant === "shelf") SCRATCH.lerp(new T.Color(0xe0c9a0), 0.3);
  return SCRATCH.getHex();
}

// Each piece's geometry rests on y = 0 and fits a 0.15 m square.
function pieceGeometry(shape: ShapeId): T.BufferGeometry {
  switch (shape) {
    case "round":
      return new T.SphereGeometry(0.066, 10, 7).translate(0, 0.066, 0);
    case "leafy":
      return mergeGeometries([
        new T.ConeGeometry(0.07, 0.17, 7).translate(0, 0.12, 0),
        new T.CylinderGeometry(0.018, 0.022, 0.05, 6).translate(0, 0.025, 0),
      ]);
    case "root":
      return new T.ConeGeometry(0.042, 0.18, 7)
        .rotateZ(Math.PI / 2)
        .translate(0, 0.042, 0);
    case "cut":
      return new T.CylinderGeometry(0.072, 0.072, 0.045, 12)
        .scale(1.15, 1, 0.82)
        .translate(0, 0.0225, 0);
    case "fish":
      return mergeGeometries([
        new T.SphereGeometry(0.05, 10, 7).scale(0.85, 0.75, 1.9),
        new T.ConeGeometry(0.04, 0.06, 4)
          .rotateX(-Math.PI / 2)
          .scale(0.35, 1, 1)
          .translate(0, 0, -0.115),
      ]).translate(0, 0.038, 0);
    case "shellfish":
      return new T.TorusGeometry(0.045, 0.022, 6, 12, Math.PI * 1.5)
        .rotateX(-Math.PI / 2)
        .translate(0, 0.022, 0);
    case "sack":
      return mergeGeometries([
        new T.CylinderGeometry(0.052, 0.068, 0.12, 9).translate(0, 0.06, 0),
        new T.SphereGeometry(0.03, 7, 5).translate(0, 0.13, 0),
      ]);
    case "jar":
      return mergeGeometries([
        new T.CylinderGeometry(0.046, 0.046, 0.1, 12).translate(0, 0.05, 0),
        new T.CylinderGeometry(0.05, 0.05, 0.024, 12).translate(0, 0.112, 0),
      ]);
    case "bottle":
      return mergeGeometries([
        new T.CylinderGeometry(0.036, 0.036, 0.12, 10).translate(0, 0.06, 0),
        new T.CylinderGeometry(0.014, 0.024, 0.06, 8).translate(0, 0.15, 0),
      ]);
    case "loaf":
      return new T.CapsuleGeometry(0.045, 0.08, 4, 8)
        .rotateZ(Math.PI / 2)
        .scale(1, 0.85, 1.15)
        .translate(0, 0.038, 0);
    case "block":
      return new T.BoxGeometry(0.11, 0.075, 0.09).translate(0, 0.0375, 0);
    case "carton":
      return new T.BoxGeometry(0.08, 0.14, 0.06).translate(0, 0.07, 0);
  }
}

// An open box: a floor and four walls, resting on y = 0.
function openBox(w: number, d: number, h: number, t: number) {
  return [
    new T.BoxGeometry(w, t, d).translate(0, t / 2, 0),
    new T.BoxGeometry(w, h, t).translate(0, h / 2, d / 2 - t / 2),
    new T.BoxGeometry(w, h, t).translate(0, h / 2, -d / 2 + t / 2),
    new T.BoxGeometry(t, h, d).translate(w / 2 - t / 2, h / 2, 0),
    new T.BoxGeometry(t, h, d).translate(-w / 2 + t / 2, h / 2, 0),
  ];
}

// A crate with the stake its price tag stands on.
function crateGeometry(): T.BufferGeometry {
  return mergeGeometries([
    ...openBox(CRATE_W, CRATE_D, CRATE_H, 0.022),
    new T.BoxGeometry(0.03, TAG_BOTTOM + 0.04, 0.02).translate(
      0,
      (TAG_BOTTOM + 0.04) / 2,
      -TAG_BACK + 0.012,
    ),
  ]);
}

// Cart: the handle bar at (0, CART_HANDLE_HEIGHT, 0); the basket ahead, +z.
const BASKET = { w: 0.5, d: 0.72, h: 0.2, y: 0.5, z: 0.5 };
function cartGeometry(): T.BufferGeometry {
  const parts: T.BufferGeometry[] = [
    new T.CylinderGeometry(0.016, 0.016, 0.5, 8)
      .rotateZ(Math.PI / 2)
      .translate(0, CART_HANDLE_HEIGHT, 0),
    ...openBox(BASKET.w, BASKET.d, BASKET.h, 0.014).map((g) =>
      g.translate(0, BASKET.y, BASKET.z),
    ),
  ];
  for (const side of [-1, 1]) {
    parts.push(
      new T.BoxGeometry(0.02, 0.02, 0.2)
        .rotateX(-0.45)
        .translate(side * 0.23, CART_HANDLE_HEIGHT - 0.045, 0.08),
    );
    for (const end of [0, 1]) {
      const z = BASKET.z + (end ? 1 : -1) * (BASKET.d / 2 - 0.04);
      parts.push(
        new T.BoxGeometry(0.02, BASKET.y - 0.06, 0.02).translate(
          side * (BASKET.w / 2 - 0.03),
          0.06 + (BASKET.y - 0.06) / 2,
          z,
        ),
        new T.CylinderGeometry(0.055, 0.055, 0.03, 10)
          .rotateZ(Math.PI / 2)
          .translate(side * (BASKET.w / 2 - 0.03), 0.055, z),
      );
    }
  }
  return mergeGeometries(parts);
}

function starGeometry(): T.BufferGeometry {
  const shape = new T.Shape();
  for (let i = 0; i < 10; i++) {
    const r = i % 2 ? 0.032 : 0.075;
    const a = Math.PI / 2 + (i * Math.PI) / 5;
    if (i === 0) shape.moveTo(Math.cos(a) * r, Math.sin(a) * r);
    else shape.lineTo(Math.cos(a) * r, Math.sin(a) * r);
  }
  shape.closePath();
  return new T.ExtrudeGeometry(shape, {
    depth: 0.018,
    bevelEnabled: false,
  }).translate(0, 0, -0.009);
}

/** A price label from the panel, or a dash if the label cannot be made. */
function safely<A>(label: (value: A) => string, value: A): string {
  try {
    const text = label(value);
    return typeof text === "string" ? text : "";
  } catch {
    return "–";
  }
}

type Shopper = {
  restaurant: string;
  look: Look;
  pieces: { shape: ShapeId; colour: number }[];
  points: { x: number; z: number; pause: boolean }[];
  started: number;
  ends: number;
  still: boolean;
  vendor?: VendorId; // the stall a still shopper stands at
};

/** Where a shopper is `elapsed` ms into a trip along `points`. */
function shopperAt(
  shopper: Shopper,
  elapsed: number,
  out: { x: number; z: number; yaw: number; walking: boolean; stride: number },
) {
  const { points } = shopper;
  if (shopper.still) {
    const stop = points.find((p) => p.pause) ?? points[0];
    out.x = stop.x;
    out.z = stop.z;
    out.yaw = Math.PI / 2;
    out.walking = false;
    out.stride = 0;
    return;
  }
  let time = 0;
  let metres = 0;
  out.yaw = Math.PI / 2;
  for (let i = 0; i < points.length; i++) {
    const at = points[i];
    if (at.pause) {
      if (elapsed < time + PAUSE_MS) {
        out.x = at.x;
        out.z = at.z;
        out.walking = false;
        out.stride = 0;
        return;
      }
      time += PAUSE_MS;
    }
    const next = points[i + 1];
    if (!next) break;
    const length = Math.hypot(next.x - at.x, next.z - at.z);
    const duration = (length / WALK_SPEED) * 1000;
    out.yaw = Math.atan2(next.x - at.x, next.z - at.z);
    if (elapsed < time + duration) {
      const k = (elapsed - time) / duration;
      out.x = at.x + (next.x - at.x) * k;
      out.z = at.z + (next.z - at.z) * k;
      out.walking = true;
      out.stride = Math.sin((metres + length * k) * GAIT);
      return;
    }
    time += duration;
    metres += length;
  }
  const last = points[points.length - 1];
  out.x = last.x;
  out.z = last.z;
  out.walking = false;
  out.stride = 0;
}

function tripDuration(points: Shopper["points"]): number {
  let total = 0;
  for (let i = 0; i < points.length; i++) {
    if (points[i].pause) total += PAUSE_MS;
    const next = points[i + 1];
    if (next)
      total +=
        (Math.hypot(next.x - points[i].x, next.z - points[i].z) / WALK_SPEED) *
        1000;
  }
  return total;
}

export function createMarketScene(
  host: HTMLElement,
  actions: MarketActions,
): MarketScene {
  const renderer = new T.WebGLRenderer({
    antialias: true,
    alpha: false,
    powerPreference: "low-power",
  });
  renderer.setClearColor("#e8dcc6");
  renderer.outputColorSpace = T.SRGBColorSpace;
  const canvas = renderer.domElement;
  canvas.setAttribute("aria-hidden", "true");
  canvas.style.display = "block";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  canvas.style.touchAction = "manipulation";
  host.appendChild(canvas);
  const anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());

  const scene = new T.Scene();
  const camera = new T.PerspectiveCamera(CAMERA_FOV, 16 / 9, 0.2, 140);
  scene.add(
    new T.HemisphereLight("#fff4e0", "#8a7a68", 2.3),
    (() => {
      const key = new T.DirectionalLight("#fff1d8", 1.9);
      key.position.set(-5, 12, 9);
      return key;
    })(),
    (() => {
      const fill = new T.DirectionalLight("#cfe0ff", 0.6);
      fill.position.set(7, 5, 6);
      return fill;
    })(),
  );

  // Shared resources, built once.
  const unitBox = new T.BoxGeometry(1, 1, 1);
  const floorGeometry = new T.PlaneGeometry(400, 120).rotateX(-Math.PI / 2);
  const floorMaterial = new T.MeshStandardMaterial({
    color: "#bfae90",
    roughness: 0.95,
  });
  const floor = new T.Mesh(floorGeometry, floorMaterial);
  floor.position.z = -10;
  scene.add(floor);
  const solid = new T.MeshStandardMaterial({ roughness: 0.82 });
  const pieces = new Map(
    SHAPES.map((shape) => [shape, pieceGeometry(shape)] as const),
  );
  const pieceMaterial = new T.MeshStandardMaterial({ roughness: 0.65 });
  const crateGeo = crateGeometry();
  const cartGeo = cartGeometry();
  const starGeo = starGeometry();
  const lowGeo = new T.ConeGeometry(0.045, 0.1, 4).rotateX(Math.PI);
  const starMaterial = new T.MeshStandardMaterial({
    color: "#ffc93a",
    emissive: "#b07a00",
    emissiveIntensity: 0.55,
    roughness: 0.4,
    metalness: 0.2,
  });
  const lowMaterial = new T.MeshStandardMaterial({
    color: "#e2412b",
    emissive: "#8a1a0c",
    emissiveIntensity: 0.45,
    roughness: 0.5,
  });
  const hitMaterial = new T.MeshBasicMaterial({ visible: false });
  const markMaterial = (colour: string, opacity: number) =>
    new T.MeshBasicMaterial({
      color: colour,
      transparent: true,
      opacity,
      depthWrite: false,
    });
  const selectedMaterial = markMaterial("#ffcf3f", 0.32);
  const hoverMaterial = markMaterial("#ffffff", 0.22);
  const selectedMark = new T.Mesh(unitBox, selectedMaterial);
  const hoverMark = new T.Mesh(unitBox, hoverMaterial);
  selectedMark.visible = hoverMark.visible = false;
  selectedMark.renderOrder = hoverMark.renderOrder = 2;
  scene.add(selectedMark, hoverMark);

  function instanced(
    geometry: T.BufferGeometry,
    material: T.Material,
    capacity: number,
  ): T.InstancedMesh {
    const mesh = new T.InstancedMesh(geometry, material, Math.max(1, capacity));
    mesh.count = 0;
    mesh.frustumCulled = false;
    return mesh;
  }
  /** Flags the slots in use for upload, and hides an empty mesh. */
  function flush(mesh: T.InstancedMesh) {
    mesh.visible = mesh.count > 0;
    if (mesh.count === 0) return;
    const buffers: [T.BufferAttribute, number][] = [[mesh.instanceMatrix, 16]];
    if (mesh.instanceColor) buffers.push([mesh.instanceColor, 3]);
    for (const [buffer, size] of buffers) {
      buffer.clearUpdateRanges();
      buffer.addUpdateRange(0, mesh.count * size);
      buffer.needsUpdate = true;
    }
  }

  // The owner's cart and the rivals' carts share one batch; slot 0 is the owner's.
  const carts = instanced(cartGeo, solid, MAX_SHOPPERS + 1);
  const ownerCrates = instanced(unitBox, solid, 120);
  const arrivedLids = instanced(unitBox, solid, 120);
  const rivalPieces = new Map(
    SHAPES.map(
      (shape) =>
        [
          shape,
          instanced(
            pieces.get(shape) as T.BufferGeometry,
            pieceMaterial,
            9 * MAX_SHOPPERS,
          ),
        ] as const,
    ),
  );
  for (const mesh of [carts, ownerCrates, arrivedLids, ...rivalPieces.values()])
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
  scene.add(carts, ownerCrates, arrivedLids, ...rivalPieces.values());

  const faces = createFaceTexture();
  const people = createPeople(MAX_SHOPPERS, faces, 1);
  scene.add(...people.meshes);
  const shopperBoxes = Array.from({ length: MAX_SHOPPERS }, () => {
    const box = new T.Mesh(unitBox, hitMaterial);
    box.scale.set(0.7, 1.7, 1.6);
    box.visible = false;
    scene.add(box);
    return box;
  });

  // ---------------------------------------------------------------------
  // The stalls and their containers: rebuilt when the set of products changes.
  // ---------------------------------------------------------------------
  type Built = {
    key: string;
    layout: MarketLayout;
    index: Map<string, number>; // product -> container index
    goods: Good[]; // per container
    group: T.Group;
    disposables: { dispose(): void }[];
    crates: T.InstancedMesh;
    hits: T.InstancedMesh;
    beds: T.InstancedMesh;
    stars: T.InstancedMesh;
    lows: T.InstancedMesh;
    pieceMeshes: Map<ShapeId, T.InstancedMesh>;
    vendorHits: T.Mesh[];
    signs: { stall: Stall; material: T.MeshBasicMaterial; label: string }[];
    atlas: HTMLCanvasElement;
    atlasTexture: T.CanvasTexture;
    atlasColumns: number;
    cellKeys: string[];
  };
  let built: Built | null = null;

  const dummy = new T.Object3D();
  function place(
    mesh: T.InstancedMesh,
    x: number,
    y: number,
    z: number,
    sx = 1,
    sy = 1,
    sz = 1,
    yaw = 0,
    tilt = 0,
  ): number {
    dummy.position.set(x, y, z);
    dummy.rotation.set(tilt, yaw, 0);
    dummy.scale.set(sx, sy, sz);
    dummy.updateMatrix();
    const index = mesh.count++;
    mesh.setMatrixAt(index, dummy.matrix);
    return index;
  }

  function crateCentre(c: Placed): T.Vector3 {
    return new T.Vector3(c.x, c.y, c.z + CRATE_FORWARD);
  }
  // A container's pick box: the crate and its tag.
  const HIT = {
    w: PITCH_X * 0.92,
    h: TAG_BOTTOM + TAG_H + 0.04,
    back: TAG_BACK + 0.03,
    front: CRATE_D / 2 + 0.02,
  };
  function hitCentre(c: Placed): T.Vector3 {
    const centre = crateCentre(c);
    return new T.Vector3(
      centre.x,
      c.y + HIT.h / 2,
      centre.z + (HIT.front - HIT.back) / 2,
    );
  }
  // The tag leans back about its bottom edge: TAG_TILT about x.
  function tagCentre(c: Placed): T.Vector3 {
    const centre = crateCentre(c);
    return new T.Vector3(
      centre.x,
      c.y + TAG_BOTTOM + (TAG_H / 2) * Math.cos(TAG_TILT),
      centre.z - TAG_BACK + (TAG_H / 2) * Math.sin(TAG_TILT),
    );
  }

  function paintSign(stall: Stall, label: string): T.CanvasTexture | null {
    const sign = document.createElement("canvas");
    sign.width = 640;
    sign.height = 128;
    const ctx = sign.getContext("2d");
    if (!ctx) return null;
    SCRATCH.setHex(VENDOR_COLOURS[stall.vendor]).multiplyScalar(0.55);
    ctx.fillStyle = "#" + SCRATCH.getHexString();
    ctx.fillRect(0, 0, 640, 128);
    ctx.strokeStyle = "#fff3dc";
    ctx.lineWidth = 6;
    ctx.strokeRect(8, 8, 624, 112);
    ctx.fillStyle = "#fff6e6";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = `800 64px ${TAG_FONT}`;
    ctx.fillText(label, 320, 68, 590);
    const texture = new T.CanvasTexture(sign);
    texture.colorSpace = T.SRGBColorSpace;
    texture.anisotropy = anisotropy;
    return texture;
  }

  function stripes(): T.CanvasTexture | null {
    const c = document.createElement("canvas");
    c.width = 64;
    c.height = 4;
    const ctx = c.getContext("2d");
    if (!ctx) return null;
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, 64, 4);
    ctx.fillStyle = "#f6efe2";
    ctx.fillRect(32, 0, 32, 4);
    const texture = new T.CanvasTexture(c);
    texture.colorSpace = T.SRGBColorSpace;
    texture.wrapS = T.RepeatWrapping;
    return texture;
  }

  function build(key: string, products: string[]): Built {
    const layout = marketLayout(products);
    const group = new T.Group();
    const disposables: { dispose(): void }[] = [];
    const n = layout.containers.length;
    const goods = layout.containers.map((c) => goodFor(c.product));

    // Stands: stepped blocks, a back board, posts, a canopy and a sign.
    const blocks = instanced(
      unitBox,
      solid,
      layout.stalls.reduce((sum, stall) => sum + 2 * stall.tiers + 3, 0),
    );
    disposables.push(blocks);
    const stripeMap = stripes();
    if (stripeMap) disposables.push(stripeMap);
    const vendorHits: T.Mesh[] = [];
    const signs: Built["signs"] = [];
    const colour = (index: number, hex: number) =>
      blocks.setColorAt(index, SCRATCH.setHex(hex));
    for (const stall of layout.stalls) {
      for (let t = 0; t < stall.tiers; t++) {
        const y = BASE_Y + t * TIER_RISE;
        const i = place(
          blocks,
          stall.x,
          y / 2,
          -(t + 0.5) * TIER_DEPTH,
          stall.width,
          y,
          TIER_DEPTH,
        );
        colour(i, t % 2 ? 0x8a6446 : 0x7a573c);
        // A pale lip along each step's front edge.
        const lip = place(
          blocks,
          stall.x,
          y - 0.015,
          -t * TIER_DEPTH - 0.012,
          stall.width + 0.01,
          0.03,
          0.03,
        );
        colour(lip, 0xe9dcc2);
      }
      const back = -stall.depth - 0.05;
      // The sign hangs above the top step's tags, clear of them from the camera.
      const signW = Math.min(stall.width * 0.86, 4.2);
      const signH = Math.min(SIGN_MAX_H, signW / 5);
      const signBottom = stall.height + SIGN_BOTTOM;
      const boardTop = signBottom + signH + 0.08;
      const vendorColour = new T.Color(VENDOR_COLOURS[stall.vendor]);
      const board = place(
        blocks,
        stall.x,
        boardTop / 2,
        back,
        stall.width,
        boardTop,
        0.1,
      );
      blocks.setColorAt(board, SCRATCH.copy(vendorColour).lerp(WHITE, 0.55));
      for (const side of [-1, 1]) {
        const post = place(
          blocks,
          stall.x + side * (stall.width / 2 - 0.05),
          (boardTop + 0.35) / 2,
          back + 0.12,
          0.1,
          boardTop + 0.35,
          0.1,
        );
        colour(post, 0x5a3f2c);
      }
      // Canopy over the top step, striped in the vendor's colour.
      const canopyMaterial = new T.MeshStandardMaterial({
        color: vendorColour,
        map: stripeMap,
        roughness: 0.8,
      });
      disposables.push(canopyMaterial);
      const canopyGeometry = new T.BoxGeometry(stall.width + 0.3, 0.05, 0.9);
      const uv = canopyGeometry.attributes.uv;
      for (let i = 0; i < uv.count; i++)
        uv.setX(i, uv.getX(i) * Math.round((stall.width + 0.3) / 0.35));
      disposables.push(canopyGeometry);
      const canopy = new T.Mesh(canopyGeometry, canopyMaterial);
      canopy.position.set(stall.x, boardTop + 0.12, back + 0.42);
      canopy.rotation.x = 0.28;
      canopy.userData.vendor = stall.vendor;
      group.add(canopy);
      // The sign hangs from the canopy's front edge.
      const signGeometry = new T.PlaneGeometry(signW, signH);
      disposables.push(signGeometry);
      const signMaterial = new T.MeshBasicMaterial({ color: 0xffffff });
      disposables.push(signMaterial);
      const sign = new T.Mesh(signGeometry, signMaterial);
      sign.position.set(stall.x, signBottom + signH / 2, back + 0.86);
      sign.rotation.x = -0.12;
      sign.userData.vendor = stall.vendor;
      group.add(sign);
      signs.push({ stall, material: signMaterial, label: "" });
      // One box covers the whole stall for "focus this vendor".
      const hit = new T.Mesh(unitBox, hitMaterial);
      hit.scale.set(stall.width, boardTop + 0.3, stall.depth + 1.2);
      hit.position.set(stall.x, (boardTop + 0.3) / 2, -stall.depth / 2 + 0.5);
      hit.userData.vendor = stall.vendor;
      group.add(hit);
      vendorHits.push(hit, canopy, sign);
    }
    flush(blocks);
    blocks.computeBoundingSphere();
    group.add(blocks);

    // Containers: crates in their variant's colour, and pick boxes.
    const crates = instanced(crateGeo, solid, n);
    const hits = instanced(unitBox, hitMaterial, n);
    const index = new Map<string, number>();
    layout.containers.forEach((c, i) => {
      index.set(c.product, i);
      const centre = crateCentre(c);
      place(crates, centre.x, c.y, centre.z);
      crates.setColorAt(i, SCRATCH.setHex(CRATE_COLOURS[goods[i].variant]));
      const box = hitCentre(c);
      place(hits, box.x, box.y, box.z, HIT.w, HIT.h, HIT.back + HIT.front);
    });
    flush(crates);
    hits.count = n;
    hits.computeBoundingSphere();
    disposables.push(crates, hits);
    group.add(crates, hits);

    // Dynamic per update: loose goods, pieces, stars and low markers.
    const beds = instanced(unitBox, pieceMaterial, n);
    const stars = instanced(starGeo, starMaterial, n);
    const lows = instanced(lowGeo, lowMaterial, n);
    const pieceMeshes = new Map<ShapeId, T.InstancedMesh>();
    const perShape = new Map<ShapeId, number>();
    for (const good of goods)
      perShape.set(pieceShape(good), (perShape.get(pieceShape(good)) ?? 0) + 1);
    for (const [shape, count] of perShape) {
      const mesh = instanced(
        pieces.get(shape) as T.BufferGeometry,
        pieceMaterial,
        count * GOODS_PER_CONTAINER,
      );
      pieceMeshes.set(shape, mesh);
    }
    for (const mesh of [beds, stars, lows, ...pieceMeshes.values()]) {
      disposables.push(mesh);
      group.add(mesh);
    }

    // Tags: one quad per container into a shared canvas atlas.
    const atlasColumns = Math.max(
      1,
      Math.ceil(Math.sqrt((n * CELL_H) / CELL_W)),
    );
    const atlasRows = Math.max(1, Math.ceil(n / atlasColumns));
    const atlas = document.createElement("canvas");
    atlas.width = atlasColumns * CELL_W;
    atlas.height = atlasRows * CELL_H;
    const atlasTexture = new T.CanvasTexture(atlas);
    atlasTexture.colorSpace = T.SRGBColorSpace;
    atlasTexture.anisotropy = anisotropy;
    const positions = new Float32Array(n * 12);
    const uvs = new Float32Array(n * 8);
    const indices: number[] = [];
    const corner = new T.Vector3();
    const tilt = new T.Matrix4().makeRotationX(TAG_TILT);
    layout.containers.forEach((c, i) => {
      const centre = crateCentre(c);
      const base = new T.Vector3(
        centre.x,
        c.y + TAG_BOTTOM,
        centre.z - TAG_BACK,
      );
      const quad: [number, number][] = [
        [-TAG_W / 2, 0],
        [TAG_W / 2, 0],
        [TAG_W / 2, TAG_H],
        [-TAG_W / 2, TAG_H],
      ];
      quad.forEach(([dx, dy], k) => {
        corner.set(dx, dy, 0).applyMatrix4(tilt).add(base);
        positions.set([corner.x, corner.y, corner.z], i * 12 + k * 3);
      });
      const col = i % atlasColumns;
      const row = Math.floor(i / atlasColumns);
      const u0 = (col * CELL_W + 1) / atlas.width;
      const u1 = ((col + 1) * CELL_W - 1) / atlas.width;
      const v1 = 1 - (row * CELL_H + 1) / atlas.height;
      const v0 = 1 - ((row + 1) * CELL_H - 1) / atlas.height;
      uvs.set([u0, v0, u1, v0, u1, v1, u0, v1], i * 8);
      const v = i * 4;
      indices.push(v, v + 1, v + 2, v, v + 2, v + 3);
    });
    const tagGeometry = new T.BufferGeometry();
    tagGeometry.setAttribute("position", new T.BufferAttribute(positions, 3));
    tagGeometry.setAttribute("uv", new T.BufferAttribute(uvs, 2));
    tagGeometry.setIndex(indices);
    const tagMaterial = new T.MeshBasicMaterial({ map: atlasTexture });
    const tags = new T.Mesh(tagGeometry, tagMaterial);
    disposables.push(tagGeometry, tagMaterial, atlasTexture);
    group.add(tags);

    scene.add(group);
    return {
      key,
      layout,
      index,
      goods,
      group,
      disposables,
      crates,
      hits,
      beds,
      stars,
      lows,
      pieceMeshes,
      vendorHits,
      signs,
      atlas,
      atlasTexture,
      atlasColumns,
      cellKeys: Array.from({ length: n }, () => ""),
    };
  }

  function discard(old: Built) {
    scene.remove(old.group);
    for (const sign of old.signs) sign.material.map?.dispose();
    for (const item of old.disposables) item.dispose();
  }

  // ---------------------------------------------------------------------
  // Per update: what the containers hold, tags, stars, the owner's cart.
  // ---------------------------------------------------------------------
  let fontsRequested = false;
  function paintTags(b: Built, next: MarketAppearance, force = false) {
    const ctx = b.atlas.getContext("2d");
    if (!ctx) return;
    let dirty = false;
    b.layout.containers.forEach((c, i) => {
      const entry = next.market[c.product];
      const level = levelOf(entry?.level);
      const price = entry ? safely(next.priceLabel, entry.price) : "";
      const crate =
        entry && typeof entry.crate === "number" && Number.isFinite(entry.crate)
          ? safely(next.crateLabel, entry.crate)
          : "";
      const variant = b.goods[i].variant;
      const low = level < LOW_LEVEL;
      const empty = outOfStock(entry?.stock);
      const key = `${price}\u0000${crate}\u0000${variant}\u0000${low}\u0000${empty}`;
      if (!force && b.cellKeys[i] === key) return;
      b.cellKeys[i] = key;
      dirty = true;
      const x = (i % b.atlasColumns) * CELL_W;
      const y = Math.floor(i / b.atlasColumns) * CELL_H;
      paintTag(ctx, x, y, price, crate, variant, low, empty);
    });
    if (dirty) b.atlasTexture.needsUpdate = true;
    if (!fontsRequested && typeof document.fonts?.load === "function") {
      fontsRequested = true;
      const font = `800 40px ${TAG_FONT}`;
      if (!document.fonts.check(font, "0123456789"))
        void document.fonts
          .load(font, "0123456789")
          .then(() => {
            if (disposed || !built || !appearance) return;
            paintTags(built, appearance, true);
            for (const sign of built.signs) sign.label = "";
            paintSigns(built, appearance);
            draw();
          })
          .catch(() => {});
    }
  }

  function paintTag(
    ctx: CanvasRenderingContext2D,
    x: number,
    y: number,
    price: string,
    crate: string,
    variant: VariantId,
    low: boolean,
    empty: boolean,
  ) {
    ctx.save();
    ctx.translate(x, y);
    ctx.clearRect(0, 0, CELL_W, CELL_H);
    const border = low ? 9 : 4;
    ctx.fillStyle = low ? "#e2412b" : "#4a3626";
    roundRect(ctx, 0, 0, CELL_W, CELL_H, 12);
    ctx.fill();
    ctx.fillStyle = empty
      ? "#d8d2c8"
      : variant === "frozen"
        ? "#dcefff"
        : "#fff8e8";
    roundRect(ctx, border, border, CELL_W - 2 * border, CELL_H - 2 * border, 9);
    ctx.fill();
    let left = border + 4;
    if (variant === "frozen") {
      snowflake(ctx, left + 15, CELL_H / 2, 13);
      left += 32;
    }
    const right = CELL_W - border - 4;
    const width = right - left;
    const centre = left + width / 2;
    ctx.fillStyle = empty ? "#7d746a" : "#22180f";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (crate) {
      ctx.font = `800 46px ${TAG_FONT}`;
      ctx.fillText(price, centre, CELL_H * 0.37, width);
      ctx.font = `700 27px ${TAG_FONT}`;
      ctx.fillStyle = empty ? "#7d746a" : "#5a4636";
      ctx.fillText(crate, centre, CELL_H * 0.78, width);
    } else {
      ctx.font = `800 52px ${TAG_FONT}`;
      ctx.fillText(price, centre, CELL_H / 2 + 2, width);
    }
    ctx.restore();
  }

  function paintSigns(b: Built, next: MarketAppearance) {
    for (const sign of b.signs) {
      const label = safely(next.vendorLabel, sign.stall.vendor);
      if (label === sign.label) continue;
      sign.label = label;
      const map = paintSign(sign.stall, label);
      sign.material.map?.dispose();
      sign.material.map = map;
      sign.material.needsUpdate = true;
    }
  }

  function fillContainers(b: Built, next: MarketAppearance) {
    const starred = new Set(next.starred);
    b.beds.count = b.stars.count = b.lows.count = 0;
    for (const mesh of b.pieceMeshes.values()) mesh.count = 0;
    b.layout.containers.forEach((c, i) => {
      const good = b.goods[i];
      const entry = next.market[c.product];
      const level = levelOf(entry?.level);
      const fill = containerFill(entry?.stock, level);
      const centre = crateCentre(c);
      const colour = pieceColour(good);
      let surface = c.y + FLOOR_Y;
      if (fill > 0) {
        const depth = BED_MAX * fill;
        const bed = place(
          b.beds,
          centre.x,
          surface + depth / 2,
          centre.z,
          CRATE_W - 0.06,
          depth,
          CRATE_D - 0.05,
        );
        b.beds.setColorAt(bed, SCRATCH.setHex(colour).multiplyScalar(0.72));
        surface += depth;
        const mesh = b.pieceMeshes.get(pieceShape(good)) as T.InstancedMesh;
        const count = Math.max(1, Math.round(fill * GOODS_PER_CONTAINER));
        for (let k = 0; k < count; k++) {
          const [dx, dz] = GOOD_SLOTS[k];
          const piece = place(
            mesh,
            centre.x + dx,
            surface,
            centre.z + dz,
            1,
            1,
            1,
            ((i * 7 + k * 3) % 5) * 0.35 - 0.7,
          );
          mesh.setColorAt(piece, SCRATCH.setHex(colour));
        }
      }
      const tagTop = c.y + TAG_BOTTOM + TAG_H * Math.cos(TAG_TILT);
      const tagZ = centre.z - TAG_BACK + TAG_H * Math.sin(TAG_TILT);
      if (starred.has(c.product))
        place(
          b.stars,
          centre.x + TAG_W / 2 - 0.05,
          tagTop + 0.02,
          tagZ + 0.03,
          1.25,
          1.25,
          1.25,
          0,
          TAG_TILT,
        );
      if (level < LOW_LEVEL)
        place(b.lows, centre.x - TAG_W / 2 + 0.06, tagTop + 0.08, tagZ + 0.02);
    });
    for (const mesh of [b.beds, b.stars, b.lows, ...b.pieceMeshes.values()])
      flush(mesh);
  }

  // Where the owner's cart's handle is: in the gap right of the focused
  // stall, its basket towards the stalls; in the aisle for the whole row.
  function ownerCartSpot(b: Built | null, vendor: VendorId | null) {
    const stall = b?.layout.stalls.find((s) => s.vendor === vendor);
    if (stall) return { x: stall.x + stall.width / 2 + STALL_GAP / 2, z: 0.25 };
    return { x: 0, z: 1.6 };
  }

  function fillOwnerCart(next: MarketAppearance) {
    ownerCrates.count = 0;
    const spot = ownerCartSpot(built, next.focusedVendor);
    // Parked with its basket towards the stalls (yaw pi: forward is -z).
    const yaw = Math.PI;
    carts.count = Math.max(carts.count, 1);
    dummy.position.set(spot.x, 0, spot.z);
    dummy.rotation.set(0, yaw, 0);
    dummy.scale.set(1, 1, 1);
    dummy.updateMatrix();
    carts.setMatrixAt(0, dummy.matrix);
    carts.setColorAt(0, SCRATCH.setHex(OWNER_CART));
    const size = 0.095;
    const pitchX = (BASKET.w - 0.05) / 4;
    const pitchZ = (BASKET.d - 0.05) / 6;
    let slot = 0;
    arrivedLids.count = 0;
    // Arrived crates first, at the bottom, so new draft crates never hide them.
    const lines = [
      ...(next.arrived ?? []).map((line) => ({ ...line, arrived: true })),
      ...next.cart.map((line) => ({ ...line, arrived: false })),
    ];
    for (const line of lines) {
      const crates = Math.min(
        CART_CRATES_PER_LINE,
        Math.max(0, Math.floor(line.crates)),
      );
      const colour = pieceColour(goodFor(line.product));
      for (
        let k = 0;
        k < crates && slot < ownerCrates.instanceMatrix.count;
        k++
      ) {
        const layer = Math.floor(slot / 24);
        const col = slot % 4;
        const row = Math.floor((slot % 24) / 4);
        // Basket-local, then turned to the cart's heading.
        const lx = (col - 1.5) * pitchX;
        const lz = BASKET.z - BASKET.d / 2 + 0.025 + (row + 0.5) * pitchZ;
        const index = place(
          ownerCrates,
          spot.x - lx,
          BASKET.y + 0.02 + size / 2 + layer * size,
          spot.z - lz,
          size,
          size,
          size,
        );
        ownerCrates.setColorAt(index, SCRATCH.setHex(colour));
        if (line.arrived) {
          const lid = place(
            arrivedLids,
            spot.x - lx,
            BASKET.y + 0.02 + size + layer * size + 0.012,
            spot.z - lz,
            size * 1.15,
            0.024,
            size * 1.15,
          );
          arrivedLids.setColorAt(lid, SCRATCH.setHex(ARRIVED_LID));
        }
        slot++;
      }
    }
    flush(ownerCrates);
    flush(arrivedLids);
  }

  // ---------------------------------------------------------------------
  // Shoppers.
  // ---------------------------------------------------------------------
  const shoppers: Shopper[] = [];
  // The newest clearing staged or seen; null until the first update.
  let tripMark: number | null = null;

  function stageNewTrips(next: MarketAppearance, now: number) {
    const { staged, mark } = stageTrips(
      next.trips,
      tripMark,
      next.ownRestaurant,
    );
    tripMark = mark;
    if (!built) return;
    let slot = 0;
    for (const trip of staged) {
      const route = tripRoute(trip.products, built.layout);
      const still = !next.motion;
      let points: Shopper["points"];
      let vendor: VendorId | undefined;
      if (still) {
        // Without motion, the shopper stands in the aisle in front of the
        // first stall they buy from, beside any already standing there.
        const stop = route.find((point) => point.pause);
        const stall = built.layout.stalls.find((s) => s.x === stop?.x);
        if (!stall) continue;
        vendor = stall.vendor;
        const standing = shoppers.filter(
          (s) => s.still && s.vendor === vendor && now < s.ends,
        ).length;
        points = [{ ...standingSpot(stall, standing), pause: true }];
      } else {
        // Shoppers staged together keep to alternate sides of the aisle and
        // stop a little apart.
        const behind = (slot % 4) * STAND_SPACING;
        const lane = slot % 2 ? LANE_OFFSET : -LANE_OFFSET / 2;
        points = route.map((point) => ({
          x: point.pause ? point.x - behind : point.x,
          z: point.z + lane,
          pause: point.pause,
        }));
      }
      if (points.length === 0) continue;
      const products = trip.products.length ? trip.products : [""];
      const pieceList = Array.from({ length: cartGoods(trip.size) }, (_, k) => {
        const good = goodFor(products[k % products.length]);
        return { shape: pieceShape(good), colour: pieceColour(good) };
      });
      shoppers.push({
        restaurant: trip.restaurant_id,
        look: personLook(serialFor("owner:" + trip.restaurant_id), "owner"),
        pieces: pieceList,
        points,
        // Walkers staged together set off one after another.
        started: still ? now : now + slot * STAGGER_MS,
        ends:
          now +
          (still ? STILL_SHOPPER_MS : slot * STAGGER_MS + tripDuration(points)),
        still,
        vendor,
      });
      slot++;
      while (shoppers.length > MAX_SHOPPERS) shoppers.shift();
    }
  }

  const figure: Pose = {
    x: 0,
    z: 0,
    yaw: 0,
    faceYaw: 0,
    stride: 0,
    walking: false,
    carrying: false,
    pushing: true,
    seated: false,
  };
  const where = { x: 0, z: 0, yaw: 0, walking: false, stride: 0 };
  let drawnShoppers = -1;

  /** Sends home shoppers whose time is up. */
  function pruneShoppers(now: number) {
    for (let i = shoppers.length - 1; i >= 0; i--)
      if (now >= shoppers[i].ends) shoppers.splice(i, 1);
  }

  function drawShoppers(now: number) {
    pruneShoppers(now);
    people.begin();
    carts.count = 1;
    for (const mesh of rivalPieces.values()) mesh.count = 0;
    shoppers.forEach((shopper, n) => {
      shopperAt(shopper, Math.max(0, now - shopper.started), where);
      figure.x = where.x;
      figure.z = where.z;
      figure.yaw = where.yaw;
      figure.walking = where.walking;
      figure.stride = where.stride;
      figure.faceYaw = where.walking ? 0 : 0.55; // a look at the stall
      people.add(shopper.look, figure, "full");
      const handle = cartHandlePoint(shopper.look, figure.stride);
      const sin = Math.sin(where.yaw);
      const cos = Math.cos(where.yaw);
      const cx = where.x + sin * handle.forward;
      const cz = where.z + cos * handle.forward;
      const cart = place(carts, cx, 0, cz, 1, 1, 1, where.yaw);
      carts.setColorAt(cart, SCRATCH.setHex(RIVAL_CART));
      shopper.pieces.forEach((piece, k) => {
        const lx = ((k % 3) - 1) * 0.14;
        const lz = BASKET.z + (Math.floor(k / 3) - 1) * 0.2;
        const mesh = rivalPieces.get(piece.shape) as T.InstancedMesh;
        const index = place(
          mesh,
          cx + cos * lx + sin * lz,
          BASKET.y + 0.015,
          cz - sin * lx + cos * lz,
          1.4,
          1.4,
          1.4,
          where.yaw + k,
        );
        mesh.setColorAt(index, SCRATCH.setHex(piece.colour));
      });
      const box = shopperBoxes[n];
      box.position.set(where.x + sin * 0.35, 0.85, where.z + cos * 0.35);
      box.rotation.y = where.yaw;
      box.userData.restaurant = shopper.restaurant;
    });
    for (let n = 0; n < shopperBoxes.length; n++)
      shopperBoxes[n].userData.active = n < shoppers.length;
    people.end();
    flush(carts);
    for (const mesh of rivalPieces.values()) flush(mesh);
    if (shoppers.length !== drawnShoppers) {
      drawnShoppers = shoppers.length;
      host.setAttribute("data-market-shoppers", String(drawnShoppers));
    }
  }

  // ---------------------------------------------------------------------
  // Camera.
  // ---------------------------------------------------------------------
  const from = { position: new T.Vector3(), target: new T.Vector3() };
  const to = { position: new T.Vector3(), target: new T.Vector3() };
  const lookAt = new T.Vector3();
  let easeStart = 0;
  let easing = false;
  let cameraPlaced = false;
  let posedFor: VendorId | null | undefined = undefined;

  function goalPose(): CameraPose {
    const aspect = camera.aspect;
    const stalls = built?.layout.stalls ?? [];
    const stall = stalls.find((s) => s.vendor === appearance?.focusedVendor);
    return stall ? vendorPose(stall, aspect) : overviewPose(stalls, aspect);
  }

  function aim(cut: boolean) {
    const pose = goalPose();
    to.position.set(...pose.position);
    to.target.set(...pose.target);
    if (cut || !cameraPlaced || !appearance?.motion) {
      camera.position.copy(to.position);
      lookAt.copy(to.target);
      camera.lookAt(lookAt);
      easing = false;
      cameraPlaced = true;
      return;
    }
    from.position.copy(camera.position);
    from.target.copy(lookAt);
    easeStart = performance.now();
    easing = true;
  }

  function stepCamera(now: number) {
    if (!easing) return;
    const k = Math.min(1, (now - easeStart) / EASE_MS);
    const s = k * k * (3 - 2 * k);
    camera.position.lerpVectors(from.position, to.position, s);
    lookAt.lerpVectors(from.target, to.target, s);
    camera.lookAt(lookAt);
    if (k >= 1) easing = false;
  }

  // ---------------------------------------------------------------------
  // Picking.
  // ---------------------------------------------------------------------
  const ray = new T.Raycaster();
  const cursor = new T.Vector2();
  /** Points the pick ray at (x, y), CSS px from the canvas's top-left. */
  function aimRay(x: number, y: number): boolean {
    const bounds = canvas.getBoundingClientRect();
    if (!built || !bounds.width || !bounds.height) return false;
    cursor.set((x / bounds.width) * 2 - 1, -(y / bounds.height) * 2 + 1);
    ray.setFromCamera(cursor, camera);
    return true;
  }
  /** The container or stall on the ray, ignoring shoppers: they never block a click. */
  function targetOnRay(): PointerTarget {
    if (!built) return null;
    const containerHit = ray.intersectObject(built.hits, false)[0];
    if (containerHit?.instanceId !== undefined) {
      const { product, vendor } =
        built.layout.containers[containerHit.instanceId];
      return { kind: "container", product, vendor };
    }
    const vendorHit = ray.intersectObjects(built.vendorHits, false)[0];
    return vendorHit
      ? { kind: "stall", vendor: vendorHit.object.userData.vendor as VendorId }
      : null;
  }
  function targetAt(x: number, y: number): PointerTarget {
    return aimRay(x, y) ? targetOnRay() : null;
  }
  /** The restaurant of a shopper on the ray, or "". */
  function shopperOnRay(): string {
    const hit = ray.intersectObjects(
      shopperBoxes.filter((box) => box.userData.active),
      false,
    )[0];
    return hit ? (hit.object.userData.restaurant as string) : "";
  }
  function eventPoint(event: PointerEvent): [number, number] {
    const bounds = canvas.getBoundingClientRect();
    return [event.clientX - bounds.left, event.clientY - bounds.top];
  }

  let hoverProduct = "";
  let hoverRestaurant = "";
  function setHover(product: string, restaurant: string) {
    if (product !== hoverProduct) {
      hoverProduct = product;
      actions.hover(product);
      draw();
    }
    if (restaurant !== hoverRestaurant) {
      hoverRestaurant = restaurant;
      actions.hoverShopper(
        restaurant && appearance
          ? safely(appearance.restaurantName, restaurant)
          : "",
      );
    }
  }

  let press: [number, number] | null = null;
  function down(event: PointerEvent) {
    press = [event.clientX, event.clientY];
  }
  function up(event: PointerEvent) {
    const start = press;
    press = null;
    if (
      !start ||
      event.button !== 0 ||
      Math.hypot(event.clientX - start[0], event.clientY - start[1]) > 6
    )
      return;
    const outcome = clickOutcome(
      targetAt(...eventPoint(event)),
      appearance?.focusedVendor ?? null,
    );
    if (outcome.action === "add") actions.add(outcome.product);
    else if (outcome.action === "focus") actions.focusVendor(outcome.vendor);
  }
  function move(event: PointerEvent) {
    if (event.buttons !== 0) return;
    if (!aimRay(...eventPoint(event))) return leave();
    const focused = appearance?.focusedVendor ?? null;
    const target = targetOnRay();
    canvas.style.cursor =
      clickOutcome(target, focused).action === "none" ? "" : "pointer";
    // A shopper under the pointer is named instead of the goods behind them.
    const shopper = shopperOnRay();
    setHover(shopper ? "" : hoveredProduct(target, focused), shopper);
  }
  function leave() {
    canvas.style.cursor = "";
    setHover("", "");
  }
  function lost(event: Event) {
    event.preventDefault();
    actions.fail();
  }
  canvas.addEventListener("pointerdown", down);
  canvas.addEventListener("pointerup", up);
  canvas.addEventListener("pointermove", move);
  canvas.addEventListener("pointerleave", leave);
  canvas.addEventListener("webglcontextlost", lost);

  // ---------------------------------------------------------------------
  // Drawing on demand.
  // ---------------------------------------------------------------------
  let appearance: MarketAppearance | null = null;
  let visible = true;
  let disposed = false;
  let animating = false;
  let frame = 0;
  let lastFrame = 0;
  let stillTimer: ReturnType<typeof setTimeout> | undefined;
  let hitAttribute = "";

  function mark(mesh: T.Mesh, product: string) {
    const i = built?.index.get(product);
    if (!built || i === undefined) {
      mesh.visible = false;
      return;
    }
    const centre = hitCentre(built.layout.containers[i]);
    mesh.position.copy(centre);
    mesh.scale.set(HIT.w + 0.04, HIT.h + 0.04, HIT.back + HIT.front + 0.04);
    mesh.visible = true;
  }

  // For browser tests: a point where a real click calls add(selected). Set
  // only when the selected product's vendor is focused, the camera has
  // settled, and the pick there (shoppers ignored, as for a click) is that
  // product; otherwise absent.
  function updateHitAttribute() {
    let value = "";
    const selected = appearance?.selected ?? "";
    const i = built?.index.get(selected);
    if (built && i !== undefined && !easing) {
      const c = built.layout.containers[i];
      const bounds = canvas.getBoundingClientRect();
      for (const point of [hitCentre(c), tagCentre(c), crateCentre(c)]) {
        const ndc = point.clone().project(camera);
        if (ndc.z > 1 || Math.abs(ndc.x) > 0.98 || Math.abs(ndc.y) > 0.98)
          continue;
        const x = Math.round(((ndc.x + 1) / 2) * bounds.width);
        const y = Math.round(((1 - ndc.y) / 2) * bounds.height);
        const outcome = clickOutcome(
          targetAt(x, y),
          appearance?.focusedVendor ?? null,
        );
        if (outcome.action === "add" && outcome.product === selected) {
          value = `${selected}:${x},${y}`;
          break;
        }
      }
    }
    if (value === hitAttribute) return;
    hitAttribute = value;
    if (value) host.setAttribute("data-market-hit", value);
    else host.removeAttribute("data-market-hit");
  }

  function draw(now = performance.now()) {
    if (disposed || !visible || document.hidden) return;
    stepCamera(now);
    drawShoppers(now);
    mark(selectedMark, appearance?.selected ?? "");
    mark(hoverMark, hoverProduct !== appearance?.selected ? hoverProduct : "");
    try {
      renderer.render(scene, camera);
    } catch {
      actions.fail();
      return;
    }
    updateHitAttribute();
  }

  function animate(now: number) {
    if (!animating || disposed) return;
    if (now - lastFrame >= FRAME_MS) {
      lastFrame = now;
      draw(now);
      schedule();
    }
    if (animating) frame = requestAnimationFrame(animate);
  }

  function schedule() {
    const now = performance.now();
    pruneShoppers(now);
    const walking = shoppers.some((s) => !s.still);
    const next =
      visible && !document.hidden && !disposed && (easing || walking);
    clearTimeout(stillTimer);
    stillTimer = undefined;
    // A standing shopper needs one more frame, when they leave.
    // Never while hidden: the visibilitychange handler and setVisible(true)
    // call schedule again when the scene can be seen.
    if (
      !next &&
      shoppers.length > 0 &&
      visible &&
      !document.hidden &&
      !disposed
    ) {
      const due = Math.min(...shoppers.map((s) => s.ends)) - now;
      stillTimer = setTimeout(
        () => {
          draw();
          schedule();
        },
        Math.max(0, due) + 20,
      );
    }
    if (animating === next) return;
    animating = next;
    if (next) {
      lastFrame = 0;
      frame = requestAnimationFrame(animate);
    } else cancelAnimationFrame(frame);
  }

  const resize = new ResizeObserver(() => {
    if (!host.clientWidth || !host.clientHeight) return;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(host.clientWidth, host.clientHeight, false);
    camera.aspect = host.clientWidth / host.clientHeight;
    camera.updateProjectionMatrix();
    if (appearance) aim(!easing);
    draw();
  });
  resize.observe(host);
  function visibility() {
    schedule();
    draw();
  }
  document.addEventListener("visibilitychange", visibility);

  host.setAttribute("data-market-containers", "0");
  host.setAttribute("data-market-shoppers", "0");
  host.setAttribute("data-market-cart", "0");
  host.setAttribute("data-market-arrived", "0");
  host.setAttribute("data-market-vendor", "");

  return {
    update(next) {
      if (disposed) return;
      const now = performance.now();
      appearance = next;
      const products = Object.keys(next.market).sort();
      const key = products.join("\u0000");
      const rebuilt = !built || built.key !== key;
      if (!built || rebuilt) {
        if (built) discard(built);
        built = build(key, products);
      }
      paintTags(built, next);
      paintSigns(built, next);
      fillContainers(built, next);
      fillOwnerCart(next);
      stageNewTrips(next, now);
      // A new set of products moves the stalls: cut to the new pose.
      if (rebuilt || posedFor !== next.focusedVendor) {
        aim(rebuilt);
        posedFor = next.focusedVendor;
      }
      host.setAttribute(
        "data-market-containers",
        String(built.layout.containers.length),
      );
      host.setAttribute(
        "data-market-cart",
        String(
          next.cart.reduce(
            (sum, line) =>
              sum +
              (Number.isFinite(line.crates) ? Math.max(0, line.crates) : 0),
            0,
          ),
        ),
      );
      host.setAttribute(
        "data-market-arrived",
        String(
          (next.arrived ?? []).reduce(
            (sum, line) =>
              sum +
              (Number.isFinite(line.crates) ? Math.max(0, line.crates) : 0),
            0,
          ),
        ),
      );
      host.setAttribute("data-market-vendor", next.focusedVendor ?? "");
      // A product named by the pointer stops being named when its stall is
      // no longer the focused one, or it leaves the market.
      const hovered = built.index.get(hoverProduct);
      if (
        hoverProduct &&
        (hovered === undefined ||
          built.layout.containers[hovered].vendor !== next.focusedVendor)
      )
        setHover("", hoverRestaurant);
      draw(now);
      schedule();
    },
    setVisible(next) {
      if (disposed || visible === next) return;
      visible = next;
      if (visible) draw();
      schedule();
    },
    dispose() {
      disposed = true;
      cancelAnimationFrame(frame);
      clearTimeout(stillTimer);
      resize.disconnect();
      document.removeEventListener("visibilitychange", visibility);
      canvas.removeEventListener("pointerdown", down);
      canvas.removeEventListener("pointerup", up);
      canvas.removeEventListener("pointermove", move);
      canvas.removeEventListener("pointerleave", leave);
      canvas.removeEventListener("webglcontextlost", lost);
      if (built) discard(built);
      built = null;
      people.dispose();
      faces?.dispose();
      for (const mesh of [
        carts,
        ownerCrates,
        arrivedLids,
        ...rivalPieces.values(),
      ])
        mesh.dispose();
      for (const geometry of [
        unitBox,
        floorGeometry,
        crateGeo,
        cartGeo,
        starGeo,
        lowGeo,
        ...pieces.values(),
      ])
        geometry.dispose();
      for (const material of [
        floorMaterial,
        solid,
        pieceMaterial,
        starMaterial,
        lowMaterial,
        hitMaterial,
        selectedMaterial,
        hoverMaterial,
      ])
        material.dispose();
      for (const attribute of [
        "data-market-containers",
        "data-market-shoppers",
        "data-market-cart",
        "data-market-arrived",
        "data-market-vendor",
        "data-market-hit",
      ])
        host.removeAttribute(attribute);
      renderer.dispose();
      renderer.forceContextLoss();
      canvas.remove();
    },
  };
}

/** A level from the server, or full when an older server sends none. */
function levelOf(level: number | undefined): number {
  if (typeof level !== "number" || !Number.isFinite(level)) return 1000;
  return Math.min(1000, Math.max(0, level));
}

function roundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function snowflake(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  r: number,
) {
  ctx.save();
  ctx.strokeStyle = "#2f74b5";
  ctx.lineWidth = 3.5;
  ctx.lineCap = "round";
  for (let k = 0; k < 3; k++) {
    const a = (k * Math.PI) / 3 + Math.PI / 2;
    ctx.beginPath();
    ctx.moveTo(x - Math.cos(a) * r, y - Math.sin(a) * r);
    ctx.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r);
    ctx.stroke();
  }
  ctx.restore();
}
