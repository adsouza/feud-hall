// The street side of the intro's made-up room 1: a forecourt for the street
// shot to stand on, a row of small upper windows across the facade that light
// one after another, glass in the big windows that brightens with the room's
// lights, and a blank lightbox over the entrance. Intro-only; the live hall
// never builds it.
import * as T from "three";
import { ENTRANCE_WIDTH, ROOM_SIDE, type Point } from "./room-layout";

// hall-shell's wall depth, window sill and head, doorway and wall heights.
const WALL_DEPTH = 0.22;
const SILL = 1.12;
const WINDOW_TOP = 3.45;
const DOORWAY_TOP = 3.05;
const WALL_TOP = 4.65;
/** The entrance wall's street face, from the room centre. */
export const FACADE_FACE = ROOM_SIDE / 2 + WALL_DEPTH;
const FORECOURT_WIDTH = 48;
const FORECOURT_DEPTH = 26;
/** The entrance lightbox stutters through this pattern as it comes on. */
const FLICKER = [1, 0, 1, 1, 0, 0, 1, 0, 1];
const FLICKER_STEP_MS = 60;

/** A small window on the facade, room-centre relative, lit from `at` ms. */
export type FacadeLight = {
  x: number;
  y: number;
  width: number;
  height: number;
  at: number;
};
const UPPER_WIDTH = 0.8;
const UPPER_HEIGHT = 0.5;
/** Each upper pane's frame is this much wider and taller than the pane. */
const UPPER_FRAME = 0.12;
const UPPER_FROM_MS = 4100;
const UPPER_STEP_MS = 400;
/**
 * The upper row, in the order it lights: in the plaster band above the big
 * windows, beside the entrance but clear of its lightbox, within the span the
 * street shot sees. One lights every 400 ms while the camera holds still.
 */
export const FACADE_LIGHTS: readonly FacadeLight[] = [
  4.4, -3.25, 5.55, -4.4, 3.25, -5.55,
].map((x, k) => ({
  x,
  y: (WINDOW_TOP + WALL_TOP) / 2,
  width: UPPER_WIDTH,
  height: UPPER_HEIGHT,
  at: UPPER_FROM_MS + k * UPPER_STEP_MS,
}));

const DARK = new T.Color("#2b2d3a");
const LIT = new T.Color("#ffffff");
const GLASS_DARK = new T.Color("#141a2a");
const GLASS_LIT = new T.Color("#ffd79c");

/** A lightbox with an accent band above and below: a sign with no words. */
export function lightboxTexture(accent: T.Color) {
  const canvas = document.createElement("canvas");
  canvas.width = 256;
  canvas.height = 40;
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.fillStyle = "#f3e4c6";
  ctx.fillRect(0, 0, 256, 40);
  ctx.fillStyle = "#" + accent.getHexString();
  ctx.fillRect(0, 0, 256, 5);
  ctx.fillRect(0, 35, 256, 5);
  const texture = new T.CanvasTexture(canvas);
  texture.colorSpace = T.SRGBColorSpace;
  return texture;
}

/** A sign's tint: dark, or lit. */
export function signTint(lit: boolean) {
  return lit ? LIT : DARK;
}

/**
 * The entrance wall's big windows, as hall-shell's buildWall lays out a
 * windowed wall around a central opening.
 */
function facadeWindows() {
  const from = ENTRANCE_WIDTH / 2;
  const length = FACADE_FACE - from;
  const count = Math.min(6, Math.max(1, Math.floor(length / 5)));
  const bay = length / count;
  const width = Math.min(3.8, bay * 0.72);
  return Array.from(
    { length: count },
    (_, i) => from + (i + 0.5) * bay,
  ).flatMap((x) => [
    { x: -x, width },
    { x, width },
  ]);
}

export function createIntroFacade(scene: T.Scene, centre: Point) {
  const group = new T.Group();
  group.position.set(centre.x, 0, centre.z);
  scene.add(group);

  // Just below the shell's own pavement, reaching well behind the camera.
  const forecourtGeometry = new T.BoxGeometry(
    FORECOURT_WIDTH,
    0.1,
    FORECOURT_DEPTH,
  );
  const paving = new T.MeshStandardMaterial({
    color: "#3b3e4a",
    roughness: 0.95,
  });
  const forecourt = new T.Mesh(forecourtGeometry, paving);
  forecourt.position.set(0, -0.1, FACADE_FACE + FORECOURT_DEPTH / 2);
  group.add(forecourt);

  // Glass in the big windows, within the wall's depth and facing the street:
  // the frames and plaster in front edge it, and from inside the room it
  // faces away and is culled. It brightens with the room's lights.
  const paneGeometry = new T.PlaneGeometry();
  const glass = new T.MeshBasicMaterial({ color: GLASS_DARK });
  for (const { x, width } of facadeWindows()) {
    const pane = new T.Mesh(paneGeometry, glass);
    pane.scale.set(width + 0.1, WINDOW_TOP - SILL + 0.1, 1);
    pane.position.set(x, (SILL + WINDOW_TOP) / 2, FACADE_FACE - 0.07);
    group.add(pane);
  }

  // The upper row: a dark frame on the plaster with a pane just in front.
  const unlitPane = new T.MeshBasicMaterial({ color: GLASS_DARK });
  const litPane = new T.MeshBasicMaterial({ color: GLASS_LIT });
  const frame = new T.MeshBasicMaterial({ color: "#292e3d" });
  const upper = FACADE_LIGHTS.map((light) => {
    const surround = new T.Mesh(paneGeometry, frame);
    surround.scale.set(
      light.width + UPPER_FRAME,
      light.height + UPPER_FRAME,
      1,
    );
    surround.position.set(light.x, light.y, FACADE_FACE + 0.01);
    const pane = new T.Mesh(paneGeometry, unlitPane);
    pane.scale.set(light.width, light.height, 1);
    pane.position.set(light.x, light.y, FACADE_FACE + 0.02);
    group.add(surround, pane);
    return { pane, at: light.at };
  });

  const signGeometry = new T.PlaneGeometry(ENTRANCE_WIDTH - 0.6, 0.8);
  const signMaterial = new T.MeshBasicMaterial({
    map: lightboxTexture(new T.Color("#ffb35c")),
    color: DARK,
  });
  const sign = new T.Mesh(signGeometry, signMaterial);
  sign.position.set(0, (DOORWAY_TOP + WALL_TOP) / 2 + 0.05, FACADE_FACE + 0.02);
  group.add(sign);
  let signSince: number | null = null;

  return {
    /**
     * `light`: the room's light level, 0 to 1. `skipped`: a skip went
     * straight to the hold, where everything is lit.
     */
    update(ms: number, light: number, signOn: boolean, skipped: boolean) {
      glass.color.lerpColors(GLASS_DARK, GLASS_LIT, skipped ? 1 : light);
      for (const { pane, at } of upper)
        pane.material = skipped || ms >= at ? litPane : unlitPane;
      if (!signOn) signSince = null;
      else signSince ??= ms;
      const step =
        signSince === null
          ? -1
          : Math.floor((ms - signSince) / FLICKER_STEP_MS);
      const lit =
        skipped || step >= FLICKER.length || (step >= 0 && FLICKER[step] === 1);
      signMaterial.color.copy(signTint(lit));
    },
    dispose() {
      scene.remove(group);
      signMaterial.map?.dispose();
      for (const material of [
        paving,
        glass,
        unlitPane,
        litPane,
        frame,
        signMaterial,
      ])
        material.dispose();
      for (const geometry of [forecourtGeometry, paneGeometry, signGeometry])
        geometry.dispose();
    },
  };
}
