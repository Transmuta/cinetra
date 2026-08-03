import { describe, it, expect, vi, beforeEach } from 'vitest';

const pkg = vi.hoisted(() => ({ previewSeries: vi.fn() }));
vi.mock('$lib/server/packages', () => pkg);

import { POST } from './+server';

// `tipo` é o `content-type` do request — ver a nota gêmea no teste do `index`. Default JSON.
function ev(id: string, body: unknown, tipo: string | null = 'application/json') {
	return {
		params: { id },
		request: {
			headers: { get: (k: string) => (k.toLowerCase() === 'content-type' ? tipo : null) },
			json: async () => body
		}
	} as never;
}

beforeEach(() => pkg.previewSeries.mockReset());

describe('POST /pacientes/[id]/pacotes/preview', () => {
	it('injeta o patient_id do path (não confia no corpo) e devolve a prévia', async () => {
		const preview = { ocorrencias: [], bloqueios: 0, pode_salvar: true };
		pkg.previewSeries.mockResolvedValueOnce({ status: 200, preview });

		const res = await POST(ev('pac1', { patient_id: 'FORJADO', total: 4 }));

		expect(pkg.previewSeries.mock.calls[0][1].patient_id).toBe('pac1');
		expect(pkg.previewSeries.mock.calls[0][1].total).toBe(4);
		expect(await res.json()).toEqual({ preview });
	});

	it('prévia null (falha de forma) sai como preview null', async () => {
		pkg.previewSeries.mockResolvedValueOnce({ status: 400, preview: null });
		const res = await POST(ev('pac1', {}));
		expect(res.status).toBe(400);
		expect(await res.json()).toEqual({ preview: null });
	});

	it('corpo não-JSON não estoura', async () => {
		pkg.previewSeries.mockResolvedValueOnce({ status: 200, preview: null });
		const res = await POST({
			params: { id: 'pac1' },
			request: {
				headers: { get: () => 'application/json' },
				json: async () => {
					throw new SyntaxError('não é JSON');
				}
			}
		} as never);
		expect(pkg.previewSeries.mock.calls[0][1].patient_id).toBe('pac1');
		expect(res.status).toBe(200);
	});
});

// A mesma guarda do `index` (doc 101, M11). A prévia não escreve, mas lê a agenda de um paciente
// pelo path — e a regra do projeto é uma só para todo `+server.ts` que aceita `POST`.
describe('a guarda cross-site', () => {
	it('415 sem content-type, e a prévia NÃO é lida', async () => {
		const res = await POST(ev('pac1', { total: 4 }, null));

		expect(res.status).toBe(415);
		expect(pkg.previewSeries).not.toHaveBeenCalled();
	});
});
