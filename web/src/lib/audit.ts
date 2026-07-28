// Tipos e regras puras da tela de auditoria (`/auditoria`, doc 25 §11.4). A autoridade real é a
// API (recurso `*.Version` + policies `owner·admin`); aqui é UX — traduzir os nomes técnicos para
// português de clínica, formatar os valores do diff e formatar o "quando" no fuso da clínica.
// Sem essa camada a tela mostraria nome de coluna e uuid para a recepção.
import { canManageMembers, type Papel } from './session';
import { STATUS_META, shiftDate, zonedParts, type AppointmentStatus } from './agenda';
import { hrefWithQuery, type QueryPatch } from './querystring';
import { parsePage, type PageInfo } from './pagination';

// `parsePage` e a forma do recorte vêm de `$lib/pagination` — a fonte única declarada ("o pouco
// que toda tela paginada repete"). Esta tela chegou a ter uma **segunda cópia** de `parsePage`,
// idêntica byte a byte, e o bate-volta mediu o preço: sabotar a do módulo central deixava os 59
// testes da Auditoria verdes. Duas implementações que ninguém sabia estarem desligadas.
export { parsePage };

// Os treze tipos de registro que a trilha cobre (doc 63, D-Aud3). Espelha
// `Api.Audit.ResourceKind` — a autoridade é o enum do servidor, que devolve **422** para valor
// fora da lista; aqui é UX (rótulo, ícone, agrupamento).
export type AuditResource =
	| 'appointment'
	| 'attendance'
	| 'patient'
	| 'professional'
	| 'membership'
	| 'clinic'
	| 'appointment_type'
	| 'clinic_hours'
	| 'professional_hours'
	| 'schedule_exception'
	| 'package'
	| 'waitlist_entry'
	| 'attachment'
	| 'seguranca';

export interface AuditRef {
	id: string;
	nome: string;
}

// Uma linha do diff campo-a-campo. `from`/`to` são os valores JÁ "dumpados" pela trilha
// (string/número/booleano/null) — o backend resolve o par no momento da ESCRITA (doc 63), não
// mais encadeando versões na leitura.
//
// `redacted` é a D-Aud4: CPF, RG e dados bancários entram na trilha como "este campo mudou" e
// **sem** os valores. A linha vem sem `from`/`to`, e a tela precisa dizer isso — não fingir que
// o campo não mudou.
export interface DiffRow {
	field: string;
	from?: unknown;
	to?: unknown;
	redacted?: boolean;
}

export interface AuditEntry {
	id: string;
	resource: AuditResource;
	/** O registro tocado. Nulo em `seguranca` (nem toda tentativa negada mira um registro). */
	record_id: string | null;
	/** O nome do registro NO INSTANTE do evento — é o que mantém a linha legível depois que ele
	 *  deixa de existir ("Removeu o acesso de Carlos", com o Carlos já fora). */
	label: string | null;
	action: string;
	/** `read` e `deny` são as duas naturezas que o modelo de versões não tinha (doc 63). */
	action_type: 'create' | 'update' | 'destroy' | 'read' | 'deny';
	// ISO-8601 UTC de QUANDO o evento aconteceu (relógio da clínica, ADR-009).
	at: string;
	actor: AuditRef | null;
	// Resolvidos por nome pela API a partir de `meta`, em lote.
	professional: AuditRef | null;
	patient: AuditRef | null;
	/** Contexto livre por recurso: `starts_at`, `session_starts_at`, `appointment_id`, `papel`… */
	meta: Record<string, unknown>;
	diff: DiffRow[];
}

export interface AuditData {
	entries: AuditEntry[];
	// `PageInfo` do módulo de paginação: o `total` dele já é **opcional**, exatamente pelo motivo
	// do D-Aud1 (a trilha não paga `COUNT(*)`), então não havia por que declarar uma forma própria.
	page: PageInfo;
}

/** A rota da tela. Saiu de `/configuracoes/auditoria` — auditar não é um ajuste da clínica. */
export const AUDIT_BASE = '/auditoria';

// ---- Grupos de registro (a faceta "Registro" da sidebar) ----
//
// Com dois recursos irmãos, "tipo de registro" era um EIXO: trocar de aba trocava qual tabela de
// versão a API paginava, e não existia "o que aconteceu na clínica". Com treze, isso não escala —
// treze abas, treze paginações, e o admin reordenando de cabeça.
//
// Agora é uma FACETA sobre um feed só: ausente = a clínica inteira (o default, e a pergunta que
// de fato se faz). Os grupos abaixo espelham a navegação do próprio app, e não a tabela do banco:
// quem audita pensa em "mexeram na agenda" / "mexeram nos acessos", não em `schedule_exceptions`.

export type ResourceGroup =
	| 'agenda'
	| 'cadastros'
	| 'acessos'
	| 'configuracoes'
	| 'pacotes'
	| 'anexos'
	| 'seguranca';

export const RESOURCE_GROUPS: ReadonlyArray<{
	key: ResourceGroup;
	label: string;
	resources: AuditResource[];
}> = [
	{ key: 'agenda', label: 'Agenda', resources: ['appointment', 'attendance'] },
	{ key: 'cadastros', label: 'Pacientes e profissionais', resources: ['patient', 'professional'] },
	{ key: 'acessos', label: 'Equipe e acessos', resources: ['membership'] },
	{
		key: 'configuracoes',
		label: 'Configurações',
		resources: [
			'clinic',
			'appointment_type',
			'clinic_hours',
			'professional_hours',
			'schedule_exception'
		]
	},
	{ key: 'pacotes', label: 'Pacotes e fila', resources: ['package', 'waitlist_entry'] },
	{ key: 'anexos', label: 'Anexos', resources: ['attachment'] },
	{ key: 'seguranca', label: 'Acesso negado', resources: ['seguranca'] }
];

/** O grupo pedido na URL, ou `null` para "tudo" (o default). Valor desconhecido vira `null`. */
export function parseResource(value: string | null | undefined): ResourceGroup | null {
	const grupo = RESOURCE_GROUPS.find((g) => g.key === value);
	return grupo ? grupo.key : null;
}

/**
 * O valor de `?resource=` que o BFF manda à API: os tipos do grupo, separados por vírgula.
 *
 * `undefined` para "tudo" — e aí a API devolve o feed da clínica inteira. Um valor desconhecido
 * **nunca** chega lá: `parseResource` já o transformou em `null`. (Do outro lado a API responde
 * 422 a tipo inválido, e não filtro nulo: um recorte que silenciosamente devolve tudo é o erro
 * que a whitelist de ações cometia.)
 */
export function resourceParam(group: ResourceGroup | null): string | undefined {
	if (!group) return undefined;
	return RESOURCE_GROUPS.find((g) => g.key === group)?.resources.join(',');
}

/** Os tipos de registro de um grupo (ou todos, quando não há grupo). */
export function resourcesOf(group: ResourceGroup | null): AuditResource[] {
	if (!group) return RESOURCE_GROUPS.flatMap((g) => g.resources);
	return RESOURCE_GROUPS.find((g) => g.key === group)?.resources ?? [];
}

// ---- Período ----
//
// Preset, e não date-picker, por uma razão do servidor: a janela `from`/`to` é validada em
// **menos de 31 dias** (`TenantScope.validate_window`), a mesma regra da agenda. "30 dias" é o
// maior recorte legal; "tudo" é a ausência de janela — que além de ser o default é o caminho
// mais barato (o índice `(clinic_id, version_inserted_at DESC)` já limita o que se lê).

export type PeriodFilter = 'hoje' | '7d' | '30d' | 'tudo';

export const PERIOD_OPTIONS: ReadonlyArray<{ key: PeriodFilter; label: string }> = [
	{ key: 'hoje', label: 'Hoje' },
	{ key: '7d', label: 'Últimos 7 dias' },
	{ key: '30d', label: 'Últimos 30 dias' },
	{ key: 'tudo', label: 'Todo o histórico' }
];

export function parsePeriod(value: string | null | undefined): PeriodFilter {
	return value === 'hoje' || value === '7d' || value === '30d' ? value : 'tudo';
}

/**
 * A janela `from`/`to` (datas locais da clínica) de um preset, ou `null` para "tudo".
 *
 * `hoje` é a data local **do servidor** — nunca `new Date()` no browser (ADR-009).
 */
export function periodRange(
	period: PeriodFilter,
	hoje: string
): { from: string; to: string } | null {
	if (period === 'hoje') return { from: hoje, to: hoje };
	if (period === '7d') return { from: shiftDate(hoje, -6), to: hoje };
	if (period === '30d') return { from: shiftDate(hoje, -29), to: hoje };
	return null;
}

// ---- Tradução das ações ----
//
// Duas tabelas por recurso, porque são dois usos diferentes:
//
//   * `ACTION_LABELS` — o verbo curto, para o filtro e para o chip ("Remarcou");
//   * `HEADLINES` — a frase da linha do feed, com o objeto no lugar certo.
//
// A frase importa mais do que parece. Os verbos de `attendance` nasceram na perspectiva do
// PACIENTE ("Entrou na turma") e eram renderizados com o ATOR como sujeito — o feed dizia
// literalmente "Fulano entrou na turma · Mariana", afirmando algo falso. Aqui todo verbo é de
// ator, e o objeto entra na própria frase: `{p}` é o paciente, `{n}` é o nome do registro
// (`label`, gravado no instante do evento).
//
// Recurso sem entrada aqui degrada para o verbo genérico do `action_type` — o feed nunca mostra
// átomo cru, mesmo que alguém ligue a trilha num recurso novo e esqueça desta tabela.

const ACTION_LABELS: Record<string, Record<string, string>> = {
	appointment: {
		schedule: 'Agendou',
		add_participant: 'Adicionou participante',
		remove_participant: 'Removeu participante',
		reschedule: 'Remarcou',
		cancel: 'Cancelou',
		reopen: 'Reabriu',
		exclude: 'Excluiu',
		apply_participant_rollup: 'Atualizou pela turma',
		set_pkg_hold: 'Reserva de pacote',
		// Ações APOSENTADAS (o eixo de bloco saiu na A2/bate-volta da Onda 3). Ficam porque a
		// trilha guarda o que aconteceu: linhas antigas carregam estes nomes, e sem o rótulo a
		// tela mostraria o átomo cru.
		mark_completed: 'Concluiu',
		mark_missed: 'Marcou falta',
		set_falta_justificada: 'Justificou a falta'
	},
	attendance: {
		create: 'Adicionou ao atendimento',
		remove: 'Removeu do atendimento',
		transition: 'Alterou a presença',
		mark_present: 'Marcou presença',
		mark_absent: 'Marcou falta',
		reopen_attendance: 'Reabriu a presença',
		justify_absence: 'Justificou a falta',
		set_package: 'Vinculou a um pacote'
	},
	patient: {
		create: 'Cadastrou',
		update: 'Editou a ficha',
		deactivate: 'Arquivou',
		reactivate: 'Reativou',
		visualizou_ficha: 'Abriu a ficha'
	},
	professional: {
		create: 'Cadastrou',
		update: 'Editou o cadastro',
		deactivate: 'Arquivou',
		reactivate: 'Reativou'
	},
	membership: {
		invite: 'Convidou',
		invite_by_email: 'Convidou por e-mail',
		update: 'Mudou o papel',
		accept_invite: 'Aceitou o convite',
		revoke_access: 'Revogou o acesso'
	},
	clinic: {
		onboard: 'Criou a clínica',
		update_settings: 'Mudou os ajustes',
		update_info: 'Mudou os dados',
		update_messaging: 'Mudou a comunicação'
	},
	appointment_type: {
		create: 'Criou o tipo',
		update: 'Editou o tipo',
		archive: 'Arquivou o tipo',
		restore: 'Reativou o tipo'
	},
	clinic_hours: { set_day: 'Mudou o expediente' },
	professional_hours: { set_day: 'Mudou a grade' },
	schedule_exception: { create: 'Lançou exceção', destroy: 'Removeu exceção' },
	package: {
		create: 'Criou o pacote',
		update: 'Editou o pacote',
		pause: 'Pausou o pacote',
		resume: 'Retomou o pacote',
		cancel: 'Cancelou o pacote'
	},
	waitlist_entry: {
		create: 'Colocou na fila',
		update: 'Editou a fila',
		destroy: 'Tirou da fila'
	},
	attachment: {
		enviou: 'Enviou o anexo',
		visualizou: 'Baixou o anexo',
		renomeou: 'Renomeou o anexo',
		removeu: 'Removeu o anexo'
	},
	seguranca: { acesso_negado: 'Acesso negado' }
};

const HEADLINES: Record<string, Record<string, string>> = {
	appointment: {
		schedule: 'Criou o agendamento',
		add_participant: 'Adicionou um participante',
		remove_participant: 'Removeu um participante',
		reschedule: 'Remarcou o agendamento',
		cancel: 'Cancelou o agendamento',
		reopen: 'Reabriu o agendamento',
		exclude: 'Excluiu o agendamento',
		apply_participant_rollup: 'Atualizou a situação pela turma',
		set_pkg_hold: 'Atualizou a reserva do pacote',
		mark_completed: 'Concluiu o agendamento',
		mark_missed: 'Marcou falta no agendamento',
		set_falta_justificada: 'Justificou a falta'
	},
	attendance: {
		create: 'Adicionou {p} ao atendimento',
		remove: 'Removeu {p} do atendimento',
		transition: 'Alterou a presença de {p}',
		mark_present: 'Marcou a presença de {p}',
		mark_absent: 'Marcou a falta de {p}',
		reopen_attendance: 'Reabriu a presença de {p}',
		justify_absence: 'Justificou a falta de {p}',
		set_package: 'Vinculou a sessão de {p} a um pacote'
	},
	patient: {
		create: 'Cadastrou o paciente {n}',
		update: 'Editou a ficha de {n}',
		deactivate: 'Arquivou o paciente {n}',
		reactivate: 'Reativou o paciente {n}',
		visualizou_ficha: 'Abriu a ficha de {n}'
	},
	professional: {
		create: 'Cadastrou {n}',
		update: 'Editou o cadastro de {n}',
		deactivate: 'Arquivou {n}',
		reactivate: 'Reativou {n}'
	},
	membership: {
		invite: 'Convidou {n} para a clínica',
		invite_by_email: 'Convidou {n} por e-mail',
		update: 'Mudou o papel de {n}',
		accept_invite: '{n} aceitou o convite',
		revoke_access: 'Revogou o acesso de {n}'
	},
	clinic: {
		onboard: 'Criou a clínica {n}',
		update_settings: 'Mudou os ajustes da clínica',
		update_info: 'Mudou os dados da clínica',
		update_messaging: 'Mudou a comunicação com o paciente'
	},
	appointment_type: {
		create: 'Criou o tipo {n}',
		update: 'Editou o tipo {n}',
		archive: 'Arquivou o tipo {n}',
		restore: 'Reativou o tipo {n}'
	},
	clinic_hours: { set_day: 'Mudou o expediente da clínica' },
	professional_hours: { set_day: 'Mudou a grade de um profissional' },
	schedule_exception: {
		create: 'Lançou a exceção {n}',
		destroy: 'Removeu a exceção {n}'
	},
	package: {
		create: 'Criou o pacote {n}',
		update: 'Editou o pacote {n}',
		pause: 'Pausou o pacote {n}',
		resume: 'Retomou o pacote {n}',
		cancel: 'Cancelou o pacote {n}'
	},
	waitlist_entry: {
		create: 'Colocou {p} na fila',
		update: 'Editou a espera de {p}',
		destroy: 'Tirou {p} da fila'
	},
	attachment: {
		enviou: 'Enviou o anexo {n}',
		visualizou: 'Baixou o anexo {n}',
		renomeou: 'Renomeou o anexo {n}',
		removeu: 'Removeu o anexo {n}'
	},
	seguranca: { acesso_negado: 'Acesso negado em {n}' }
};

// A rede: recurso ou ação sem entrada nas tabelas nunca vira átomo cru na tela.
const TYPE_FALLBACK: Record<AuditEntry['action_type'], string> = {
	create: 'Criou um registro',
	update: 'Alterou um registro',
	destroy: 'Removeu um registro',
	read: 'Consultou um registro',
	deny: 'Acesso negado'
};

/** O rótulo humano de um tipo de registro ("Agendamento", "Ficha do paciente"). */
const RESOURCE_LABELS: Record<AuditResource, string> = {
	appointment: 'Agendamento',
	attendance: 'Participante',
	patient: 'Paciente',
	professional: 'Profissional',
	membership: 'Equipe e acessos',
	clinic: 'Clínica',
	appointment_type: 'Tipo de atendimento',
	clinic_hours: 'Expediente',
	professional_hours: 'Grade do profissional',
	schedule_exception: 'Exceção de agenda',
	package: 'Pacote',
	waitlist_entry: 'Fila de espera',
	attachment: 'Anexo',
	seguranca: 'Segurança'
};

export function resourceLabel(resource: AuditResource): string {
	return RESOURCE_LABELS[resource] ?? resource;
}

/** O verbo curto da ação — filtro, chip. Ação desconhecida cai no nome cru (não quebra). */
export function actionLabel(entry: Pick<AuditEntry, 'resource' | 'action'>): string {
	return ACTION_LABELS[entry.resource]?.[entry.action] ?? entry.action;
}

/**
 * As ações filtráveis de um grupo de registro, sem repetir rótulo.
 *
 * Vários recursos compartilham nomes de ação (`create`, `update`) com rótulos diferentes por
 * contexto; a chave é `<resource>:<action>` para o filtro não misturar "Cadastrou paciente" com
 * "Criou o tipo". O `key` que vai para a URL é só o nome da ação, porque o grupo já recorta.
 */
export function actionOptions(
	group: ResourceGroup | null
): ReadonlyArray<{ key: string; label: string }> {
	const vistas = new Map<string, string>();
	for (const resource of resourcesOf(group)) {
		for (const [key, label] of Object.entries(ACTION_LABELS[resource] ?? {})) {
			if (!vistas.has(key)) vistas.set(key, label);
		}
	}
	return [...vistas].map(([key, label]) => ({ key, label }));
}

/**
 * A ação vinda da URL, **validada contra o grupo**.
 *
 * Nome fora da tabela vira `null` (sem filtro). Do lado da API isso mudou: `action` é uma coluna
 * de texto, então um nome desconhecido devolve **vazio** em vez do feed inteiro (era a falha
 * silenciosa da whitelist, doc 63). Validar aqui continua valendo por outro motivo: impede a
 * tela de exibir um chip "Cancelou" sobre um recorte que não corresponde ao grupo aberto.
 */
export function parseAction(
	value: string | null | undefined,
	group: ResourceGroup | null
): string | null {
	if (!value) return null;
	return actionOptions(group).some((o) => o.key === value) ? value : null;
}

/**
 * A frase da linha do feed: verbo de ator + objeto. O ator NÃO entra aqui — ele vai para a
 * terceira linha ("por Fulano"), onde não compete com o fato.
 */
export function entryHeadline(
	entry: Pick<AuditEntry, 'resource' | 'action' | 'action_type' | 'patient' | 'label'>
): string {
	const template = HEADLINES[entry.resource]?.[entry.action];
	if (!template) return TYPE_FALLBACK[entry.action_type] ?? entry.action;

	return template
		.replace('{p}', entry.patient?.nome ?? 'um paciente')
		.replace('{n}', entry.label ?? entry.patient?.nome ?? 'um registro');
}

/** O horário da sessão a que a linha se refere, quando há um. */
export function entrySessionAt(entry: Pick<AuditEntry, 'meta'>): string | null {
	const valor = entry.meta?.session_starts_at ?? entry.meta?.starts_at;
	return typeof valor === 'string' ? valor : null;
}

/** O contexto do registro: "Dra. Bea · ter 20/07, 09:00". Vazio quando nada foi resolvido. */
export function entryContext(
	entry: Pick<AuditEntry, 'professional' | 'meta'>,
	timezone: string
): string {
	const sessao = entrySessionAt(entry);
	const partes = [entry.professional?.nome, sessao ? formatSession(sessao, timezone) : null].filter(
		Boolean
	);
	return partes.join(' · ');
}

// ---- Tradução dos campos do diff ----

const FIELD_LABELS: Record<string, string> = {
	status: 'Situação',
	starts_at: 'Início',
	obs: 'Observação',
	encaixe: 'Encaixe',
	duration_minutos: 'Duração',
	cancel_reason: 'Motivo do cancelamento',
	falta_justificada: 'Falta justificada',
	excluded_at: 'Excluído em',
	justificativa: 'Justificativa',
	// Ficha do paciente e cadastro do profissional (doc 63): os campos que de fato mudam.
	nome: 'Nome',
	nome_social: 'Nome social',
	nome_exibicao: 'Nome de exibição',
	cpf: 'CPF',
	rg: 'RG',
	tel: 'Telefone',
	email: 'E-mail',
	nascimento: 'Nascimento',
	endereco: 'Endereço',
	cidade: 'Cidade',
	uf: 'UF',
	cep: 'CEP',
	convenio: 'Convênio',
	carteirinha: 'Carteirinha',
	medico: 'Médico',
	crm: 'CRM',
	crefito: 'CREFITO',
	especialidades: 'Especialidades',
	tags: 'Tags',
	ativo: 'Ativo',
	// Consentimento — o par que o `06 §4` cobra por nome ("concessão e revogação").
	lgpd: 'Consentimento LGPD',
	comunicacao: 'Aceita comunicação',
	// Dados bancários e contratuais do profissional (todos redigidos, D-Aud4).
	banco: 'Banco',
	agencia: 'Agência',
	conta: 'Conta',
	conta_tipo: 'Tipo de conta',
	pix: 'PIX',
	cnpj: 'CNPJ',
	razao_social: 'Razão social',
	vinculo: 'Vínculo',
	// Equipe e acessos.
	papel: 'Papel',
	// Clínica e catálogo.
	timezone: 'Fuso horário',
	slot_minutos: 'Passo da grade',
	cap_turma_padrao: 'Capacidade padrão',
	duracao_minutos: 'Duração',
	capacidade: 'Capacidade',
	grupo: 'Em grupo',
	cor: 'Cor',
	icon: 'Ícone',
	// Expediente e exceções.
	periods: 'Períodos',
	dow: 'Dia da semana',
	modo: 'Modo',
	data: 'Data',
	tipo: 'Tipo',
	// Pacotes e fila.
	total: 'Total de sessões',
	falta_punitiva: 'Falta consome sessão',
	data_inicio: 'Início',
	prio: 'Prioridade',
	janela: 'Janela'
};

export function fieldLabel(field: string): string {
	return FIELD_LABELS[field] ?? field;
}

// Situação do participante (o `AttendanceStatus` da API). A do agendamento reusa `STATUS_META`
// da agenda — fonte única, para o mesmo "Concluído" não divergir entre a agenda e a auditoria.
const ATTENDANCE_STATUS_LABELS: Record<string, string> = {
	prevista: 'Prevista',
	concluida: 'Concluída',
	faltou: 'Faltou',
	cancelada: 'Cancelada'
};

function statusLabel(resource: AuditResource, value: string): string {
	if (resource === 'attendance') return ATTENDANCE_STATUS_LABELS[value] ?? value;
	if (resource === 'appointment') return STATUS_META[value as AppointmentStatus]?.label ?? value;
	// Os demais recursos têm `status` com vocabulário próprio (pacote, anexo, vínculo) e nenhum
	// deles é o da agenda — traduzir com `STATUS_META` diria a coisa errada com confiança.
	return value;
}

// Formata um VALOR do diff para exibição, ciente do campo e do recurso: datas → hora local da
// clínica; situação → rótulo; booleano → Sim/Não; nulo/vazio → "—".
export function formatValue(
	resource: AuditResource,
	field: string,
	value: unknown,
	timezone: string
): string {
	if (value === null || value === undefined || value === '') return '—';
	if (field === 'status') return statusLabel(resource, String(value));
	if (field === 'starts_at' || field === 'excluded_at') return formatAt(String(value), timezone);
	if (typeof value === 'boolean') return value ? 'Sim' : 'Não';
	// `especialidades`, `tags`, `prefs` são arrays; `periods` é uma lista de mapas. Sem isto o
	// `String()` renderizaria "[object Object]" — que é pior do que não mostrar.
	if (Array.isArray(value)) {
		return value.every((v) => typeof v === 'string' || typeof v === 'number')
			? value.join(', ') || '—'
			: `${value.length} item(ns)`;
	}
	if (typeof value === 'object') return '—';
	return String(value);
}

// ---- "Quando", no fuso da clínica ----

const atCache = new Map<string, Intl.DateTimeFormat>();
const timeCache = new Map<string, Intl.DateTimeFormat>();
const sessionCache = new Map<string, Intl.DateTimeFormat>();

function cached(
	cache: Map<string, Intl.DateTimeFormat>,
	timezone: string,
	options: Intl.DateTimeFormatOptions
): Intl.DateTimeFormat {
	let fmt = cache.get(timezone);
	if (!fmt) {
		fmt = new Intl.DateTimeFormat('pt-BR', { timeZone: timezone, hour12: false, ...options });
		cache.set(timezone, fmt);
	}
	return fmt;
}

// O instante da mudança formatado no fuso da clínica (ADR-009) — NUNCA no fuso do processo/
// browser, como o resto da agenda (`agenda.ts`). "20/07/2026 14:32". Segue sendo o carimbo
// COMPLETO: é o que vai no `title` da linha (o corpo mostra só a hora, dentro do grupo do dia).
export function formatAt(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;

	const fmt = cached(atCache, timezone, {
		day: '2-digit',
		month: '2-digit',
		year: 'numeric',
		hour: '2-digit',
		minute: '2-digit'
	});
	// "20/07/2026, 14:32" → "20/07/2026 14:32" (a vírgula do locale é ruído aqui).
	return fmt.format(new Date(ms)).replace(', ', ' ');
}

/** Só a hora ("14:32") — o que a linha mostra, já que o grupo diz o dia. */
export function formatTime(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;
	return cached(timeCache, timezone, { hour: '2-digit', minute: '2-digit' }).format(new Date(ms));
}

/** O horário da SESSÃO, para a linha de contexto: "ter 20/07, 09:00". */
export function formatSession(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;

	const fmt = cached(sessionCache, timezone, {
		weekday: 'short',
		day: '2-digit',
		month: '2-digit',
		hour: '2-digit',
		minute: '2-digit'
	});
	// pt-BR devolve "seg., 20/07, 09:00" (ou "seg, …" conforme o ICU) — o ponto e a vírgula da
	// abreviação são ruído numa linha densa. O recorte é `[^,]` e não `\w` porque "sáb" tem
	// acento, que `\w` não casa.
	return fmt.format(new Date(ms)).replace(/^([^,]+?)\.?,\s*/, '$1 ');
}

// Dia local (chave de agrupamento do feed por data). "2026-07-20". Reusa `zonedParts` da agenda
// — fonte única do "dia local de um instante" — que já cacheia o `Intl.DateTimeFormat` por fuso
// (senão `groupByDay` alocaria um formatter por entrada, por render). Guarda o iso inválido.
export function dayKey(iso: string, timezone: string): string {
	if (Number.isNaN(Date.parse(iso))) return iso;
	return zonedParts(iso, timezone).date;
}

const MONTHS = [
	'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
	'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

const WEEKDAY_FMT = new Intl.DateTimeFormat('pt-BR', { weekday: 'long', timeZone: 'UTC' });

/**
 * Cabeçalho de um grupo do feed. "20 de julho de 2026" — com **"Hoje ·"** / **"Ontem ·"** e o
 * dia da semana quando o dia é recente, que é o recorte que alguém varre de fato.
 *
 * `hoje` vem do servidor (nunca do relógio do browser). Sem ele, degrada para a data seca.
 */
export function dayHeading(key: string, hoje?: string): string {
	const [y, m, d] = key.split('-').map(Number);
	if (!y || !m || !d) return key;

	const data = `${d} de ${MONTHS[m - 1]} de ${y}`;
	if (!hoje) return data;
	if (key === hoje) return `Hoje · ${semana(key)}, ${d} de ${MONTHS[m - 1]}`;
	if (key === shiftDate(hoje, -1)) return `Ontem · ${semana(key)}, ${d} de ${MONTHS[m - 1]}`;
	return data;
}

// Meio-dia UTC de propósito: a data "YYYY-MM-DD" é um dia de calendário, e ler às 00:00 faria
// qualquer fuso a oeste recuar um dia no nome da semana.
function semana(key: string): string {
	return WEEKDAY_FMT.format(new Date(`${key}T12:00:00Z`));
}

// Agrupa as entradas (já em ordem decrescente) por dia local, preservando a ordem. Cada grupo
// leva a chave e o cabeçalho prontos.
export function groupByDay(
	entries: AuditEntry[],
	timezone: string,
	hoje?: string
): { day: string; heading: string; entries: AuditEntry[] }[] {
	const groups: { day: string; heading: string; entries: AuditEntry[] }[] = [];
	for (const entry of entries) {
		const day = dayKey(entry.at, timezone);
		let last = groups[groups.length - 1];
		if (!last || last.day !== day) {
			last = { day, heading: dayHeading(day, hoje), entries: [] };
			groups.push(last);
		}
		last.entries.push(entry);
	}
	return groups;
}

/**
 * Rodapé da paginação ("Página 2 · 51–100").
 *
 * **Sem o "de Z" (D-Aud1).** O total chegou a voltar nesta fatia, com o argumento de que a
 * retenção de 90 dias limitava a tabela — o bate-volta mediu e derrubou o argumento: ele é sobre
 * tamanho, não sobre custo por request. O `COUNT(*)` sai como uma **segunda query** e lê o
 * recorte inteiro apesar do `LIMIT`: 23,9 ms · 191 buffers contra 0,090 ms · 9 buffers da própria
 * página, num recorte de 84 mil linhas (**265×**) — ~99% do tempo de banco da tela.
 *
 * A função continua aceitando `total` e o usa quando existe: outras listas (Pacientes, Fila) têm
 * teto natural e pagam a conta de bom grado. O que mudou é que a trilha não manda mais.
 *
 * Nome próprio (`auditPageLabel`) de propósito: chamar-se `pageLabel` como o do
 * `$lib/pagination` é o tipo de colisão que passa despercebida num import trocado.
 */
export function auditPageLabel(page: PageInfo, shown: number, current = 1): string {
	if (!shown) return '';
	const faixa = `${page.offset + 1}–${page.offset + shown}`;
	const total = typeof page.total === 'number' ? `${faixa} de ${page.total}` : faixa;
	return current > 1 ? `Página ${current} · ${total}` : total;
}

// Só owner·admin veem a auditoria (RBAC da API; aqui é o gating do menu/UX). Espelha o
// `with_admin_scope` do controller — a autoridade continua na policy.
export const canViewAudit: (papel: Papel | null | undefined) => boolean = canManageMembers;

// ---- Estado da tela na URL ----

/** Um link da tela com a query remendada (o estado mora na URL, como nas outras listas). */
export function auditHref(params: URLSearchParams, patch: QueryPatch): string {
	return hrefWithQuery(AUDIT_BASE, params, patch);
}

/**
 * O patch que troca de grupo de registro.
 *
 * Zera `acao` e `record_id` junto — e não só a página. Os vocabulários de ação não se cruzam
 * (`cancel` não existe em anexo), então manter o filtro ao trocar de grupo devolveria um feed
 * **legitimamente** vazio, que lê como defeito. `record_id` é de um recurso só, pela mesma razão.
 */
export function resourcePatch(group: ResourceGroup | null): QueryPatch {
	return { resource: group, acao: null, record_id: null, page: null };
}

export interface FilterChip {
	/** A chave da query a limpar. */
	key: string;
	label: string;
}

/**
 * Os chips do que está filtrando agora, para o corpo da tela.
 *
 * Filtro que mora na sidebar precisa de eco no corpo: sem isso, uma lista curta (ou vazia) lê
 * como "não aconteceu nada" em vez de "você está filtrando" — o mesmo motivo do vazio ciente
 * do filtro na caixa de notificações (doc 53).
 */
export function activeChips(state: {
	resource: ResourceGroup | null;
	action: string | null;
	period: PeriodFilter;
	autor: string | null;
	recordId: string | null;
	autores: AuditRef[];
}): FilterChip[] {
	const chips: FilterChip[] = [];

	// O grupo de registro virou chip porque deixou de ser um eixo obrigatório: agora existe o
	// estado "sem recorte" (a clínica inteira), e sem o chip não haveria como perceber — nem
	// desfazer — que se está olhando só um pedaço.
	if (state.resource) {
		const label = RESOURCE_GROUPS.find((g) => g.key === state.resource)?.label ?? state.resource;
		chips.push({ key: 'resource', label });
	}

	if (state.period !== 'tudo') {
		const label = PERIOD_OPTIONS.find((p) => p.key === state.period)?.label ?? state.period;
		chips.push({ key: 'periodo', label });
	}

	if (state.action) {
		const opcao = actionOptions(state.resource).find((o) => o.key === state.action);
		chips.push({ key: 'acao', label: opcao?.label ?? state.action });
	}

	if (state.autor) {
		const nome = state.autores.find((a) => a.id === state.autor)?.nome ?? 'Autor';
		chips.push({ key: 'autor', label: `Por ${nome}` });
	}

	if (state.recordId) chips.push({ key: 'record_id', label: 'Um registro só' });

	return chips;
}
