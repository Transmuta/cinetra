// Tipos e regras puras da tela de Profissionais (fatia Profissionais). Espelha o diretório do
// protótipo (`renderProfissionais` :2929, `renderProfForm` :2955). A autoridade real é a API
// (recursos `Professional`/`ProfessionalHours` + policies); aqui é UX — filtrar, buscar,
// resolver o horário efetivo para a coluna "Atendimento" e escolher a cor do avatar.
import { canManageMembers, type Papel } from './session';
import { formatPeriods, WEEKDAYS, type Period } from './scheduling';
import { avatarColor } from './avatar';

export type ContractType = 'autonomo' | 'pj' | 'clt';
export type WeekdayMode = 'herda' | 'custom' | 'fechado';

// Uma linha da grade semanal (ou do expediente da clínica, que vem sem `modo`).
export interface HoursRow {
	dow: number;
	modo: WeekdayMode | null;
	periods: Period[];
}

export interface ProfessionalException {
	id: string;
	data: string;
	nome: string | null;
	tipo: 'fechado' | 'horario';
	periods: Period[];
}

// A ficha. Campos opcionais são `string | null` (a API devolve null quando vazio). `weekly_hours`
// vem na lista e na ficha; `exceptions` só na ficha (show).
export interface Professional {
	id: string;
	nome: string;
	nome_exibicao: string | null;
	nascimento: string | null;
	cpf: string | null;
	rg: string | null;
	estado_civil: string | null;
	tel: string | null;
	email: string | null;
	cep: string | null;
	endereco: string | null;
	numero: string | null;
	complemento: string | null;
	bairro: string | null;
	cidade: string | null;
	uf: string | null;
	emergencia_nome: string | null;
	emergencia_tel: string | null;
	profissao: string | null;
	crefito: string | null;
	registro_uf: string | null;
	ano_conclusao: string | null;
	especialidades: string[];
	sub: string | null;
	vinculo: ContractType | null;
	razao_social: string | null;
	cnpj: string | null;
	banco: string | null;
	agencia: string | null;
	conta: string | null;
	conta_tipo: string | null;
	pix: string | null;
	cor_indice: number;
	segue_horario_clinica: boolean;
	ativo: boolean;
	weekly_hours?: HoursRow[];
	exceptions?: ProfessionalException[];
}

export interface ProfessionalsData {
	professionals: Professional[];
	clinic_hours: HoursRow[];
}

// Gestão do diretório = owner/admin (ADR-016), o MESMO recorte de Membros/Tipos/Horário — daí
// o alias. A autoridade é a policy da API; isto só some da UI o que a pessoa não pode fazer.
export const canManageProfessionals: (papel: Papel | null | undefined) => boolean =
	canManageMembers;

// Rótulos do vínculo (badge da lista).
export const CONTRACT_LABELS: Record<ContractType, string> = {
	autonomo: 'Autônomo',
	pj: 'PJ',
	clt: 'CLT'
};

// Cor do avatar do profissional — a paleta da agenda vive em `$lib/avatar` (token
// compartilhado com o paciente). Re-export nomeado para os call-sites não mudarem.
export const profColor = avatarColor;

// ---- Filtro por status (Todos / Ativos / Inativos) ----

export type StatusFilter = 'todos' | 'ativos' | 'inativos';

export function filterByStatus(list: Professional[], status: StatusFilter): Professional[] {
	if (status === 'ativos') return list.filter((p) => p.ativo);
	if (status === 'inativos') return list.filter((p) => !p.ativo);
	return list;
}

export function countByStatus(list: Professional[]): Record<StatusFilter, number> {
	return {
		todos: list.length,
		ativos: list.filter((p) => p.ativo).length,
		inativos: list.filter((p) => !p.ativo).length
	};
}

// Rótulo de especialidade da lista (`espLabel` :2914): a 1ª especialidade + "+N", ou o `sub`,
// ou "—". A especialidade tem prioridade sobre o `sub`.
export function especialidadeLabel(p: Professional): string {
	const e = p.especialidades ?? [];
	if (e.length) return e.length > 1 ? `${e[0]} +${e.length - 1}` : e[0];
	return p.sub ?? '—';
}

/**
 * id → nome, para a tela resolver quem é o profissional preferido do paciente.
 *
 * O simétrico de `patientNameMap` (`agenda.ts:160`), que já existia. Este faltava, e por isso a
 * linha estava escrita à mão em duas telas — inclusive com o mesmo cast (doc 94 §D-5). Aceita a
 * forma mínima (`{ id, nome }`) porque quem chama é o `load` da tela de pacientes, cujo
 * `professionals` é o resumo da lista, não a ficha inteira.
 */
export function professionalNameMap(
	professionals: { id: string; nome: string }[] | undefined
): Record<string, string> {
	return Object.fromEntries((professionals ?? []).map((p) => [p.id, p.nome]));
}

// ---- Busca (nome, exibição, CREFITO, especialidade; CPF/telefone por dígitos) ----

const digits = (s: string | null): string => (s ?? '').replace(/\D/g, '');

export function searchProfessionals(list: Professional[], term: string): Professional[] {
	const q = term.trim().toLowerCase();
	if (!q) return list;
	const qDigits = q.replace(/\D/g, '');

	return list.filter((p) => {
		const haystack = [p.nome, p.nome_exibicao, p.crefito, p.sub, ...p.especialidades]
			.filter(Boolean)
			.join(' ')
			.toLowerCase();
		if (haystack.includes(q)) return true;
		// CPF/telefone por dígitos (só quando o termo tem dígitos, para não casar tudo com "").
		return qDigits.length > 0 && (digits(p.cpf).includes(qDigits) || digits(p.tel).includes(qDigits));
	});
}

// ---- Horário efetivo semanal (coluna "Atendimento") ----

// Converte o expediente da clínica (mapa `{dow => periods}` do BFF de Horário) em linhas
// `HoursRow[]` — a forma que o editor de grade e os helpers desta fatia consomem. Usado pelos
// loads de `/profissionais/novo` e `/[id]` (antes duplicado em cada um).
export function weekToHoursRows(week: Record<string, Period[]>): HoursRow[] {
	return Object.entries(week).map(([dow, periods]) => ({ dow: Number(dow), modo: null, periods }));
}

// Mapa dow→períodos do expediente da clínica.
function clinicMap(clinicHours: HoursRow[]): Record<number, Period[]> {
	const map: Record<number, Period[]> = {};
	for (const row of clinicHours) map[row.dow] = row.periods;
	return map;
}

// Períodos efetivos do profissional num dia-da-semana (espelho de `profWeek` :840): a grade tem
// `:custom`/`:fechado`; sem linha, herda a clínica quando "segue", senão não atende.
export function resolveWeekday(
	prof: Professional,
	dow: number,
	clinicHours: HoursRow[]
): Period[] {
	const row = (prof.weekly_hours ?? []).find((r) => r.dow === dow);
	const clinic = clinicMap(clinicHours)[dow] ?? [];

	if (row) {
		if (row.modo === 'custom') return row.periods;
		if (row.modo === 'fechado') return [];
		return clinic; // :herda
	}
	return prof.segue_horario_clinica ? clinic : [];
}

// Resumo textual para a lista ("Seg–Sex", "Seg, Qua", "Segue a clínica" ou "—") e o horário de
// referência (o de segunda), como o protótipo faz (`renderProfissionais` :2929).
export interface AttendanceSummary {
	days: string;
	hours: string;
	followsClinic: boolean;
}

const WD_SHORT: Record<number, string> = { 1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 0: 'Dom' };

export function attendanceSummary(prof: Professional, clinicHours: HoursRow[]): AttendanceSummary {
	const openWeekdays = [1, 2, 3, 4, 5].filter(
		(d) => resolveWeekday(prof, d, clinicHours).length > 0
	);

	const days =
		openWeekdays.length === 5
			? 'Seg–Sex'
			: openWeekdays.length
				? openWeekdays.map((d) => WD_SHORT[d]).join(', ')
				: '—';

	const monday = resolveWeekday(prof, 1, clinicHours);
	const hours = monday.length ? monday.map(([i, f]) => `${i}–${f}`).join(', ') : '';

	// "Segue a clínica": segue o expediente e não tem nenhum override próprio.
	const noOverrides = (prof.weekly_hours ?? []).every((r) => r.modo === 'herda');
	const followsClinic = prof.segue_horario_clinica && noOverrides;

	return { days, hours, followsClinic };
}

// ---- Grade do profissional (editor + submissão) ----

// Um dia da grade a submeter ao backend: modo + períodos (só `custom` carrega períodos).
export interface GradeDay {
	dow: number;
	modo: WeekdayMode;
	periods: Period[];
}

// Estado do editor: dow → períodos (custom) ou `null` (não atende). Dia ausente = não tocado.
export type GradeState = Record<number, Period[] | null>;

const mins = (t: string): number => {
	const [h, m] = t.split(':');
	return Number(h) * 60 + Number(m);
};

// Invariante prof ⊆ clínica (espelho de `Api.Scheduling.Periods.within/2`, a API é a autoridade):
// todo período cabe dentro de algum período da clínica no dia. Clínica fechada ⇒ só vazio cabe.
export function periodsWithinClinic(periods: Period[], clinic: Period[]): boolean {
	if (!clinic.length) return periods.length === 0;
	return periods.every(([i, f]) =>
		clinic.some(([ci, cf]) => mins(ci) <= mins(i) && mins(f) <= mins(cf))
	);
}

// Grade inicial do editor a partir da ficha: `custom`→períodos, `fechado`→null; herda/ausente
// pré-preenche uma cópia do expediente da clínica (o dia começa "aberto igual à clínica", como
// `toggleOwn` :2981 faz ao ligar um dia) — ou null quando a clínica está fechada nesse dia.
export function initialGrade(prof: Professional | null, clinicHours: HoursRow[]): GradeState {
	const clinic = clinicMap(clinicHours);
	const rows = prof?.weekly_hours ?? [];
	const grade: GradeState = {};

	for (const { dow } of WEEKDAYS) {
		const row = rows.find((r) => r.dow === dow);
		const clinicDay = clinic[dow] ?? [];

		if (row?.modo === 'custom') grade[dow] = row.periods;
		else if (row?.modo === 'fechado') grade[dow] = null;
		else grade[dow] = clinicDay.length ? clinicDay.map(([i, f]): Period => [i, f]) : null;
	}
	return grade;
}

// Os 7 dias a submeter. Seguindo a clínica ⇒ tudo `:herda` (limpa qualquer custom antigo).
// Senão: clínica fechada ⇒ `:fechado` (não se atende quando a clínica não abre); dia ligado com
// períodos ⇒ `:custom`; dia desligado ⇒ `:fechado`.
export function buildDays(
	segue: boolean,
	grade: GradeState,
	clinicHours: HoursRow[]
): GradeDay[] {
	const clinic = clinicMap(clinicHours);

	return WEEKDAYS.map(({ dow }): GradeDay => {
		if (segue) return { dow, modo: 'herda', periods: [] };
		if (!(clinic[dow] ?? []).length) return { dow, modo: 'fechado', periods: [] };
		const day = grade[dow];
		return day && day.length
			? { dow, modo: 'custom', periods: day }
			: { dow, modo: 'fechado', periods: [] };
	});
}

// "Horário obrigatório": seguindo a clínica, sempre ok; senão, ao menos um dia atende.
export function hasAttendingDay(
	segue: boolean,
	grade: GradeState,
	clinicHours: HoursRow[]
): boolean {
	if (segue) return true;
	const clinic = clinicMap(clinicHours);
	return WEEKDAYS.some(({ dow }) => (clinic[dow] ?? []).length && (grade[dow]?.length ?? 0) > 0);
}

// Reexport para conveniência das telas (evita import duplo de scheduling).
export { formatPeriods, WEEKDAYS };
