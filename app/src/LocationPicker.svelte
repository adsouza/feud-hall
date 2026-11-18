<script lang="ts">
  import type { Slot, View } from "./api";
  import { cash } from "./api";
  import { contentLabel, label, type Key, type Locale } from "./i18n";
  import {
    DOOR_WIDTH,
    ENTRANCE_WIDTH,
    ROOM_SIDE,
    SPOTS_PER_ROOM,
    spotPlacement,
    tableSpots,
    type SpotKind,
  } from "./room-layout";
  import type { Snippet } from "svelte";

  let {
    slots,
    rooms,
    value = $bindable(""),
    locale,
    terms,
  }: {
    slots: Slot[];
    rooms: View["hall"]["rooms"];
    value?: string;
    locale: Locale;
    terms: Snippet;
  } = $props();

  const classes = {
    quiet: "quietTradeoff",
    standard: "standardTradeoff",
    busy: "busyTradeoff",
    prime: "primeTradeoff",
  } satisfies Record<SpotKind, Key>;
  const t = (key: Key) => label(locale, key);
  const title = (id: string) => contentLabel(locale, id);
  const roomLabel = (room: number) =>
    t("hallRoom").replace("{n}", String(room));

  // All rooms share one footprint. Only the server's quotes make a bay selectable.
  const planSide = ROOM_SIDE + 6;
  const planPercent = (offset: number) => `${50 + (offset / planSide) * 100}%`;
  const planPosition = ({ x, z }: { x: number; z: number }) =>
    `left: ${planPercent(x)}; top: ${planPercent(z)};`;
  const bays = Array.from({ length: SPOTS_PER_ROOM }, (_, index) =>
    planPosition(spotPlacement(1, index)),
  );
  const tables = tableSpots(1).map(planPosition);
  let browsedRoom = $state<number | null>(null);
  let selected = $derived(slots.find((slot) => slot.stall_id === value));
  let room = $derived(
    Math.min(browsedRoom ?? selected?.room ?? 1, rooms?.open ?? 1),
  );
  let slotsByRoom = $derived(
    rooms
      ? Array.from({ length: rooms.open }, (_, index) => ({
          room: index + 1,
          slots: slots.filter((slot) => slot.room === index + 1),
        }))
      : [],
  );
  let unmapped = $derived(
    rooms ? slots.filter((slot) => slot.room == null) : slots,
  );
  let roomSlots = $derived(
    new Map(slotsByRoom[room - 1]?.slots.map((slot) => [slot.position, slot])),
  );
</script>

<fieldset class="location-picker">
  <legend>{t("location")}</legend>
  <div class="location-layout">
    {#if rooms}
      <div class="floor">
        {#if rooms.open > 1}
          <nav class="floor-rooms" aria-label={t("hallRooms")}>
            {#each slotsByRoom as group (group.room)}
              <button
                type="button"
                aria-pressed={room === group.room}
                onclick={() => (browsedRoom = group.room)}
              >
                {roomLabel(group.room)}
              </button>
            {/each}
          </nav>
        {:else}
          <p class="floor-room">{roomLabel(room)}</p>
        {/if}
        <div
          class="plan"
          role="group"
          aria-label={t("stallFloorPlan") + " · " + roomLabel(room)}
          style:--wall-inset={planPercent(-ROOM_SIDE / 2)}
          style:--door-size={(DOOR_WIDTH / planSide) * 100 + "%"}
          style:--entrance-size={(ENTRANCE_WIDTH / planSide) * 100 + "%"}
        >
          <div class="walls" aria-hidden="true"></div>
          {#if room > 1}<span class="door west" aria-hidden="true"></span>{/if}
          {#if room < rooms.open}<span class="door east" aria-hidden="true"
            ></span>{/if}
          <span class="door entrance" aria-hidden="true"></span>
          <span class="entrance-label" aria-hidden="true"
            >{t("hallEntrance")}</span
          >
          {#each tables as at (at)}
            <span class="table" aria-hidden="true" style={at}></span>
          {/each}
          <span class="seating" aria-hidden="true">{t("hallSeating")}</span>
          {#each bays as at, index (index)}
            {@const slot = roomSlots.get(index)}
            {#if slot}
              {@const spotLabel = slot.stall_id + " · " + title(slot.tier)}
              <button
                type="button"
                class="bay"
                data-tier={slot.tier}
                style={at}
                aria-label={spotLabel}
                title={spotLabel}
                aria-pressed={value === slot.stall_id}
                onclick={() => {
                  value = slot.stall_id;
                  browsedRoom = null;
                }}>{slot.stall_id}</button
              >
            {:else}
              <span class="bay unavailable" aria-hidden="true" style={at}
                >×</span
              >
            {/if}
          {/each}
        </div>
        <p class="floor-caption">× {t("unavailableSpot")}</p>
      </div>
    {/if}

    <div class="location-info">
      {#snippet options(choices: Slot[])}
        {#each choices as slot (slot.stall_id)}
          <option value={slot.stall_id}>
            {slot.stall_id} · {title(slot.tier)} · {cash(slot.rent)}
          </option>
        {/each}
      {/snippet}
      {#if slots.length}
        <label>
          {t("location")}
          <select bind:value required onchange={() => (browsedRoom = null)}>
            <option value="">—</option>
            {#each slotsByRoom as group (group.room)}
              {#if group.slots.length}
                <optgroup label={roomLabel(group.room)}>
                  {@render options(group.slots)}
                </optgroup>
              {/if}
            {/each}
            {@render options(unmapped)}
          </select>
        </label>
      {:else}
        <p>{t("noLeaseSpots")}</p>
      {/if}
      {@render terms()}
      <h3>{t("locationClasses")}</h3>
      <dl class="classes">
        {#each Object.entries(classes) as [tier, explanation] (tier)}
          <div class="class" data-tier={tier}>
            <dt>{title(tier)}</dt>
            <dd>{t(explanation)}</dd>
          </div>
        {/each}
      </dl>
      <p class="traffic-hint">{t("locationTrafficHint")}</p>
    </div>
  </div>
</fieldset>

<style>
  .location-picker {
    margin: 1rem 0;
    border: 1px solid var(--line);
    border-radius: 0.6rem;
    padding: 0.65rem;
    min-width: 0;
    max-width: 61rem;
  }
  .location-layout {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 18rem), 1fr));
    gap: 1rem;
    align-items: start;
  }
  .floor {
    width: min(100%, 27rem);
  }
  .floor-rooms {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
  }
  .floor-rooms button {
    margin: 0;
  }
  .floor-rooms button[aria-pressed="true"] {
    border-color: var(--accent);
  }
  .floor-room {
    margin: 0;
    font-weight: 650;
  }
  .plan {
    position: relative;
    isolation: isolate;
    aspect-ratio: 1;
    margin-top: 0.45rem;
    background: #151a29;
    border-radius: 0.55rem;
  }
  .walls {
    position: absolute;
    inset: var(--wall-inset);
    border: 2px solid #6b7895;
    background: #232b40;
  }
  .door {
    position: absolute;
    background: #232b40;
  }
  .west,
  .east {
    top: 50%;
    transform: translateY(-50%);
    height: var(--door-size);
    width: 3px;
  }
  .west {
    left: var(--wall-inset);
  }
  .east {
    right: var(--wall-inset);
  }
  .entrance {
    bottom: var(--wall-inset);
    left: 50%;
    transform: translateX(-50%);
    height: 3px;
    width: var(--entrance-size);
  }
  .entrance-label {
    position: absolute;
    left: 50%;
    top: calc(100% - var(--wall-inset) + 1px);
    transform: translateX(-50%);
    color: var(--text-muted);
    font-size: 0.75rem;
  }
  .table,
  .seating {
    position: absolute;
    transform: translate(-50%, -50%);
  }
  .table {
    width: 5.5%;
    aspect-ratio: 1;
    border: 1px solid #748099;
    border-radius: 50%;
    background: #38435c;
  }
  .seating {
    top: 50%;
    left: 50%;
    font-size: 0.75rem;
    color: var(--text-muted);
  }
  .bay {
    position: absolute;
    transform: translate(-50%, -50%);
    width: 10.6%;
    height: 10.6%;
    min-height: 0;
    margin: 0;
    padding: 0;
    border: 1px solid var(--tier-color, var(--line));
    border-radius: 0.3rem;
    background: #171b2a;
    color: var(--tier-color, var(--text-muted));
    display: grid;
    place-items: center;
    font-size: clamp(0.62rem, 2.7vw, 0.78rem);
    line-height: 1;
  }
  .bay:hover {
    background: #353c52;
  }
  .bay[aria-pressed="true"] {
    background: var(--tier-color, var(--accent));
    color: #131623;
    box-shadow: 0 0 0 2px #fff;
    z-index: 1;
  }
  .unavailable {
    background: #30384d;
    border-color: #69728a;
  }
  .floor-caption {
    margin: 0.25rem 0 0;
    color: var(--text-muted);
    font-size: 0.8rem;
  }
  [data-tier="quiet"] {
    --tier-color: #99ddcf;
  }
  [data-tier="standard"] {
    --tier-color: #b9ccf6;
  }
  [data-tier="busy"] {
    --tier-color: #ffd48c;
  }
  [data-tier="prime"] {
    --tier-color: #f2b5e8;
  }
  .location-info {
    min-width: 0;
  }
  .location-info h3 {
    font-size: 1rem;
    margin: 0.9rem 0 0.45rem;
  }
  .classes {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    margin: 0;
  }
  .class {
    border: 1px solid var(--line);
    border-inline-start: 3px solid var(--tier-color);
    border-radius: 0.35rem;
    padding: 0.45rem;
  }
  .class dt {
    color: var(--tier-color);
    font-weight: 650;
  }
  .class dd,
  .traffic-hint {
    font-size: 0.85rem;
    color: var(--text-muted);
  }
  .traffic-hint {
    margin: 0.55rem 0 0;
  }
</style>
