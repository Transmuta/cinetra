<script lang="ts">
	// A legenda da agenda (AN-01 sub `h`, HOM-002).
	//
	// O relatório pediu uma fileira de seis chips. **Não é o que fazemos aqui**, e a razão está
	// no §9.3 do doc 37: a proposta comete o defeito que ela mesma diagnostica. Ela promove
	// "Ação necessária" a status, mas a pendência é ORTOGONAL — um bloco *agendado* ou
	// *confirmado* pode precisar de ação. Enfileirar as duas coisas é exatamente o "um sinal
	// representando mais de uma dimensão" do HOM-002. E "Em atendimento", que é status real
	// nosso, some da proposta dele.
	//
	// Então a legenda tem DOIS blocos, e a separação entre eles é a informação principal:
	//  - **o que aconteceu** — os 6 status, mutuamente exclusivos (o ponto e o badge do card);
	//  - **o que exige atenção** — conflito, encaixe e pendência, que se somam a qualquer status.
	//
	// Fica aberta por padrão (D3): quem chega novo aprende sem procurar, e quem já sabe fecha
	// uma vez. O estado mora no `localStorage` porque é preferência de pessoa, não de clínica —
	// não vale uma coluna no banco nem uma ida ao servidor.
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Zap from '@lucide/svelte/icons/zap';
	import { STATUS_META, type AppointmentStatus } from '$lib/agenda';

	const CHAVE = 'agenda:legenda';

	// A ordem é a do ciclo de vida, não a alfabética: é assim que a recepção encontra o que
	// procura ("onde é que o bloco está agora?").
	const STATUS: AppointmentStatus[] = [
		'agendado',
		'confirmado',
		'em_atendimento',
		'concluido',
		'faltou',
		'cancelado'
	];

	let aberta = $state(true);

	// Leitura no cliente, dentro do `$effect`: no SSR não existe `localStorage`, e ler no corpo
	// do componente quebraria a renderização do servidor. O padrão aberto vale até o efeito
	// rodar, então quem nunca fechou não vê piscar.
	$effect(() => {
		if (localStorage.getItem(CHAVE) === 'fechada') aberta = false;
	});

	function alternar() {
		aberta = !aberta;
		localStorage.setItem(CHAVE, aberta ? 'aberta' : 'fechada');
	}

	const corDoTom = (tom: string | null) => (tom ? `var(--color-${tom})` : 'var(--color-muted)');
</script>

<div class="border-b border-edge bg-surface px-4 py-1.5" data-testid="agenda-legend">
	<button
		type="button"
		onclick={alternar}
		aria-expanded={aberta}
		class="flex items-center gap-1 text-[11px] font-semibold text-muted hover:text-ink"
	>
		Entenda a agenda
		<span
			class="transition-transform duration-150"
			style="transform:rotate({aberta ? 0 : -90}deg)"
		>
			<ChevronDown size={13} />
		</span>
	</button>

	{#if aberta}
		<div class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-1.5 pb-0.5">
			<div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
				<span class="text-[10px] font-semibold tracking-wide text-faint uppercase">
					O que aconteceu
				</span>
				{#each STATUS as s (s)}
					<span class="flex items-center gap-1 text-[11px] text-muted">
						<span
							class="size-1.5 shrink-0 rounded-full"
							style="background:{corDoTom(STATUS_META[s].tone)}"
						></span>
						{STATUS_META[s].label}
					</span>
				{/each}
			</div>

			<div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
				<span class="text-[10px] font-semibold tracking-wide text-faint uppercase">
					Exige atenção
				</span>
				<span class="flex items-center gap-1 text-[11px] text-muted">
					<span class="text-danger"><TriangleAlert size={11} /></span> Conflito de horário
				</span>
				<span class="flex items-center gap-1 text-[11px] text-muted">
					<span class="text-warning"><Zap size={11} /></span> Encaixe
				</span>
				<span class="flex items-center gap-1 text-[11px] text-muted">
					<span
						class="rounded px-1 py-px text-[9px] font-bold text-warning"
						style="background:color-mix(in srgb, var(--color-warning) 12%, transparent)"
					>
						Registrar status
					</span>
					Terminou sem desfecho
				</span>
			</div>

			<!-- O terceiro bloco existe porque a fatia INVENTOU um sinal e quase o deixou de fora
			     desta legenda: numa turma já registrada o badge deixa de ser a palavra do status e
			     vira a composição (D13). O ponto que a acompanha é NEUTRO quando a turma é mista — o
			     mesmo cinza de "Agendado". Dois sinais, uma cor: sem esta linha, a legenda
			     reproduziria o HOM-002 dentro da própria correção dele.

			     (Eram TRÊS até "Cancelado" ganhar o `faint` que o protótipo já lhe dava — agendado e
			     cancelado, que são estados opostos, saíam idênticos no ponto.) -->
			<div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
				<span class="text-[10px] font-semibold tracking-wide text-faint uppercase">Turma</span>
				<span class="flex items-center gap-1 text-[11px] text-muted">
					<span
						class="rounded px-1 py-px text-[9px] font-bold text-muted"
						style="background:color-mix(in srgb, var(--color-muted) 12%, transparent)"
					>
						3 de 4 concluídas
					</span>
					Quantos vieram — no lugar do status, quando já há presença registrada
				</span>
			</div>

			<!-- A quarta dimensão do card não é chip: é posição. Dizer isso em uma frase evita a
			     pergunta "e essa listra colorida?" que a cor sozinha não responde. -->
			<span class="text-[11px] text-faint">
				A faixa colorida à esquerda do bloco é a cor do profissional.
			</span>
		</div>
	{/if}
</div>
