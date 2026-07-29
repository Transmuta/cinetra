import { describe, it, expect, vi, beforeEach } from 'vitest';

const s = vi.hoisted(() => ({ fetchCandidates: vi.fn() }));
vi.mock('$lib/server/waitlist', () => s);

import { GET } from './+server';

// O "quem cabe aqui" (AN-12, doc 64): o drawer pergunta à fila quando a vaga abriu
// (cancelamento/falta). Como em `/agenda/mensagens/[id]`, o comportamento que importa é o de
// **degradar**: a seção fica vazia, o drawer nunca deixa de abrir por causa da fila.

beforeEach(() => s.fetchCandidates.mockReset());

const event = (search: string) =>
	({ url: new URL(`http://x/agenda/candidatos${search}`) }) as never;

const slotQs =
	'?professional_id=p1&starts_at=2026-07-21T12:00:00Z&ends_at=2026-07-21T12:50:00Z';

describe('GET /agenda/candidatos', () => {
	it('repassa o slot inteiro e devolve os candidatos', async () => {
		s.fetchCandidates.mockResolvedValueOnce({
			status: 200,
			data: { candidates: [{ id: 'e1' }] }
		});

		const res = await GET(event(slotQs));

		expect(await res.json()).toEqual({ candidates: [{ id: 'e1' }] });
		expect(s.fetchCandidates.mock.calls[0][1]).toEqual({
			professional_id: 'p1',
			starts_at: '2026-07-21T12:00:00Z',
			ends_at: '2026-07-21T12:50:00Z'
		});
	});

	it('slot incompleto → vazio, sem nem bater na API', async () => {
		const res = await GET(event('?professional_id=p1'));

		expect(await res.json()).toEqual({ candidates: [] });
		expect(s.fetchCandidates).not.toHaveBeenCalled();
	});

	it('sem dado, devolve a forma VAZIA em vez de estourar', async () => {
		s.fetchCandidates.mockResolvedValueOnce({ status: 502, data: null });

		const res = await GET(event(slotQs));

		expect(await res.json()).toEqual({ candidates: [] });
	});
});
