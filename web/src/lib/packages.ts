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
