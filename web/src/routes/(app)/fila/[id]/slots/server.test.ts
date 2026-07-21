import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchSlots: vi.fn() }));
vi.mock('$lib/server/waitlist', () => m);

import { GET } from './+server';

function ev(id: string) {
	return { params: { id } } as never;
}

const body = async (r: Response) => (await r.json()) as { slots: unknown[] };

beforeEach(() => m.fetchSlots.mockReset());

describe('GET /fila/[id]/slots — proxy do motor find_slots', () => {
	it('repassa o id do parâmetro e devolve as vagas', async () => {
		m.fetchSlots.mockResolvedValueOnce({ status: 200, data: { slots: [{ date: '2026-07-21', start: 540 }] } });
		const out = await body(await GET(ev('e1')));
		expect(m.fetchSlots.mock.calls[0][1]).toBe('e1');
		expect(out.slots).toHaveLength(1);
	});

	// A falha degrada para `slots: []` — o modal mostra o vazio ("nenhuma vaga"), não estoura.
	it('sem dados (404/erro/rede) devolve lista vazia', async () => {
		m.fetchSlots.mockResolvedValueOnce({ status: 404, data: null });
		expect(await body(await GET(ev('e1')))).toEqual({ slots: [] });
	});
});
