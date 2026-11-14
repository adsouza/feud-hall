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
  readonly count: number; // people accepted since begin()
  mesh(kind: PartKind): T.InstancedMesh;
  readonly meshes: readonly T.InstancedMesh[]; // one per PartKind
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

const SCRATCH = new T.Color();

export function createPeople(
  capacity: number,
  faces: T.Texture | null,
): People {
  const byKind = new Map<PartKind, T.InstancedMesh>();
  const colours = new Map<PartKind, T.InstancedBufferAttribute>();
  const meshes: T.InstancedMesh[] = [];
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
    const material = new T.MeshStandardMaterial({
      map: kind === "head" ? faces : null,
      roughness: 0.9,
      vertexColors: true,
      alphaHash: true,
    });
    const mesh = new T.InstancedMesh(geometry, material, slots);
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
    mesh.frustumCulled = false;
    mesh.count = 0;
    byKind.set(kind, mesh);
    colours.set(kind, attribute);
    meshes.push(mesh);
  }

  let people = 0;
  let alpha = 1;
  const emit = (kind: PartKind, matrix: T.Matrix4, colour: number): void => {
    const mesh = byKind.get(kind) as T.InstancedMesh;
    const index = mesh.count++;
    mesh.setMatrixAt(index, matrix);
    SCRATCH.setHex(colour);
    (colours.get(kind) as T.InstancedBufferAttribute).setXYZW(
      index,
      SCRATCH.r,
      SCRATCH.g,
      SCRATCH.b,
      alpha,
    );
  };

  return {
    begin() {
      people = 0;
      for (const mesh of meshes) mesh.count = 0;
    },
    add(look, pose, detail, opacity = 1) {
      // Decide before writing any part: every kind has a slot per person.
      if (people >= capacity || !(opacity > 0)) return;
      people++;
      alpha = Math.min(1, opacity);
      posePerson(look, pose, detail, emit);
    },
    end() {
      for (const kind of PART_KINDS) {
        (byKind.get(kind) as T.InstancedMesh).instanceMatrix.needsUpdate = true;
        (colours.get(kind) as T.InstancedBufferAttribute).needsUpdate = true;
      }
    },
    get count() {
      return people;
    },
    mesh(kind) {
      return byKind.get(kind) as T.InstancedMesh;
    },
    meshes,
    dispose() {
      for (const mesh of meshes) {
        mesh.geometry.dispose();
        (mesh.material as T.Material).dispose();
        mesh.dispose();
      }
    },
  };
}
