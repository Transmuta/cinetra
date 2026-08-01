import { describe, it, expect, vi, beforeEach } from 'vitest';

const s = vi.hoisted(() => ({ fetchMessages: vi.fn() }));
vi.mock('$lib/server/messages', () => s);

import { GET } from './+server';

// O endpoint que o drawer chama ao abrir (doc 52 §6). O comportamento que importa é o de
// **degradar**: a agenda não pode perder o drawer porque a comunicação está fora do ar.

beforeEach(() => s.fetchMessages.mockReset());

const event = (id: string) => ({ params: { id } }) as never;

describe('GET /agenda/mensagens/[id]', () => {
	it('devolve a timeline', async () => {
		const data = { participantes: [{ attendance_id: 'a1' }] };
		s.fetchMessages.mockResolvedValueOnce({ status: 200, data });

		const res = await GET(event('ap1'));

		expect(res.status).toBe(200);
		expect(await res.json()).toEqual(data);
		expect(s.fetchMessages.mock.calls[0][1]).toBe('ap1');
	});

	it('sem dado, devolve a forma VAZIA em vez de estourar', async () => {
		// O drawer precisa abrir de qualquer jeito — o bloco é o assunto da tela, isto é o rodapé.
		s.fetchMessages.mockResolvedValueOnce({ status: 502, data: null });

		const res = await GET(event('ap1'));

		expect(res.status).toBe(502);
		expect(await res.json()).toEqual({ participantes: [] });
	});
});
