// Tipos da sessão/escopo (espelham `/api/auth/me`, ADR-014). Compartilhados entre o load
// do servidor e os componentes do shell.

import type { Endereco } from './endereco';

export type Papel = 'owner' | 'admin' | 'profissional' | 'recepcao';

export interface MembershipSummary {
	clinic_id: string;
	clinic_nome: string | null;
	// Identidade da clínica (para o topo do sidebar); vem do /me junto do nome. O endereço são
	// sete campos, os mesmos da tela /configuracoes/clinica — enquanto só `clinic_endereco`
	// (o logradouro) viajava, o sidebar mostrava "Av. Paulista" e engolia o resto.
	clinic_cnpj: string | null;
	clinic_telefone: string | null;
	clinic_cep: string | null;
	clinic_endereco: string | null;
	clinic_numero: string | null;
	clinic_complemento: string | null;
	clinic_bairro: string | null;
	clinic_cidade: string | null;
	clinic_uf: string | null;
	// O fuso muda junto com o tenant na troca de clínica.
	clinic_timezone: string | null;
	papel: Papel;
	professional_id: string | null;
}

/** A identidade da clínica como o shell a mostra — sem o prefixo `clinic_` do payload. */
export interface ClinicIdentity extends Endereco {
	nome: string | null;
	cnpj: string | null;
	telefone: string | null;
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

// A identidade da clínica ativa, num objeto só.
//
// Existe para o shell não conhecer o formato achatado do `/me` (o payload é um membership por
// clínica, e por isso prefixa tudo com `clinic_`). Um objeto, e não uma prop por campo: o cromo
// é montado DUAS vezes (fixo no desktop, dentro da gaveta no mobile) e cada prop nova precisava
// ser ligada nos dois — foi assim que o CNPJ ficou de fora de uma delas. Dez props de endereço
// seriam a mesma armadilha, dez vezes.
export function clinicIdentity(m: MembershipSummary | null | undefined): ClinicIdentity | null {
	if (!m) return null;

	return {
		nome: m.clinic_nome,
		cnpj: m.clinic_cnpj,
		telefone: m.clinic_telefone,
		cep: m.clinic_cep,
		endereco: m.clinic_endereco,
		numero: m.clinic_numero,
		complemento: m.clinic_complemento,
		bairro: m.clinic_bairro,
		cidade: m.clinic_cidade,
		uf: m.clinic_uf
	};
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
