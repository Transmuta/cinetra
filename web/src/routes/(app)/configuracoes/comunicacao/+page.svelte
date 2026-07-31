<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	// O que a clínica manda ao paciente, e quando (doc 52 §7).
	//
	// Por clínica, não por profissional: por profissional vira matriz que ninguém mantém.
	//
	// A tela existe para tornar **ligar o lembrete** uma escolha de número, não um deploy — o cron
	// nasceu construído e calado de propósito, e é aqui que ele acorda.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import Info from '@lucide/svelte/icons/info';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import { canManageClinic } from '$lib/session';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	const canManage = $derived(canManageClinic(data.me.papel));

	// Rascunho local, como nas outras telas de config: edita e só então salva.
	let confirmacao = $state(untrack(() => data.clinic.msg_confirmacao_auto));
	let lembrete = $state(untrack(() => data.clinic.msg_lembrete_horas != null));
	let horas = $state(untrack(() => String(data.clinic.msg_lembrete_horas ?? 24)));
	let silencio = $state(untrack(() => data.clinic.msg_silencio_inicio != null));
	let inicio = $state(untrack(() => String(data.clinic.msg_silencio_inicio ?? 21)));
	let fim = $state(untrack(() => String(data.clinic.msg_silencio_fim ?? 8)));

	// O que de fato será enviado — o "desligado" do lembrete é `null`, não zero.
	const horasEfetivas = $derived(lembrete ? Number(horas) : null);
	const horasInvalidas = $derived(
		lembrete && (!Number.isInteger(Number(horas)) || Number(horas) < 1 || Number(horas) > 168)
	);

	const dirty = $derived(
		confirmacao !== data.clinic.msg_confirmacao_auto ||
			horasEfetivas !== (data.clinic.msg_lembrete_horas ?? null) ||
			(silencio ? Number(inicio) : null) !== (data.clinic.msg_silencio_inicio ?? null) ||
			(silencio ? Number(fim) : null) !== (data.clinic.msg_silencio_fim ?? null)
	);

	function sync() {
		confirmacao = data.clinic.msg_confirmacao_auto;
		lembrete = data.clinic.msg_lembrete_horas != null;
		horas = String(data.clinic.msg_lembrete_horas ?? 24);
		silencio = data.clinic.msg_silencio_inicio != null;
		inicio = String(data.clinic.msg_silencio_inicio ?? 21);
		fim = String(data.clinic.msg_silencio_fim ?? 8);
	}

	const save = envio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				sync();
				toast('Configuração de comunicação salva');
			} else if (result.type === 'failure') {
				const message = result.data?.error;
				toast(typeof message === 'string' ? message : 'Não foi possível salvar.', 'error');
			}
		}
	});

	const inputCls = `${CONTROL_CLASS} ${CONTROL_PX} ${CONTROL_H} w-[86px]`;
</script>

<svelte:head><title>Comunicação · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		{#if canManage}
			<form method="POST" action="?/save" use:enhance={save.submit} class="space-y-5">
				<!-- Confirmação na criação -->
				<div class="flex items-start justify-between gap-4">
					<div>
						<p class="text-corpo font-semibold">Confirmar automaticamente</p>
						<p class="mt-0.5 text-rotulo text-muted">
							Ao marcar uma sessão, o paciente recebe a confirmação na hora.
						</p>
					</div>
					<SwitchToggle
						checked={confirmacao}
						onchange={() => (confirmacao = !confirmacao)}
						label="Confirmação automática"
					/>
					<input type="hidden" name="msg_confirmacao_auto" value={confirmacao ? 'on' : ''} />
				</div>

				<!-- Lembrete -->
				<div class="border-t border-edge pt-5">
					<div class="flex items-start justify-between gap-4">
						<div>
							<p class="text-corpo font-semibold">Lembrar antes da sessão</p>
							<p class="mt-0.5 text-rotulo text-muted">
								Uma segunda mensagem, algumas horas antes.
							</p>
						</div>
						<SwitchToggle
							checked={lembrete}
							onchange={() => (lembrete = !lembrete)}
							label="Lembrete antes da sessão"
						/>
					</div>

					{#if lembrete}
						<div class="mt-3 flex items-center gap-2 text-corpo">
							<input
								id="horas"
								name="msg_lembrete_horas"
								bind:value={horas}
								type="number"
								min="1"
								max="168"
								aria-invalid={horasInvalidas}
								class="{inputCls} {horasInvalidas ? 'border-danger' : ''}"
							/>
							<label for="horas" class="text-muted">horas antes</label>
						</div>
						{#if horasInvalidas}
							<p class="mt-1 text-rotulo text-danger">Escolha entre 1 e 168 horas.</p>
						{/if}
					{:else}
						<!-- Desligado é `null` no servidor, e o campo nem viaja: mandar 0 ligaria o
						     lembrete para o instante da sessão. -->
						<input type="hidden" name="msg_lembrete_horas" value="" />
					{/if}
				</div>

				<!-- Janela de silêncio -->
				<div class="border-t border-edge pt-5">
					<div class="flex items-start justify-between gap-4">
						<div>
							<p class="text-corpo font-semibold">Não incomodar</p>
							<p class="mt-0.5 text-rotulo text-muted">
								Mensagem que cairia nesse intervalo é <strong>adiada</strong>, não descartada.
							</p>
						</div>
						<SwitchToggle
							checked={silencio}
							onchange={() => (silencio = !silencio)}
							label="Janela de silêncio"
						/>
					</div>

					{#if silencio}
						<div class="mt-3 flex items-center gap-2 text-corpo">
							<label for="inicio" class="text-muted">das</label>
							<input
								id="inicio"
								name="msg_silencio_inicio"
								bind:value={inicio}
								type="number"
								min="0"
								max="23"
								class={inputCls}
							/>
							<label for="fim" class="text-muted">h às</label>
							<input
								id="fim"
								name="msg_silencio_fim"
								bind:value={fim}
								type="number"
								min="0"
								max="23"
								class={inputCls}
							/>
							<span class="text-muted">h</span>
						</div>
					{/if}
				</div>

				<div
					class="flex items-start gap-2 rounded-controle bg-surface-2 px-3.5 py-3 text-rotulo text-muted"
				>
					<span class="mt-0.5 shrink-0 text-faint"><Info size={14} /></span>
					<span>
						Só recebe quem tem <strong>consentimento de comunicação</strong> na ficha e um contato
						cadastrado. Quem pediu para não receber continua de fora, mesmo com tudo ligado aqui.
					</span>
				</div>

				<div class="flex items-center gap-2.5 border-t border-edge pt-3.5">
					<div
						class="flex flex-1 items-center gap-1.5 text-rotulo {dirty
							? 'font-semibold text-warning'
							: 'text-faint'}"
					>
						{#if dirty}
							<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
						{:else}
							Vale para toda a clínica.
						{/if}
					</div>

					{#if dirty}
						<button
							type="button"
							onclick={() => {
								sync();
								toast('Alterações descartadas');
							}}
							class="rounded-controle border border-edge bg-surface px-3.5 py-2 text-corpo font-semibold text-muted hover:bg-surface-2"
						>
							Descartar
						</button>
					{/if}

					<Button type="submit"
						emVoo={save.emVoo}
						disabled={!dirty || horasInvalidas}
					>
						Salvar
					</Button>
				</div>
			</form>
		{:else}
			<!-- Leitura para não-gestores: o mesmo conteúdo, sem os controles. -->
			<h2 class="mb-3 text-leitura font-semibold">Comunicação com o paciente</h2>
			<dl class="space-y-2.5 text-corpo">
				<div class="flex gap-3">
					<dt class="w-[190px] shrink-0 text-muted">Confirmação automática</dt>
					<dd class="font-medium">{data.clinic.msg_confirmacao_auto ? 'Ligada' : 'Desligada'}</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[190px] shrink-0 text-muted">Lembrete antes da sessão</dt>
					<dd class="font-medium">
						{data.clinic.msg_lembrete_horas
							? `${data.clinic.msg_lembrete_horas} h antes`
							: 'Desligado'}
					</dd>
				</div>
				<div class="flex gap-3">
					<dt class="w-[190px] shrink-0 text-muted">Não incomodar</dt>
					<dd class="font-medium">
						{data.clinic.msg_silencio_inicio != null
							? `das ${data.clinic.msg_silencio_inicio}h às ${data.clinic.msg_silencio_fim}h`
							: 'Sem janela'}
					</dd>
				</div>
			</dl>
		{/if}
	</section>
</div>
