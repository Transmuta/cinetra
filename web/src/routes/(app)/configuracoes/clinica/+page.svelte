<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import { maskCnpj, normalizeCnpj, isValidCnpj } from '$lib/cnpj';
	import { canManageClinic } from '$lib/session';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// Todo membro lê; só owner/admin edita (a policy da API é a autoridade — aqui é UX).
	const canManage = $derived(canManageClinic(data.me.papel));

	// Rascunho local: edita e só então salva (como Horário/Tipos). Reidratado do `data` após salvar.
	let nome = $state(untrack(() => data.clinic.nome));
	let cnpj = $state(untrack(() => maskCnpj(data.clinic.cnpj ?? '')));
	let endereco = $state(untrack(() => data.clinic.endereco ?? ''));

	// CNPJ é opcional; quando preenchido, precisa ser válido (espelho do `Api.Cnpj` — a API confirma).
	const cnpjInvalido = $derived(cnpj.trim() !== '' && !isValidCnpj(cnpj));

	const dirty = $derived(
		nome.trim() !== data.clinic.nome ||
			normalizeCnpj(cnpj) !== (data.clinic.cnpj ?? '') ||
			endereco.trim() !== (data.clinic.endereco ?? '')
	);
	const podeSalvar = $derived(dirty && nome.trim() !== '' && !cnpjInvalido);

	function sync() {
		nome = data.clinic.nome;
		cnpj = maskCnpj(data.clinic.cnpj ?? '');
		endereco = data.clinic.endereco ?? '';
	}

	const save = envio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				sync();
				toast('Dados da clínica salvos');
			} else if (result.type === 'failure') {
				const message = result.data?.error;
				toast(typeof message === 'string' ? message : 'Não foi possível salvar.', 'error');
			}
		}
	});

	function discard() {
		sync();
		toast('Alterações descartadas');
	}

	const inputCls = `${CONTROL_CLASS} ${CONTROL_PX} ${CONTROL_H} w-full`;
</script>

<svelte:head><title>Clínica · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		{#if canManage}
			<form method="POST" action="?/save" use:enhance={save.submit} class="space-y-4">
				<div>
					<label for="nome" class="mb-1 block text-rotulo font-medium text-muted">
						Nome da clínica <span class="text-danger">*</span>
					</label>
					<input
						id="nome"
						name="nome"
						bind:value={nome}
						maxlength="160"
						placeholder="ex.: Clínica Vida"
						class={inputCls}
					/>
				</div>

				<div>
					<label for="cnpj" class="mb-1 block text-rotulo font-medium text-muted">CNPJ</label>
					<input
						id="cnpj"
						name="cnpj"
						value={cnpj}
						oninput={(e) => (cnpj = maskCnpj(e.currentTarget.value))}
						inputmode="text"
						autocapitalize="characters"
						placeholder="00.000.000/0000-00"
						aria-invalid={cnpjInvalido}
						class="{inputCls} font-mono {cnpjInvalido ? 'border-danger' : ''}"
					/>
					{#if cnpjInvalido}
						<p class="mt-1 text-rotulo text-danger">CNPJ inválido.</p>
					{/if}
				</div>

				<div>
					<label for="endereco" class="mb-1 block text-rotulo font-medium text-muted">Endereço</label>
					<input
						id="endereco"
						name="endereco"
						bind:value={endereco}
						maxlength="200"
						placeholder="ex.: Rua das Flores, 100 — Centro, São Paulo/SP"
						class={inputCls}
					/>
				</div>

				<div class="flex items-center gap-2.5 border-t border-edge pt-3.5">
					<div
						class="flex flex-1 items-center gap-1.5 text-rotulo {cnpjInvalido
							? 'font-semibold text-danger'
							: dirty
								? 'font-semibold text-warning'
								: 'text-faint'}"
					>
						{#if cnpjInvalido}
							<Circle size={8} class="fill-danger text-danger" /> Corrija o CNPJ.
						{:else if dirty}
							<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
						{:else}
							O nome aparece no topo do menu lateral.
						{/if}
					</div>

					{#if dirty}
						<button
							type="button"
							onclick={discard}
							class="rounded-controle border border-edge bg-surface px-3.5 py-2 text-corpo font-semibold text-muted hover:bg-surface-2"
						>
							Descartar
						</button>
					{/if}

					<Button type="submit"
						emVoo={save.emVoo}
						disabled={!podeSalvar}
					>
						Salvar
					</Button>
				</div>
			</form>
		{:else}
			<!-- Leitura para não-gestores: a ficha sem os controles de edição. -->
			<h2 class="mb-3 text-leitura font-semibold">Dados da clínica</h2>
			<dl class="space-y-2.5 text-corpo">
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">Nome</dt>
					<dd class="font-medium">{data.clinic.nome}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">CNPJ</dt>
					<dd class="font-mono">{data.clinic.cnpj ? maskCnpj(data.clinic.cnpj) : '—'}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[90px] shrink-0 text-muted">Endereço</dt>
					<dd>{data.clinic.endereco ?? '—'}</dd>
				</div>
			</dl>
		{/if}
	</section>
</div>
