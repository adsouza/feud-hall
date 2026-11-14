import * as T from "three";
import {
  FIGURE,
  PART_KINDS,
  posePerson,
  type Detail,
  type Look,
  type PartKind,
  type Pose,
} from "./people";

export type People = {
  begin(): void; // start a frame: nobody drawn yet
  add(look: Look, pose: Pose, detail: Detail, opacity?: number): void; // opacity defaults to 1
  end(): void; // flag buffers for upload
  readonly count: number; // people accepted since begin(), solid and fading
  mesh(kind: PartKind): T.InstancedMesh; // solid people
  fadingMesh(kind: PartKind): T.InstancedMesh; // fading people, colour pass
  fadingDepthMesh(kind: PartKind): T.InstancedMesh; // fading people, depth pre-pass
  readonly meshes: readonly T.InstancedMesh[]; // every mesh to add to the scene
  dispose(): void;
};

const F = FIGURE;

// A limb hangs along -Y from its joint at the origin.
function limb(radius: number, length: number): T.BufferGeometry {
  return new T.CapsuleGeometry(radius, length - 2 * radius, 4, 8).translate(
    0,
    -length / 2,
    0,
  );
}

function hairCap(): T.BufferGeometry {
  // Tilted back so the forehead shows.
  return new T.SphereGeometry(
    F.hairCapR,
    12,
    6,
    0,
    Math.PI * 2,
    0,
    Math.PI / 2,
  ).rotateX(-F.hairTilt);
}

// Geometry for each part kind, authored for the unit figure so the matrices
// from posePerson place it directly, and whether the kind comes in pairs.
const SHAPES: Record<
  PartKind,
  { make: () => T.BufferGeometry; paired: boolean }
> = {
  torso: {
    make: () => new T.CapsuleGeometry(F.torsoR, F.torsoStraight, 4, 10),
    paired: false,
  },
  skirt: {
    make: () =>
      new T.CylinderGeometry(F.skirtRTop, F.skirtRBottom, F.skirtLen, 12).scale(
        1,
        1,
        F.skirtDeep,
      ),
    paired: false,
  },
  apron: {
    make: () => new T.BoxGeometry(F.apronW, F.apronH, F.apronT),
    paired: false,
  },
  neck: {
    make: () => new T.CylinderGeometry(F.neckRTop, F.neckRBottom, F.neckLen, 8),
    paired: false,
  },
  // The painted face is at +Z: Three maps u = 0.25 of a sphere there.
  head: {
    make: () => new T.SphereGeometry(F.headR, 12, 8),
    paired: false,
  },
  hairCap: { make: hairCap, paired: false },
  hairLong: {
    make: () =>
      new T.CapsuleGeometry(F.hairLongR, F.hairLongStraight, 4, 8)
        .scale(F.hairLongWide, 1, F.hairLongDeep)
        .translate(0, -0.05, -0.075),
    paired: false,
  },
  hairBun: {
    make: () => new T.SphereGeometry(F.bunR, 8, 6).translate(0, 0.045, -0.1),
    paired: false,
  },
  hairBrim: {
    make: () =>
      new T.BoxGeometry(F.brimW, F.brimT, F.brimLen).translate(0, 0.03, 0.1),
    paired: false,
  },
  upperLeg: { make: () => limb(F.thighR, F.thighLen), paired: true },
  lowerLeg: { make: () => limb(F.shinR, F.shinLen), paired: true },
  foot: {
    make: () => new T.BoxGeometry(F.footW, F.footH, F.footLen),
    paired: true,
  },
  upperArm: { make: () => limb(F.upperArmR, F.upperArmLen), paired: true },
  forearm: { make: () => limb(F.forearmR, F.forearmLen), paired: true },
  hand: {
    make: () => new T.SphereGeometry(F.handR, 8, 6),
    paired: true,
  },
};

// The painted face for the head batches: two eyes and a smile on white, so
// the instance colour tints the skin. Touches `document` only when called.
export function createFaceTexture(): T.CanvasTexture | null {
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

const SCRATCH = new T.Color();

// One instanced batch per part kind. A fading batch also has a depth-only
// twin sharing its geometry and matrices: drawn last in the opaque pass, it
// lays down the fading person's nearest surface, so the transparent colour
// pass shades only that surface and limbs do not show through the body.
type Batch = {
  meshes: Map<PartKind, T.InstancedMesh>;
  depth: Map<PartKind, T.InstancedMesh>;
  colours: Map<PartKind, T.InstancedBufferAttribute>;
  capacity: number;
  people: number;
};

function createBatch(
  capacity: number,
  faces: T.Texture | null,
  fading: boolean,
): Batch {
  const batch: Batch = {
    meshes: new Map(),
    depth: new Map(),
    colours: new Map(),
    capacity,
    people: 0,
  };
  for (const kind of PART_KINDS) {
    const shape = SHAPES[kind];
    const slots = shape.paired ? capacity * 2 : capacity;
    const geometry = shape.make();
    const attribute = new T.InstancedBufferAttribute(
      new Float32Array(slots * 4),
      4,
    ).setUsage(T.DynamicDrawUsage);
    // Three.js reads the instanced RGBA attribute as vertex colors, including alpha.
    geometry.setAttribute("color", attribute);
    const options = {
      map: kind === "head" ? faces : null,
      roughness: 0.9,
      vertexColors: true,
    };
    const material = fading
      ? new T.MeshStandardMaterial({
          ...options,
          transparent: true,
          depthWrite: false,
        })
      : new T.MeshStandardMaterial(options);
    const mesh = new T.InstancedMesh(geometry, material, slots);
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
    mesh.frustumCulled = false;
    mesh.count = 0;
    batch.meshes.set(kind, mesh);
    batch.colours.set(kind, attribute);
    if (fading) {
      const depth = new T.InstancedMesh(
        geometry,
        new T.MeshStandardMaterial({ ...options, colorWrite: false }),
        slots,
      );
      depth.instanceMatrix = mesh.instanceMatrix;
      depth.frustumCulled = false;
      depth.count = 0;
      // After every other opaque object, so it never hides what lies behind.
      depth.renderOrder = 1;
      batch.depth.set(kind, depth);
    }
  }
  return batch;
}

export function createPeople(
  capacity: number,
  faces: T.Texture | null,
  fadingCapacity: number = capacity,
): People {
  const solid = createBatch(capacity, faces, false);
  const fading = createBatch(fadingCapacity, faces, true);
  const meshes = [
    ...solid.meshes.values(),
    ...fading.meshes.values(),
    ...fading.depth.values(),
  ];

  let target = solid;
  let alpha = 1;
  const emit = (kind: PartKind, matrix: T.Matrix4, colour: number): void => {
    const mesh = target.meshes.get(kind) as T.InstancedMesh;
    const index = mesh.count++;
    const depth = target.depth.get(kind);
    if (depth) depth.count = mesh.count;
    mesh.setMatrixAt(index, matrix);
    SCRATCH.setHex(colour);
    (target.colours.get(kind) as T.InstancedBufferAttribute).setXYZW(
      index,
      SCRATCH.r,
      SCRATCH.g,
      SCRATCH.b,
      alpha,
    );
  };

  return {
    begin() {
      solid.people = fading.people = 0;
      for (const mesh of meshes) mesh.count = 0;
    },
    add(look, pose, detail, opacity = 1) {
      // Decide before writing any part: every kind has a slot per person.
      if (!(opacity > 0)) return;
      const batch = opacity >= 1 ? solid : fading;
      if (batch.people >= batch.capacity) return;
      batch.people++;
      target = batch;
      alpha = Math.min(1, opacity);
      posePerson(look, pose, detail, emit);
    },
    end() {
      // Upload only the slots in use: whole buffers sized for every stall
      // are megabytes per frame. A zero count uploads nothing (WebGL2 reads
      // a zero-length range as "to the end of the array"). A fading pair
      // shares one matrix buffer, flagged once through its colour mesh.
      for (const batch of [solid, fading])
        for (const kind of PART_KINDS) {
          const mesh = batch.meshes.get(kind) as T.InstancedMesh;
          if (mesh.count === 0) continue;
          const colour = batch.colours.get(kind) as T.InstancedBufferAttribute;
          for (const [buffer, size] of [
            [mesh.instanceMatrix, 16],
            [colour, 4],
          ] as const) {
            buffer.clearUpdateRanges();
            buffer.addUpdateRange(0, mesh.count * size);
            buffer.needsUpdate = true;
          }
        }
    },
    get count() {
      return solid.people + fading.people;
    },
    mesh(kind) {
      return solid.meshes.get(kind) as T.InstancedMesh;
    },
    fadingMesh(kind) {
      return fading.meshes.get(kind) as T.InstancedMesh;
    },
    fadingDepthMesh(kind) {
      return fading.depth.get(kind) as T.InstancedMesh;
    },
    meshes,
    dispose() {
      // The depth twins share their colour mesh's geometry: dispose it once.
      const twins = new Set(fading.depth.values());
      for (const mesh of meshes) {
        if (!twins.has(mesh)) mesh.geometry.dispose();
        (mesh.material as T.Material).dispose();
        mesh.dispose();
      }
    },
  };
}
