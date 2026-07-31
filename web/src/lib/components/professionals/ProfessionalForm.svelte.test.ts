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

	// D6 (doc 64): o telefone entrou no mínimo do profissional também — a decisão foi "nos dois
	// cadastros", não só no paciente.
	it('salvar só habilita com nome E telefone', async () => {
		const { getByRole, getByPlaceholderText, getByLabelText } = render(ProfessionalForm, { props: { clinicHours } });
		const save = getByRole('button', { name: 'Cadastrar profissional' });
		expect(save).toBeDisabled();

		await fireEvent.input(getByPlaceholderText('Nome do profissional'), { target: { value: 'Marina' } });
		expect(save).toBeDisabled();

		await fireEvent.input(getByLabelText(/Celular \/ WhatsApp/), {
			target: { value: '11987654321' }
		});
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

	// Mesma correção da ficha do paciente: número em E.164 volta mascarado. Aqui o `+55` chega das
	// fichas gravadas por outro caminho (importação, ou o dia em que o profissional virar destino
	// de mensagem como o paciente já é) — e o `maskTel` transformaria o DDI em DDD na primeira tecla.
	it('reabre o telefone mascarado, sem o DDI', () => {
		const { getAllByPlaceholderText } = render(ProfessionalForm, {
			props: { professional: prof({ tel: '+5511987654321', emergencia_tel: '+551133334444' }), clinicHours }
		});
		const tels = getAllByPlaceholderText('(11) 90000-0000') as HTMLInputElement[];
		expect(tels[0].value).toBe('(11) 98765-4321');
		expect(tels[1].value).toBe('(11) 3333-4444');
	});
});

/**
 * O vão que o doc 94 §4.7 mediu: 754 linhas para **10 `it`**, contra 823 e 25 do gêmeo
 * `PatientForm`. E não era "este componente é mais simples" — rodando os títulos lado a lado, o
 * que faltava eram exatamente as classes que o outro cobre: validação de campo, estado de erro
 * do servidor e semântica de a11y.
 *
 * Metade dos testes de um provava o código do outro **por cópia, não por reúso**. Agora que o
 * CEP e a coluna de seções são módulos compartilhados e testados, o que sobra aqui é o que é
 * mesmo do profissional — e é isto.
 */
describe('ProfessionalForm — o que barra o salvar', () => {
	interface Q {
		getByPlaceholderText(text: string): HTMLElement;
		getByLabelText(text: RegExp | string): HTMLElement;
		getByRole(role: string, opts?: { name?: string | RegExp }): HTMLElement;
		getByText(text: RegExp | string): HTMLElement;
	}

	async function preencherMinimo(r: Q) {
		await fireEvent.input(r.getByPlaceholderText('Nome do profissional'), {
			target: { value: 'Rafael Couto' }
		});
		await fireEvent.input(r.getByLabelText(/Celular \/ WhatsApp/), { target: { value: '11987654321' } });
	}

	it('com nome e telefone, salva', async () => {
		const r = render(ProfessionalForm, { props: { clinicHours } });
		await preencherMinimo(r);

		expect(r.getByRole('button', { name: 'Cadastrar profissional' })).toBeEnabled();
	});

	/**
	 * O profissional que não atende em dia nenhum não é um cadastro incompleto — é um cadastro que
	 * não pode existir: ele nunca apareceria como coluna da agenda, e a recepção não teria como
	 * descobrir por quê.
	 */
	it('sem NENHUM dia de atendimento, desabilita e o rodapé diz o porquê', async () => {
		const r = render(ProfessionalForm, { props: { clinicHours } });
		await preencherMinimo(r);

		// Desligar "seguir a clínica" revela a grade; com todos os dias fechados, não há atendimento.
		await fireEvent.click(r.getByRole('switch', { name: /Seguir o horário da clínica/ }));

		for (const dia of Array.from(
			document.querySelectorAll<HTMLElement>('[role="switch"][aria-checked="true"]')
		)) {
			if (!/Seguir o horário/.test(dia.getAttribute('aria-label') ?? '')) await fireEvent.click(dia);
		}

		expect(r.getByRole('button', { name: 'Cadastrar profissional' })).toBeDisabled();
		// Pelo PAPEL, e não por texto solto: o rodapé precisa ANUNCIAR, não só mostrar.
		expect(r.getByRole('alert')).toHaveTextContent(/ao menos um dia de atendimento/i);
	});

	it('telefone pela metade desabilita e explica — não é o 422 depois da viagem', async () => {
		const r = render(ProfessionalForm, { props: { clinicHours } });
		await fireEvent.input(r.getByPlaceholderText('Nome do profissional'), {
			target: { value: 'Rafael Couto' }
		});
		await fireEvent.input(r.getByLabelText(/Celular \/ WhatsApp/), { target: { value: '1198765' } });

		expect(r.getByRole('button', { name: 'Cadastrar profissional' })).toBeDisabled();
		expect(r.getByRole('alert')).toHaveTextContent(/Telefone incompleto/i);
	});
});

describe('ProfessionalForm — o rodapé fala com quem não vê a tela', () => {
	/**
	 * ACC-04: o erro do servidor ficava numa faixa que sumia em larguras pequenas, e em nenhuma
	 * delas era live region — quem usa leitor de tela não recebia nada. O par do teste gêmeo.
	 */
	it('o erro do servidor é anunciado e aparece em QUALQUER largura', () => {
		const { getByRole } = render(ProfessionalForm, {
			props: { clinicHours, error: 'CREFITO já cadastrado para outro profissional.' }
		});

		const aviso = getByRole('alert');
		expect(aviso).toHaveTextContent('CREFITO já cadastrado para outro profissional.');
		expect(aviso.className).not.toContain('hidden');
		expect(aviso.className).not.toContain('md:flex');
	});

	it('a DICA neutra não é alert (senão o leitor de tela a anunciaria a cada toque)', () => {
		const { queryByRole, getByText } = render(ProfessionalForm, { props: { clinicHours } });

		expect(queryByRole('alert')).toBeNull();
		expect(getByText(/Nome e telefone são obrigatórios/)).toBeInTheDocument();
	});
});
