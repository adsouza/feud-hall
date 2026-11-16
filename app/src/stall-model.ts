import * as T from "three";
import type { SpotPlacement } from "./room-layout";

export const SHUTTER_SLATS = 9;
export const SHUTTER_HEIGHT = 0.91;
export const SHUTTER_FONT = '900 79px "Noto Sans JP", system-ui, sans-serif';
/** Where the shutter's top edge hangs: the canopy line. */
const SHUTTER_Y = 1.38;

/** What a stall's looks depend on; both scenes colour a cuisine the same way. */
export type StallLook = { cuisine: string };
export type StallParts = {
  root: T.Group;
  trim: T.Group;
  shutters: T.Mesh;
  sign: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
};

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

export const hash = (value: string) =>
  [...value].reduce((sum, char) => (sum * 31 + char.charCodeAt(0)) >>> 0, 0);

/** The accent colour a cuisine's stall is painted in. */
export function stallAccent(cuisine: string) {
  return new T.Color(hues[hash(cuisine) % hues.length]);
}

export function shutterTexture(label: string) {
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

/**
 * The decorative stall: walls, slate, canopy and trim, counter, shutters and
 * name sign. Live-only parts (tablet, pickup, lamp, placard) are the caller's.
 * Materials and geometry here are shared by every stall built from one kit;
 * `dispose()` releases them, not the box passed in or the sign textures.
 */
export function createStallKit(
  box: T.BoxGeometry,
  onChange: () => void = () => {},
) {
  let disposed = false;
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
          onChange();
        })
        .catch(() => {});
    }
  }
  const ivory = new T.MeshStandardMaterial({
    color: "#e6d4ae",
    roughness: 0.55,
  });
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
  const signGeometry = new T.PlaneGeometry(2.9, 0.43);

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

  function build(look: StallLook, placement: SpotPlacement): StallParts {
    const root = new T.Group();
    const trim = new T.Group();
    root.add(trim);
    root.position.set(placement.x, 0, placement.z);
    root.rotation.y = placement.yaw;
    const colorIndex = hash(look.cuisine) % hues.length;
    const accent = accents[colorIndex];
    const canopy = awnings[colorIndex];
    const style = hash(look.cuisine + ":shape") % 3;
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
    shutters.position.set(0, SHUTTER_Y, 0.8);
    root.add(shutters);
    const sign = new T.Mesh(
      signGeometry,
      new T.MeshBasicMaterial({ color: "#ffffff" }),
    );
    sign.position.set(0, 1.94, 1.035);
    root.add(sign);
    return { root, trim, shutters, sign };
  }

  /** The shutter hangs from the canopy: its bottom edge rolls down. */
  function applyShutter(parts: StallParts, level: number) {
    parts.shutters.visible = level > 0;
    parts.shutters.scale.y = Math.max(level, 1e-3);
    parts.shutters.position.y = SHUTTER_Y + (SHUTTER_HEIGHT * (1 - level)) / 2;
  }

  function dispose() {
    disposed = true;
    shut.map?.dispose();
    for (const material of [
      wall,
      wood,
      slate,
      shut,
      ivory,
      ...accents,
      ...awnings,
    ])
      material.dispose();
    for (const geometry of [backWall, sideWall, shutterGeometry, signGeometry])
      geometry.dispose();
  }

  return { build, paintShutters, applyShutter, dispose };
}
