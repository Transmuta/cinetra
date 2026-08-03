import { describe, it, expect, vi, beforeEach } from 'vitest';

const pkg = vi.hoisted(() => ({ createSeries: vi.fn() }));
vi.mock('$lib/server/packages', () => pkg);

import { POST } from './+server';

// `tipo` é o `content-type` do request — o que decide se um site de terceiro precisa de preflight,
// e portanto se ele consegue disparar a chamada. Default JSON: é o que o modal manda.
function ev(id: string, body: unknown, tipo: string | null = 'application/json') {
	return {
		params: { id },
		request: {
			headers: { get: (k: string) => (k.toLowerCase() === 'content-type' ? tipo : null) },
			json: async () => body
		}
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

// A guarda cross-site (doc 101, M11). `request.json()` ignora o content-type, então sem esta
// checagem um `POST` **sem** content-type nenhum — simple request, sem preflight — criava a série.
describe('a guarda cross-site', () => {
	it('415 sem content-type, e a série NÃO é criada', async () => {
		const res = await POST(ev('pac1', { total: 4 }, null));

		expect(res.status).toBe(415);
		expect(pkg.createSeries).not.toHaveBeenCalled();
	});

	it('415 com content-type de formulário — o que o browser deixa sair cross-site', async () => {
		const res = await POST(ev('pac1', { total: 4 }, 'application/x-www-form-urlencoded'));

		expect(res.status).toBe(415);
		expect(pkg.createSeries).not.toHaveBeenCalled();
	});
});
