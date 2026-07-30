import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchAllSlots: vi.fn() }));
vi.mock('$lib/server/waitlist', () => m);

import { GET } from './+server';

// O handler lê a janela da URL (F6) — o evento mínimo precisa dela.
const evento = (qs = '') => ({ url: new URL(`http://localhost/fila/slots${qs}`) }) as never;
const ev = evento();
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

	// F6: a tela pede vagas para a MESMA janela da fila. Sem isto o motor calcularia a fila
	// inteira para uma tela que desenha 50 linhas.
	it('repassa limit/offset da URL para a API', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({ status: 200, data: { slots_by_entry: {} } });
		await GET(evento('?limit=10&offset=20'));
		expect(m.fetchAllSlots.mock.calls[0][1]).toEqual({ limit: 10, offset: 20 });
	});

	// O bate-volta pegou isto ao vivo: com `?prio=` na tela, a fila mostrava um item e o motor
	// calculava as vagas de OUTRO — as duas chamadas precisam da mesma janela, e o filtro faz
	// parte dela. Sem o prio, a linha filtrada aparece sem chip de vaga.
	it('repassa o filtro de prioridade junto da janela', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({ status: 200, data: { slots_by_entry: {} } });
		await GET(evento('?limit=50&offset=0&prio=baixa'));
		expect(m.fetchAllSlots.mock.calls[0][1]).toEqual({ limit: 50, offset: 0, prio: 'baixa' });
	});

	it('sem janela na URL usa o tamanho de página padrão', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({ status: 200, data: { slots_by_entry: {} } });
		await GET(ev);
		expect(m.fetchAllSlots.mock.calls[0][1]).toEqual({ limit: 50, offset: 0 });
	});

	// A falha degrada para `{}` — a linha só não mostra a vaga, não estoura.
	it('sem dados (erro/rede) devolve mapa vazio', async () => {
		m.fetchAllSlots.mockResolvedValueOnce({ status: 502, data: null });
		expect(await body(await GET(ev))).toEqual({ slots_by_entry: {} });
	});
});
