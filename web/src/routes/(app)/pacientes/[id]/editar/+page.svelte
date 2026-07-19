<script lang="ts">
	import PatientForm from '$lib/components/patients/PatientForm.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();
</script>

<svelte:head><title>Editar · {data.patient.nome} · Pacientes · Cinetra</title></svelte:head>

<PatientForm
	patient={data.patient}
	professionals={data.professionals}
	error={form?.error ?? null}
/>
