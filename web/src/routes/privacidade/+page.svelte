<script lang="ts">
	// O texto mora em `$lib/legal.ts` e a casca em `LegalPage`: esta rota é só a fiação entre os
	// dois. `/termos` é idêntica, com o outro documento.
	import LegalPage from '$lib/components/cinetra/LegalPage.svelte';
	import { PRIVACIDADE } from '$lib/legal';

	let { data }: { data: { canonical: string; origem: string } } = $props();
</script>

<LegalPage doc={PRIVACIDADE} canonical={data.canonical} origem={data.origem} />
