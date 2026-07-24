// Tipos e rótulos dos pacotes (Fatia 3). Espelham o JSON de `ApiWeb.PackagesJSON`. Sem lógica de
// tenant/RBAC aqui — isso vive no escopo da API.

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
	grade: PackageGrade | null;
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
// fechada vive aqui para o modal oferecer só tons legíveis. Espelha a paleta dos tipos.
export const PACKAGE_COLORS = [
	'#0FB5A6',
	'#7A52CC',
	'#2B7FFF',
	'#009E73',
	'#D55E00',
	'#E69F00',
	'#CC79A7',
	'#0072B2'
] as const;

// Defaults do "Novo pacote". `falta_punitiva` nasce marcada — é a combinação comercial mais
// comum (a falta desconta a sessão) e é obrigatória na criação (imutável depois).
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
