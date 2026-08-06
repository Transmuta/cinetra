<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	// O que a clínica manda ao paciente, e quando (doc 52 §7).
	//
	// Por clínica, não por profissional: por profissional vira matriz que ninguém mantém.
	//
	// Dois controles: por qual CANAL se fala e QUANDO não incomodar. O "quando lembrar" saiu em
	// 2026-08-01 junto com o lembrete automático — não sobrou nenhum disparo por relógio, e um
	// campo de horas sem cron seria um controle que não faz nada (a mesma régua que tirou o
	// `msg_confirmacao_auto` no doc 98).
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import Info from '@lucide/svelte/icons/info';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import MessageCircle from '@lucide/svelte/icons/message-circle';
	import { canManageClinic } from '$lib/session';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	const canManage = $derived(canManageClinic(data.me.papel));

	// O telefone da clínica é o que destrava o canal — a API recusa ligar sem ele
	// (`WhatsappExigeTelefone`), porque ele é posicional OBRIGATÓRIA do template aprovado. Sem
	// isso a mensagem sairia dizendo "Ligue para —".
	const temTelefone = $derived((data.clinic.telefone ?? '').trim() !== '');

	// Rascunho local, como nas outras telas de config: edita e só então salva.
	let whatsapp = $state(untrack(() => data.clinic.msg_whatsapp_ativo));
	let silencio = $state(untrack(() => data.clinic.msg_silencio_inicio != null));
	let inicio = $state(untrack(() => String(data.clinic.msg_silencio_inicio ?? 21)));
	let fim = $state(untrack(() => String(data.clinic.msg_silencio_fim ?? 8)));

	const dirty = $derived(
		whatsapp !== data.clinic.msg_whatsapp_ativo ||
			(silencio ? Number(inicio) : null) !== (data.clinic.msg_silencio_inicio ?? null) ||
			(silencio ? Number(fim) : null) !== (data.clinic.msg_silencio_fim ?? null)
	);

	function sync() {
		whatsapp = data.clinic.msg_whatsapp_ativo;
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
				<!-- Canal de WhatsApp -->
				<div>
					<div class="flex items-start justify-between gap-4">
						<div>
							<p class="text-corpo font-semibold">Falar por WhatsApp</p>
							<p class="mt-0.5 text-rotulo text-muted">
								Vale para <strong>todas</strong> as mensagens ao paciente. Desligado, tudo continua
								saindo por e-mail — e cada mensagem de WhatsApp é cobrada.
							</p>
						</div>
						<SwitchToggle
							checked={whatsapp}
							disabled={!temTelefone}
							onchange={() => (whatsapp = !whatsapp)}
							label="Falar por WhatsApp"
						/>
						<!-- Mesmo motivo do `silencio` abaixo: `<button role="switch">` não entra no FormData. -->
						<input type="hidden" name="whatsapp" value={whatsapp ? 'on' : ''} />
					</div>

					{#if !temTelefone}
						<!-- O bloqueio explica a causa E leva até ela. Um interruptor apagado sem dizer por
						     quê manda a pessoa procurar em três telas. -->
						<p
							class="mt-3 flex items-start gap-2 rounded-controle bg-surface-2 px-3.5 py-3 text-rotulo text-muted"
						>
							<span class="mt-0.5 shrink-0 text-faint"><MessageCircle size={14} /></span>
							<span>
								Para ligar o WhatsApp, cadastre antes o <strong>telefone da clínica</strong> em
								<a href="/configuracoes/clinica" class="font-semibold text-accent-text underline"
									>Dados da clínica</a
								>. Ele vai dentro da mensagem, porque quem responde pelo WhatsApp não é lido por
								ninguém — o paciente precisa de um número para ligar.
							</span>
						</p>
					{/if}
				</div>

				<!-- Janela de silêncio -->
				<div class="border-t border-edge pt-5">
					<div class="flex items-start justify-between gap-4">
						<div>
							<p class="text-corpo font-semibold">Não incomodar</p>
							<p class="mt-0.5 text-rotulo text-muted">
								Mensagem que cairia nesse intervalo é <strong>adiada</strong>, não descartada — ela
								sai no fim da janela.
							</p>
						</div>
						<SwitchToggle
							checked={silencio}
							onchange={() => (silencio = !silencio)}
							label="Janela de silêncio"
						/>
						<!-- O `SwitchToggle` é um `<button role="switch">`, e botão não entra no FormData. Sem
						     este campo a action lê `silencio` como ausente e apaga as DUAS pontas da janela — o
						     que acontecia em TODA gravação, mesmo a que não mexia na janela (doc 98 §6). -->
						<input type="hidden" name="silencio" value={silencio ? 'on' : ''} />
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
						disabled={!dirty}
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
					<dt class="w-[190px] shrink-0 text-muted">Falar por WhatsApp</dt>
					<dd class="font-medium">
						{data.clinic.msg_whatsapp_ativo ? 'Ligado' : 'Desligado — tudo sai por e-mail'}
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
