// Fábricas de fixture para os testes.
//
// Existe porque 11 arquivos de teste montavam um `Me` à mão, e cada campo novo no payload de
// `/api/auth/me` exigia tocar nos 11 — foi o que aconteceu ao levar `timezone` para lá.
// Com a fábrica, o campo novo entra num lugar só e todo teste que não se importa com ele
// continua verde; quem se importa sobrescreve pelo `over`.

import type { Me, MembershipSummary, Papel } from '../session';
import type { AgendaProfessional } from '../agenda';
import type { DayCount, ProfessionalCount } from '../agenda-views';

export function membershipFixture(over: Partial<MembershipSummary> = {}): MembershipSummary {
	return {
		clinic_id: 'c1',
		clinic_nome: 'Clínica Teste',
		clinic_cnpj: null,
		clinic_endereco: null,
		clinic_timezone: 'America/Sao_Paulo',
		papel: 'owner' as Papel,
		professional_id: null,
		...over
	};
}

// ---------------------------------------------------------------------------
// Agenda — contagens das visões Semana e Mês
//
// Nasceram três fábricas `dia()` com o mesmo nome, o mesmo papel e três contratos diferentes
// (uma por objeto parcial, uma posicional, uma sem overrides) espalhadas por WeekView,
// MonthView e page.server. Um campo novo em `ProfessionalCount` custaria quatro consertos com
// quatro assinaturas incompatíveis — o caso que o checklist do bate-volta chama de "o mais
// caro, e o mais fácil de não ver".
// ---------------------------------------------------------------------------

export function professionalCountFixture(over: Partial<ProfessionalCount> = {}): ProfessionalCount {
	return {
		professional_id: 'p1',
		total: 3,
		ocupado_minutos: 270,
		capacidade_minutos: 540,
		...over
	};
}

/**
 * Um dia de contagens. Sem `professionals`, nasce com um profissional a 50% de ocupação
 * (270/540) — o caso normal, que é o que a maioria dos testes quer de pano de fundo.
 */
export function dayCountFixture(date: string, professionals?: Partial<ProfessionalCount>[]): DayCount {
	return {
		date,
		professionals: (professionals ?? [{}]).map(professionalCountFixture)
	};
}

export function agendaProfessionalFixture(
	over: Partial<AgendaProfessional> = {}
): AgendaProfessional {
	return {
		id: 'p1',
		nome: 'Dra. Teste',
		nome_exibicao: null,
		crefito: null,
		cor_indice: 1,
		segue_horario_clinica: true,
		...over
	};
}

export function meFixture(over: Partial<Me> = {}): Me {
	return {
		user: { id: 'u1', nome: 'Fulano', email: 'fulano@example.com' },
		active_clinic_id: 'c1',
		papel: 'owner' as Papel,
		professional_id: null,
		timezone: 'America/Sao_Paulo',
		memberships: [membershipFixture()],
		...over
	};
}
