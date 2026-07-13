// Tipos da sessão/escopo (espelham `/api/auth/me`, ADR-014). Compartilhados entre o load
// do servidor e os componentes do shell.

export type Papel = 'owner' | 'admin' | 'profissional' | 'recepcao';

export interface MembershipSummary {
	clinic_id: string;
	clinic_nome: string | null;
	papel: Papel;
	professional_id: string | null;
}

export interface Me {
	user: { id: string; nome: string; email: string };
	active_clinic_id: string | null;
	papel: Papel | null;
	professional_id: string | null;
	memberships: MembershipSummary[];
}

// O membership da clínica ativa (traz o nome da clínica para o chrome).
export function activeMembership(me: Me): MembershipSummary | undefined {
	return me.memberships.find((m) => m.clinic_id === me.active_clinic_id);
}

// Quem pode gerir a equipe (RBAC ADR-016). Espelho da guarda do servidor — a autoridade
// real é a policy da API; aqui é só para esconder o que o usuário não pode fazer.
export function canManageMembers(papel: Papel | null | undefined): boolean {
	return papel === 'owner' || papel === 'admin';
}
