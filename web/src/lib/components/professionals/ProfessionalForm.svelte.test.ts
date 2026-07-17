import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import ProfessionalForm from './ProfessionalForm.svelte';
import type { HoursRow, Professional } from '$lib/professionals';

const clinicHours: HoursRow[] = [
	{ dow: 0, modo: null, periods: [] },
	{ dow: 1, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 2, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 3, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 4, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 5, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 6, modo: null, periods: [['08:00', '12:00']] }
];

function ficha(container: HTMLElement) {
	const el = container.querySelector('input[name="ficha"]') as HTMLInputElement;
	return JSON.parse(el.value);
}

function prof(overrides: Partial<Professional> = {}): Professional {
	return {
		id: 'p1', nome: 'Dr. Rafael', nome_exibicao: null, nascimento: null, cpf: null, rg: null,
		estado_civil: null, tel: null, email: null, cep: null, endereco: null, numero: null,
		complemento: null, bairro: null, cidade: null, uf: null, emergencia_nome: null,
		emergencia_tel: null, profissao: null, crefito: null, registro_uf: null, ano_conclusao: null,
		especialidades: [], sub: null, vinculo: null, razao_social: null, cnpj: null, banco: null,
		agencia: null, conta: null, conta_tipo: null, pix: null, cor_indice: 1,
		segue_horario_clinica: true, ativo: true, weekly_hours: [], exceptions: [],
		...overrides
	};
}

describe('ProfessionalForm — novo', () => {
	it('mostra as seções e o botão de cadastrar', () => {
		// os subtítulos são únicos do cartão (o título repete na nav de SEÇÕES).
		const { getByText, getByRole } = render(ProfessionalForm, { props: { clinicHours } });
		expect(getByText('Dados básicos para o contrato')).toBeInTheDocument();
		expect(getByText('Disponibilidade na agenda')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Cadastrar profissional' })).toBeInTheDocument();
	});

	it('salvar fica desabilitado sem nome e habilita ao preencher', async () => {
		const { getByRole, getByPlaceholderText } = render(ProfessionalForm, { props: { clinicHours } });
		const save = getByRole('button', { name: 'Cadastrar profissional' });
		expect(save).toBeDisabled();

		await fireEvent.input(getByPlaceholderText('Nome do profissional'), { target: { value: 'Marina' } });
		expect(save).toBeEnabled();
	});

	it('a ficha (hidden) reflete nome, segue-clínica e cor padrão', async () => {
		const { container, getByPlaceholderText } = render(ProfessionalForm, { props: { clinicHours } });
		await fireEvent.input(getByPlaceholderText('Nome do profissional'), { target: { value: 'Marina' } });

		const f = ficha(container);
		expect(f.nome).toBe('Marina');
		expect(f.segue_horario_clinica).toBe(true);
		expect(f.cor_indice).toBe(1);
	});

	it('desligar "seguir a clínica" revela a grade por dia', async () => {
		const { getByRole, queryByRole } = render(ProfessionalForm, { props: { clinicHours } });
		expect(queryByRole('switch', { name: 'Segunda' })).toBeNull();

		await fireEvent.click(getByRole('switch', { name: 'Seguir o horário da clínica' }));
		expect(getByRole('switch', { name: 'Segunda' })).toBeInTheDocument();
	});

	it('selecionar especialidade entra na ficha', async () => {
		const { container, getByRole } = render(ProfessionalForm, { props: { clinicHours } });
		await fireEvent.click(getByRole('button', { name: /Pilates/ }));
		expect(ficha(container).especialidades).toContain('Pilates');
	});

	it('mascara o CPF ao digitar', async () => {
		const { getByPlaceholderText } = render(ProfessionalForm, { props: { clinicHours } });
		const cpf = getByPlaceholderText('000.000.000-00') as HTMLInputElement;
		await fireEvent.input(cpf, { target: { value: '12345678901' } });
		expect(cpf.value).toBe('123.456.789-01');
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
			const { getByPlaceholderText } = render(ProfessionalForm, { props: { clinicHours } });
			await fireEvent.input(getByPlaceholderText('00000-000'), { target: { value: '01310100' } });

			await vi.waitFor(() =>
				expect((getByPlaceholderText('Preenchido pelo CEP') as HTMLInputElement).value).toBe('Avenida Paulista')
			);
			expect(fetchMock).toHaveBeenCalledWith('/api/cep/01310100');
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it('adicionar uma exceção de data a encena na lista', async () => {
		const { getByLabelText, getByText, container } = render(ProfessionalForm, { props: { clinicHours } });
		await fireEvent.input(getByLabelText('Data da exceção'), { target: { value: '2026-08-10' } });
		await fireEvent.click(getByText('Adicionar exceção'));

		expect(getByText('Ausência')).toBeInTheDocument();
		const exc = JSON.parse((container.querySelector('input[name="exceptions"]') as HTMLInputElement).value);
		expect(exc).toHaveLength(1);
		expect(exc[0].id).toBeNull(); // nova (sem id) → o save cria
	});
});

describe('ProfessionalForm — edição', () => {
	it('pré-preenche o nome e mostra "Salvar"', () => {
		const { getByDisplayValue, getByRole } = render(ProfessionalForm, {
			props: { professional: prof({ nome: 'Dr. Rafael' }), clinicHours }
		});
		expect(getByDisplayValue('Dr. Rafael')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Salvar' })).toBeInTheDocument();
	});
});
