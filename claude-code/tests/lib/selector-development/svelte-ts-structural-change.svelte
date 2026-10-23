<script lang="ts">
  export let label: string;
  export let onClick: () => void;
</script>
<div class="wrapper"><button class="btn-primary" on:click={onClick}>{label}</button></div>
