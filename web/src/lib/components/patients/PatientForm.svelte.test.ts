import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import PatientForm from './PatientForm.svelte';
import type { Patient } from '$lib/patients';
import type { Professional } from '$lib/professionals';

// A ficha só usa id/nome/cor_indice/ativo do profissional (chips) — subset com cast.
const professionals = [
	{ id: 'p1', nome: 'Dra. Ana', cor_indice: 2, ativo: true },
	{ id: 'p2', nome: 'Dr. Rui', cor_indice: 3, ativo: false }
] as unknown as Professional[];

function ficha(container: HTMLElement) {
	const el = container.querySelector('input[name="ficha"]') as HTMLInputElement;
	return JSON.parse(el.value);
}

function patient(overrides: Partial<Patient> = {}): Patient {
	return {
		id: 'pac1', nome: 'Mariana Alves', nome_social: null, cpf: null, rg: null, genero: null,
		estado_civil: null, nascimento: null, responsavel: null, tel: null, email: null, cep: null,
		endereco: null, numero: null, complemento: null, bairro: null, cidade: null, uf: null,
		emergencia_nome: null, emergencia_parentesco: null, emergencia_tel: null, profissao: null,
		empresa: null, atend_tipo: 'particular', convenio: null, carteirinha: null,
		convenio_validade: null, medico: null, crm: null, como_conheceu: null, prefs: [], tags: [],
		lgpd: false, comunicacao: false, cor_indice: 1, ativo: true,
		...overrides
	};
}

describe('PatientForm — novo', () => {
	it('mostra as seções e o botão de cadastrar', () => {
		const { getByText, getByRole } = render(PatientForm, { props: { professionals } });
		expect(getByText('Nome, contato principal e documento')).toBeInTheDocument();
		expect(getByText('Autorizações LGPD e contato')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Cadastrar paciente' })).toBeInTheDocument();
	});

	// D6 (doc 64): o mínimo passou a ser nome **e** telefone. O nome sozinho não habilita mais —
	// antes habilitava, e o 422 do servidor só aparecia depois de clicar.
	it('salvar só habilita com nome E telefone', async () => {
		const { getByRole, getByPlaceholderText, getByLabelText } = render(PatientForm, { props: { professionals } });
		const save = getByRole('button', { name: 'Cadastrar paciente' });
		expect(save).toBeDisabled();

		await fireEvent.input(getByPlaceholderText('Nome do paciente'), { target: { value: 'Mariana' } });
		expect(save).toBeDisabled();

		await fireEvent.input(getByLabelText(/Telefone \/ WhatsApp/), {
			target: { value: '11987654321' }
		});
		expect(save).toBeEnabled();
	});

	it('telefone incompleto não habilita', async () => {
		const { getByRole, getByPlaceholderText, getByLabelText } = render(PatientForm, { props: { professionals } });
		await fireEvent.input(getByPlaceholderText('Nome do paciente'), { target: { value: 'Mariana' } });
		await fireEvent.input(getByLabelText(/Telefone \/ WhatsApp/), { target: { value: '119876' } });

		expect(getByRole('button', { name: 'Cadastrar paciente' })).toBeDisabled();
	});

	it('a ficha (hidden) reflete nome e os defaults (particular, sem consentimento)', async () => {
		const { container, getByPlaceholderText } = render(PatientForm, { props: { professionals } });
		await fireEvent.input(getByPlaceholderText('Nome do paciente'), { target: { value: 'Mariana' } });

		const f = ficha(container);
		expect(f.nome).toBe('Mariana');
		expect(f.atend_tipo).toBe('particular');
		expect(f.lgpd).toBe(false);
		expect(f.cor_indice).toBe(1);
	});

	it('mascara o CPF ao digitar', async () => {
		const { getByPlaceholderText } = render(PatientForm, { props: { professionals } });
		const cpf = getByPlaceholderText('000.000.000-00') as HTMLInputElement;
		await fireEvent.input(cpf, { target: { value: '12345678901' } });
		expect(cpf.value).toBe('123.456.789-01');
	});

	it('avisa possível duplicado consultando o servidor quando o CPF fica completo', async () => {
		const fetchMock = vi.fn(
			async () =>
				new Response(
					JSON.stringify({
						matches: [{ id: 'outro', nome: 'João Souza', cpf: '111.111.111-11', tel: null }]
					}),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
		);
		vi.stubGlobal('fetch', fetchMock);
		try {
			const { getByPlaceholderText, getByText } = render(PatientForm, { props: { professionals } });
			await fireEvent.input(getByPlaceholderText('000.000.000-00'), { target: { value: '11111111111' } });

			await vi.waitFor(() => expect(getByText(/Possível duplicado/)).toBeInTheDocument());
			expect(getByText(/João Souza/)).toBeInTheDocument();
			expect(fetchMock).toHaveBeenCalledWith('/api/patients/lookup?q=11111111111');
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it('não consulta duplicado com CPF incompleto', async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal('fetch', fetchMock);
		try {
			const { getByPlaceholderText } = render(PatientForm, { props: { professionals } });
			await fireEvent.input(getByPlaceholderText('000.000.000-00'), { target: { value: '123' } });
			await new Promise((r) => setTimeout(r, 500));
			expect(fetchMock).not.toHaveBeenCalled();
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it('escolher um profissional preferido entra na ficha (só ativos aparecem)', async () => {
		const { container, getByRole, queryByRole } = render(PatientForm, { props: { professionals } });
		// Dr. Rui é inativo → não vira chip.
		expect(queryByRole('button', { name: /Rui/ })).toBeNull();
		await fireEvent.click(getByRole('button', { name: /Ana/ }));
		expect(ficha(container).prefs).toContain('p1');
	});

	it('adicionar uma tag pela sugestão entra na ficha', async () => {
		const { container, getByRole } = render(PatientForm, { props: { professionals } });
		await fireEvent.click(getByRole('button', { name: '+ lombalgia' }));
		expect(ficha(container).tags).toContain('lombalgia');
	});

	it('marcar "possui convênio" revela os campos do plano', async () => {
		const { getByRole, queryByText, getByText } = render(PatientForm, { props: { professionals } });
		expect(queryByText('Nome do convênio')).toBeNull();
		await fireEvent.click(getByRole('checkbox', { name: /possui convênio/ }));
		expect(getByText('Nome do convênio')).toBeInTheDocument();
	});

	it('marcar o consentimento LGPD entra na ficha', async () => {
		const { container, getByRole } = render(PatientForm, { props: { professionals } });
		await fireEvent.click(getByRole('checkbox', { name: /Autorizo o tratamento/ }));
		expect(ficha(container).lgpd).toBe(true);
	});

	it('autopreenche o endereço ao digitar um CEP válido (via BFF)', async () => {
		const fetchMock = vi.fn(
			async () =>
				new Response(
					JSON.stringify({ endereco: 'Avenida Paulista', bairro: 'Bela Vista', cidade: 'São Paulo', uf: 'SP' }),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
		);
		vi.stubGlobal('fetch', fetchMock);
		try {
			const { getByPlaceholderText } = render(PatientForm, { props: { professionals } });
			await fireEvent.input(getByPlaceholderText('00000-000'), { target: { value: '01310100' } });
			await vi.waitFor(() =>
				expect(
					(getByPlaceholderText('Preenchido automaticamente pelo CEP') as HTMLInputElement).value
				).toBe('Avenida Paulista')
			);
			expect(fetchMock).toHaveBeenCalledWith('/api/cep/01310100');
		} finally {
			vi.unstubAllGlobals();
		}
	});
});

describe('PatientForm — edição', () => {
	it('pré-preenche o nome e mostra "Salvar"', () => {
		const { getByDisplayValue, getByRole } = render(PatientForm, {
			props: { patient: patient({ nome: 'Mariana Alves' }), professionals }
		});
		expect(getByDisplayValue('Mariana Alves')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Salvar' })).toBeInTheDocument();
	});

	it('paciente com convênio já abre a seção expandida', () => {
		const { getByText } = render(PatientForm, {
			props: { patient: patient({ convenio: 'Unimed' }), professionals }
		});
		expect(getByText('Nome do convênio')).toBeInTheDocument();
	});
});
