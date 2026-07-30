import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchPatients: vi.fn() }));
vi.mock('$lib/server/patients', () => m);
const pf = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => pf);

import { load } from './+page.server';

// O load agora lê `?q=`, `?filter=` e `?page=` da URL e traduz em `offset` para a API.
function ev(search = '') {
	return { url: new URL(`http://localhost/pacientes${search}`) } as never;
}

const okPage = {
	status: 200,
	data: {
		patients: [{ id: 'pac1' }],
		page: { limit: 50, offset: 0, total: 1, more: false },
		counts: { todos: 1, ativos: 1, inativos: 0, resp: 0 }
	}
};

beforeEach(() => {
	m.fetchPatients.mockReset();
	pf.fetchProfessionals.mockReset();
	pf.fetchProfessionals.mockResolvedValue({ status: 200, data: { professionals: [], clinic_hours: [] } });
});

describe('load', () => {
	it('200 → página + contagens + diretório', async () => {
		m.fetchPatients.mockResolvedValueOnce(okPage);
		pf.fetchProfessionals.mockResolvedValueOnce({
			status: 200,
			data: { professionals: [{ id: 'p1' }], clinic_hours: [] }
		});

		const r = (await load(ev())) as {
			patients: unknown[];
			pageInfo: { total: number };
			counts: { todos: number };
			professionals: unknown[];
		};

		expect(r.patients).toHaveLength(1);
		expect(r.pageInfo.total).toBe(1);
		expect(r.counts.todos).toBe(1);
		expect(r.professionals).toHaveLength(1);
	});

	it('repassa busca e segmento para a API', async () => {
		m.fetchPatients.mockResolvedValueOnce(okPage);

		const r = (await load(ev('?q=mari&filter=inativos'))) as { q: string; filter: string };

		expect(m.fetchPatients).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ q: 'mari', filter: 'inativos', offset: 0 })
		);
		expect(r.q).toBe('mari');
		expect(r.filter).toBe('inativos');
	});

	it('?page=3 vira offset 100 (páginas de 50)', async () => {
		m.fetchPatients.mockResolvedValueOnce(okPage);

		const r = (await load(ev('?page=3'))) as { current: number };

		expect(m.fetchPatients).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ limit: 50, offset: 100 })
		);
		expect(r.current).toBe(3);
	});

	it('page inválida cai na 1 (offset 0) e filter desconhecido cai em todos', async () => {
		m.fetchPatients.mockResolvedValueOnce(okPage);

		const r = (await load(ev('?page=abc&filter=lixo'))) as { current: number; filter: string };

		expect(m.fetchPatients).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ offset: 0, filter: 'todos' })
		);
		expect(r.current).toBe(1);
		expect(r.filter).toBe('todos');
	});

	it('diretório indisponível → lista vazia (não quebra a página)', async () => {
		m.fetchPatients.mockResolvedValueOnce(okPage);
		pf.fetchProfessionals.mockResolvedValueOnce({ status: 502, data: null });

		const r = (await load(ev())) as { professionals: unknown[] };
		expect(r.professionals).toEqual([]);
	});

	it('pacientes indisponíveis → error de gateway', async () => {
		m.fetchPatients.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load(ev())).rejects.toMatchObject({ status: 502 });
	});
});
