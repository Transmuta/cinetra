// Tipos e metadados da tela de Tipos de atendimento (doc 20). Cobre o catálogo da clínica
// (Avaliação, Sessão, RPG…) — NÃO a categoria comercial do paciente (particular/reembolso/
// convênio), que divide o rótulo na UI mas é outro recurso (doc 20 §0).

import Activity from '@lucide/svelte/icons/activity';
import ClipboardList from '@lucide/svelte/icons/clipboard-list';
import StretchHorizontal from '@lucide/svelte/icons/stretch-horizontal';
import Users from '@lucide/svelte/icons/users';
import RefreshCw from '@lucide/svelte/icons/refresh-cw';
import HeartPulse from '@lucide/svelte/icons/heart-pulse';
import Dumbbell from '@lucide/svelte/icons/dumbbell';
import Footprints from '@lucide/svelte/icons/footprints';
import Hand from '@lucide/svelte/icons/hand';
import Bone from '@lucide/svelte/icons/bone';
import { canManageMembers, type Papel } from './session';

// Objeto da wire (doc 20 §3). `sigla` é derivada no servidor (T4) — read-only aqui.
export interface AppointmentType {
	id: string;
	nome: string;
	sigla: string;
	duracao_minutos: number;
	cor: string;
	icon: string;
	grupo: boolean;
	capacidade: number | null;
	ativo: boolean;
}

export interface AppointmentTypesData {
	// Ativos E arquivados: a API manda tudo e a tela separa (doc 20 §3 / T5).
	appointment_types: AppointmentType[];
	// Default de capacidade do modal: vem SEMPRE junto do GET (doc 20 §3 — irmão de
	// `appointment_types`, no molde do `{members, professionals}`). É o `clinic.cap_turma_padrao`.
	// Obrigatório porque o contrato garante e o teste do backend prova; o `?? DEFAULT_CAPACIDADE`
	// no load é só cinto contra resposta malformada, não parte normal do contrato.
	cap_turma_padrao: number;
}

// Paleta fechada de cores (protótipo :2391). Validada com `one_of` no servidor também —
// aqui ela existe para a UI só oferecer o que a API aceita.
export const TYPE_COLORS = [
	'#0FB5A6',
	'#0072B2',
	'#009E73',
	'#CC79A7',
	'#7A52CC',
	'#D55E00',
	'#E69F00',
	'#2B7FFF'
] as const;

// Paleta fechada de ícones (protótipo :2390).
export const TYPE_ICONS = [
	'Activity',
	'ClipboardList',
	'StretchHorizontal',
	'Users',
	'RefreshCw',
	'HeartPulse',
	'Dumbbell',
	'Footprints',
	'Hand',
	'Bone'
] as const;

export type TypeIconName = (typeof TYPE_ICONS)[number];

// Defaults do "Novo tipo" (protótipo :3229). A capacidade é o fallback de `cap_turma_padrao`
// da clínica (doc 20 §1) — ver `+page.server.ts`.
export const DEFAULT_DURACAO = 50;
export const DEFAULT_COR = '#0072B2';
export const DEFAULT_ICON = 'Activity';
export const DEFAULT_CAPACIDADE = 4;

// O map nome→componente vive AQUI, e não nos componentes como manda o nav.ts, por um motivo
// concreto: o ícone de um tipo é *dado* vindo da API, e tanto a lista quanto o modal precisam
// resolver o mesmo nome. Duplicar o map nos dois seria a divergência de amanhã.
const ICON_COMPONENTS: Record<TypeIconName, typeof Activity> = {
	Activity,
	ClipboardList,
	StretchHorizontal,
	Users,
	RefreshCw,
	HeartPulse,
	Dumbbell,
	Footprints,
	Hand,
	Bone
};

// Componente do ícone pelo nome vindo da API. Nome desconhecido cai no default (:2392): a
// paleta é validada no servidor, mas um dado antigo/divergente não pode derrubar a tela.
export function iconComponent(name: string): typeof Activity {
	return ICON_COMPONENTS[name as TypeIconName] ?? ICON_COMPONENTS[DEFAULT_ICON as TypeIconName];
}

// tint() do protótipo (:314): hex → rgba. É o fundo do quadrado do ícone na lista, a única
// cor que precisa ser calculada em runtime (a paleta dos tipos não é tokenizável no CSS).
export function tint(hex: string, alpha: number): string {
	// `String(… ?? '')` não é paranoia decorativa: `cor` é tipada como string, mas chega de
	// JSON não-tipado da API — e um null aqui derrubaria o render da linha inteira.
	const h = String(hex ?? '').replace('#', '');
	if (!/^[0-9a-fA-F]{6}$/.test(h)) return 'transparent';
	const r = parseInt(h.slice(0, 2), 16);
	const g = parseInt(h.slice(2, 4), 16);
	const b = parseInt(h.slice(4, 6), 16);
	return `rgba(${r},${g},${b},${alpha})`;
}

export interface SplitTypes {
	ativos: AppointmentType[];
	arquivados: AppointmentType[];
}

// Arquivar some da lista principal e joga na seção "Arquivados" (T5). A API manda os dois
// no mesmo array (§3), então o corte é aqui.
export function splitByStatus(types: AppointmentType[]): SplitTypes {
	return {
		ativos: types.filter((t) => t.ativo),
		arquivados: types.filter((t) => !t.ativo)
	};
}

// Gestão do catálogo = owner/admin (T8), exatamente o MESMO recorte de Membros — daí o
// alias em vez de uma segunda cópia da regra. Se um dia divergirem, separa-se aqui. Como
// sempre, a autoridade real é a policy da API; isto só esconde da UI o que não dá para fazer.
export const canManageAppointmentTypes: (papel: Papel | null | undefined) => boolean =
	canManageMembers;
