<script lang="ts">
  import { onDestroy } from "svelte";
  import { compareDining, cash, serviceDuration } from "./api";
  import type { DiningFilters, DiningOption, DiningOptions } from "./api";
  import type { Key } from "./i18n";

  let {
    diets,
    signedIn,
    allowed,
    stall,
    filters = $bindable(),
    result = $bindable(),
    t,
    title,
    choose,
  }: {
    diets: string[];
    signedIn: boolean;
    allowed: boolean;
    stall: string;
    filters: DiningFilters;
    result: DiningOptions | null;
    t: (key: Key) => string;
    title: (id: string) => string;
    choose: (option: DiningOption, profile: string) => void;
  } = $props();

  let loading = $state(false);
  let failed = $state(false);
  let generation = 0;
  let searchedProfile = $state("");
  let stallFilter = $derived(filters.onlySelected ? stall : "");
  let valid = $derived(
    !filters.budget || /^\d{1,10}(\.\d{1,2})?$/.test(filters.budget),
  );

  onDestroy(() => {
    generation++;
  });

  function change() {
    generation++;
    result = null;
    loading = false;
    failed = false;
  }

  async function find(event: SubmitEvent) {
    event.preventDefault();
    if (!allowed || loading || !valid || !diets.includes(filters.profile))
      return;
    const [dollars, cents = ""] = filters.budget.split(".");
    const budget = dollars
      ? (BigInt(dollars) * 100n + BigInt(cents.padEnd(2, "0"))).toString()
      : "";
    const query = { ...filters, budget };
    const current = ++generation;
    loading = true;
    failed = false;
    try {
      const next = await compareDining(query, stallFilter);
      if (current === generation) {
        searchedProfile = query.profile;
        result = next;
      }
    } catch {
      if (current === generation) failed = true;
    } finally {
      if (current === generation) loading = false;
    }
  }

  $effect(() => {
    if (!diets.includes(filters.profile)) {
      filters.profile = diets[0] ?? "";
      change();
    }
  });

  $effect(() => {
    if (!allowed) change();
  });

  $effect(() => {
    if (filters.onlySelected) {
      if (!stallFilter) filters.onlySelected = false;
      change();
    }
  });
</script>

<details class="compare">
  <summary>{t("compareDining")}</summary>
  <form onsubmit={find} onchange={change}>
    <label
      >{t("diet")}
      <select bind:value={filters.profile} required>
        {#each diets as id (id)}<option value={id}>{title(id)}</option>{/each}
      </select>
    </label>
    <label
      >{t("budgetDollars")}
      <input
        inputmode="decimal"
        maxlength="13"
        bind:value={filters.budget}
        oninput={change}
      />
    </label>
    <label class="check"
      ><input
        type="checkbox"
        disabled={!stall}
        bind:checked={filters.onlySelected}
      />{t("onlySelectedStall")}</label
    >
    <label
      >{t("sortOffers")}
      <select bind:value={filters.sort}>
        <option value="wait">{t("fastestFirst")}</option>
        <option value="price">{t("cheapestFirst")}</option>
      </select>
    </label>
    <label class="check"
      ><input type="checkbox" bind:checked={filters.drink} />{t(
        "includeDrinkInCompare",
      )}</label
    >
    {#if signedIn}
      <label class="check"
        ><input type="checkbox" bind:checked={filters.newOnly} />{t(
          "newToMe",
        )}</label
      >
    {/if}
    <button disabled={!allowed || loading || !valid}>{t("findMeals")}</button>
  </form>
  {#if failed}<p role="status">{t("diningOptionsUnavailable")}</p>{/if}
  {#if result}
    {#if result.sold_out?.length}
      <p>{t("soldOut")} · {result.sold_out.map(title).join(", ")}</p>
    {/if}
    {#if signedIn}
      <p>
        {t("tastingList")} · {result.tasted.length
          ? result.tasted.map(title).join(", ")
          : t("nothingTasted")}
      </p>
    {/if}
    {#if result.options.length}
      <p>{t("compareEstimate")}</p>
      <p>
        {t("matchingMeals")
          .replace("{shown}", String(result.options.length))
          .replace("{total}", String(result.matched))}
      </p>
      <ul>
        {#each result.options as option (option.stall_id + ":" + option.main)}
          <li>
            <strong
              >{title(option.main)}{option.drink
                ? " + " + title(option.drink)
                : ""}</strong
            >
            <small
              >{option.name} · {cash(option.total)} · {t("estimatedWait")}
              {serviceDuration(option.completion - result.at)}</small
            >
            <button
              type="button"
              disabled={!allowed}
              onclick={() => choose(option, searchedProfile || filters.profile)}
            >
              {t("chooseMeal")}
            </button>
          </li>
        {/each}
      </ul>
    {:else}<p role="status">{t("noMatchingMeals")}</p>{/if}
  {/if}
</details>

<style>
  .compare {
    margin-block: 1rem;
  }
  form {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    gap: 0.65rem;
    margin-block: 0.7rem;
  }
  label {
    display: grid;
    gap: 0.2rem;
    margin: 0;
  }
  .check {
    display: inline-flex;
    align-items: center;
  }
  ul {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 14rem), 1fr));
    gap: 0.6rem;
    list-style: none;
    padding: 0;
  }
  li {
    display: grid;
    gap: 0.45rem;
    border: 1px solid var(--line);
    padding: 0.6rem;
    border-radius: 0.6rem;
  }
</style>
