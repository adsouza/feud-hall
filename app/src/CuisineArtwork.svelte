<script lang="ts">
  import { cuisineArtwork } from "./cuisine-artwork";

  let { cuisine, name }: { cuisine: string; name: string } = $props();
  let tile = $derived(cuisineArtwork.get(cuisine));
</script>

{#if tile}
  <figure class="cuisine-artwork">
    <div class="illustration">
      <img
        src={tile.url}
        alt=""
        width={tile.columns * 320}
        height={tile.rows * 320}
        style:width={`${tile.columns * 100}%`}
        style:height={`${tile.rows * 100}%`}
        style:left={`${-(tile.index % tile.columns) * 100}%`}
        style:top={`${-Math.floor(tile.index / tile.columns) * 100}%`}
      />
    </div>
    <figcaption>{name}</figcaption>
  </figure>
{/if}

<style>
  figure {
    display: none;
    margin: 0;
    overflow: hidden;
    border: 1px solid var(--line);
    border-radius: 1rem;
    background: var(--panel);
  }
  .illustration {
    position: relative;
    aspect-ratio: 1;
    overflow: hidden;
    background: #efdfbb;
  }
  img {
    position: absolute;
    max-width: none;
  }
  figcaption {
    padding: 0.8rem 1rem;
    text-align: center;
    font-weight: 650;
    overflow-wrap: anywhere;
  }
  @container (min-width: 60rem) {
    figure {
      display: block;
      position: sticky;
      top: 1rem;
    }
  }
</style>
