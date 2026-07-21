import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchAllSlots: vi.fn() }));
vi.mock('$lib/server/waitlist', () => m);

import { GET } from './+server';

const ev = {} as never;
const body = async (r: Response) => (await r.json()) as { slots_by_entry: Record<string, unknown[]> };

beforeEach(() => m.fetchAllSlots.mockReset());

describe('GET /fila/slots — proxy do motor em lote', () => {
	it('devolve o mapa entry_id → vagas', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({
			status: 200,
			data: { slots_by_entry: { e1: [{ date: '2026-07-21', start: 540 }], e2: [] } }
		});
		const out = await body(await GET(ev));
		expect(Object.keys(out.slots_by_entry)).toEqual(['e1', 'e2']);
		expect(out.slots_by_entry.e1).toHaveLength(1);
	});

	// A falha degrada para `{}` — a linha só não mostra a vaga, não estoura.
	it('sem dados (erro/rede) devolve mapa vazio', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({ status: 502, data: null });
		expect(await body(await GET(ev))).toEqual({ slots_by_entry: {} });
	});
});
