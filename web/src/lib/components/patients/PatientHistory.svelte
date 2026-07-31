<script lang="ts">
	// "Histórico" da ficha do paciente (C13, Frente 7) — a segunda aba que a Fatia 3 destravou
	// (Anexos seguem ocultos: dependem do prontuário, v2).
	//
	// A linha é a PRESENÇA dele, não o bloco: numa turma o bloco pode estar concluído com a
	// presença dele faltando (`attendance.ex:8`), e a ficha que mostrasse o desfecho do bloco
	// contaria uma sessão que ele não fez. O selo, portanto, sai do status da presença.
	import History from '@lucide/svelte/icons/history';
	import Package from '@lucide/svelte/icons/package';
	import { appointmentHref, attendanceSelo, zonedParts, m2t } from '$lib/agenda';
	import type { HistorySession } from '$lib/server/patients';

	let {
		sessions,
		more = false,
		timezone = 'America/Sao_Paulo'
	}: {
		sessions: HistorySession[];
		/** o servidor cortou a lista (teto de leitura) — a tela avisa em vez de mentir */
		more?: boolean;
		timezone?: string;
	} = $props();

	function quando(iso: string): string {
		const { date, minutes } = zonedParts(iso, timezone);
		const [ano, mes, dia] = date.split('-');
		return `${dia}/${mes}/${ano} · ${m2t(minutes)}`;
	}

	const selo = (s: HistorySession) => attendanceSelo(s.status, s.falta_justificada);

	// O bloco daquela sessão, com o dia ao lado (doc 85). A linha é a presença, mas o que se abre é
	// o bloco — é lá que estão a observação, o participante e o débito de pacote.
	const linkDaSessao = (s: HistorySession) =>
		appointmentHref(s.appointment_id, zonedParts(s.starts_at, timezone).date);
</script>

<!--
	Cabeçalho e moldura do protótipo ([`:2814`]): o `cardHead` (teal no protótipo, acento no app) que os cartões vizinhos usam,
	a contagem em mono à direita, e as linhas dentro de uma caixa com borda (doc 51 §L5/§L6).
-->
<section class="rounded-[14px] border border-edge bg-surface p-5">
	<div class="mb-4 flex items-center gap-2.5">
		<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-accent-subtle text-accent-text">
			<History size={15} />
		</span>
		<h2 class="flex-1 text-[14px] font-bold">Histórico de atendimentos</h2>
		{#if sessions.length}
			<span class="font-mono text-[11px] text-faint">{sessions.length}</span>
		{/if}
	</div>

	<div class="overflow-hidden rounded-[10px] border border-edge">
		{#if sessions.length === 0}
			<div class="p-5 text-center text-[13px] text-faint">Sem atendimentos registrados.</div>
		{:else}
			<ul class="divide-y divide-edge">
				{#each sessions as s (s.id)}
					{@const tag = selo(s)}
					<li>
						<!-- A linha vira LINK para o bloco (doc 85). O histórico responde "o que
						     aconteceu"; a pergunta seguinte é sempre sobre uma daquelas sessões (o que
						     foi anotado, quem atendeu, qual pacote debitou) — e a resposta mora no drawer,
						     que até aqui só se alcançava indo à agenda e caçando o dia. -->
						<a
							href={linkDaSessao(s)}
							class="flex w-full items-center gap-2.5 px-3 py-2.5 hover:bg-surface-2"
						>
							<span
								class="inline-block size-2.5 shrink-0 rounded-full"
								style="background:{s.cor ?? 'var(--color-edge)'}"
							></span>
							<div class="min-w-0 flex-1">
								<div class="flex items-center gap-2">
									<!-- largura fixa: sem ela as datas não alinham entre linhas, que é o
									     motivo de o protótipo reservar uma coluna para elas -->
									<span class="shrink-0 font-mono text-[11.5px] text-muted">
										{quando(s.starts_at)}
									</span>
									{#if s.package_id}
										<span
											class="inline-flex items-center gap-1 text-[11px] text-faint"
											title="Sessão de pacote"
										>
											<Package size={12} /> pacote
										</span>
									{/if}
								</div>
								<div class="truncate text-[12px] text-muted">
									{s.tipo ?? 'Sessão'}{s.profissional ? ` · ${s.profissional}` : ''}
								</div>
							</div>
							<span
								class="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold"
								style="background:{tag.tone
									? `color-mix(in srgb, var(--color-${tag.tone}) 14%, transparent)`
									: 'var(--color-surface-2)'}; color:{tag.tone
									? `var(--color-${tag.tone})`
									: 'var(--color-muted)'}"
							>
								{tag.label}
							</span>
						</a>
					</li>
				{/each}
			</ul>
		{/if}
	</div>

	{#if more}
		<!--
			Era um `<p>` mudo ("há mais no histórico"): informava a truncagem e não oferecia o
			caminho. A ficha agora abre com 8 linhas (doc 56) e o resto é este link, que sobe o
			teto pela URL — sem estado no cliente, funciona sem JS e é compartilhável.

			Sem contagem de propósito: o número exigiria um `COUNT(*)` na maior tabela por ficha
			aberta, que é justamente o que a trilha de auditoria tirou (doc 55 §6).
		-->
		<a
			href="?historico=200"
			class="mt-2.5 inline-block text-[11.5px] font-semibold text-primary hover:underline"
		>
			Ver histórico completo
		</a>
	{/if}
</section>
