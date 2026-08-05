import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => m);

import { load } from './+page.server';

beforeEach(() => m.fetchProfessionals.mockReset());

describe('load', () => {
	it('200 → profissionais + expediente da clínica', async () => {
		m.fetchProfessionals.mockResolvedValueOnce({
			status: 200,
			data: { professionals: [{ id: 'p1' }], clinic_hours: [{ dow: 1, modo: null, periods: [] }] }
		});
		const r = (await load({} as never)) as { professionals: unknown[]; clinicHours: unknown[] };
		expect(r.professionals).toHaveLength(1);
		expect(r.clinicHours).toHaveLength(1);
	});

	it('sem data → error de gateway', async () => {
		m.fetchProfessionals.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});

	// 403 é o papel `profissional` desde 2026-08-04 (doc 103): a tela não é dele. Tem mensagem
	// PRÓPRIA — "não foi possível carregar" leria como falha de rede e mandaria tentar de novo
	// uma tela que, para ele, não existe.
	it('403 → mensagem de perfil, não de falha de carregamento', async () => {
		m.fetchProfessionals.mockResolvedValueOnce({ status: 403, data: null });
		await expect(load({} as never)).rejects.toMatchObject({
			status: 403,
			body: { message: 'Esta tela não está disponível para o seu perfil.' }
		});
	});
});
