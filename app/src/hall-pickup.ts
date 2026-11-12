import * as T from "three";

/** A short cosmetic handover: reach, grasp, draw the tray toward the camera, lower it. */
export function createPickupHands(
  scene: T.Scene,
  camera: T.PerspectiveCamera,
  trayGeometry: T.BufferGeometry,
  trayMaterial: T.Material,
) {
  const root = new T.Group();
  root.name = "player-pickup-hands";
  root.visible = false;
  scene.add(root);
  const armGeometry = new T.CylinderGeometry(0.065, 0.082, 1, 8);
  const handGeometry = new T.BoxGeometry(0.14, 0.08, 0.19);
  const skin = new T.MeshStandardMaterial({ color: "#dca57f", roughness: 0.8 });
  const sleeve = new T.MeshStandardMaterial({
    color: "#6387b2",
    roughness: 0.85,
  });
  const arms = [-1, 1].map((side) => {
    const arm = new T.Mesh(armGeometry, sleeve),
      hand = new T.Mesh(handGeometry, skin);
    root.add(arm, hand);
    return { side, arm, hand };
  });
  const tray = new T.Mesh(trayGeometry, trayMaterial);
  tray.name = "player-carried-tray";
  root.add(tray);
  let started: number | null = null;
  const origin = new T.Vector3(),
    orientation = new T.Quaternion();
  const up = new T.Vector3(0, 1, 0),
    shoulder = new T.Vector3(),
    rest = new T.Vector3(),
    grip = new T.Vector3(),
    end = new T.Vector3(),
    direction = new T.Vector3();
  const smooth = (value: number) => T.MathUtils.smoothstep(value, 0, 1);
  const local = (x: number, y: number, z: number) =>
    camera.localToWorld(new T.Vector3(x, y, z));
  return {
    get active() {
      return started !== null;
    },
    begin(position: T.Vector3, quaternion: T.Quaternion, now: number) {
      origin.copy(position);
      orientation.copy(quaternion);
      started = now;
      root.visible = true;
    },
    finish() {
      started = null;
      root.visible = false;
    },
    update(now: number) {
      if (started === null) return;
      const t = Math.min(1, (now - started) / 1350);
      root.userData.phase =
        t < 0.35 ? "reaching" : t < 0.85 ? "taking" : "lowering";
      const pull = smooth((t - 0.35) / 0.5),
        lower = smooth((t - 0.85) / 0.15);
      const carried = local(0, -0.16 - lower * 0.85, -1.2);
      tray.position.copy(origin).lerp(carried, pull);
      const carriedRotation = camera.getWorldQuaternion(new T.Quaternion());
      tray.quaternion.copy(orientation).slerp(carriedRotation, pull);
      for (const { side, arm, hand } of arms) {
        shoulder.copy(local(side * 0.3, -0.4, -0.15));
        rest.copy(local(side * 0.3, -0.5, -0.4));
        grip
          .set(side * 0.43, 0.025, 0)
          .applyQuaternion(orientation)
          .add(origin);
        end.copy(local(side * 0.43, -0.16 - lower * 0.85, -1.2));
        hand.position
          .copy(rest)
          .lerp(grip, smooth(t / 0.35))
          .lerp(end, pull);
        direction.copy(hand.position).sub(shoulder);
        arm.position.copy(shoulder).add(hand.position).multiplyScalar(0.5);
        arm.scale.set(1, Math.max(0.05, direction.length()), 1);
        arm.quaternion.setFromUnitVectors(up, direction.normalize());
        hand.quaternion.copy(orientation).slerp(carriedRotation, pull);
      }
      if (t >= 1) {
        started = null;
        root.visible = false;
      }
    },
    dispose() {
      scene.remove(root);
      armGeometry.dispose();
      handGeometry.dispose();
      skin.dispose();
      sleeve.dispose();
    },
  };
}
