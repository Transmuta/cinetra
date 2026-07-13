// Tipos e metadados da tela de Equipe & acessos (Fatia 10). Sem dependência de Svelte —
// usável no load, nos componentes e nos testes.

import type { Papel } from './session';

export type MemberStatus = 'ativo' | 'pendente';

export interface Member {
	id: string;
	nome: string;
	email: string;
	papel: Papel;
	status: MemberStatus;
	professional_id: string | null;
}

export interface Professional {
	id: string;
	nome: string;
}

export interface MembersData {
	members: Member[];
	professionals: Professional[];
}

// Rótulo + descrição de cada papel (o ícone é resolvido no componente, que importa lucide).
export const ROLE_META: Record<Papel, { label: string; desc: string }> = {
	owner: {
		label: 'Dona',
		desc: 'Controle total: configurações, equipe, faturamento e a própria clínica.'
	},
	admin: {
		label: 'Administrador',
		desc: 'Acesso total — configurações, equipe, todas as agendas e relatórios.'
	},
	profissional: {
		label: 'Profissional',
		desc: 'Gerencia a própria agenda e seus pacientes.'
	},
	recepcao: {
		label: 'Recepção',
		desc: 'Opera a agenda de todos, sem configurações sensíveis.'
	}
};

// Papéis oferecidos ao convidar/editar. `owner` não entra: a dona é definida no onboarding
// e a gestão de owners é exclusiva de owner (ADR-016 / D23).
export const INVITABLE_ROLES: Papel[] = ['admin', 'profissional', 'recepcao'];

// Professionais ativos que ainda não têm um membro vinculado (card "sem acesso").
export function professionalsWithoutAccess(data: MembersData): Professional[] {
	const linked = new Set(
		data.members
			.filter((m) => m.papel === 'profissional' && m.professional_id)
			.map((m) => m.professional_id)
	);
	return data.professionals.filter((p) => !linked.has(p.id));
}

// Nome do profissional vinculado a um membro (ou null).
export function linkedProfessionalName(member: Member, data: MembersData): string | null {
	if (member.papel !== 'profissional' || !member.professional_id) return null;
	return data.professionals.find((p) => p.id === member.professional_id)?.nome ?? null;
}
