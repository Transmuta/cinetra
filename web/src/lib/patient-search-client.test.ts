import { describe, it, expect, vi, afterEach } from 'vitest';
import { buscarPacientes } from './patient-search-client';

afterEach(() => vi.restoreAllMocks());

function respondeCom(body: unknown, status = 200) {
	return vi
		.spyOn(globalThis, 'fetch')
		.mockResolvedValue(new Response(JSON.stringify(body), { status }));
}

describe('buscarPacientes', () => {
	it('monta a URL a partir da base da tela e escapa o termo', async () => {
		const f = respondeCom({ patients: [], total: 0 });

		await buscarPacientes('/agenda/pacientes', 'ana & maria');

		expect(f.mock.calls[0][0]).toBe('/agenda/pacientes?q=ana%20%26%20maria');
	});

	it('devolve o corpo quando o servidor responde', async () => {
		respondeCom({ patients: [{ id: 'p1', nome: 'Ana' }], total: 42 });

		expect(await buscarPacientes('/fila/pacientes', 'ana')).toEqual({
			patients: [{ id: 'p1', nome: 'Ana' }],
			total: 42
		});
	});

	/**
	 * As duas degradações são contrato: o picker que não acha nada mostra o vazio, e é isso que se
	 * quer quando a rede cai no meio de uma digitação. Estourar derrubaria o modal inteiro por
	 * causa de uma tecla.
	 */
	it('resposta de erro vira lista vazia, não exceção', async () => {
		respondeCom({ error: 'nope' }, 500);

		expect(await buscarPacientes('/agenda/pacientes', 'ana')).toEqual({ patients: [], total: 0 });
	});

	it('rede fora vira lista vazia, não exceção', async () => {
		vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));

		expect(await buscarPacientes('/agenda/pacientes', 'ana')).toEqual({ patients: [], total: 0 });
	});
});
