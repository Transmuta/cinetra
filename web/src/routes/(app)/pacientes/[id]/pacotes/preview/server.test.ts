import { describe, it, expect, vi, beforeEach } from 'vitest';

const pkg = vi.hoisted(() => ({ previewSeries: vi.fn() }));
vi.mock('$lib/server/packages', () => pkg);

import { POST } from './+server';

function ev(id: string, body: unknown) {
	return {
		params: { id },
		request: { json: async () => body }
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
				json: async () => {
					throw new SyntaxError('não é JSON');
				}
			}
		} as never);
		expect(pkg.previewSeries.mock.calls[0][1].patient_id).toBe('pac1');
		expect(res.status).toBe(200);
	});
});
