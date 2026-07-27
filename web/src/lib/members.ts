// Tipos e metadados da tela de Equipe & acessos (Fatia 10). Sem dependência de Svelte —
// usável no load, nos componentes e nos testes.

import { canManageMembers, type Papel } from './session';

export type MemberStatus = 'ativo' | 'pendente';

export interface Member {
	/** O id do VÍNCULO — é por ele que se edita/revoga o membro. */
	id: string;
	/**
	 * O id do USUÁRIO — o que a trilha de auditoria grava como autor (`version.user_id`), e por
	 * onde a tela de Auditoria filtra "por autor".
	 *
	 * Opcional porque a tela de Equipe constrói um `Member` sintético para pré-preencher o
	 * convite de um profissional **sem acesso**: ali não existe usuário ainda.
	 */
	user_id?: string;
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

// Este membro é gerenciável (editar/remover) pelo actor? owner mexe em todos — inclusive
// outro owner; admin só nos papéis abaixo dele (não mexe em owner nem em outro admin).
// Espelho da hierarquia da API (RoleManagement) — a autoridade real é a policy; aqui é só
// para esconder da UI o que o usuário não pode fazer.
export function canManageMember(actorPapel: Papel | null | undefined, target: Member): boolean {
	if (!canManageMembers(actorPapel)) return false;
	if (actorPapel === 'owner') return true;
	// admin:
	return target.papel !== 'owner' && target.papel !== 'admin';
}

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
