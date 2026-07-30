<script lang="ts">
	import PatientForm from '$lib/components/patients/PatientForm.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();
</script>

<svelte:head><title>Novo paciente · Pacientes · Cinetra</title></svelte:head>

<PatientForm professionals={data.professionals} error={form?.error ?? null} />
