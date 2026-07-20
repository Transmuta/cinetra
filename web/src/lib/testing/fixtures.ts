// Fábricas de fixture para os testes.
//
// Existe porque 11 arquivos de teste montavam um `Me` à mão, e cada campo novo no payload de
// `/api/auth/me` exigia tocar nos 11 — foi o que aconteceu ao levar `timezone` para lá.
// Com a fábrica, o campo novo entra num lugar só e todo teste que não se importa com ele
// continua verde; quem se importa sobrescreve pelo `over`.

import type { Me, MembershipSummary, Papel } from '../session';

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
