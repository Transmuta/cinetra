<script lang="ts">
	// Gêmea de `/privacidade`: mesma casca, outro documento.
	import LegalPage from '$lib/components/cinetra/LegalPage.svelte';
	import { TERMOS } from '$lib/legal';

	let { data }: { data: { canonical: string; origem: string } } = $props();
</script>

<LegalPage doc={TERMOS} canonical={data.canonical} origem={data.origem} />
