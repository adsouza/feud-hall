import * as T from "three";
import street from "./assets/hall/street-at-dusk.webp";
import {
  DOOR_WIDTH,
  ENTRANCE_WIDTH,
  ROOM_COUNT,
  ROOM_SIDE,
  roomCentre,
  tableSpots,
} from "./room-layout";

const HEIGHT = 4.65;
const SILL = 1.12;
const WINDOW_TOP = 3.45;
const WALL_DEPTH = 0.22;
const DOORWAY_HEIGHT = 3.05;
const HALF = ROOM_SIDE / 2;
/** Interior gap between two neighbouring rooms, as in the room layout. */
const GAP = roomCentre(2).x - roomCentre(1).x - ROOM_SIDE;
/** Tables and four seats per table, for up to three shown rooms. */
const TABLE_LIMIT = 3 * 12;
const SEATS = [
  [0, 0.95],
  [0, -0.95],
  [0.95, 0],
  [-0.95, 0],
] as const;

export type ShownRoom = { room: number; detail: "full" | "simple" };

type Edge = {
  wall: T.Group;
  axis: "x" | "z";
  sign: -1 | 1;
  at: number;
};
/** An opening along a wall, centred on the wall's middle. */
type Opening = { width: number; fill: "street" | "door" | "open" };

export function createHallShell(scene: T.Scene, redraw: () => void) {
  const rooms = new T.Group();
  const ceilings: T.Group[] = [];
  const edges: Edge[] = [];
  let shownSpan = { west: 0, east: 0 };
  let signature = "";
  scene.add(rooms);
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
  const door = new T.MeshStandardMaterial({
    color: "#5b3f33",
    roughness: 0.7,
  });
  const brass = new T.MeshStandardMaterial({
    color: "#ffca69",
    metalness: 0.35,
    roughness: 0.36,
  });
  const ceilingPaint = new T.MeshStandardMaterial({
    color: "#9c9589",
    emissive: "#5e5345",
    emissiveIntensity: 0.22,
    roughness: 0.92,
  });
  const tile = new T.MeshStandardMaterial({
    color: "#252b40",
    roughness: 0.86,
  });
  const foundation = new T.MeshStandardMaterial({
    color: "#14172a",
    roughness: 0.94,
  });
  const pavement = new T.MeshStandardMaterial({
    color: "#3b3e4a",
    roughness: 0.95,
  });
  const tableTop = new T.MeshStandardMaterial({
    color: "#b48a63",
    roughness: 0.62,
  });
  const seat = new T.MeshStandardMaterial({
    color: "#7c3f3a",
    roughness: 0.8,
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

  // Tables, their legs and their seats, shared by every shown room.
  const tableGeometry = new T.CylinderGeometry(0.62, 0.62, 0.07, 18);
  const legGeometry = new T.CylinderGeometry(0.07, 0.11, 0.72, 8);
  const seatGeometry = new T.CylinderGeometry(0.24, 0.2, 0.46, 10);
  const tables = new T.InstancedMesh(tableGeometry, tableTop, TABLE_LIMIT);
  const legs = new T.InstancedMesh(legGeometry, frame, TABLE_LIMIT);
  const seats = new T.InstancedMesh(
    seatGeometry,
    seat,
    TABLE_LIMIT * SEATS.length,
  );
  for (const mesh of [tables, legs, seats]) {
    mesh.count = 0;
    mesh.frustumCulled = false;
    scene.add(mesh);
  }

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
        transform.rotation.set(0, 0, 0);
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

  /**
   * One wall, built in its own frame: local x runs along it, local +z faces
   * into the room. An opening, if any, is in the middle.
   */
  function buildWall(
    span: number,
    x: number,
    z: number,
    yaw: number,
    variant: number,
    windows: boolean,
    opening?: Opening,
  ) {
    const wall = new T.Group();
    wall.position.set(x, 0, z);
    wall.rotation.y = yaw;
    rooms.add(wall);
    const { add, finish } = groupBoxes(wall);
    const gap = opening?.width ?? 0;
    const segments: [number, number][] = opening
      ? [
          [-span / 2, -gap / 2],
          [gap / 2, span / 2],
        ]
      : [[-span / 2, span / 2]];
    let paneIndex = variant;
    for (const [from, to] of segments) {
      const length = to - from;
      const middle = (from + to) / 2;
      add(wainscot, middle, SILL / 2, 0, length, SILL, WALL_DEPTH);
      add(
        plaster,
        middle,
        (HEIGHT + WINDOW_TOP) / 2,
        0,
        length,
        HEIGHT - WINDOW_TOP,
        WALL_DEPTH,
      );
      add(wood, middle, 0.76, 0.119, length, 0.075, 0.04);
      add(wood, middle, HEIGHT - 0.18, 0.13, length, 0.16, 0.11);
      const height = WINDOW_TOP - SILL;
      const mid = (WINDOW_TOP + SILL) / 2;
      if (!windows || length < 4) {
        add(plaster, middle, mid, 0, length, height, WALL_DEPTH);
        continue;
      }
      const count = Math.min(6, Math.max(1, Math.floor(length / 5)));
      const bay = length / count;
      const aperture = Math.min(3.8, bay * 0.72);
      const pier = (bay - aperture) / 2;
      for (let index = 0; index < count; index++) {
        const center = from + (index + 0.5) * bay;
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

        const pane = new T.Mesh(views[paneIndex++ % views.length], outdoor);
        pane.scale.set(aperture + 0.14, height + 0.1, 1);
        pane.position.set(center, mid, -0.128);
        wall.add(pane);
      }
    }
    if (opening) {
      // The lintel above the opening and a dark casing around it.
      add(
        plaster,
        0,
        (HEIGHT + DOORWAY_HEIGHT) / 2,
        0,
        gap,
        HEIGHT - DOORWAY_HEIGHT,
        WALL_DEPTH,
      );
      add(wood, 0, HEIGHT - 0.18, 0.13, gap, 0.16, 0.11);
      for (const sign of [-1, 1])
        add(
          frame,
          (sign * (gap + 0.12)) / 2,
          DOORWAY_HEIGHT / 2,
          0,
          0.12,
          DOORWAY_HEIGHT,
          WALL_DEPTH + 0.08,
        );
      add(
        frame,
        0,
        DOORWAY_HEIGHT + 0.06,
        0,
        gap + 0.24,
        0.12,
        WALL_DEPTH + 0.08,
      );
      if (opening.fill === "door") {
        // A shut door: the room beyond is not open yet.
        add(door, 0, DOORWAY_HEIGHT / 2, 0, gap, DOORWAY_HEIGHT, 0.09);
        for (const row of [0.62, 1.55, 2.48])
          for (const sign of [-1, 1])
            add(frame, (sign * gap) / 4, row, 0.05, gap / 2 - 0.3, 0.72, 0.02);
        add(brass, gap / 2 - 0.35, 1.05, 0.08, 0.1, 0.1, 0.08);
      } else if (opening.fill === "street") {
        // The street outside: a pavement and the dusk view beyond it.
        const depth = 2.4;
        const width = gap + 6;
        add(pavement, 0, -0.09, -depth / 2, width, 0.1, depth);
        const view = new T.Mesh(views[1], outdoor);
        view.scale.set(width, HEIGHT + 1.2, 1);
        view.position.set(0, (HEIGHT + 1.2) / 2 - 0.1, -depth);
        wall.add(view);
      }
    }
    finish();
    return wall;
  }

  function buildRoom({ room, detail }: ShownRoom, openRooms: number) {
    const full = detail === "full";
    const c = roomCentre(room);
    const span = ROOM_SIDE + 2 * WALL_DEPTH;
    const offset = HALF + WALL_DEPTH / 2;
    const neighbour = (other: number): Opening | undefined =>
      other < 1 || other > ROOM_COUNT
        ? undefined
        : { width: DOOR_WIDTH, fill: other > openRooms ? "door" : "open" };
    edges.push(
      {
        wall: buildWall(span, c.x, c.z - offset, 0, room, full),
        axis: "z",
        sign: -1,
        at: c.z - offset,
      },
      {
        wall: buildWall(span, c.x, c.z + offset, Math.PI, room + 1, full, {
          width: ENTRANCE_WIDTH,
          fill: "street",
        }),
        axis: "z",
        sign: 1,
        at: c.z + offset,
      },
      {
        wall: buildWall(
          ROOM_SIDE,
          c.x - offset,
          c.z,
          Math.PI / 2,
          0,
          false,
          neighbour(room - 1),
        ),
        axis: "x",
        sign: -1,
        at: c.x - offset,
      },
      {
        wall: buildWall(
          ROOM_SIDE,
          c.x + offset,
          c.z,
          -Math.PI / 2,
          0,
          false,
          neighbour(room + 1),
        ),
        axis: "x",
        sign: 1,
        at: c.x + offset,
      },
    );

    const ground = new T.Group();
    rooms.add(ground);
    const floor = groupBoxes(ground);
    // Each floor reaches halfway into the wall gap, so doorways have a floor.
    floor.add(foundation, c.x, -0.32, c.z, ROOM_SIDE + GAP, 0.4, span + 0.3);
    floor.add(tile, c.x, -0.09, c.z, ROOM_SIDE + GAP, 0.1, ROOM_SIDE);
    floor.finish();

    const ceiling = new T.Group();
    ceiling.position.set(c.x, 0, c.z);
    rooms.add(ceiling);
    ceilings.push(ceiling);
    const { add, finish } = groupBoxes(ceiling);
    add(ceilingPaint, 0, HEIGHT + 0.09, 0, span, 0.18, span);
    if (full) {
      const count = 6;
      for (let row = 0; row < count; row++) {
        const beamZ = ((row + 0.5) / count - 0.5) * ROOM_SIDE;
        add(wood, 0, HEIGHT - 0.12, beamZ, span, 0.24, 0.19);
        for (const side of [-1, 1])
          add(
            diffuser,
            side * ROOM_SIDE * 0.25,
            HEIGHT - 0.27,
            beamZ,
            1.12,
            0.085,
            0.22,
          );
      }
    }
    finish();
  }

  function placeTables(shown: ShownRoom[]) {
    let count = 0;
    let seated = 0;
    for (const { room } of shown)
      for (const spot of tableSpots(room)) {
        if (count >= TABLE_LIMIT) break;
        transform.rotation.set(0, spot.yaw, 0);
        transform.scale.set(1, 1, 1);
        transform.position.set(spot.x, 0.76, spot.z);
        transform.updateMatrix();
        tables.setMatrixAt(count, transform.matrix);
        transform.position.set(spot.x, 0.36, spot.z);
        transform.updateMatrix();
        legs.setMatrixAt(count, transform.matrix);
        count++;
        for (const [dx, dz] of SEATS) {
          const c = Math.cos(spot.yaw),
            s = Math.sin(spot.yaw);
          transform.position.set(
            spot.x + c * dx + s * dz,
            0.23,
            spot.z - s * dx + c * dz,
          );
          transform.updateMatrix();
          seats.setMatrixAt(seated++, transform.matrix);
        }
      }
    tables.count = legs.count = count;
    seats.count = seated;
    for (const mesh of [tables, legs, seats])
      mesh.instanceMatrix.needsUpdate = true;
  }

  function clearLayout() {
    rooms.traverse((object) => {
      if (object instanceof T.InstancedMesh) object.dispose();
    });
    rooms.clear();
    ceilings.length = 0;
    edges.length = 0;
  }

  return {
    /** Draw these rooms. A doorway toward a room above `openRooms` is shut. */
    show(shown: ShownRoom[], openRooms: number) {
      const next =
        shown.map(({ room, detail }) => `${room}${detail[0]}`).join(",") +
        `/${openRooms}`;
      if (next === signature) return;
      signature = next;
      clearLayout();
      for (const room of shown) buildRoom(room, openRooms);
      placeTables(shown);
      const xs = shown.map(({ room }) => roomCentre(room).x);
      shownSpan = {
        west: Math.min(...xs) - HALF - GAP,
        east: Math.max(...xs) + HALF + GAP,
      };
    },
    update(camera: T.Vector3) {
      for (const { wall, axis, sign, at } of edges) {
        // Cut away walls on the camera side when orbiting outside a room.
        wall.visible = sign * (camera[axis] - at) < 0;
      }
      const inside =
        camera.y >= 0 &&
        camera.y < HEIGHT &&
        Math.abs(camera.z) < HALF &&
        camera.x > shownSpan.west &&
        camera.x < shownSpan.east;
      for (const ceiling of ceilings) ceiling.visible = inside;
    },
    dispose() {
      disposed = true;
      clearLayout();
      scene.remove(rooms);
      for (const mesh of [tables, legs, seats]) {
        scene.remove(mesh);
        mesh.dispose();
      }
      outdoor.map?.dispose();
      for (const material of [
        plaster,
        wainscot,
        wood,
        frame,
        door,
        brass,
        ceilingPaint,
        tile,
        foundation,
        pavement,
        tableTop,
        seat,
        diffuser,
        outdoor,
      ])
        material.dispose();
      for (const geometry of [
        box,
        tableGeometry,
        legGeometry,
        seatGeometry,
        ...views,
      ])
        geometry.dispose();
    },
  };
}
