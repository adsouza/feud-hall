import * as T from "three";
import { mergeGeometries } from "three/addons/utils/BufferGeometryUtils.js";
import { cuisineArtwork } from "./cuisine-artwork";

type StallPlacement = { cuisine: string; root: T.Group };
type StripeLabel = {
  batch: T.InstancedMesh<T.BufferGeometry, T.MeshBasicMaterial>;
  context: CanvasRenderingContext2D;
  texture: T.CanvasTexture;
  text: string;
};
const LABEL_FONT = '"Noto Sans JP", system-ui, sans-serif';

export function createCuisineArt(
  parent: T.Group,
  capacity: number,
  redraw: () => void,
) {
  const panels = [
    new T.PlaneGeometry(0.64, 0.64).translate(0.83, 0.44, 1.083),
    new T.PlaneGeometry(1.18, 1.18)
      .rotateY(Math.PI / 2)
      .translate(1.586, 1.55, -0.03),
    new T.PlaneGeometry(1.18, 1.18)
      .rotateY(-Math.PI / 2)
      .translate(-1.586, 1.55, -0.03),
  ];
  const geometry = mergeGeometries(panels);
  const stripe = new T.PlaneGeometry(1.86, 0.24).translate(-0.44, 0.35, 1.079);
  for (const panel of panels) panel.dispose();
  const materials = new Map<string, T.MeshBasicMaterial>();
  const batches = new Map<string, T.InstancedMesh>();
  const labels = new Map<string, StripeLabel>();
  const instances: T.InstancedMesh[] = [];
  let disposed = false;

  function addBatch(panel: T.BufferGeometry, material: T.MeshBasicMaterial) {
    const batch = new T.InstancedMesh(panel, material, capacity);
    batch.count = 0;
    batch.frustumCulled = false;
    batch.instanceMatrix.setUsage(T.DynamicDrawUsage);
    parent.add(batch);
    instances.push(batch);
    return batch;
  }

  function materialFor(url: string) {
    const existing = materials.get(url);
    if (existing) return existing;
    const material = new T.MeshBasicMaterial({ visible: false });
    materials.set(url, material);

    const image = new Image();
    image.onload = () => {
      if (disposed) return;
      const map = new T.Texture(image);
      map.colorSpace = T.SRGBColorSpace;
      map.needsUpdate = true;
      material.map = map;
      material.visible = true;
      material.needsUpdate = true;
      redraw();
    };
    image.src = url;
    return material;
  }

  function batchFor(cuisine: string) {
    const existing = batches.get(cuisine);
    if (existing) return existing;
    const tile = cuisineArtwork.get(cuisine);
    if (!tile) return;

    const poster = geometry.clone();
    const uv = poster.attributes.uv;
    const column = tile.index % tile.columns;
    const row = Math.floor(tile.index / tile.columns);
    // Inset the sample inside each tile to keep its parchment margin clean.
    for (let i = 0; i < uv.count; i++) {
      uv.setXY(
        i,
        (column + 0.01 + uv.getX(i) * 0.98) / tile.columns,
        (tile.rows - 1 - row + 0.01 + uv.getY(i) * 0.98) / tile.rows,
      );
    }
    const batch = addBatch(poster, materialFor(tile.url));
    batches.set(cuisine, batch);
    return batch;
  }

  function paintLabel(label: StripeLabel) {
    const ctx = label.context;
    const { width, height } = ctx.canvas;
    ctx.clearRect(0, 0, width, height);
    ctx.font = `900 82px ${LABEL_FONT}`;
    const size = Math.min(
      82,
      (82 * (width - 36)) / ctx.measureText(label.text).width,
    );
    ctx.font = `900 ${size}px ${LABEL_FONT}`;
    ctx.fillStyle = "#171a2a";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label.text, width / 2, height / 2);
    label.texture.needsUpdate = true;
  }

  function labelFor(cuisine: string, name: string) {
    let label = labels.get(cuisine);
    if (!label) {
      const canvas = document.createElement("canvas");
      canvas.width = 768;
      canvas.height = 100;
      const context = canvas.getContext("2d");
      if (!context) return;
      const texture = new T.CanvasTexture(canvas);
      texture.colorSpace = T.SRGBColorSpace;
      const material = new T.MeshBasicMaterial({
        map: texture,
        transparent: true,
        depthWrite: false,
      });
      label = { batch: addBatch(stripe, material), context, texture, text: "" };
      labels.set(cuisine, label);
    }

    const text = name.toUpperCase();
    if (label.text !== text) {
      label.text = text;
      paintLabel(label);
      const font = `900 82px ${LABEL_FONT}`;
      if (!document.fonts.check(font, text)) {
        const current = label;
        void document.fonts
          .load(font, text)
          .then(() => {
            if (disposed || current.text !== text) return;
            paintLabel(current);
            redraw();
          })
          .catch(() => {});
      }
    }
    return label.batch;
  }

  return {
    update(
      stalls: Iterable<StallPlacement>,
      cuisineLabel: (id: string) => string,
    ) {
      for (const batch of instances) batch.count = 0;
      for (const { cuisine, root } of stalls) {
        root.updateMatrix();
        const poster = batchFor(cuisine);
        const label = labelFor(cuisine, cuisineLabel(cuisine));
        if (poster) poster.setMatrixAt(poster.count++, root.matrix);
        if (label) label.setMatrixAt(label.count++, root.matrix);
      }
      for (const batch of instances) {
        if (batch.count > 0) batch.instanceMatrix.needsUpdate = true;
      }
    },
    dispose() {
      disposed = true;
      for (const batch of instances) {
        parent.remove(batch);
        if (batch.geometry !== stripe) batch.geometry.dispose();
        batch.dispose();
      }
      for (const { batch, texture } of labels.values()) {
        texture.dispose();
        batch.material.dispose();
      }
      for (const material of materials.values()) {
        material.map?.dispose();
        material.dispose();
      }
      geometry.dispose();
      stripe.dispose();
    },
  };
}
