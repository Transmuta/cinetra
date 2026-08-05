import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/confirmar/tok-abc') }
}));

import Confirmar from './+page.svelte';

/**
 * A tela que o **paciente** abre pelo link da mensagem.
 *
 * Os testes aqui são sobre a máquina de estados dela, que é onde estavam os buracos: uma sessão
 * cancelada continuava oferecendo "confirmar presença", quem pedia remarcação recebia uma caixa
 * verde de sucesso, e quem tocou no botão errado não tinha volta.
 */

const quando = {
	extenso: 'quarta-feira, 5 de agosto',
	hora: '08:30',
	proximidade: 'amanhã' as const,
	passou: false
};

const resumo = {
	clinica: 'Clínica Moving',
	clinica_telefone: '(61) 99946-6274',
	paciente: 'Ana',
	data: '05/08/2026',
	hora: '08:30',
	inicio: '2026-08-05T11:30:00Z',
	fim: '2026-08-05T12:20:00Z',
	timezone: 'America/Sao_Paulo',
	ativa: true,
	resposta: null as string | null,
	respondido_em: null as string | null
};

const tela = (over: Partial<typeof resumo> = {}, overQuando: Partial<typeof quando> = {}) =>
	render(Confirmar, {
		props: {
			data: { resumo: { ...resumo, ...over }, status: 200, quando: { ...quando, ...overQuando } },
			form: null
		} as never
	});

describe('/confirmar — a pergunta', () => {
	it('põe o QUANDO em destaque, por extenso e com o atalho de proximidade', () => {
		// "05/08/2026" é um número para decodificar; quem abre isto no ônibus procura "amanhã" e o
		// dia da semana.
		const { getByText } = tela();

		expect(getByText('amanhã')).toBeInTheDocument();
		expect(getByText('08:30')).toBeInTheDocument();
		expect(getByText('quarta-feira, 5 de agosto')).toBeInTheDocument();
	});

	it('sem `quando` cai na data congelada da mensagem, que continua verdadeira', () => {
		const { getByText } = render(Confirmar, {
			props: { data: { resumo, status: 200, quando: null }, form: null } as never
		});

		expect(getByText('05/08/2026')).toBeInTheDocument();
	});

	it('oferece as duas respostas', () => {
		const { getByRole } = tela();

		expect(getByRole('button', { name: /Confirmar presença/ })).toBeInTheDocument();
		expect(getByRole('button', { name: /Preciso remarcar/ })).toBeInTheDocument();
	});
});

describe('/confirmar — o depois da resposta', () => {
	it('confirmou: caixa de desfecho e o evento para a agenda do celular', () => {
		const { getByText, getByRole } = tela({ resposta: 'confirmou' });

		expect(getByText(/Presença confirmada/)).toBeInTheDocument();
		expect(getByRole('link', { name: /Adicionar à agenda/ })).toHaveAttribute(
			'href',
			'/confirmar/tok-abc/sessao.ics'
		);
	});

	it('quer remarcar: tom de espera (não de sucesso) e o telefone na mão', () => {
		// Verde aqui dizia "resolvido" para quem ainda não tem horário nenhum.
		const { container, getByRole } = tela({ resposta: 'quer_remarcar' });

		expect(container.querySelector('.cn-paciente-aviso-espera')).not.toBeNull();
		expect(container.querySelector('.cn-paciente-aviso-sim')).toBeNull();
		expect(getByRole('link', { name: /Ligar para a clínica/ })).toHaveAttribute(
			'href',
			'tel:+5561999466274'
		);
	});

	it('o resultado é anunciado a leitor de tela', () => {
		// Os botões somem no mesmo instante; sem a região viva, quem navega por teclado fica sem
		// foco e sem notícia do que aconteceu.
		const { container } = tela({ resposta: 'confirmou' });

		expect(container.querySelector('[aria-live="polite"]')).not.toBeNull();
	});

	it('os botões somem depois de responder — e voltam quando se pede', async () => {
		const { getByRole, queryByRole } = tela({ resposta: 'confirmou' });

		expect(queryByRole('button', { name: /Preciso remarcar/ })).toBeNull();

		await getByRole('button', { name: /Mudar minha resposta/ }).click();

		expect(getByRole('button', { name: /Preciso remarcar/ })).toBeInTheDocument();
	});
});

describe('/confirmar — quando não há o que confirmar', () => {
	it('sessão cancelada não oferece confirmação, e diz o que houve', () => {
		// O link vale 30 dias; a sessão, não. Antes disto a tela anunciava como marcada uma sessão
		// que a clínica já tinha cancelado.
		const { getByText, queryByRole, getByRole } = tela({ ativa: false });

		expect(getByText('Esta sessão foi cancelada')).toBeInTheDocument();
		expect(queryByRole('button', { name: /Confirmar presença/ })).toBeNull();
		expect(getByRole('link', { name: /Ligar para a clínica/ })).toBeInTheDocument();
	});

	it('sessão que já passou também não se confirma', () => {
		const { getByText, queryByRole } = tela({}, { passou: true });

		expect(getByText('Essa sessão já passou')).toBeInTheDocument();
		expect(queryByRole('button', { name: /Confirmar presença/ })).toBeNull();
	});

	it('link inválido fala com um paciente, não com um usuário do sistema', () => {
		const { getByText, queryByText } = render(Confirmar, {
			props: { data: { resumo: null, status: 404, quando: null }, form: null } as never
		});

		expect(getByText('Não encontramos esta sessão')).toBeInTheDocument();
		expect(queryByText(/painel/i)).toBeNull();
	});

	it('link vencido diz por quanto tempo ele valia', () => {
		const { getByText } = render(Confirmar, {
			props: { data: { resumo: null, status: 410, quando: null }, form: null } as never
		});

		expect(getByText('Este link expirou')).toBeInTheDocument();
		expect(getByText(/valem por 30 dias/)).toBeInTheDocument();
	});
});
