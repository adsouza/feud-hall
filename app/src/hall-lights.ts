import * as T from "three";

const DAY = { ambient: 2.4, key: 2.2, fill: 0.95 };
/** Night keeps a tenth of the daylight: dim, never black. */
const NIGHT_SHARE = 0.1;

/**
 * The hall's three lights. `setLevel(1)` is the lighting the hall always
 * had; `setLevel(0)` is night. Levels between blend linearly.
 */
export function createHallLights(scene: T.Scene) {
  const ambient = new T.HemisphereLight("#ffe8c9", "#7a72ac", DAY.ambient);
  const key = new T.DirectionalLight("#fff3d9", DAY.key);
  key.position.set(-6, 12, 8);
  const fill = new T.DirectionalLight("#8bbcff", DAY.fill);
  fill.position.set(9, 6, -10);
  scene.add(ambient, key, fill);

  return {
    setLevel(level: number) {
      const share =
        NIGHT_SHARE + (1 - NIGHT_SHARE) * Math.min(Math.max(level, 0), 1);
      ambient.intensity = DAY.ambient * share;
      key.intensity = DAY.key * share;
      fill.intensity = DAY.fill * share;
    },
    dispose() {
      scene.remove(ambient, key, fill);
      ambient.dispose();
      key.dispose();
      fill.dispose();
    },
  };
}
