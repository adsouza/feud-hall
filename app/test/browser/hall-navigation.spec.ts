import * as T from "three";
import type { Page } from "@playwright/test";
import { test, expect, state } from "./hall";
import {
  hallLayout,
  walkingEntrance,
  stallBlocks,
  toStall,
} from "../../src/hall-layout";

test.use({
  launch: true,
  viewport: { width: 1280, height: 900 },
  launchOptions: {
    args: [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
    ],
  },
});

test("walking entrances prefer open counters and remain clear at every hall size", () => {
  const failures: string[] = [];
  for (let count = 1; count <= 150; count++) {
    const layout = hallLayout(count);
    for (const chosen of [0, Math.floor(count / 2), count - 1]) {
      const stalls = layout.placements.map((placement, i) => ({
        id: `stall-${i}`,
        open: i === chosen,
        placement,
      }));
      const entry = walkingEntrance(
        stalls,
        "stall-0",
        layout.floorWidth,
        layout.floorDepth,
      );
      if (entry.stall !== `stall-${chosen}`)
        failures.push("closed counter preferred");
      if (
        stalls.some((stall) =>
          stallBlocks(stall.placement, entry.position.x, entry.position.z),
        )
      )
        failures.push("spawn in booth");
      if (
        Math.abs(entry.position.x) > layout.floorWidth / 2 - 0.3 ||
        Math.abs(entry.position.z) > layout.floorDepth / 2 - 0.3
      )
        failures.push("spawn outside room");
      const local = toStall(
        stalls[chosen].placement,
        entry.position.x,
        entry.position.z,
      );
      if (local.z < 4 || Math.abs(local.x) > 1)
        failures.push("spawn behind counter");
    }
  }
  expect(failures).toEqual([]);
  const layout = hallLayout(3),
    stalls = layout.placements.map((placement, i) => ({
      id: String(i),
      open: false,
      placement,
    }));
  expect(
    walkingEntrance(stalls, "1", layout.floorWidth, layout.floorDepth).stall,
  ).toBe("1");
  expect(walkingEntrance([], "", 20, 20)).toEqual({
    stall: "",
    position: { x: 0, z: 0 },
    target: { x: 0, z: -6 },
  });
});

type Probe = Window & {
  hallViewMatrix: number[];
  __THREE_DEVTOOLS__: EventTarget;
};
// Observe the camera at the real draw boundary using Three's existing devtools hook.
function observeCamera(page: Page) {
  return page.addInitScript(() => {
    const probe = window as unknown as Probe;
    probe.__THREE_DEVTOOLS__ = new EventTarget();
    probe.__THREE_DEVTOOLS__.addEventListener("observe", (event) => {
      const renderer = (event as CustomEvent).detail as T.WebGLRenderer & {
        isWebGLRenderer?: boolean;
      };
      if (!renderer?.isWebGLRenderer) return;
      const draw = renderer.render;
      renderer.render = function (scene, camera) {
        draw.call(this, scene, camera);
        probe.hallViewMatrix = [...camera.matrixWorldInverse.elements];
      };
    });
  });
}
test("every first arrow enters at eye level facing an open stall, then walking resumes", async ({
  page,
  hall,
}, info) => {
  await observeCamera(page);
  await page.goto(hall.origin);
  const snapshot = await state(page);
  snapshot.hall.stalls[0]["open?"] = false;
  await page.route("**/api/state**", (route) =>
    route.fulfill({ json: snapshot }),
  );
  await page.reload();
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  const selected = page.getByRole("combobox", {
    name: "Location",
    exact: true,
  });
  await selected.selectOption(snapshot.hall.stalls[0].stall_id);
  async function pose() {
    const values = await page.evaluate(
      () => (window as unknown as Probe).hallViewMatrix,
    );
    expect(values).toHaveLength(16);
    const world = new T.Matrix4().fromArray(values).invert();
    return {
      position: new T.Vector3().setFromMatrixPosition(world),
      forward: new T.Vector3(0, 0, -1).transformDirection(world),
    };
  }
  const layout = hallLayout(snapshot.hall.stalls.length);
  for (const key of [
    "ArrowUp",
    "ArrowDown",
    "ArrowLeft",
    "ArrowRight",
    "Shift+ArrowLeft",
    "Shift+ArrowUp",
  ]) {
    await page
      .getByRole("button", { name: "Reset camera", exact: true })
      .click();
    await host.focus();
    await host.press(key);
    const camera = await pose();
    expect(camera.position.y, key).toBeCloseTo(1.55, 4);
    expect(Math.abs(camera.forward.y), key).toBeLessThan(0.08);
    const id = await selected.inputValue();
    const index = snapshot.hall.stalls.findIndex(
      (stall: any) => stall.stall_id === id,
    );
    expect(snapshot.hall.stalls[index]["open?"], key).toBe(true);
    const counter = layout.placements[index];
    const toward = new T.Vector3(
      counter.x - camera.position.x,
      0,
      counter.z - camera.position.z,
    ).normalize();
    expect(camera.forward.dot(toward), key).toBeGreaterThan(0.98);
    const local = toStall(counter, camera.position.x, camera.position.z);
    expect(local.z, key).toBeGreaterThan(4);
    expect(local.z, key).toBeLessThan(5.3);
  }
  await page.getByRole("button", { name: "Reset camera", exact: true }).click();
  await host.focus();
  await host.press("ArrowUp");
  const first = await pose();
  await host.press("ArrowUp");
  const second = await pose();
  expect(first.position.distanceTo(second.position)).toBeGreaterThan(0.08);
  expect(first.position.distanceTo(second.position)).toBeLessThan(0.3);
  // Ordinary focus changes and returning from another screen preserve the walk.
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect(host).toHaveAttribute("tabindex", "0");
  const restored = await pose();
  expect(second.position.distanceTo(restored.position)).toBeLessThan(1e-5);
  await host.focus();
  await host.press("ArrowUp");
  const resumed = await pose();
  expect(second.position.distanceTo(resumed.position)).toBeGreaterThan(0.08);
  expect(second.position.distanceTo(resumed.position)).toBeLessThan(0.3);
  // Opening and closing the in-world tablet returns to this walking position.
  const walkingId = await selected.inputValue();
  await host.press("e");
  await expect(host).toHaveAttribute("data-hall-tablet", walkingId);
  await host.press("Escape");
  await expect(host).toHaveAttribute("data-hall-tablet", "");
  expect(resumed.position.distanceTo((await pose()).position)).toBeLessThan(
    1e-5,
  );
  await host.press("ArrowUp");
  const afterMenu = await pose();
  expect(resumed.position.distanceTo(afterMenu.position)).toBeGreaterThan(0.08);
  expect(resumed.position.distanceTo(afterMenu.position)).toBeLessThan(0.3);
  await host
    .locator("canvas")
    .screenshot({ path: info.outputPath("walking-entry.png") });
});

test("returning to the hall with nothing selected keeps the overview camera", async ({
  page,
  hall,
}) => {
  await observeCamera(page);
  await page.goto(hall.origin);
  const host = page.locator("[data-hall-canvas]");
  await expect(host.locator("canvas")).toBeVisible();
  await expect(
    page.getByRole("combobox", { name: "Location", exact: true }),
  ).toHaveValue("");
  // Null until the current scene has drawn a frame.
  const position = async () => {
    const values = await page.evaluate(
      () => (window as unknown as Probe).hallViewMatrix,
    );
    if (values?.length !== 16) return null;
    const world = new T.Matrix4().fromArray(values).invert();
    return new T.Vector3().setFromMatrixPosition(world);
  };
  await expect.poll(position).not.toBeNull();
  const before = (await position())!;
  // Remounting hands the saved camera to a new scene, whose first update
  // must not rescale it as if the hall had grown from nothing.
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  await page.evaluate(() => {
    (window as unknown as Probe).hallViewMatrix = [];
  });
  await page.getByRole("button", { name: "Hall", exact: true }).click();
  await expect
    .poll(async () => (await position())?.distanceTo(before) ?? Infinity)
    .toBeLessThan(1e-5);
});
