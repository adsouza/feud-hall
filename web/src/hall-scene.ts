import * as T from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import type { Stall } from "./api";

type Point = [number, number, number];
export type CameraState = { position: Point; target: Point };
type Actions = {
  select: (id: string) => void;
  hover: (id: string | null) => void;
  fail: () => void;
};
type Appearance = {
  stalls: Stall[];
  selected: string;
  pickup: string;
  detail: boolean;
  motion: boolean;
};
type Counter = {
  root: T.Group;
  trim: T.Group;
  hit: T.Mesh;
  edge: T.Mesh;
  shutters: T.Mesh;
  sign: T.Mesh<T.PlaneGeometry, T.MeshBasicMaterial>;
  plaque: T.Mesh;
  pickup: T.Mesh;
  serviceLamp: T.Mesh;
  index: number;
  name: string;
  cuisine: string;
  color: T.Color;
  activity?: Stall["activity"];
  open: boolean;
};

const COLS = 5;
const GAP_X = 4.7;
const GAP_Z = 5.5;
const CROWD_LIMIT = 150 * 4;
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
  scene.fog = new T.FogExp2("#111526", 0.012);
  const camera = new T.PerspectiveCamera(42, 1, 0.25, 175);
  const orbit = new OrbitControls(camera, renderer.domElement);
  orbit.enableDamping = false;
  orbit.screenSpacePanning = true;
  orbit.minDistance = 3.5;
  orbit.maxDistance = 115;
  orbit.minPolarAngle = 0.25;
  orbit.maxPolarAngle = 1.46;
  orbit.mouseButtons.LEFT = T.MOUSE.ROTATE;
  orbit.touches.ONE = T.TOUCH.ROTATE;
  if (saved) {
    camera.position.copy(vec(saved.position));
    orbit.target.copy(vec(saved.target));
  }

  const ambient = new T.HemisphereLight("#ffe8c9", "#7a72ac", 2.4);
  const key = new T.DirectionalLight("#fff3d9", 2.2);
  key.position.set(-6, 12, 8);
  const fill = new T.DirectionalLight("#8bbcff", 0.95);
  fill.position.set(9, 6, -10);
  scene.add(ambient, key, fill);

  const box = new T.BoxGeometry();
  const tileMat = new T.MeshStandardMaterial({
    color: "#252b40",
    roughness: 0.86,
  });
  const foundationMat = new T.MeshStandardMaterial({
    color: "#14172a",
    roughness: 0.94,
  });
  const wall = new T.MeshStandardMaterial({
    color: "#313853",
    roughness: 0.75,
  });
  const wood = new T.MeshStandardMaterial({
    color: "#826451",
    roughness: 0.75,
  });
  const slate = new T.MeshStandardMaterial({
    color: "#29233b",
    roughness: 0.77,
  });
  const shut = new T.MeshStandardMaterial({ color: "#60667a", roughness: 0.8 });
  const ivory = new T.MeshStandardMaterial({
    color: "#e6d4ae",
    roughness: 0.55,
  });
  const light = new T.MeshBasicMaterial({ color: "#fff7bd" });
  const dark = new T.MeshBasicMaterial({ color: "#4e5570" });
  const highlight = new T.MeshBasicMaterial({ color: "#ffcb67" });
  const teal = new T.MeshBasicMaterial({ color: "#68ecdd" });
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
  const buildings = new T.Group();
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
  const lines = new T.Group();
  floor.add(lines);
  let floorSignature = "";
  let centre = new T.Vector3();
  let radius = 15;

  function resizeFloor(columns: number, rows: number) {
    const signature = `${columns}:${rows}`;
    if (signature === floorSignature) return;
    floorSignature = signature;
    const width = Math.max(2, columns) * GAP_X + 1.3;
    const depth = rows * GAP_Z + 1.7;
    centre = new T.Vector3(
      ((columns - 1) * GAP_X) / 2,
      0,
      ((rows - 1) * GAP_Z + 1.3) / 2,
    );
    radius = Math.hypot(width, depth) * 0.91;
    floorBase.position.set(centre.x, -0.32, centre.z);
    floorBase.scale.set(width + 0.3, 0.4, depth + 0.3);
    floorTop.position.set(centre.x, -0.09, centre.z);
    floorTop.scale.set(width, 0.1, depth);
    lines.clear();
    for (let row = 0; row < rows; row++) {
      brick(
        lines,
        laneMat,
        centre.x,
        -0.028,
        row * GAP_Z + 1.5,
        width - 0.6,
        0.025,
        0.065,
      );
      brick(
        lines,
        slate,
        centre.x,
        -0.026,
        row * GAP_Z + 3.05,
        width - 0.6,
        0.026,
        0.08,
      );
    }
    for (let col = 0; col <= columns; col++) {
      brick(
        lines,
        slate,
        (col - 0.5) * GAP_X,
        -0.03,
        centre.z,
        0.07,
        0.02,
        depth - 0.6,
      );
    }
  }

  const signGeometry = new T.PlaneGeometry(2.9, 0.43);
  function paintSign(counter: Counter, stall: Stall) {
    const text = stall.name + " · " + stall.stall_id;
    if (text === counter.name) return;
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
    ctx.font = "600 31px system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, 256, 40, 482);
    const map = new T.CanvasTexture(canvas);
    map.colorSpace = T.SRGBColorSpace;
    counter.sign.material.map?.dispose();
    counter.sign.material.map = map;
    counter.sign.material.needsUpdate = true;
  }

  function createCounter(stall: Stall, index: number): Counter {
    const root = new T.Group();
    const trim = new T.Group();
    root.add(trim);
    root.position.set(
      (index % COLS) * GAP_X,
      0,
      Math.floor(index / COLS) * GAP_Z,
    );
    const colorIndex = hash(stall.cuisine) % hues.length;
    const accent = accents[colorIndex];
    const canopy = awnings[colorIndex];
    const style = hash(stall.cuisine + ":shape") % 3;
    brick(root, wall, 0, 1.03, -0.87, 3.2, 2.06, 0.17);
    brick(root, slate, 0, 0.06, -0.18, 3.5, 0.12, 2.48);
    brick(root, wall, -1.52, 1.1, 0, 0.12, 2.2, 1.9);
    brick(root, wall, 1.52, 1.1, 0, 0.12, 2.2, 1.9);
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
    brick(trim, wood, -0.93, 0.86, -0.34, 0.86, 0.13, 0.58);
    brick(trim, slate, 0.91, 0.89, -0.42, 0.89, 0.16, 0.6);
    brick(trim, ivory, 1.08, 0.99, 0.64, 0.5, 0.1, 0.33);
    const shutters = brick(root, shut, 0, 1.35, 0.78, 3, 0.91, 0.06);
    const serviceLamp = brick(root, light, -1.23, 1.68, 0.91, 0.15, 0.2, 0.12);
    const edge = brick(root, highlight, 0, 0.032, 1.14, 3.47, 0.065, 0.11);
    const pickup = brick(root, teal, 0, 0.947, 0.69, 0.82, 0.045, 0.45);
    const plaque = brick(root, plaqueMat, 1.48, 1.2, 1.05, 0.25, 0.3, 0.05);
    const sign = new T.Mesh(
      signGeometry,
      new T.MeshBasicMaterial({ color: "#ffffff" }),
    );
    sign.position.set(0, 1.94, 1.035);
    root.add(sign);
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
      plaque,
      pickup,
      serviceLamp,
      index,
      name: "",
      cuisine: stall.cuisine,
      color: accent.color,
      open: false,
    };
    paintSign(result, stall);
    return result;
  }

  function discardCounter(counter: Counter) {
    buildings.remove(counter.root);
    counter.sign.material.map?.dispose();
    counter.sign.material.dispose();
  }

  const actorGeometry = new T.CapsuleGeometry(0.14, 0.28, 3, 6);
  const headGeometry = new T.SphereGeometry(0.115, 6, 4);
  const body = new T.InstancedMesh(
    actorGeometry,
    new T.MeshStandardMaterial({ roughness: 0.9 }),
    CROWD_LIMIT + 300,
  );
  const heads = new T.InstancedMesh(
    headGeometry,
    new T.MeshStandardMaterial({ color: "#dca57f", roughness: 0.9 }),
    CROWD_LIMIT + 300,
  );
  const steam = new T.InstancedMesh(
    headGeometry,
    new T.MeshBasicMaterial({
      color: "#ffe8c4",
      transparent: true,
      opacity: 0.35,
      depthWrite: false,
    }),
    300,
  );
  for (const mesh of [body, heads, steam]) {
    mesh.frustumCulled = false;
    mesh.count = 0;
    mesh.instanceMatrix.setUsage(T.DynamicDrawUsage);
    scene.add(mesh);
  }
  const dummy = new T.Object3D();
  const workerTint = new T.Color("#8de2d1");
  function actor(index: number, x: number, z: number, color: T.Color) {
    dummy.scale.setScalar(1);
    dummy.position.set(x, 0.27, z);
    dummy.updateMatrix();
    body.setMatrixAt(index, dummy.matrix);
    body.setColorAt(index, color);
    dummy.position.y = 0.63;
    dummy.updateMatrix();
    heads.setMatrixAt(index, dummy.matrix);
  }

  let appearance: Appearance = {
    stalls: [],
    selected: "",
    pickup: "",
    detail: true,
    motion: true,
  };
  let hover = "";
  let frame = 0;
  let animating = false;
  let disposed = false;
  let initialized = Boolean(saved);
  let lastFrame = 0;

  function draw(now = 0) {
    if (disposed || document.hidden) return;
    let actors = 0;
    let puffs = 0;
    const time = appearance.motion ? now / 1000 : 0;
    for (const [id, model] of stalls) {
      const nearby =
        camera.position.distanceToSquared(model.root.position) < 28 ** 2;
      const inspected =
        id === appearance.selected || id === hover || id === appearance.pickup;
      const detailed = inspected || (appearance.detail && nearby);
      model.trim.visible = detailed;
      model.sign.visible = detailed || stalls.size <= COLS;
      model.edge.visible = inspected;
      model.pickup.visible =
        id === appearance.pickup || Boolean(model.activity?.handover);
      const activity = model.activity;
      if (!activity) continue;
      const x = model.root.position.x;
      const z = model.root.position.z;
      const count = Math.min(activity.waiting, detailed ? 4 : 1);
      for (let n = 0; n < count; n++) {
        const sway = appearance.motion
          ? Math.sin(time * 2 + model.index + n) * 0.045
          : 0;
        actor(
          actors++,
          x - 0.54 + (n % 2) * 0.57 + sway,
          z + 1.55 + Math.floor(n / 2) * 0.52,
          model.color,
        );
      }
      if (
        activity.staffed &&
        (model.open || activity.cooking > 0 || activity.handover)
      ) {
        actor(
          actors++,
          x +
            (activity.handover || activity.staging
              ? 0.65
              : -0.36 + Math.sin(time * 2 + model.index) * 0.22),
          z + 0.12,
          workerTint,
        );
      }
      if (detailed && activity.cooking > 0) {
        for (let n = 0; n < Math.min(2, activity.cooking); n++) {
          const progress = (time * 0.7 + model.index * 0.27 + n * 0.42) % 1;
          dummy.position.set(
            x + 0.82 + n * 0.26 + progress * 0.13,
            1.1 + progress * 0.52,
            z - 0.45,
          );
          dummy.scale.setScalar(0.8 + progress * 0.75);
          dummy.updateMatrix();
          steam.setMatrixAt(puffs++, dummy.matrix);
        }
      }
    }
    body.count = heads.count = actors;
    steam.count = puffs;
    for (const mesh of [body, heads, steam])
      mesh.instanceMatrix.needsUpdate = true;
    if (body.instanceColor) body.instanceColor.needsUpdate = true;
    try {
      renderer.render(scene, camera);
    } catch {
      actions.fail();
    }
  }

  function animate(now: number) {
    if (!animating || disposed) return;
    if (now - lastFrame > 32) {
      lastFrame = now;
      draw(now);
    }
    frame = requestAnimationFrame(animate);
  }

  function schedule() {
    const active = appearance.stalls.some(
      (stall) =>
        stall.activity &&
        (stall.activity.waiting > 0 || stall.activity.staging),
    );
    const next =
      appearance.motion && appearance.detail && active && !document.hidden;
    if (animating === next) return;
    animating = next;
    if (next) frame = requestAnimationFrame(animate);
    else cancelAnimationFrame(frame);
  }

  function reset() {
    orbit.target.copy(centre);
    camera.position
      .copy(centre)
      .add(new T.Vector3(radius * 0.62, radius * 0.67, radius * 0.77));
    orbit.update();
    draw();
  }

  function focus(id: string) {
    const model = stalls.get(id);
    if (!model) return;
    const offset = camera.position
      .clone()
      .sub(orbit.target)
      .normalize()
      .multiplyScalar(8);
    orbit.target.copy(model.root.position).add(new T.Vector3(0, 0.75, 0.35));
    camera.position.copy(orbit.target).add(offset);
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
    press = [event.clientX, event.clientY];
  }
  function up(event: PointerEvent) {
    if (
      !press ||
      event.button !== 0 ||
      Math.hypot(event.clientX - press[0], event.clientY - press[1]) > 5
    )
      return;
    const selected = hit(event);
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
  function orbitChanged() {
    draw(performance.now());
  }
  orbit.addEventListener("change", orbitChanged);
  const resize = new ResizeObserver(() => {
    if (!host.clientWidth || !host.clientHeight) return;
    renderer.setPixelRatio(
      Math.min(window.devicePixelRatio, appearance.detail ? 1.65 : 1),
    );
    renderer.setSize(host.clientWidth, host.clientHeight, false);
    camera.aspect = host.clientWidth / host.clientHeight;
    camera.updateProjectionMatrix();
    draw();
  });
  resize.observe(host);
  function visibility() {
    schedule();
    if (!document.hidden) draw();
  }
  document.addEventListener("visibilitychange", visibility);

  return {
    update(next: Appearance) {
      const detailChanged = appearance.detail !== next.detail;
      appearance = next;
      const ids = new Set(next.stalls.map((stall) => stall.stall_id));
      for (const [id, model] of stalls) {
        if (!ids.has(id)) {
          discardCounter(model);
          stalls.delete(id);
        }
      }
      const indices = new Set([...stalls.values()].map((model) => model.index));
      let index = 0;
      for (const stall of next.stalls) {
        let model = stalls.get(stall.stall_id);
        if (model && model.cuisine !== stall.cuisine) {
          const index = model.index;
          discardCounter(model);
          model = createCounter(stall, index);
          stalls.set(stall.stall_id, model);
        }
        if (!model) {
          while (indices.has(index)) index++;
          model = createCounter(stall, index);
          indices.add(index);
          stalls.set(stall.stall_id, model);
        }
        paintSign(model, stall);
        model.activity = stall.activity;
        model.open = stall["open?"];
        model.shutters.visible = !model.open;
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
      const last = Math.max(0, ...indices);
      resizeFloor(Math.min(COLS, last + 1), 1 + Math.floor(last / COLS));
      if (detailChanged)
        renderer.setPixelRatio(
          Math.min(window.devicePixelRatio, next.detail ? 1.65 : 1),
        );
      if (!initialized) {
        initialized = true;
        reset();
      }
      schedule();
      draw(performance.now());
    },
    focus,
    reset,
    zoom(factor: number) {
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
      const delta = camera.position.clone().sub(orbit.target);
      delta.applyAxisAngle(new T.Vector3(0, 1, 0), angle);
      camera.position.copy(orbit.target).add(delta);
      orbit.update();
      draw();
    },
    camera(): CameraState {
      return { position: point(camera.position), target: point(orbit.target) };
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
      renderer.domElement.removeEventListener("webglcontextlost", lost);
      orbit.dispose();
      for (const model of stalls.values()) discardCounter(model);
      for (const mesh of [body, heads, steam]) {
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
        teal,
        plaqueMat,
        hitMat,
        laneMat,
        ...accents,
        ...awnings,
      ])
        material.dispose();
      for (const geometry of [box, signGeometry, actorGeometry, headGeometry])
        geometry.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      renderer.domElement.remove();
    },
  };
}
