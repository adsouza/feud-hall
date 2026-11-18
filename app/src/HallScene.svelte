<script lang="ts">
  import { onMount } from "svelte";
  import type { CounterPickup, Stall } from "./api";
  import type { Key } from "./i18n";
  import type {
    CameraState,
    HallTarget,
    HallVacancy,
    createHallScene,
  } from "./hall-scene";
  import type { TabletView, TabletAction } from "./hall-tablet";
  import { createHallAudio } from "./hall-audio";

  let {
    stalls,
    rooms,
    vacancies,
    serving,
    today,
    queueLimit,
    snapshot,
    saved,
    room = $bindable(saved?.room ?? 1),
    onVacancy,
    ownedStalls,
    selected,
    pickup,
    pickups,
    onTakePickup,
    tablet,
    onTabletAction,
    t,
    title,
    reopeningTime,
    select,
    inspect,
    interact,
    immersive,
    toggleImmersive,
    saveCamera,
    onUnavailable,
  }: {
    stalls: Stall[];
    rooms?: { count: number; open: number };
    vacancies?: HallVacancy[];
    serving: boolean;
    today?: { arrivals: number; admitted: number; left: number };
    queueLimit?: number;
    /** The view's `hall.position`: which server view the counts came from. */
    snapshot?: number;
    room?: number;
    onVacancy: (stallId: string) => void;
    ownedStalls: Stall[];
    selected: string;
    pickup: string;
    pickups: CounterPickup[];
    onTakePickup: (id: string) => boolean;
    tablet: TabletView | null;
    onTabletAction: (id: string, action: TabletAction) => void;
    saved: CameraState | undefined;
    t: (key: Key) => string;
    title: (id: string) => string;
    reopeningTime: (stall: Stall) => string;
    select: (id: string) => void;
    inspect: (id: string) => void;
    interact: (id: string, target: HallTarget) => void;
    immersive: boolean;
    toggleImmersive: () => void;
    saveCamera: (state: CameraState) => void;
    onUnavailable: () => void;
  } = $props();

  let host: HTMLDivElement;
  const targetLabels: Record<HallTarget, Key> = {
    menu: "hallMenuAction",
    counter: "hallCounterAction",
    staff: "hallStaffAction",
    supply: "hallSupplyAction",
  };
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
  let pickupStatus = $state<"" | "taking" | "taken">("");
  let inside = $state(saved?.inside?.stall ?? "");
  let ownerLocation = $state(saved?.inside?.stall ?? "");
  let ownerStall = $derived(
    ownedStalls.find((stall) => stall.stall_id === ownerLocation) ??
      ownedStalls.find((stall) => stall.stall_id === selected) ??
      ownedStalls[0],
  );

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
              select: (id) => inspect(id),
              interact,
              tablet: onTabletAction,
              collect: (id) => {
                if (!onTakePickup(id)) return false;
                pickupStatus = "taking";
                return true;
              },
              collected: () => (pickupStatus = "taken"),
              hover: (id) => (hovered = id),
              fail: onUnavailable,
              inside: (id) => (inside = id),
              walk: (id) => {
                lastSelection = id;
                select(id);
              },
              room: (next) => (room = next),
              vacancy: (id) => onVacancy(id),
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
      rooms,
      vacancies,
      serving,
      today,
      queueLimit,
      snapshot,
      toLetLabel: t("toLet"),
      ownedStalls: ownedStalls.map((stall) => stall.stall_id),
      selected,
      pickup,
      pickups,
      closedLabel: t("closed").toUpperCase(),
      cuisineLabel: title,
      reopeningHeading: t("reopeningExpected"),
      reopeningTime,
      detail: !reduced,
      motion: !motionPreference && !reduced,
      tablet,
      tabletLabel: t("tabletMenu"),
      tabletHint: t("tabletTap"),
    });
    if (inside && !ownedStalls.some((stall) => stall.stall_id === inside))
      inside = "";
    hall.setInside(inside);
    if (hall && !inside && selected && selected !== lastSelection)
      hall.focus(selected);
    hall.readMenu(tablet?.stall ?? "");
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

<div class="scene" class:immersive>
  <!-- svelte-ignore a11y_no_noninteractive_tabindex (The 3D view handles keyboard navigation while focused.) -->
  <div
    bind:this={host}
    class="canvas"
    data-hall-canvas
    data-hall-view={inside || "hall"}
    data-hall-tablet={tablet?.stall ?? ""}
    role="application"
    aria-label={t("hall3d")}
    aria-describedby="hall-keyboard-help"
    tabindex={hall ? 0 : -1}
  ></div>
  {#if !hall}<p class="scene-label">{t("loading")}</p>{/if}
  {#if hovered}
    <p class="scene-label">
      {stalls.find((stall) => stall.stall_id === hovered)?.name}
    </p>
  {/if}
</div>
{#if rooms}
  <div class="controls hall-rooms" role="group" aria-label={t("hallRooms")}>
    {#each Array.from({ length: rooms.count }, (_, i) => i + 1) as n (n)}
      <button
        aria-pressed={n === room}
        disabled={n > rooms.open}
        aria-describedby={n > rooms.open ? "hall-room-closed" : undefined}
        onclick={() => hall?.showRoom(n)}
        >{t("hallRoom").replace("{n}", String(n))}</button
      >
    {/each}
  </div>
  {#if rooms.open < rooms.count}
    <p id="hall-room-closed" class="hall-room-note">{t("hallRoomClosed")}</p>
  {/if}
{/if}
<div class="controls" role="group" aria-label={t("hallActions")}>
  <button aria-pressed={immersive} onclick={toggleImmersive}
    >{t(immersive ? "leaveImmersiveHall" : "enterImmersiveHall")}</button
  >
  {#if pickups.some((tray) => tray.stall === selected)}
    <button
      aria-keyshortcuts="F"
      disabled={!hall || pickupStatus === "taking"}
      onclick={() => {
        const tray = pickups.find((tray) => tray.stall === selected);
        if (tray) hall?.takePickup(tray.id);
      }}>{t("takeTray")}</button
    >
  {/if}
  {#if selected}
    {#each ["menu", "counter", "staff", ...(ownedStalls.some((stall) => stall.stall_id === selected) ? ["supply"] : [])] as target}
      <button
        disabled={!hall}
        onclick={() => interact(selected, target as HallTarget)}
        >{t(targetLabels[target as HallTarget])}</button
      >
    {/each}
  {/if}
</div>
<span class="sr-only" role="status"
  >{pickupStatus === "taking"
    ? t("takingTray")
    : pickupStatus === "taken"
      ? t("trayTaken")
      : ""}</span
>
<p class="keyboard-help">{t("hallInteractHelp")}</p>
{#if tablet}
  <p role="status" class="keyboard-help">{t("tabletKeyboardHelp")}</p>
  <details class="tablet-text-controls">
    <summary>{t("tabletAccessible")}</summary>
    <h2>{tablet.title} · {tablet.subtitle}</h2>
    <p class:tablet-error={tablet.noticeError}>{tablet.notice}</p>
    <ol>
      {#each tablet.rows as row, index}
        <li class:tablet-error={row.error}>
          {#if row.action}<button
              data-tablet-kind={row.action.kind}
              data-tablet-id={"id" in row.action ? row.action.id : undefined}
              data-tablet-row={index}
              disabled={row.disabled}
              onclick={() => onTabletAction(tablet.stall, row.action!)}
              >{row.text}</button
            >
          {:else}<span>{row.text}</span>{/if}
        </li>
      {/each}
    </ol>
    <button onclick={() => onTabletAction(tablet.stall, { kind: "close" })}
      >{t("tabletClose")}</button
    >
  </details>
{/if}
{#if ownerStall}
  <div class="controls" role="group" aria-label={t("ownerView")}>
    {#if ownedStalls.length > 1}
      <label
        >{t("yourStall")}
        <select
          value={ownerStall.stall_id}
          onchange={(event) => {
            ownerLocation = event.currentTarget.value;
            if (inside) {
              inside = ownerLocation;
              select(inside);
            }
          }}
        >
          {#each ownedStalls as stall (stall.stall_id)}
            <option value={stall.stall_id}
              >{stall.name} · {stall.stall_id}</option
            >
          {/each}
        </select>
      </label>
    {/if}
    <button
      disabled={!hall}
      aria-pressed={!!inside}
      onclick={() => {
        inside = inside ? "" : ownerStall.stall_id;
        if (inside) {
          ownerLocation = inside;
          select(inside);
        }
      }}>{t(inside ? "returnToHall" : "insideMyStall")}</button
    >
  </div>
{/if}
{#if inside}
  <p role="status">
    {t("insideStall").replace(
      "{stall}",
      stalls.find((stall) => stall.stall_id === inside)?.name ?? inside,
    )}
    {#if !stalls.find((stall) => stall.stall_id === inside)?.["open?"]}
      {t("insideClosedStall")}{/if}
  </p>
{/if}
<p id="hall-keyboard-help" class="keyboard-help">
  {t(inside ? "ownerKeyboardHelp" : "hallKeyboardHelp")}
</p>
<div class="controls" role="group" aria-label={t("cameraControls")}>
  <button
    disabled={!hall}
    onclick={() => {
      if (tablet) onTabletAction(tablet.stall, { kind: "close" });
      hall?.reset();
    }}>{t("resetCamera")}</button
  >
  <button disabled={!hall} onclick={() => hall?.rotate(Math.PI / 8)}
    >{t(inside ? "lookLeft" : "rotateLeft")}</button
  >
  <button disabled={!hall} onclick={() => hall?.rotate(-Math.PI / 8)}
    >{t(inside ? "lookRight" : "rotateRight")}</button
  >
  {#if inside}
    <button onclick={() => hall?.tilt(Math.PI / 18)}>{t("lookUp")}</button>
    <button onclick={() => hall?.tilt(-Math.PI / 18)}>{t("lookDown")}</button>
  {/if}
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
  .tablet-error {
    color: #ff8f93;
  }
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
  @media (width < 400px) {
    .canvas {
      height: clamp(15rem, 38svh, 22rem);
    }
  }
  .canvas:focus-visible {
    outline: 2px solid #ffcb67;
    outline-offset: -2px;
  }
  .keyboard-help {
    margin: 0.45rem 0;
    font-size: 0.85rem;
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
  .scene.immersive .canvas {
    height: min(78svh, 60rem);
    min-height: 22rem;
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
  .hall-room-note {
    margin-block: -0.35rem 0.65rem;
    font-size: 0.9em;
  }
</style>
