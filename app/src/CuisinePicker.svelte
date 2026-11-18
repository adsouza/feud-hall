<script lang="ts">
  import type { View } from "./api";
  import world from "./data/cuisine-map.json";
  import {
    contentLabel,
    label as message,
    type Key,
    type Locale,
  } from "./i18n";

  let {
    cuisines,
    recipes,
    locale,
    value = $bindable(""),
    label,
    overlapLabel = label,
  }: {
    cuisines: string[];
    recipes: View["hall"]["recipes"];
    locale: Locale;
    value?: string;
    label: string;
    overlapLabel?: string;
  } = $props();

  const t = (key: Key) => message(locale, key);
  const title = (id: string) => contentLabel(locale, id);
  const kindOrder = { main: 0, drink: 1, dessert: 2 };
  let selectedRecipes = $derived(
    cuisines.includes(value)
      ? Object.values(recipes)
          .filter((recipe) => recipe.cuisine === value)
          .sort(
            (a, b) =>
              kindOrder[a.kind] - kindOrder[b.kind] || a.id.localeCompare(b.id),
          )
      : [],
  );

  let hoveredCuisine = $state<string | null>(null);
  let focusedCuisine = $state<string | null>(null);
  let overlapping = $state<string[]>([]);
  const regions: Record<string, string> = world.regions;
  function select(event: KeyboardEvent, id: string) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      choose(id);
    }
  }

  function choose(id: string) {
    value = id;
    overlapping = [];
  }

  function selectPoint(event: MouseEvent, id: string) {
    const target = event.currentTarget as SVGPathElement;
    const svg = target.ownerSVGElement;
    const matrix = svg?.getScreenCTM();
    if (!svg || !matrix || event.detail === 0) {
      choose(id);
      return;
    }

    const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(
      matrix.inverse(),
    );
    const matches = [
      ...svg.querySelectorAll<SVGPathElement>(".region"),
    ].flatMap((path) =>
      path.dataset.cuisine && path.isPointInFill(point)
        ? [path.dataset.cuisine]
        : [],
    );

    if (matches.length > 1) overlapping = matches;
    else choose(id);
  }
</script>

<fieldset>
  <legend>{label}</legend>
  <div class="picker-layout">
    <div>
      <svg viewBox="0 0 640 320" aria-label={label}>
        <path class="ocean" d={world.outline} />
        <path class="graticule" d={world.graticule} />
        <path class="land" d={world.land} />
        {#each cuisines as id (id)}
          {#if regions[id]}
            <path
              d={regions[id]}
              class="region"
              data-cuisine={id}
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
              onclick={(event) => selectPoint(event, id)}
              onkeydown={(event) => select(event, id)}
            />
          {/if}
        {/each}
      </svg>
      {#if overlapping.length}
        <div class="overlap" role="group" aria-label={overlapLabel}>
          <p>{overlapLabel}</p>
          {#each overlapping as id (id)}
            <button type="button" onclick={() => choose(id)}>{title(id)}</button
            >
          {/each}
        </div>
      {/if}
    </div>
    <div class="choices">
      {#each cuisines as id (id)}
        <label class:highlighted={(hoveredCuisine ?? focusedCuisine) === id}
          ><input
            type="radio"
            name="cuisine"
            value={id}
            bind:group={value}
            onchange={() => (overlapping = [])}
            required
          />
          {title(id)}</label
        >
      {/each}
    </div>
    <div class="recipe-preview" aria-live="polite" aria-atomic="true">
      {#if selectedRecipes.length}
        <h3>{t("cuisineRecipes").replace("{cuisine}", title(value))}</h3>
        <div class="recipe-groups">
          {#each [true, false] as starter}
            {@const group = selectedRecipes.filter(
              (recipe) => recipe.starter === starter,
            )}
            {#if group.length}
              <div>
                <h4>{t(starter ? "starterRecipes" : "unlockableRecipes")}</h4>
                <ul>
                  {#each group as recipe (recipe.id)}
                    <li>
                      {title(recipe.id)} <span>· {t(recipe.kind)}</span>
                    </li>
                  {/each}
                </ul>
              </div>
            {/if}
          {/each}
        </div>
      {:else}
        <p>{t("chooseCuisinePreview")}</p>
      {/if}
    </div>
  </div>
</fieldset>

<style>
  fieldset {
    margin: 1rem 0;
    border: 1px solid var(--line);
    border-radius: 0.6rem;
    padding: 0.65rem;
    min-width: 0;
    max-width: 61rem;
    container-type: inline-size;
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
  .recipe-preview {
    margin-top: 0.65rem;
    padding: 0.8rem;
    background: #171b2a;
    border: 1px solid var(--line);
    border-radius: 0.45rem;
  }
  .recipe-preview h3 {
    margin: 0 0 0.5rem;
  }
  .recipe-preview h4,
  .recipe-preview p {
    margin: 0;
  }
  .recipe-preview ul {
    margin: 0.25rem 0 0;
    padding-inline-start: 1.25rem;
  }
  .recipe-preview span {
    color: var(--text-muted);
    font-size: 0.85rem;
  }
  .recipe-groups {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 13rem), 1fr));
    gap: 0.75rem;
  }
  @container (min-width: 44rem) {
    .picker-layout {
      display: grid;
      grid-template-columns: minmax(0, 3fr) minmax(0, 2fr);
      align-items: start;
      gap: 0.65rem;
    }
    .choices {
      grid-column: 1 / -1;
    }
    .recipe-preview {
      grid-column: 2;
      grid-row: 1;
      margin-top: 0;
    }
  }
</style>
