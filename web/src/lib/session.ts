// Tipos da sessão/escopo (espelham `/api/auth/me`, ADR-014). Compartilhados entre o load
// do servidor e os componentes do shell.

export type Papel = 'owner' | 'admin' | 'profissional' | 'recepcao';

export interface MembershipSummary {
	clinic_id: string;
	clinic_nome: string | null;
	// Identidade da clínica (para o topo do sidebar); vem do /me junto do nome.
	clinic_cnpj: string | null;
	clinic_endereco: string | null;
	// O fuso muda junto com o tenant na troca de clínica.
	clinic_timezone: string | null;
	papel: Papel;
	professional_id: string | null;
}

export interface Me {
	// `avatar_url` é a foto de perfil (hoje só a que veio do Google) **já assinada** pela API: o
	// objeto mora em bucket privado, e a URL vale poucos minutos. Nula = sem foto, e a tela cai
	// nas iniciais — nenhum lugar do web deve assumir que ela existe.
	user: { id: string; nome: string; email: string; avatar_url?: string | null };
	active_clinic_id: string | null;
	papel: Papel | null;
	professional_id: string | null;
	// Fuso da clínica ativa (ADR-009), para que a agenda saiba que dia é NA CLÍNICA antes da
	// primeira busca — ver `(app)/agenda/+page.server.ts`. O relógio NÃO vem junto de
	// propósito: o `me` é carregado pelo layout, que não reexecuta em navegação client-side,
	// e um instante daqui congelaria na abertura da aba.
	timezone: string | null;
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

// Quem pode editar os dados da clínica (identidade: nome/CNPJ/endereço). Predicado próprio,
// como canManageSchedule/canManageProfessionals: hoje coincide com a gestão de equipe, mas a
// autoridade é a policy `update_info` da API — este é só o recorte de UX do domínio "clínica".
export function canManageClinic(papel: Papel | null | undefined): boolean {
	return papel === 'owner' || papel === 'admin';
}
