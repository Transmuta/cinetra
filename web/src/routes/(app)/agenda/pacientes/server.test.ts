import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchPatients: vi.fn() }));
vi.mock('$lib/server/patients', () => m);

import { GET } from './+server';

function ev(search: string) {
	return { url: new URL(`http://x/agenda/pacientes${search}`) } as never;
}

const body = async (r: Response) => (await r.json()) as { patients: unknown[]; total: number };

const paciente = (over = {}) => ({
	id: 'pat1',
	nome: 'Maria Silva',
	tel: '11999990000',
	cpf: '12345678900',
	cor_indice: 3,
	ativo: true,
	...over
});

beforeEach(() => m.fetchPatients.mockReset());

describe('GET /agenda/pacientes — busca do PatientPicker', () => {
	// A regra de 2 caracteres é do protótipo (:1946). Vale também aqui, no servidor: sem
	// isso, um "a" solto varreria o cadastro inteiro a cada tecla.
	it('menos de 2 caracteres não chega à API', async () => {
		const r = await GET(ev('?q=a'));
		expect(await body(r)).toEqual({ patients: [], total: 0 });
		expect(m.fetchPatients).not.toHaveBeenCalled();
	});

	it('busca vazia também não chega à API', async () => {
		await GET(ev(''));
		expect(m.fetchPatients).not.toHaveBeenCalled();
	});

	it('2+ caracteres busca ativos, no máximo 10 (protótipo :1949)', async () => {
		m.fetchPatients.mockResolvedValueOnce({
			status: 200,
			data: { patients: [paciente()], page: { total: 1 }, counts: {} }
		});

		await GET(ev('?q=ma'));
		expect(m.fetchPatients.mock.calls[0][1]).toMatchObject({
			q: 'ma',
			filter: 'ativos',
			limit: 10
		});
	});

	it('devolve só o que o picker desenha — não a ficha inteira', async () => {
		m.fetchPatients.mockResolvedValueOnce({
			status: 200,
			data: { patients: [paciente()], page: { total: 1 }, counts: {} }
		});

		const out = await body(await GET(ev('?q=maria')));
		expect(out.patients[0]).toEqual({
			id: 'pat1',
			nome: 'Maria Silva',
			tel: '11999990000',
			cor_indice: 3
		});
		// CPF é dado sensível e o picker não o exibe: não sai do servidor.
		expect(out.patients[0]).not.toHaveProperty('cpf');
	});

	it('total permite o aviso "Mostrando 10 de N"', async () => {
		m.fetchPatients.mockResolvedValueOnce({
			status: 200,
			data: { patients: [paciente()], page: { total: 42 }, counts: {} }
		});
		expect((await body(await GET(ev('?q=maria')))).total).toBe(42);
	});

	it('erro da API vira lista vazia — o picker não quebra o modal', async () => {
		m.fetchPatients.mockResolvedValueOnce({ status: 500, data: null });
		expect(await body(await GET(ev('?q=maria')))).toEqual({ patients: [], total: 0 });
	});
});
