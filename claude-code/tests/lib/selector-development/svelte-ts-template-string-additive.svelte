<script lang="ts">
  export let label: string;
  // A template string containing a (properly escaped) closing-script
  // sequence — exercises that a lang="ts" script with template literals
  // parses under svelte 5 without breaking selector validation. The escape
  // `<\/script>` is the HTML-spec-correct way to embed the sequence.
  const snippet: string = `<div></div><\/script>`;
</script>
<button class="btn-primary" on:click={() => console.log(snippet)} data-testid="primary-button">{label}</button>
