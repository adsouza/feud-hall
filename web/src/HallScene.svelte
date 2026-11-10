<script lang="ts">
  import { onMount } from "svelte";
  import type { Stall } from "./api";
  import type { Key } from "./i18n";
  import type { CameraState, createHallScene } from "./hall-scene";
  import { createHallAudio } from "./hall-audio";

  let {
    stalls,
    selected,
    pickup,
    saved,
    t,
    select,
    saveCamera,
    onUnavailable,
  }: {
    stalls: Stall[];
    selected: string;
    pickup: string;
    saved: CameraState | undefined;
    t: (key: Key) => string;
    select: (id: string) => void;
    saveCamera: (state: CameraState) => void;
    onUnavailable: () => void;
  } = $props();

  let host: HTMLDivElement;
  let hall = $state.raw<ReturnType<typeof createHallScene> | null>(null);
  let hovered = $state<string | null>(null);
  let reduced = $state(false);
  let motionPreference = $state(false);
  let audio = $state.raw<ReturnType<typeof createHallAudio> | null>(null);
  let sound = $state(false);
  let soundFailed = $state(false);
  let master = $state(0.45);
  let ambience = $state(0.55);
  let effects = $state(0.5);
  let lastSelection = "";

  onMount(() => {
    let live = true;
    lastSelection = saved ? selected : "";
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updateMotion = () => (motionPreference = motion.matches);
    updateMotion();
    motion.addEventListener("change", updateMotion);
    void import("./hall-scene")
      .then(({ createHallScene }) => {
        if (live)
          hall = createHallScene(
            host,
            {
              select: (id) => select(id),
              hover: (id) => (hovered = id),
              fail: onUnavailable,
            },
            saved,
          );
      })
      .catch(() => {
        if (live) onUnavailable();
      });

    return () => {
      live = false;
      motion.removeEventListener("change", updateMotion);
      if (hall) {
        saveCamera(hall.camera());
        hall.dispose();
      }
      audio?.dispose();
    };
  });

  $effect(() => {
    if (!hall) return;
    hall.update({
      stalls,
      selected,
      pickup,
      detail: !reduced,
      motion: !motionPreference && !reduced,
    });
    if (hall && selected && selected !== lastSelection) hall.focus(selected);
    lastSelection = selected;
  });

  $effect(() => {
    audio?.levels(master, ambience, effects);
    audio?.update(stalls, selected);
  });

  async function toggleSound() {
    try {
      audio ??= createHallAudio(
        (id) => hall?.audioPosition(id) ?? { pan: 0, level: 1 },
      );
      await audio.play(!sound);
      sound = !sound;
    } catch {
      soundFailed = true;
    }
  }
</script>

<div class="scene">
  <div bind:this={host} class="canvas" data-hall-canvas></div>
  {#if !hall}<p class="scene-label">{t("loading")}</p>{/if}
  {#if hovered}
    <p class="scene-label">
      {stalls.find((stall) => stall.stall_id === hovered)?.name}
    </p>
  {/if}
</div>
<div class="controls" role="group" aria-label={t("cameraControls")}>
  <button disabled={!hall} onclick={() => hall?.reset()}
    >{t("resetCamera")}</button
  >
  <button disabled={!hall} onclick={() => hall?.rotate(Math.PI / 8)}
    >{t("rotateLeft")}</button
  >
  <button disabled={!hall} onclick={() => hall?.rotate(-Math.PI / 8)}
    >{t("rotateRight")}</button
  >
  <button disabled={!hall} onclick={() => hall?.zoom(0.8)}>{t("zoomIn")}</button
  >
  <button disabled={!hall} onclick={() => hall?.zoom(1.25)}
    >{t("zoomOut")}</button
  >
  <label
    ><input type="checkbox" bind:checked={reduced} />{t("reduceDetail")}</label
  >
  <button aria-pressed={sound} disabled={soundFailed} onclick={toggleSound}
    >{t("hallSound")}</button
  >
</div>
{#if sound}
  <div class="controls" role="group" aria-label={t("hallSound")}>
    <label
      >{t("masterVolume")}<input
        type="range"
        min="0"
        max="1"
        step="0.05"
        bind:value={master}
      /></label
    >
    <label
      >{t("ambienceVolume")}<input
        type="range"
        min="0"
        max="1"
        step="0.05"
        bind:value={ambience}
      /></label
    >
    <label
      >{t("effectsVolume")}<input
        type="range"
        min="0"
        max="1"
        step="0.05"
        bind:value={effects}
      /></label
    >
  </div>
{/if}
{#if soundFailed}<p role="status">{t("soundUnavailable")}</p>{/if}

<style>
  .scene {
    position: relative;
    border: 1px solid var(--line);
    border-radius: 0.9rem;
    overflow: hidden;
    background: #111526;
  }
  .canvas {
    height: clamp(15rem, 53vh, 34rem);
  }
  .canvas :global(canvas) {
    display: block;
    width: 100%;
    height: 100%;
    cursor: grab;
  }
  .canvas :global(canvas.hovering-stall) {
    cursor: pointer;
  }
  .scene-label {
    position: absolute;
    margin: 0;
    left: 0.75rem;
    bottom: 0.75rem;
    padding: 0.4rem 0.75rem;
    color: #fff3dd;
    background: #171827;
    border: 1px solid #707791;
    border-radius: 0.45rem;
    pointer-events: none;
  }
  .controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.45rem;
    margin-block: 0.65rem;
  }
  .controls label {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    margin: 0;
  }
  .controls input[type="range"] {
    width: 6rem;
  }
</style>
