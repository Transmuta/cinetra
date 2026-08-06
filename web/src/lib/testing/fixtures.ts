// Fábricas de fixture para os testes.
//
// Existe porque 11 arquivos de teste montavam um `Me` à mão, e cada campo novo no payload de
// `/api/auth/me` exigia tocar nos 11 — foi o que aconteceu ao levar `timezone` para lá.
// Com a fábrica, o campo novo entra num lugar só e todo teste que não se importa com ele
// continua verde; quem se importa sobrescreve pelo `over`.

import type { Me, MembershipSummary, Papel } from '../session';
import type { Clinic } from '../server/clinics';
import type { AgendaProfessional } from '../agenda';
import type { DayCount, ProfessionalCount } from '../agenda-views';
import type { AuditEntry } from '../audit';

export function membershipFixture(over: Partial<MembershipSummary> = {}): MembershipSummary {
	return {
		clinic_id: 'c1',
		clinic_nome: 'Clínica Teste',
		clinic_cnpj: null,
		clinic_telefone: null,
		clinic_cep: null,
		clinic_endereco: null,
		clinic_numero: null,
		clinic_complemento: null,
		clinic_bairro: null,
		clinic_cidade: null,
		clinic_uf: null,
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

// Uma entrada da trilha de auditoria. Nasceu em dobro — `entry()` reescrita em `audit.test.ts`
// e em `AuditEntry.svelte.test.ts`, com os mesmos 13 campos e defaults divergentes —, que é o
// caso exato que esta casa existe para evitar: um campo novo em `AuditEntry` custava dois
// consertos. Os defaults são de uma CRIAÇÃO de agendamento; quem testa outra coisa sobrescreve.
export function auditEntryFixture(over: Partial<AuditEntry> = {}): AuditEntry {
	return {
		id: 'v1',
		resource: 'appointment',
		record_id: 'a1',
		label: null,
		action: 'schedule',
		action_type: 'create',
		at: '2026-07-20T14:30:00Z',
		actor: { id: 'u1', nome: 'Ana Gestora' },
		professional: { id: 'p1', nome: 'Dra. Bea' },
		patient: null,
		// Quem estava no bloco — a API resolve a partir das presenças. Vazio por default: a
		// maioria dos recursos da trilha não é da agenda.
		participants: [],
		// O contexto do registro viaja em `meta` desde o doc 63 — `starts_at`/`appointment_id`
		// deixaram de ser campos de todo evento (a maioria dos doze recursos não tem horário).
		meta: { starts_at: '2026-07-20T11:00:00Z', status: 'agendado' },
		diff: [],
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

// ---------------------------------------------------------------------------
// A clínica ativa (`GET /api/clinic`)
//
// Duas telas de configuração leem do MESMO payload — identidade, contato, endereço e os `msg_*`
// viajam juntos —, então cada campo novo na clínica quebrava os dois arquivos de teste ao mesmo
// tempo. Foi o que aconteceu ao levar telefone, endereço estruturado e `msg_whatsapp_ativo` para
// lá. Mesma razão do `meFixture` logo acima.
export function clinicFixture(over: Partial<Clinic> = {}): Clinic {
	return {
		id: 'c1',
		nome: 'Clínica Vida',
		cnpj: null,
		telefone: null,
		cep: null,
		endereco: null,
		numero: null,
		complemento: null,
		bairro: null,
		cidade: null,
		uf: null,
		msg_whatsapp_ativo: false,
		msg_silencio_inicio: 21,
		msg_silencio_fim: 8,
		...over
	};
}
