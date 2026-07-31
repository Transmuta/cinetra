// Tipos e rótulos dos pacotes (Fatia 3). Espelham o JSON de `ApiWeb.PackagesJSON`. Sem lógica de
// tenant/RBAC aqui — isso vive no escopo da API.

import { TYPE_COLORS } from './appointment-types';

export type PackageStatus = 'ativo' | 'pausado' | 'cancelado' | 'concluido';

// A classificação de uma ocorrência na prévia (o save-gate). Espelha `Api.Packages.Preview`.
export type OccurrenceIssue = 'ok' | 'feriado' | 'fora_expediente' | 'conflito' | 'cheia' | 'join';

export interface PackageGrade {
	dows: number[];
	// chaves como string ("1"), no formato que o JSONB devolve.
	horarios: Record<string, string>;
	professional_id: string;
}

export interface Package {
	id: string;
	nome: string;
	status: PackageStatus;
	total: number;
	// derivados do domínio (podem vir null se não foram carregados).
	usadas: number | null;
	restantes: number | null;
	acabando: boolean | null;
	falta_punitiva: boolean;
	cor: string;
	data_inicio: string;
	/** o tipo de atendimento é a identidade do pacote (nome/duração/cor vêm do catálogo) */
	appointment_type_id: string | null;
	grade: PackageGrade | null;
	/** a trilha: uma entrada por sessão da série, com o estado. Vem junto da listagem. */
	sessoes?: PackageSession[];
}

/**
 * O estado de uma sessão na trilha. **Cancelada não está aqui**: o servidor a filtra — a trilha é
 * a série, não o cemitério dela (senão o cartão desenha oito bolinhas num pacote de seis).
 */
export type SessionState = 'concluida' | 'falta' | 'segurada' | 'proxima' | 'agendada';

export interface PackageSession {
	attendance_id: string;
	appointment_id: string;
	starts_at: string;
	estado: SessionState;
}

export interface PreviewOccurrence {
	data: string;
	hhmm: string;
	feriado: boolean;
	issue: OccurrenceIssue;
	bloqueia: boolean;
}

export interface PreviewResult {
	ocorrencias: PreviewOccurrence[];
	bloqueios: number;
	pode_salvar: boolean;
}

/**
 * O corpo dos endpoints internos que o BROWSER chama por `fetch`. Moram aqui, e não no
 * `+server.ts`, porque precisam ser importáveis dos **dois** lados — ver a nota gêmea em
 * `waitlist.ts` e o doc 94 §4.5.
 */
export interface PackageSessionsResponse {
	sessions: PackageSession[];
}

export interface PackagePreviewResponse {
	preview: PreviewResult | null;
}

// Rótulo humano do status, para o chip da ficha.
const STATUS_LABEL: Record<PackageStatus, string> = {
	ativo: 'Ativo',
	pausado: 'Pausado',
	cancelado: 'Cancelado',
	concluido: 'Concluído'
};

export function statusLabel(status: PackageStatus): string {
	return STATUS_LABEL[status] ?? status;
}

// Explicação curta do que cada issue significa, para o chip da ocorrência na prévia. `ok` não
// aparece (é o caso silencioso).
const ISSUE_LABEL: Record<OccurrenceIssue, string> = {
	ok: '',
	feriado: 'Feriado — pulado',
	fora_expediente: 'Fora do expediente',
	conflito: 'Conflito de horário',
	cheia: 'Turma cheia',
	join: 'Entra em turma existente'
};

export function issueLabel(issue: OccurrenceIssue): string {
	return ISSUE_LABEL[issue] ?? '';
}

// Dias da semana na convenção do projeto (0=domingo). Rótulos curtos para a grade.
export const DOW_LABELS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

// Paleta de cores do pacote (o `cor` do cartão). O backend só exige `allow_nil? false` — a lista
// fechada existe para o modal oferecer só tons legíveis, e é **a mesma dos tipos de atendimento**:
// as duas aparecem lado a lado na agenda, e duas paletas parecidas-mas-não-iguais é o jeito de a
// tela ficar suja sem ninguém saber por quê. Era uma terceira cópia dos mesmos 8 hexadecimais
// (I67), na mesma ordem que não batia com nenhuma das outras duas.
export const PACKAGE_COLORS = TYPE_COLORS;

// Defaults do "Novo pacote". `falta_punitiva` nasce marcada — é a combinação comercial mais
// comum (a falta desconta a sessão) e é obrigatória na criação (imutável depois).
/**
 * Teto de sessões que a tela oferece. O servidor tem um teto **próprio e maior** (120,
 * `Package.total`): o dele existe para barrar absurdo vindo de qualquer cliente — `total` dimensiona
 * a materialização e a massa, e sem teto um `500` no lugar de `50` vira ~15 s de transação única
 * (doc 43 §7). Este aqui é a faixa confortável do produto, e é o que evita o usuário receber o 422
 * do servidor (cuja mensagem vem do Ash, em inglês) por algo que a tela já sabia recusar.
 */
export const PACKAGE_MAX_TOTAL = 60;

export const NEW_PACKAGE_DEFAULTS = {
	total: 10,
	cor: PACKAGE_COLORS[0],
	falta_punitiva: true
} as const;

// Só o `fora_expediente` é bloqueio absoluto: encaixe não isenta (D14), então `forcar` não o
// materializa. Conflito e turma cheia o "agendar mesmo assim" resolve. Feriado/join/ok nunca
// bloqueiam. Espelha `Api.Packages.gate/2`.
export function hasHardBlock(preview: PreviewResult): boolean {
	return preview.ocorrencias.some((o) => o.issue === 'fora_expediente');
}

// ---------------------------------------------------------------------------
// O que o cartão da ficha precisa para RESPONDER (doc 69 §7). O cartão antigo mostrava nome,
// "X de Y restantes" e três botões — e não dizia que dias, com quem, nem quando é a próxima.
// ---------------------------------------------------------------------------

/**
 * A grade em uma linha: `Seg 08:00, Qua 09:00 · Ana Prado`. Porta do `pkgGradeLabel` do protótipo
 * ([`:333`](../../../interface/Movimento.dc.html#L333)).
 *
 * Os dias saem **ordenados** (a grade guarda o array na ordem em que o usuário clicou) e o
 * profissional que não está na lista simplesmente some do rótulo — a alternativa era imprimir
 * `undefined` na ficha por causa de um profissional arquivado.
 */
export function gradeLabel(
	grade: PackageGrade | null | undefined,
	professionals: { id: string; nome: string }[]
): string {
	if (!grade) return '';

	const dias = [...grade.dows]
		.sort((a, b) => a - b)
		.map((d) => {
			const hora = grade.horarios?.[String(d)];
			return hora ? `${DOW_LABELS[d]} ${hora}` : DOW_LABELS[d];
		})
		.join(', ');

	const prof = professionals.find((p) => p.id === grade.professional_id)?.nome;
	return [dias, prof].filter(Boolean).join(' · ');
}

export type ChipTone = 'accent' | 'warning' | 'faint' | 'danger';
/** Ícone da pílula de estado — `null` é o "Ativo", que no protótipo não tem ícone. */
export type ChipIcone = 'alerta' | 'pausa' | 'check' | 'x' | null;

/**
 * O chip de estado. Duas coisas que o cartão antigo não dizia:
 *
 *  - **"Acabando"** (o `acabando` do domínio: ativo com 1–2 restantes) — é o gatilho comercial da
 *    conversa "vamos renovar?", e vinha calculado do servidor sendo jogado fora (achado §6.4);
 *  - **"Completo"** — 0 restantes num pacote que ninguém arquivou. Por **D1** o `status` só vira
 *    `concluido` na mão, então sem este rótulo o pacote terminado se apresenta como "Ativo".
 */
export function statusChip(pkg: {
	status: PackageStatus;
	acabando: boolean | null;
	restantes: number | null;
}): { label: string; tone: ChipTone; icone: ChipIcone } {
	if (pkg.status === 'pausado') return { label: 'Pausado', tone: 'faint', icone: 'pausa' };
	if (pkg.status === 'cancelado') return { label: 'Cancelado', tone: 'danger', icone: 'x' };
	if (pkg.status === 'concluido') return { label: 'Concluído', tone: 'faint', icone: 'check' };

	if (pkg.restantes === 0) return { label: 'Completo', tone: 'faint', icone: 'check' };
	if (pkg.acabando) return { label: 'Acabando', tone: 'warning', icone: 'alerta' };
	return { label: 'Ativo', tone: 'accent', icone: null };
}

/**
 * O **código** do pacote — `PIL-2607`: a sigla do tipo + o ano/mês de início (`pkgCode` do
 * protótipo, [`:380`](../../../interface/Movimento.dc.html#L380)).
 *
 * É a identidade curta que a recepção fala ao telefone ("o PIL-2607 da Maria") e o que substitui o
 * campo "nome" que o formulário pedia. Sem o tipo à mão (arquivado), a sigla sai das letras do
 * próprio nome do pacote; sem letras nenhuma, um prefixo estável.
 */
export function packageCode(
	pkg: { data_inicio: string; nome: string },
	tipo: { sigla?: string } | undefined
): string {
	const letras = pkg.nome.replace(/[^A-Za-zÀ-ÿ]/g, '');
	const sigla = (tipo?.sigla || letras.slice(0, 3) || 'PKG').toUpperCase();
	const [ano, mes] = pkg.data_inicio.split('-');
	return `${sigla}-${ano.slice(2)}${mes}`;
}

/** Pacote "atual" é o que ainda corre — os outros são histórico (`pkgIsCurrent` do protótipo). */
export function isCurrent(status: PackageStatus): boolean {
	return status === 'ativo' || status === 'pausado';
}

/** A contagem do cabeçalho: só os atuais. Contar os mortos dava "Pacotes · 7" numa ficha antiga. */
export function activeCount(packages: { status: PackageStatus }[]): number {
	return packages.filter((p) => isCurrent(p.status)).length;
}

/**
 * A próxima sessão **daquele** pacote, tirada das próximas do paciente (que a ficha já carrega).
 * Com dois pacotes ativos, "próxima do paciente" não responde "quando é a próxima do Pilates".
 *
 * A lista chega ordenada da API (da mais próxima para a mais distante), então o primeiro casamento
 * é a resposta. Devolve `null` quando aquele pacote não tem sessão entre as próximas carregadas.
 */
export function nextSessionOf<T extends { package_id: string | null }>(
	upcoming: T[],
	packageId: string
): T | null {
	return upcoming.find((s) => s.package_id === packageId) ?? null;
}
