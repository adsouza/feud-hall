<script module lang="ts">
  export const INTRO_DISSOLVE_MS = 500;
  const HINT_MS = 6000;
</script>

<script lang="ts">
  import { onMount } from "svelte";
  import type { Key } from "./i18n";
  import { createHallIntro } from "./hall-intro";

  let {
    ending,
    t,
    onEnded,
    onFail,
  }: {
    ending: boolean;
    t: (key: Key) => string;
    onEnded: () => void;
    onFail: () => void;
  } = $props();

  let host: HTMLDivElement;
  let scene: ReturnType<typeof createHallIntro> = null;
  let hintVisible = $state(true);
  let faded = $state(false);
  let failed = false;
  let ended = false;
  let dissolveTimer: ReturnType<typeof setTimeout> | undefined;

  function disposeScene() {
    scene?.dispose();
    scene = null;
  }

  function fail() {
    if (failed || ended) return;
    failed = true;
    disposeScene();
    onFail();
  }

  function skipOnInput() {
    if (!ending) scene?.skip();
  }

  onMount(() => {
    scene = createHallIntro(host, fail);
    if (!scene) fail();
    const hintTimer = setTimeout(() => (hintVisible = false), HINT_MS);
    window.addEventListener("pointerdown", skipOnInput);
    window.addEventListener("keydown", skipOnInput);
    return () => {
      clearTimeout(hintTimer);
      clearTimeout(dissolveTimer);
      window.removeEventListener("pointerdown", skipOnInput);
      window.removeEventListener("keydown", skipOnInput);
      disposeScene();
    };
  });

  $effect(() => {
    if (!ending || ended || failed || dissolveTimer !== undefined) return;
    faded = true;
    dissolveTimer = setTimeout(() => {
      ended = true;
      disposeScene();
      onEnded();
    }, INTRO_DISSOLVE_MS);
  });
</script>

<div
  class="hall-intro"
  class:faded
  style:transition-duration="{INTRO_DISSOLVE_MS}ms"
  style:pointer-events={ending ? "none" : null}
  data-hall-intro
  aria-hidden="true"
  bind:this={host}
>
  <div class="vignette"></div>
  <div class="bar top"></div>
  <div class="bar bottom"></div>
  {#if hintVisible}
    <p class="hint">{t("introSkip")}</p>
  {/if}
</div>

<style>
  .hall-intro {
    position: absolute;
    inset: 0;
    overflow: hidden;
    background: #111526;
    opacity: 1;
    transition-property: opacity;
    transition-timing-function: linear;
  }
  .hall-intro.faded {
    opacity: 0;
  }
  .hall-intro :global(canvas) {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    display: block;
  }
  .vignette,
  .bar,
  .hint {
    position: absolute;
    pointer-events: none;
    z-index: 1;
  }
  .vignette {
    inset: 0;
    background: radial-gradient(
      ellipse at center,
      rgba(0, 0, 0, 0) 55%,
      rgba(0, 0, 0, 0.55) 100%
    );
  }
  .bar {
    left: 0;
    right: 0;
    height: 10%;
    background: #000;
  }
  .bar.top {
    top: 0;
  }
  .bar.bottom {
    bottom: 0;
  }
  .hint {
    left: 0;
    right: 0;
    bottom: calc(10% + 0.75rem);
    margin: 0;
    text-align: center;
    font-size: 0.8rem;
    color: #e8eaf2;
    text-shadow: 0 1px 3px rgba(0, 0, 0, 0.8);
  }
</style>
