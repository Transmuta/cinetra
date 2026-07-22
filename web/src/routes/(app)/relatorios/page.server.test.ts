import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchReports: vi.fn() }));
vi.mock('$lib/server/reports', () => m);

// `todayInZone` fixado num dia conhecido para a janela ser determinística no teste.
vi.mock('$lib/agenda', () => ({ todayInZone: () => '2026-06-17' }));

import { load } from './+page.server';

type LoadOk = {
	report: { totals: { atendimentos: number } };
	period: string;
	prof: string;
	professionals: unknown[];
};

function ev(search = ''): never {
	return {
		url: new URL(`http://x/relatorios${search}`),
		parent: async () => ({ me: { timezone: 'America/Sao_Paulo' } })
	} as never;
}

const okData = {
	status: 200,
	data: {
		range: { from: '2026-06-01', to: '2026-06-30' },
		totals: { atendimentos: 3 },
		por_dia: [],
		por_tipo: [],
		por_profissional: [],
		professionals: [{ id: 'p1', nome: 'Dra. Bea', cor_indice: 1 }],
		appointment_types: [],
		agora: '2026-06-17T12:00:00Z',
		timezone: 'America/Sao_Paulo'
	}
};

beforeEach(() => m.fetchReports.mockReset());

describe('load', () => {
	it('default: período "mes", prof "todos", janela do mês, sem professional_id', async () => {
		m.fetchReports.mockResolvedValueOnce(okData);

		const r = (await load(ev())) as LoadOk;

		expect(r.period).toBe('mes');
		expect(r.prof).toBe('todos');
		expect(r.report.totals.atendimentos).toBe(3);
		expect(r.professionals).toHaveLength(1);

		const [, params] = m.fetchReports.mock.calls[0];
		expect(params).toMatchObject({ date_from: '2026-06-01', date_to: '2026-06-30' });
		expect(params.professional_id).toBeUndefined();
	});

	it('?period=hoje traduz para a janela de um dia', async () => {
		m.fetchReports.mockResolvedValueOnce(okData);

		await load(ev('?period=hoje'));

		const [, params] = m.fetchReports.mock.calls[0];
		expect(params).toMatchObject({ date_from: '2026-06-17', date_to: '2026-06-17' });
	});

	it('?prof=<uuid> é repassado como professional_id; "todos" não filtra', async () => {
		m.fetchReports.mockResolvedValue(okData);

		await load(ev('?prof=p1'));
		expect(m.fetchReports.mock.calls[0][1]).toMatchObject({ professional_id: 'p1' });

		await load(ev('?prof=todos'));
		expect(m.fetchReports.mock.calls[1][1].professional_id).toBeUndefined();
	});

	it('período inválido cai em "mes"', async () => {
		m.fetchReports.mockResolvedValueOnce(okData);
		const r = (await load(ev('?period=ontem'))) as LoadOk;
		expect(r.period).toBe('mes');
	});

	it('API fora (sem dados) vira página de erro', async () => {
		m.fetchReports.mockResolvedValueOnce({ status: 0, data: null });
		await expect(load(ev())).rejects.toBeTruthy();
	});
});
