// The street side of the intro's made-up room 1: a forecourt for the street
// shot to stand on, window panes on the entrance facade that light one after
// another, and a blank lightbox over the entrance. Intro-only; the live hall
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
const FACE = ROOM_SIDE / 2 + WALL_DEPTH;
const FORECOURT_WIDTH = 48;
const FORECOURT_DEPTH = 26;
/** The first facade window lights here; each next one this much later. */
const WINDOWS_FROM_MS = 4050;
const WINDOW_STEP_MS = 250;
/** The entrance lightbox stutters through this pattern as it comes on. */
const FLICKER = [1, 0, 1, 1, 0, 0, 1, 0, 1];
const FLICKER_STEP_MS = 60;

const DARK = new T.Color("#2b2d3a");
const LIT = new T.Color("#ffffff");

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
 * The entrance wall's windows, as hall-shell's buildWall lays out a windowed
 * wall around a central opening: nearest the entrance first, left then right.
 */
function facadeWindows() {
  const from = ENTRANCE_WIDTH / 2;
  const length = ROOM_SIDE / 2 + WALL_DEPTH - from;
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
  forecourt.position.set(0, -0.1, FACE + FORECOURT_DEPTH / 2);
  group.add(forecourt);

  // Within the wall's depth, facing the street: the frames and plaster in
  // front edge them, and from inside the room they face away and are culled.
  const paneGeometry = new T.PlaneGeometry();
  const unlitPane = new T.MeshBasicMaterial({ color: "#141a2a" });
  const litPane = new T.MeshBasicMaterial({ color: "#ffd79c" });
  const panes = facadeWindows().map(({ x, width }) => {
    const pane = new T.Mesh(paneGeometry, unlitPane);
    pane.scale.set(width + 0.1, WINDOW_TOP - SILL + 0.1, 1);
    pane.position.set(x, (SILL + WINDOW_TOP) / 2, FACE - 0.07);
    group.add(pane);
    return pane;
  });

  const signGeometry = new T.PlaneGeometry(ENTRANCE_WIDTH - 0.6, 0.8);
  const signMaterial = new T.MeshBasicMaterial({
    map: lightboxTexture(new T.Color("#ffb35c")),
    color: DARK,
  });
  const sign = new T.Mesh(signGeometry, signMaterial);
  sign.position.set(0, (DOORWAY_TOP + WALL_TOP) / 2 + 0.05, FACE + 0.02);
  group.add(sign);
  let signSince: number | null = null;

  return {
    /** `skipped`: a skip went straight to the hold, where all is lit. */
    update(ms: number, signOn: boolean, skipped: boolean) {
      panes.forEach((pane, k) => {
        const lit = skipped || ms >= WINDOWS_FROM_MS + k * WINDOW_STEP_MS;
        pane.material = lit ? litPane : unlitPane;
      });
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
      for (const material of [paving, unlitPane, litPane, signMaterial])
        material.dispose();
      for (const geometry of [forecourtGeometry, paneGeometry, signGeometry])
        geometry.dispose();
    },
  };
}
