<script lang="ts">
	// "Adicionar paciente" numa turma que já existe (doc 109).
	//
	// Era o buraco central da composição da turma no drawer: dava para marcar presença de quem
	// estava lá, e não dava para mudar QUEM está lá. Entrar acontecia de rabeira — criando um
	// agendamento no mesmo slot para o servidor fundir (A-D4) —, o que obrigava a recepção a sair
	// do bloco que está olhando, abrir o modal de novo agendamento e reconstruir profissional,
	// tipo, data e hora de cabeça para cair na mesma turma.
	//
	// ## Fechado por padrão
	//
	// A busca fica atrás de um clique porque a turma é lida muito mais vezes do que é composta:
	// um combobox sempre aberto no meio da lista de participantes disputaria a atenção com os
	// controles de presença, que são a razão de o drawer estar aberto na maior parte das vezes.
	//
	// ## O teto e a saída
	//
	// A capacidade é limite **operacional**, não físico (`Validations.GroupCapacity`) — e o
	// servidor a trata assim: 422 com `code: group_full`, que o encaixe fura. Então a tela não
	// desabilita nada por antecipação: ela deixa tentar, e o 422 vira a oferta de encaixe, exatamente
	// como o `schedule_conflict` faz no criar e no remarcar. Quem não pode marcar encaixe (A9) não
	// recebe a oferta — recebe o erro, que continua sendo verdadeiro para essa pessoa.
	import Plus from '@lucide/svelte/icons/plus';
	import Button from '$lib/components/Button.svelte';
	import { enhance } from '$app/forms';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import PatientPicker from './PatientPicker.svelte';
	import ConflictErrorBox from './ConflictErrorBox.svelte';
	import type { AgendaPatient, SearchResult } from '$lib/agenda';

	let {
		id,
		version,
		capacidade,
		atual,
		podeEncaixe,
		search,
		erro = undefined,
		code = undefined,
		jaNoBloco = []
	}: {
		id: string;
		/** A versão do BLOCO — o guard de 409, como em toda escrita da agenda. */
		version: number;
		capacidade: number;
		atual: number;
		podeEncaixe: boolean;
		search: (q: string) => Promise<SearchResult>;
		/** Mensagem da última tentativa (`?/adicionar_participante`), quando houve. */
		erro?: string;
		code?: string;
		/** Quem já está na turma — para a busca não oferecer quem já está dentro. */
		jaNoBloco?: string[];
	} = $props();

	let aberto = $state(false);
	let selected = $state<AgendaPatient[]>([]);
	let encaixe = $state(false);

	const lotado = $derived(atual >= capacidade);
	const vagas = $derived(Math.max(0, capacidade - atual));

	// `reset: false`: o 422 de turma cheia volta PARA DENTRO deste formulário, com a saída de
	// encaixe — limpar o form junto apagaria a escolha que a pessoa precisa reconfirmar. Mesma
	// razão do modal de novo agendamento.
	const envio = criarEnvio({
		reset: false,
		aoResponder: (result) => {
			// Só o sucesso fecha. Numa falha o painel continua aberto com os nomes escolhidos, que é
			// o que permite reconfirmar como encaixe sem digitar tudo de novo.
			if (result?.type === 'success') fechar();
		}
	});

	function fechar() {
		aberto = false;
		selected = [];
		encaixe = false;
	}

	function pick(p: AgendaPatient) {
		// Já está na turma: escolher de novo produziria um 422 de identidade (`one_per_patient_per_appt`)
		// com uma mensagem que fala de banco, não de sala de espera.
		if (jaNoBloco.includes(p.id)) return;
		if (selected.some((s) => s.id === p.id)) return;
		selected = [...selected, p];
	}

	const oferecEncaixe = $derived(code === 'group_full' && podeEncaixe && !encaixe);
</script>

{#if aberto}
	<div class="border-t border-edge px-3 py-2.5">
		<form
			method="POST"
			action="?/adicionar_participante"
			use:enhance={envio.submit}
			id="adicionar-participante-{id}"
		>
			<input type="hidden" name="id" value={id} />
			<input type="hidden" name="expected_version" value={version} />
			<input type="hidden" name="patient_ids" value={JSON.stringify(selected.map((p) => p.id))} />
			<!-- Checkbox não entra no FormData quando desmarcado; o hidden é quem sempre manda (doc
			     98 §6). Aqui errar isso faria o encaixe reconfirmado sumir em silêncio e o 422 de
			     turma cheia voltar igual, sem que nada na tela explicasse por quê. -->
			<input type="hidden" name="encaixe" value={encaixe ? 'on' : ''} />

			<div class="mb-1.5 flex items-baseline justify-between text-rotulo">
				<span class="font-semibold text-muted">Adicionar à turma</span>
				<span class="text-meta text-faint">
					{#if lotado}
						turma cheia ({atual}/{capacidade})
					{:else}
						{vagas} vaga{vagas === 1 ? '' : 's'}
					{/if}
				</span>
			</div>

			<PatientPicker
				{selected}
				multi
				{search}
				onPick={pick}
				onRemove={(pid) => (selected = selected.filter((p) => p.id !== pid))}
			/>

			{#if encaixe}
				<!-- O estado do furo fica VISÍVEL depois de reconfirmado. Sem isto, a segunda tentativa
				     seria indistinguível da primeira e ninguém saberia que o teto foi ignorado.
				     O selo é o MESMO do bloco encaixe no cabeçalho do drawer (AN-08: texto escuro fixo
				     sobre o âmbar — branco reprova no axe), para as duas leituras do mesmo fato terem
				     a mesma cara. -->
				<div class="mt-1.5 flex items-center gap-1.5 text-meta text-muted">
					<span class="rounded-micro bg-warning-solid px-1.5 py-0.5 text-micro font-bold text-on-solid">
						ENCAIXE
					</span>
					acima da capacidade da turma
				</div>
			{/if}

			<ConflictErrorBox {erro} ofereceEncaixe={oferecEncaixe} onEncaixe={() => (encaixe = true)} />

			<div class="mt-2 flex items-center gap-2">
				<Button
					type="submit"
					emVoo={envio.emVoo}
					form="adicionar-participante-{id}"
					disabled={selected.length === 0}
				>
					Adicionar
				</Button>
				<button
					type="button"
					onclick={fechar}
					class="rounded-controle border border-edge px-2.5 py-1.5 text-rotulo font-semibold text-muted hover:bg-surface-2"
				>
					Cancelar
				</button>
			</div>
		</form>
	</div>
{:else}
	<button
		type="button"
		onclick={() => (aberto = true)}
		class="flex w-full items-center justify-center gap-1.5 border-t border-edge px-3 py-2 text-rotulo font-semibold text-accent-text transition-colors hover:bg-surface-2"
	>
		<Plus size={14} /> Adicionar paciente
	</button>
{/if}
