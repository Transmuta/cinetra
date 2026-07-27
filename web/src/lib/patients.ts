// Tipos e regras puras da tela de Pacientes (fatia Pacientes). Espelha o cadastro do protótipo
// (`renderPacientes` :2669, `renderPacienteForm` :2010, `renderFicha` :2725). A autoridade real
// é a API (recurso `Patient` + policies); aqui é UX — filtrar, buscar, calcular idade, rótulo
// comercial e a cor do avatar.
import { canManageMembers, type Papel } from './session';
import type { PageInfo } from './pagination';
import { avatarColor } from './avatar';

export type AttendanceType = 'particular' | 'reembolso' | 'convenio';

// A ficha cadastral. Campos opcionais são `string | null` (a API devolve null quando vazio).
// `faltas`, pacotes, histórico e anexos NÃO entram na v1 (dependem de F1/F3/v2).
export interface Patient {
	id: string;
	nome: string;
	nome_social: string | null;
	cpf: string | null;
	rg: string | null;
	genero: string | null;
	estado_civil: string | null;
	nascimento: string | null;
	responsavel: string | null;
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
	emergencia_parentesco: string | null;
	emergencia_tel: string | null;
	profissao: string | null;
	empresa: string | null;
	atend_tipo: AttendanceType;
	convenio: string | null;
	carteirinha: string | null;
	convenio_validade: string | null;
	medico: string | null;
	crm: string | null;
	como_conheceu: string | null;
	prefs: string[];
	tags: string[];
	lgpd: boolean;
	comunicacao: boolean;
	cor_indice: number;
	ativo: boolean;
	/**
	 * Faltas não justificadas (agregado sobre `Attendance`). Só a FICHA o recebe — na lista seria
	 * um `count` por linha e ninguém pede o número ali, então lá vem `null`.
	 */
	faltas?: number | null;
}

// O recorte de página e seus dois helpers moram em `$lib/pagination` desde que a fila passou a
// paginar também (F6) — nada neles é de paciente. Reexportados aqui para quem já os importava.
export type { PageInfo } from './pagination';
export { parsePage, pageLabel } from './pagination';

// Contagens por segmento da sidebar. Vêm do servidor: com a lista paginada, contar o que
// chegou contaria só a página.
export type PatientCounts = Record<PatientFilter, number>;

export interface PatientsData {
	patients: Patient[];
	page: PageInfo;
	counts: PatientCounts;
}

// Gestão do cadastro = owner/admin (ADR-016), o MESMO recorte de Profissionais/Membros — daí o
// alias. A autoridade é a policy da API; isto só some da UI o que a pessoa não pode fazer.
export const canManagePatients: (papel: Papel | null | undefined) => boolean = canManageMembers;

// Cor do avatar do paciente — a paleta da agenda vive em `$lib/avatar` (token compartilhado
// com o profissional; o protótipo usa `this.cat` para os dois). Re-export nomeado para os
// call-sites da fatia não mudarem.
export const patientColor = avatarColor;

// Remove o "Dr./Dra." do nome para exibição compacta (chips de preferência, coluna da lista).
export function stripTitle(nome: string): string {
	return nome.replace(/^Dra?\.\s*/, '');
}

// Rótulo comercial (`convLabel` :319): convênio mostra o nome do plano; senão Reembolso/Particular.
const ATTENDANCE_LABELS: Record<AttendanceType, string> = {
	particular: 'Particular',
	reembolso: 'Reembolso',
	convenio: 'Convênio'
};

export function convLabel(p: Patient): string {
	if (p.atend_tipo === 'convenio') return p.convenio?.trim() || 'Convênio';
	return ATTENDANCE_LABELS[p.atend_tipo] ?? 'Particular';
}

// Idade a partir da data ISO (YYYY-MM-DD) do backend (`idadeDe` :317 parseia DD/MM/AAAA; aqui a
// origem é o `<input type="date">`). Null quando vazia ou implausível.
export function idade(nascimento: string | null, hoje: Date = new Date()): number | null {
	if (!nascimento) return null;
	const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(nascimento);
	if (!m) return null;
	const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
	let a = hoje.getFullYear() - y;
	if (hoje.getMonth() + 1 < mo || (hoje.getMonth() + 1 === mo && hoje.getDate() < d)) a--;
	return a >= 0 && a < 130 ? a : null;
}

// ---- Segmento da sidebar (Todos / Ativos / Inativos / Com responsável) ----
// Eixo único como o `pacFiltro` do protótipo (:1437); a v1 só expõe os segmentos calculáveis
// hoje (pacote/faltas dependem de F3/agenda). O recorte é aplicado **no servidor** (viaja em
// `?filter=`) — filtrar no cliente devolveria páginas furadas.

export type PatientFilter = 'todos' | 'ativos' | 'inativos' | 'resp';

const FILTERS: PatientFilter[] = ['todos', 'ativos', 'inativos', 'resp'];

// Lê o segmento da URL, caindo em "todos" para qualquer valor desconhecido.
export function parseFilter(value: string | null | undefined): PatientFilter {
	return FILTERS.find((f) => f === value) ?? 'todos';
}

// ---- Paginação ----

// Nº da página (1-based) vindo da URL; qualquer coisa inválida é a página 1.
// Nomes dos profissionais preferidos, resolvidos contra um mapa id→nome (a ficha recebe o
// diretório junto). `prefNomes` :318. Some em silêncio quem não estiver no mapa.
export function prefNomes(p: Patient, nomePorId: Record<string, string>): string[] {
	return (p.prefs ?? []).map((id) => nomePorId[id]).filter((n): n is string => !!n);
}
