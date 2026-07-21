import { describe, it, expect } from 'vitest';
import { applyAppointment, applyToDay, mergePatients } from './agenda-live';
import type { Appointment, AgendaPatient } from './agenda';

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		package_id: null,
		version: 1,
		created_by_id: null,
		cancel_reason: null,
		falta_justificada: false,
		patient_ids: ['pac1'],
		...over
	};
}

describe('applyAppointment', () => {
	it('acrescenta o bloco que ainda não está na lista', () => {
		const lista = applyAppointment([], appt());
		expect(lista.map((a) => a.id)).toEqual(['a1']);
	});

	it('substitui o bloco existente pela versão nova', () => {
		const lista = applyAppointment([appt()], appt({ version: 2, status: 'confirmado' }));

		expect(lista).toHaveLength(1);
		expect(lista[0].status).toBe('confirmado');
	});

	it('IGNORA evento com versão mais velha — chegada fora de ordem não desfaz o estado', () => {
		// Dois eventos do mesmo bloco podem cruzar no caminho (rede, reconexão, dois broadcasts).
		// Sem esta guarda, o mais lento sobrescreveria o mais novo e a tela voltaria no tempo.
		const lista = applyAppointment([appt({ version: 5, status: 'confirmado' })], appt({ version: 3 }));

		expect(lista[0].version).toBe(5);
		expect(lista[0].status).toBe('confirmado');
	});

	it('aceita a MESMA versão — o merge de turma reemite sem subir version', () => {
		const lista = applyAppointment(
			[appt({ version: 1, patient_ids: ['pac1'] })],
			appt({ version: 1, patient_ids: ['pac1', 'pac2'] })
		);

		expect(lista[0].patient_ids).toEqual(['pac1', 'pac2']);
	});

	it('mantém a lista ordenada por horário', () => {
		const cedo = appt({ id: 'cedo', starts_at: '2026-07-20T10:00:00Z' });
		const tarde = appt({ id: 'tarde', starts_at: '2026-07-20T15:00:00Z' });

		const lista = applyAppointment([tarde], cedo);
		expect(lista.map((a) => a.id)).toEqual(['cedo', 'tarde']);
	});

	it('não muta a lista original', () => {
		const original = [appt()];
		applyAppointment(original, appt({ id: 'a2' }));
		expect(original).toHaveLength(1);
	});
});

describe('mergePatients', () => {
	const p = (id: string, nome: string): AgendaPatient => ({ id, nome, tel: null, ativo: true });

	it('acrescenta quem ainda não está no sidecar', () => {
		// É o ponto do sidecar no payload do canal: sem ele o bloco novo cairia no nome
		// genérico "Paciente", porque a janela carregada não conhece esse id.
		const lista = mergePatients([p('pac1', 'Ana')], [p('pac2', 'Bruno')]);
		expect(lista.map((x) => x.nome)).toEqual(['Ana', 'Bruno']);
	});

	it('não duplica quem já está, e atualiza o nome', () => {
		const lista = mergePatients([p('pac1', 'Ana')], [p('pac1', 'Ana Maria')]);
		expect(lista).toHaveLength(1);
		expect(lista[0].nome).toBe('Ana Maria');
	});

	it('tolera sidecar vazio dos dois lados', () => {
		expect(mergePatients([], [])).toEqual([]);
	});
});

describe('applyToDay (remarcação entre dias, Entrega 4)', () => {
	const TZ = 'America/Sao_Paulo';

	it('aplica normalmente o bloco que continua no dia', () => {
		// 14:00Z = 11:00 em São Paulo, dia 2026-07-20.
		const lista = applyToDay([], appt({ starts_at: '2026-07-20T14:00:00Z' }), '2026-07-20', TZ);
		expect(lista.map((a) => a.id)).toEqual(['a1']);
	});

	it('REMOVE o bloco que foi remarcado para outro dia (fecha o bloco fantasma)', () => {
		const atual = [appt({ id: 'a1', starts_at: '2026-07-20T14:00:00Z' })];
		// O tópico do dia de origem recebe o mesmo bloco, agora no dia seguinte.
		const lista = applyToDay(atual, appt({ id: 'a1', starts_at: '2026-07-21T14:00:00Z', version: 2 }), '2026-07-20', TZ);
		expect(lista).toEqual([]);
	});

	it('ignorar um bloco de outro dia não o adiciona', () => {
		const lista = applyToDay([], appt({ id: 'a9', starts_at: '2026-07-25T14:00:00Z' }), '2026-07-20', TZ);
		expect(lista).toEqual([]);
	});
});
