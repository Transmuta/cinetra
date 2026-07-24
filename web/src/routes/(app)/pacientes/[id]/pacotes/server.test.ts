import { describe, it, expect, vi, beforeEach } from 'vitest';

const pkg = vi.hoisted(() => ({ createSeries: vi.fn() }));
vi.mock('$lib/server/packages', () => pkg);

import { POST } from './+server';

function ev(id: string, body: unknown) {
	return {
		params: { id },
		request: { json: async () => body }
	} as never;
}

beforeEach(() => pkg.createSeries.mockReset());

describe('POST /pacientes/[id]/pacotes', () => {
	it('201 → { ok, package }, com o patient_id do path', async () => {
		pkg.createSeries.mockResolvedValueOnce({
			ok: true,
			status: 201,
			package: { id: 'k1' }
		});

		const res = await POST(ev('pac1', { patient_id: 'FORJADO', total: 4 }));

		expect(pkg.createSeries.mock.calls[0][1].patient_id).toBe('pac1');
		expect(res.status).toBe(201);
		expect(await res.json()).toEqual({ ok: true, package: { id: 'k1' } });
	});

	it('422 series_blocked repassa a prévia para reapresentar', async () => {
		const blocked = {
			reason: 'precisa_confirmar',
			preview: { bloqueios: 1, pode_salvar: false }
		};
		pkg.createSeries.mockResolvedValueOnce({ ok: false, status: 422, blocked });

		const res = await POST(ev('pac1', {}));
		expect(res.status).toBe(422);
		expect(await res.json()).toEqual({ ok: false, blocked });
	});

	it('erro genérico repassa a mensagem e o status', async () => {
		pkg.createSeries.mockResolvedValueOnce({
			ok: false,
			status: 500,
			error: 'Deu ruim.'
		});

		const res = await POST(ev('pac1', {}));
		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({ ok: false, error: 'Deu ruim.' });
	});
});
