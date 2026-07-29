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

	// AN-10 (HOM-013, resto): o cadastro feito SEM documento — mesmo nome e mesma data de
	// nascimento avisam, pelo mesmo aviso do CPF/telefone. Continua só avisando, nunca barrando.
	it('avisa duplicado por nome + data de nascimento', async () => {
		const fetchMock = vi.fn(
			async () =>
				new Response(
					JSON.stringify({
						matches: [{ id: 'outro', nome: 'Mariana Alves', cpf: null, tel: null }]
					}),
					{ status: 200, headers: { 'content-type': 'application/json' } }
				)
		);
		vi.stubGlobal('fetch', fetchMock);
		try {
			const { getByPlaceholderText, getByLabelText, getByText } = render(PatientForm, {
				props: { professionals }
			});
			await fireEvent.input(getByPlaceholderText('Nome do paciente'), {
				target: { value: 'Mariana Alves' }
			});
			await fireEvent.input(getByLabelText(/Data de nascimento/), {
				target: { value: '1990-05-20' }
			});

			await vi.waitFor(() => expect(getByText(/Possível duplicado/)).toBeInTheDocument());
			expect(getByText(/nome e data de nascimento/)).toBeInTheDocument();
			expect(fetchMock).toHaveBeenCalledWith(
				'/api/patients/lookup?nome=Mariana+Alves&nascimento=1990-05-20'
			);
		} finally {
			vi.unstubAllGlobals();
		}
	});

	// AN-11 (D10: **barra no salvar** — diverge do "duplicado só avisa" por decisão explícita).
	// A régua é a do servidor (`CampoValido`); aqui ela chega antes da viagem.
	describe('identificação inválida barra o salvar (AN-11)', () => {
		// Tipo estrutural: o `RenderResult` genérico do testing-library não sobrevive ao
		// svelte-check quando viaja por parâmetro — só as queries usadas interessam aqui.
		interface Q {
			getByPlaceholderText(text: string): HTMLElement;
			getByLabelText(text: RegExp | string): HTMLElement;
			getByRole(role: string, opts?: { name?: string | RegExp }): HTMLElement;
			getByText(text: RegExp | string): HTMLElement;
		}

		async function preencherMinimo(r: Q) {
			await fireEvent.input(r.getByPlaceholderText('Nome do paciente'), {
				target: { value: 'Mariana' }
			});
			await fireEvent.input(r.getByLabelText(/Telefone \/ WhatsApp/), {
				target: { value: '11987654321' }
			});
		}

		it('CPF com DV errado desabilita e o rodapé diz o porquê', async () => {
			const r = render(PatientForm, { props: { professionals } });
			await preencherMinimo(r);
			const save = r.getByRole('button', { name: 'Cadastrar paciente' });

			await fireEvent.input(r.getByPlaceholderText('000.000.000-00'), {
				target: { value: '12345678900' }
			});
			expect(save).toBeDisabled();
			expect(r.getByText(/CPF inválido/)).toBeInTheDocument();

			await fireEvent.input(r.getByPlaceholderText('000.000.000-00'), {
				target: { value: '39053344705' }
			});
			expect(save).toBeEnabled();
		});

		it('e-mail sem forma de e-mail desabilita', async () => {
			const r = render(PatientForm, { props: { professionals } });
			await preencherMinimo(r);

			await fireEvent.input(r.getByPlaceholderText('email@exemplo.com'), {
				target: { value: 'mari.example.com' }
			});
			expect(r.getByRole('button', { name: 'Cadastrar paciente' })).toBeDisabled();
			expect(r.getByText(/E-mail inválido/)).toBeInTheDocument();
		});

		it('nascimento no futuro desabilita', async () => {
			const r = render(PatientForm, { props: { professionals } });
			await preencherMinimo(r);

			await fireEvent.input(r.getByLabelText(/Data de nascimento/), {
				target: { value: '2099-01-01' }
			});
			expect(r.getByRole('button', { name: 'Cadastrar paciente' })).toBeDisabled();
		});

		it('os três vazios seguem opcionais — só nome e telefone habilitam', async () => {
			const r = render(PatientForm, { props: { professionals } });
			await preencherMinimo(r);
			expect(r.getByRole('button', { name: 'Cadastrar paciente' })).toBeEnabled();
		});
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

	// O banco guarda E.164 (`NormalizeTel`, doc 52 §9). Sem formatar ao semear, a edição reabria
	// com `+5511987654321` no campo — e um toque em qualquer tecla passava aquilo pelo `maskTel`,
	// que conta 13 dígitos, corta os 2 últimos e devolve `(55) 11987-6543`: o DDI virava DDD.
	it('reabre o telefone mascarado, sem o DDI', () => {
		const { getAllByPlaceholderText } = render(PatientForm, {
			props: { patient: patient({ tel: '+5511987654321', emergencia_tel: '+551133334444' }), professionals }
		});
		// Os dois campos de telefone da ficha, na ordem: contato principal e emergência.
		const tels = getAllByPlaceholderText('(11) 90000-0000') as HTMLInputElement[];
		expect(tels[0].value).toBe('(11) 98765-4321');
		expect(tels[1].value).toBe('(11) 3333-4444');
	});

	it('paciente com convênio já abre a seção expandida', () => {
		const { getByText } = render(PatientForm, {
			props: { patient: patient({ convenio: 'Unimed' }), professionals }
		});
		expect(getByText('Nome do convênio')).toBeInTheDocument();
	});
});
