// Tipos e regras puras da Fila de espera (doc 25, Entrega 5). Espelha os helpers do protótipo
// (`prioMeta` :2512, `wdShort` :2514, `filaRegraLabel` :2519, `vagaLabel` :2596). A autoridade
// real é o servidor (`Api.Waitlist` + policies + o motor `SlotFinder`); o que mora aqui é o que a
// TELA precisa para ordenar, filtrar e rotular — nada que só exista no cliente vira invariante.
//
// Sem Svelte e sem DOM: tudo testável no projeto `server` do Vitest.

import type { Papel } from './session';
import type { AgendaProfessional } from './agenda';

// ---------------------------------------------------------------------------
// Wire (contrato do doc 25 §5 / doc 09 §3.6) — átomos SEM acento (`Api.Waitlist.*`).
// ---------------------------------------------------------------------------

export type Priority = 'urgente' | 'alta' | 'normal' | 'baixa';
export type TimeWindow = 'manha' | 'tarde' | 'qualquer';
export type RuleType = 'semana' | 'data';

/**
 * Uma regra de disponibilidade do paciente. `dows` (0=domingo..6=sábado) só vale em `semana`;
 * `data` ("YYYY-MM-DD") só em `data`; `periodos` são pares `["HH:MM","HH:MM"]`. O `id` só vem
 * do servidor (regra já salva) — uma regra recém-criada no modal viaja sem ele, e o
 * `manage_relationship(:direct_control)` da API cria/atualiza/apaga casando por esse id.
 */
export interface Rule {
	id?: string;
	tipo: RuleType;
	dows: number[];
	data: string | null;
	periodos: [string, string][];
}

// O paciente como a fila o recebe — projeção enxuta do cadastro (a fila não carrega as ~39
// colunas da ficha), irmã da `AgendaPatient`. `faltas` é o agregado que o cartão "quem cabe" usa.
export interface WaitlistPatient {
	id: string;
	nome: string;
	tel: string | null;
	ativo: boolean;
	faltas: number;
}

export interface Entry {
	id: string;
	prio: Priority;
	janela: TimeWindow;
	obs: string | null;
	/** Profissionais preferidos (0..N). Vazio = qualquer profissional (RN-37). */
	professional_ids: string[];
	/** Derivado no servidor de `inserted_at` no fuso da clínica (ADR-009), não no cliente. */
	dias_na_fila: number;
	rules: Rule[];
	patient: WaitlistPatient;
	inserted_at: string;
}

/**
 * Uma vaga do motor (`GET /waitlist/:id/slots`). `start` é minuto LOCAL do dia e `date` é a data
 * LOCAL da clínica — para virar o `starts_at` (UTC) da conversão é preciso o fuso (`toUtcIso`).
 * `freed` marca a vaga que ABRIU (cancelamento/falta); `rule_index` casa com a regra que a gerou.
 */
export interface Slot {
	date: string;
	start: number;
	dur: number;
	professional_id: string;
	dow: number;
	rule_index: number | null;
	freed: boolean;
}

/** A reserva de 10 min criada por `offer` (o canal do 409 `slot_held` na corrida da oferta). */
export interface Hold {
	id: string;
	professional_id: string;
	waitlist_entry_id: string;
	starts_at: string;
	ends_at: string;
	expires_at: string;
}

// O profissional como a fila o consome é o MESMO da agenda (o JSON reusa `AgendaJSON.professional`)
// — reexportado para os call-sites da fila não importarem de `agenda`.
export type Professional = AgendaProfessional;

// ---------------------------------------------------------------------------
// Prioridade — cor, rótulo e ordem de exibição (protótipo `prioMeta` :2512)
// ---------------------------------------------------------------------------

export interface PriorityMeta {
	label: string;
	/** Hex fixo do protótipo — a paleta da prioridade não é tokenizável no CSS (não muda no tema). */
	color: string;
}

export const PRIORITY_META: Record<Priority, PriorityMeta> = {
	urgente: { label: 'Urgente', color: '#E5484D' },
	alta: { label: 'Alta', color: '#F5A623' },
	normal: { label: 'Normal', color: '#2B7FFF' },
	baixa: { label: 'Baixa', color: '#AEB6BE' }
};

/**
 * Ordem de urgência (urgente → baixa). É de DOMÍNIO, não `?sort` do cliente: o Postgres ordena o
 * enum pela string (alfabética), então o servidor reordena em Elixir (`Api.Waitlist.priority_rank`)
 * — e a tela espelha aqui, para que um reordenamento otimista pós-edição não desmonte a fila.
 */
export const PRIORITY_ORDER: readonly Priority[] = ['urgente', 'alta', 'normal', 'baixa'] as const;

export const TIME_WINDOW_LABEL: Record<TimeWindow, string> = {
	manha: 'Manhã',
	tarde: 'Tarde',
	qualquer: 'Qualquer'
};

// Dias-da-semana curtos, nas duas caixas do protótipo: `wdShort` (:2514, capitalizado) para o
// rótulo da regra, e a versão minúscula do `vagaLabel` (:2596) para a etiqueta da vaga.
const WD_SHORT = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const WD_SHORT_LOWER = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];

// ---------------------------------------------------------------------------
// Rótulos (portados de `filaRegraLabel` :2519 e `vagaLabel` :2596)
// ---------------------------------------------------------------------------

// "25/06" a partir de uma data ISO, sem `new Date` — o parse por fuso recuaria um dia a oeste de
// Greenwich (o mesmo motivo de `scheduling.formatDate` usar `T00:00`), e aqui a data é só rótulo.
function ddmm(iso: string): string {
	const [, m, d] = iso.split('-');
	return d && m ? `${d}/${m}` : iso;
}

function periodsLabel(periodos: [string, string][]): string {
	return periodos.map(([ini, fim]) => `${ini}–${fim}`).join(', ');
}

/**
 * Rótulo de uma regra: "Seg/Ter · 09:00–11:00" (semana) ou "25/06 · 08:00–12:00" (data). Porta o
 * `filaRegraLabel` (:2519) — dias ordenados e juntados por "/", data em DD/MM, faixas por ", ".
 */
export function ruleLabel(rule: Rule): string {
	const hh = periodsLabel(rule.periodos ?? []);
	if (rule.tipo === 'data') {
		if (!rule.data) return '—';
		return `${ddmm(rule.data)} · ${hh}`;
	}
	const dias = [...(rule.dows ?? [])].sort((a, b) => a - b).map((d) => WD_SHORT[d] ?? '?');
	return `${dias.join('/')} · ${hh}`;
}

/** Etiqueta compacta de uma vaga: "qui 25/06" (porta `vagaLabel` :2596), usada com `m2t(start)`. */
export function slotDateLabel(slot: Pick<Slot, 'date' | 'dow'>): string {
	return `${WD_SHORT_LOWER[slot.dow] ?? ''} ${ddmm(slot.date)}`.trim();
}

/**
 * Prefixo curto de uma regra para o chip de vaga casada (porta `filaRegraPrefix` :2518): só a
 * "chave" da regra (DD/MM ou "Seg/Ter"), sem as faixas de horário — a vaga já traz o horário.
 */
export function rulePrefix(rule: Rule): string {
	if (rule.tipo === 'data') return rule.data ? ddmm(rule.data) : '—';
	return [...(rule.dows ?? [])].sort((a, b) => a - b).map((d) => WD_SHORT[d] ?? '?').join('/');
}

/**
 * Uma regra `:data` cujo dia já passou (porta `filaRegraExpirada` :2516). `today` é a data local
 * da clínica (ADR-009, do load) — a comparação é lexicográfica de ISO "YYYY-MM-DD", que é
 * cronológica, sem `new Date` (que recuaria um dia a oeste de Greenwich). Regra `:semana` nunca expira.
 */
export function ruleExpired(rule: Rule, today: string): boolean {
	return rule.tipo === 'data' && !!rule.data && rule.data < today;
}

// ---------------------------------------------------------------------------
// Coluna "Disponibilidade" da lista (porta `filaDispCell` :2599)
// ---------------------------------------------------------------------------

/**
 * Um item da célula de disponibilidade:
 * - `neutral`: chip da janela ou da regra (tracejado + riscado quando `expired`; `mono` nas regras).
 * - `match`: a regra (ou "Qualquer") casou com uma vaga do motor — vira botão de oferta.
 * - `none`: o marcador "· sem vaga compatível".
 */
export type DispItem =
	| { kind: 'neutral'; label: string; expired: boolean; mono: boolean }
	| { kind: 'match'; label: string; slot: Slot }
	| { kind: 'none' };

/** Há ao menos uma vaga do motor para o item (o estado "tem vaga" da linha). */
export function hasSlots(slots: Slot[] | undefined): boolean {
	return !!slots && slots.length > 0;
}

/**
 * Monta a célula de disponibilidade de um item a partir das suas regras e das vagas do motor
 * (porta `filaDispCell` :2606-2618). Cada regra vira: chip de oferta se casou com uma vaga (pelo
 * `rule_index`), chip riscado se expirou, ou chip neutro se sem vaga. Sem regras, a janela; e o
 * marcador "sem vaga" fecha a lista quando o motor não achou nada.
 */
export function dispItems(entry: Entry, slots: Slot[], today: string): DispItem[] {
	const items: DispItem[] = [];
	const janLabel = entry.janela === 'qualquer' ? null : TIME_WINDOW_LABEL[entry.janela];

	if (entry.rules.length) {
		if (janLabel) items.push({ kind: 'neutral', label: janLabel, expired: false, mono: false });
		entry.rules.forEach((rule, i) => {
			const expired = ruleExpired(rule, today);
			const slot = expired ? undefined : slots.find((s) => s.rule_index === i);
			if (slot) items.push({ kind: 'match', label: rulePrefix(rule), slot });
			else items.push({ kind: 'neutral', label: ruleLabel(rule), expired, mono: true });
		});
	} else {
		const slot = slots[0];
		const label = janLabel ?? (slot ? 'Qualquer' : 'Qualquer horário');
		if (slot) items.push({ kind: 'match', label, slot });
		else items.push({ kind: 'neutral', label, expired: false, mono: false });
	}

	if (!slots.length) items.push({ kind: 'none' });
	return items;
}

// ---------------------------------------------------------------------------
// Ordenação e filtro por prioridade (a fila é bounded — filtra-se no cliente, como o protótipo)
// ---------------------------------------------------------------------------

/** Posto de uma prioridade (urgente = 0). Espelho de `Api.Waitlist.priority_rank/1`. */
export function priorityRank(prio: Priority): number {
	const i = PRIORITY_ORDER.indexOf(prio);
	return i === -1 ? PRIORITY_ORDER.length : i;
}

/**
 * Ordena a fila por prioridade e, dentro dela, pelo tempo de espera (mais antigo primeiro) —
 * espelho de `sort_by_priority/1`. A API já entrega ordenado; reordenar aqui é o que segura a
 * ordem certa depois de uma edição otimista, antes do load reexecutar.
 */
export function sortByPriority(entries: Entry[]): Entry[] {
	return [...entries].sort(
		(a, b) => priorityRank(a.prio) - priorityRank(b.prio) || a.inserted_at.localeCompare(b.inserted_at)
	);
}

/** O filtro da sidebar: uma prioridade, ou `todas`. */
export type PriorityFilter = Priority | 'todas';

const PRIORITY_FILTERS: readonly PriorityFilter[] = ['todas', ...PRIORITY_ORDER] as const;

/** Lê `?prio=` da URL, caindo em `todas` para qualquer valor desconhecido (molde de `parseFilter`). */
export function parsePriorityFilter(value: string | null | undefined): PriorityFilter {
	return PRIORITY_FILTERS.find((f) => f === value) ?? 'todas';
}

export type WaitlistCounts = Record<PriorityFilter, number>;

/** Contagens por prioridade para a sidebar (a fila inteira, não a filtrada). */
export function priorityCounts(entries: Entry[]): WaitlistCounts {
	const counts: WaitlistCounts = { todas: entries.length, urgente: 0, alta: 0, normal: 0, baixa: 0 };
	for (const e of entries) counts[e.prio]++;
	return counts;
}

// ---------------------------------------------------------------------------
// Permissões (espelho de UX — a autoridade é a policy `WaitlistEntry`)
// ---------------------------------------------------------------------------

/**
 * A8: administrar a fila é de quem opera a agenda — owner/admin/recepção **e** profissional (a
 * fila não é "do profissional": qualquer um vê e mexe na fila inteira da clínica). Difere de
 * `canManageMembers` (só owner/admin), daí a lista própria em vez do alias.
 */
export function canManageWaitlist(papel: Papel | null | undefined): boolean {
	return papel === 'owner' || papel === 'admin' || papel === 'recepcao' || papel === 'profissional';
}
