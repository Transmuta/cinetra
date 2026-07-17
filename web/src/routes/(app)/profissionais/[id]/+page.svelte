<script lang="ts">
	import ProfessionalForm from '$lib/components/professionals/ProfessionalForm.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();
</script>

<svelte:head><title>{data.professional.nome} · Profissionais · Cinetra</title></svelte:head>

<ProfessionalForm
	professional={data.professional}
	clinicHours={data.clinicHours}
	error={form?.error ?? null}
/>
