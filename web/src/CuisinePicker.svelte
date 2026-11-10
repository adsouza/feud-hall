<script lang="ts">
  import world from "./data/cuisine-map.json";

  let {
    cuisines,
    value = $bindable(""),
    label,
    title,
  }: {
    cuisines: string[];
    value?: string;
    label: string;
    title: (id: string) => string;
  } = $props();

  let hoveredCuisine = $state<string | null>(null);
  let focusedCuisine = $state<string | null>(null);
  const regions: Record<string, string> = world.regions;
  function select(event: KeyboardEvent, id: string) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      value = id;
    }
  }
</script>

<fieldset>
  <legend>{label}</legend>
  <svg viewBox="0 0 640 320" aria-label={label}>
    <path class="ocean" d={world.outline} />
    <path class="graticule" d={world.graticule} />
    <path class="land" d={world.land} />
    {#each cuisines as id (id)}
      {#if regions[id]}
        <path
          d={regions[id]}
          class="region"
          class:selected={value === id}
          role="button"
          tabindex="0"
          aria-label={title(id)}
          aria-pressed={value === id}
          onpointerenter={(event) => {
            if (event.pointerType !== "touch") hoveredCuisine = id;
          }}
          onpointerleave={() => (hoveredCuisine = null)}
          onfocus={(event) => {
            focusedCuisine = event.currentTarget.matches(":focus-visible")
              ? id
              : null;
          }}
          onblur={() => (focusedCuisine = null)}
          onclick={() => {
            value = id;
          }}
          onkeydown={(event) => select(event, id)}
        />
      {/if}
    {/each}
  </svg>
  <div class="choices">
    {#each cuisines as id (id)}
      <label class:highlighted={(hoveredCuisine ?? focusedCuisine) === id}
        ><input
          type="radio"
          name="cuisine"
          value={id}
          bind:group={value}
          required
        />
        {title(id)}</label
      >
    {/each}
  </div>
</fieldset>

<style>
  fieldset {
    margin: 1rem 0;
    border: 1px solid var(--line);
    border-radius: 0.6rem;
    padding: 0.65rem;
  }
  svg {
    display: block;
    max-width: 100%;
    width: min(100%, 42rem);
  }
  .ocean {
    fill: #18283c;
    stroke: #65708f;
  }
  .graticule {
    fill: none;
    stroke: #344761;
    stroke-width: 0.4;
  }
  .land {
    fill: #424962;
  }
  .region {
    fill: #ffcc55;
    stroke: #151623;
    stroke-width: 1;
    cursor: pointer;
  }
  .region:hover,
  .region:focus,
  .region.selected {
    fill: #91efd1;
    stroke: #fff;
    stroke-width: 1.5;
  }
  .choices {
    display: flex;
    gap: 0.75rem;
    flex-wrap: wrap;
  }
  label {
    display: flex;
    gap: 0.25rem;
    align-items: center;
  }
  label.highlighted {
    color: #91efd1;
    text-decoration: underline;
    text-underline-offset: 0.2em;
  }
  input {
    min-height: auto;
  }
</style>
