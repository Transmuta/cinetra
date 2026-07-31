<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	// Formulário de nova exceção, fiel a `cfgFeriados` (:3266): data + descrição + segmented
	// "Fechar o dia inteiro" / "Horário específico" + períodos condicionais. Envia para a action
	// `?/add`; reseta no sucesso. `tipo` e `periods` viajam por hidden inputs.
	import { enhance } from '$app/forms';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import PeriodEditor from './PeriodEditor.svelte';
	import { validateDayPeriods, type ExceptionKind, type Period } from '$lib/scheduling';
	import ConflictsModal from '$lib/components/scheduling/ConflictsModal.svelte';
	import { parseFutureConflicts, type FutureConflicts } from '$lib/scheduling-conflicts';

	let { error = null }: { error?: string | null } = $props();

	let data = $state('');
	let nome = $state('');
	let tipo = $state<ExceptionKind>('fechado');
	let periods = $state<Period[]>([['08:00', '12:00']]);

	// A3/D12 — o 409 `future_conflicts` abre o modal com a lista. É aviso, não escolha: não há
	// "criar mesmo assim".
	let conflitos = $state<FutureConflicts | null>(null);

	// `reset: false` e limpeza à mão: os campos são `$state`, então quem os zera é o código —
	// e só no sucesso (ver `$lib/forms.svelte.ts`).
	const envio = criarEnvio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				data = '';
				nome = '';
				tipo = 'fechado';
				periods = [['08:00', '12:00']];
				conflitos = null;
			} else if (result.type === 'failure') {
				conflitos = parseFutureConflicts(result.data?.code, result.data?.meta);
			}
		}
	});


	const seg =
		'flex-1 rounded-controle border px-2 py-[7px] text-rotulo font-semibold cursor-pointer';

	// "Horário específico" com períodos inválidos trava o Adicionar (o PeriodEditor aponta o campo).
	const periodsInvalid = $derived(tipo === 'horario' && !validateDayPeriods(periods).ok);
</script>

<form
	method="POST"
	action="?/add"
	use:enhance={envio.submit}
	class="mb-3.5 rounded-cartao border border-edge bg-surface-2 p-3"
>
	<div class="mb-2.5 flex flex-wrap gap-2">
		<input
			type="date"
			name="data"
			bind:value={data}
			aria-label="Data da exceção"
			class="h-[38px] max-w-[170px] rounded-controle border border-edge bg-surface px-2.5 text-corpo text-ink"
		/>
		<input
			name="nome"
			bind:value={nome}
			placeholder="Descrição (ex.: feriado, evento)"
			class="h-[38px] min-w-0 flex-1 rounded-controle border border-edge bg-surface px-2.5 text-corpo text-ink"
		/>
	</div>

	<div class="mb-2.5 flex gap-1.5" role="group" aria-label="Tipo de exceção">
		<button
			type="button"
			onclick={() => (tipo = 'fechado')}
			aria-pressed={tipo === 'fechado'}
			class="{seg} {tipo === 'fechado'
				? 'border-accent bg-accent-subtle text-accent-text'
				: 'border-edge bg-surface text-muted'}"
		>
			Fechar o dia inteiro
		</button>
		<button
			type="button"
			onclick={() => (tipo = 'horario')}
			aria-pressed={tipo === 'horario'}
			class="{seg} {tipo === 'horario'
				? 'border-accent bg-accent-subtle text-accent-text'
				: 'border-edge bg-surface text-muted'}"
		>
			Horário específico
		</button>
	</div>
	<input type="hidden" name="tipo" value={tipo} />

	{#if tipo === 'horario'}
		<div class="mb-2.5">
			<p class="mb-1.5 text-meta text-muted">Períodos de atendimento neste dia:</p>
			<PeriodEditor {periods} onchange={(p) => (periods = p)} />
		</div>
		<input type="hidden" name="periods" value={JSON.stringify(periods)} />
	{/if}

	<Button type="submit"
		emVoo={envio.emVoo}
		disabled={data === '' || periodsInvalid}
	>
		Adicionar exceção
	</Button>

	{#if error}
		<p class="mt-2.5 text-rotulo font-medium text-danger">{error}</p>
	{/if}
</form>

{#if conflitos}
	<ConflictsModal {conflitos} onClose={() => (conflitos = null)} />
{/if}
