import * as T from "three";
import street from "./assets/hall/street-at-dusk.webp";

const HEIGHT = 4.65;
const SILL = 1.12;
const WINDOW_TOP = 3.45;
const WALL_DEPTH = 0.22;

type Edge = {
  wall: T.Group;
  axis: "x" | "z";
  sign: -1 | 1;
  at: number;
};

export function createHallShell(scene: T.Scene, redraw: () => void) {
  const room = new T.Group();
  const ceiling = new T.Group();
  const edges: Edge[] = [];
  scene.add(room);
  const box = new T.BoxGeometry();
  const plaster = new T.MeshStandardMaterial({
    color: "#535d73",
    roughness: 0.9,
  });
  const wainscot = new T.MeshStandardMaterial({
    color: "#364154",
    roughness: 0.86,
  });
  const wood = new T.MeshStandardMaterial({
    color: "#9d806b",
    roughness: 0.76,
  });
  const frame = new T.MeshStandardMaterial({
    color: "#292e3d",
    roughness: 0.72,
  });
  const ceilingPaint = new T.MeshStandardMaterial({
    color: "#9c9589",
    emissive: "#5e5345",
    emissiveIntensity: 0.22,
    roughness: 0.92,
  });
  const diffuser = new T.MeshBasicMaterial({ color: "#ffe3b1" });
  const outdoor = new T.MeshBasicMaterial({ color: "#bac4bd" });
  const views = [0, 0.17, 0.34].map((start) => {
    const pane = new T.PlaneGeometry();
    const uv = pane.attributes.uv;
    for (let i = 0; i < uv.count; i++) {
      uv.setX(i, start + uv.getX(i) * 0.66);
    }
    return pane;
  });
  let disposed = false;
  const image = new Image();
  image.onload = () => {
    if (disposed) return;
    const texture = new T.Texture(image);
    texture.colorSpace = T.SRGBColorSpace;
    texture.needsUpdate = true;
    outdoor.color.set("#ece1d4");
    outdoor.map = texture;
    outdoor.needsUpdate = true;
    redraw();
  };
  image.src = street;

  const transform = new T.Object3D();
  function groupBoxes(parent: T.Group) {
    const parts = new Map<T.Material, T.Matrix4[]>();
    return {
      add(
        material: T.Material,
        x: number,
        y: number,
        z: number,
        w: number,
        h: number,
        d: number,
      ) {
        transform.position.set(x, y, z);
        transform.scale.set(w, h, d);
        transform.updateMatrix();
        let poses = parts.get(material);
        if (!poses) {
          poses = [];
          parts.set(material, poses);
        }
        poses.push(transform.matrix.clone());
      },
      finish() {
        for (const [material, poses] of parts) {
          const batch = new T.InstancedMesh(box, material, poses.length);
          poses.forEach((pose, i) => batch.setMatrixAt(i, pose));
          batch.instanceMatrix.needsUpdate = true;
          parent.add(batch);
        }
      },
    };
  }

  function buildWall(
    span: number,
    x: number,
    z: number,
    yaw: number,
    variant: number,
  ) {
    const wall = new T.Group();
    wall.position.set(x, 0, z);
    wall.rotation.y = yaw;
    room.add(wall);
    const { add, finish } = groupBoxes(wall);
    add(wainscot, 0, SILL / 2, 0, span, SILL, WALL_DEPTH);
    add(
      plaster,
      0,
      (HEIGHT + WINDOW_TOP) / 2,
      0,
      span,
      HEIGHT - WINDOW_TOP,
      WALL_DEPTH,
    );
    add(wood, 0, 0.76, 0.119, span, 0.075, 0.04);
    add(wood, 0, HEIGHT - 0.18, 0.13, span, 0.16, 0.11);

    const count = Math.min(6, Math.max(1, Math.floor(span / 5)));
    const bay = span / count;
    const aperture = Math.min(3.8, bay * 0.72);
    const pier = (bay - aperture) / 2;
    const height = WINDOW_TOP - SILL;
    const mid = (WINDOW_TOP + SILL) / 2;
    for (let index = 0; index < count; index++) {
      const center = -span / 2 + (index + 0.5) * bay;
      for (const sign of [-1, 1]) {
        add(
          plaster,
          center + (sign * (aperture + pier)) / 2,
          mid,
          0,
          pier,
          height,
          WALL_DEPTH,
        );
        add(
          frame,
          center + (sign * aperture) / 2,
          mid,
          0.024,
          0.11,
          height,
          0.25,
        );
      }
      add(wood, center, SILL, 0.068, aperture + 0.23, 0.11, 0.39);
      add(frame, center, WINDOW_TOP, 0.024, aperture + 0.11, 0.1, 0.25);
      add(frame, center, mid, 0.032, 0.08, height, 0.17);
      add(frame, center, mid + 0.27, 0.032, aperture, 0.064, 0.17);

      const pane = new T.Mesh(views[(index + variant) % views.length], outdoor);
      pane.scale.set(aperture + 0.14, height + 0.1, 1);
      pane.position.set(center, mid, -0.128);
      wall.add(pane);
    }
    finish();
    return wall;
  }

  function clearLayout() {
    room.traverse((object) => {
      if (object instanceof T.InstancedMesh) object.dispose();
    });
    ceiling.clear();
    room.clear();
    edges.length = 0;
  }

  return {
    resize(x: number, z: number, width: number, depth: number) {
      clearLayout();
      const halfWidth = width / 2 + 0.12;
      const halfDepth = depth / 2 + 0.12;
      const west = x - halfWidth;
      const east = x + halfWidth;
      const north = z - halfDepth;
      const south = z + halfDepth;
      const longSpan = depth + 0.24;
      const shortSpan = width + 0.46;
      edges.push(
        {
          wall: buildWall(shortSpan, x, north, 0, 0),
          axis: "z",
          sign: -1,
          at: north,
        },
        {
          wall: buildWall(shortSpan, x, south, Math.PI, 1),
          axis: "z",
          sign: 1,
          at: south,
        },
        {
          wall: buildWall(longSpan, west, z, Math.PI / 2, 1),
          axis: "x",
          sign: -1,
          at: west,
        },
        {
          wall: buildWall(longSpan, east, z, -Math.PI / 2, 2),
          axis: "x",
          sign: 1,
          at: east,
        },
      );
      ceiling.position.set(x, 0, z);
      room.add(ceiling);
      const { add, finish } = groupBoxes(ceiling);
      add(
        ceilingPaint,
        0,
        HEIGHT + 0.09,
        0,
        shortSpan,
        0.18,
        longSpan + WALL_DEPTH,
      );
      const count = Math.min(12, Math.max(2, Math.ceil(depth / 5.5)));
      for (let row = 0; row < count; row++) {
        const beamZ = ((row + 0.5) / count - 0.5) * depth;
        add(wood, 0, HEIGHT - 0.12, beamZ, shortSpan, 0.24, 0.19);
        for (const side of [-1, 1]) {
          add(
            diffuser,
            side * width * 0.25,
            HEIGHT - 0.27,
            beamZ,
            1.12,
            0.085,
            0.22,
          );
        }
      }
      finish();
    },
    update(camera: T.Vector3) {
      let inside = camera.y >= 0 && camera.y < HEIGHT;
      for (const { wall, axis, sign, at } of edges) {
        // Cut away walls on the camera side when orbiting outside the room.
        wall.visible = sign * (camera[axis] - at) < 0;
        inside &&= wall.visible;
      }
      ceiling.visible = inside;
    },
    dispose() {
      disposed = true;
      clearLayout();
      scene.remove(room);
      outdoor.map?.dispose();
      for (const material of [
        plaster,
        wainscot,
        wood,
        frame,
        ceilingPaint,
        diffuser,
        outdoor,
      ])
        material.dispose();
      for (const geometry of [box, ...views]) geometry.dispose();
    },
  };
}
