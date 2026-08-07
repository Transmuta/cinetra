import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

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
	// A clínica sem telefone existe (o campo é opcional até a D6 do doc 64), e é o caso em que a
	// tela não pode oferecer um botão de contato — daí o tipo carregar o `null`.
	clinica_telefone: '(61) 99946-6274' as string | null,
	paciente: 'Ana',
	data: '05/08/2026',
	hora: '08:30',
	// `null` é o caso real da sessão que a API não resolveu: sem instante não há calendário a
	// oferecer, nem `.ics` nem Google.
	inicio: '2026-08-05T11:30:00Z' as string | null,
	fim: '2026-08-05T12:20:00Z' as string | null,
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
		expect(getByRole('link', { name: /Google Agenda/ })).toHaveAttribute(
			'href',
			expect.stringContaining('calendar.google.com')
		);
	});

	it('NÃO oferece baixar `.ics` — download é inviável no celular, medido nos dois sistemas', () => {
		// A rota `sessao.ics` foi removida junto com o link (2026-08-06). Este teste é o que
		// impede o botão de voltar por engano: no Android o arquivo cai em Downloads sem nada
		// abrir, e no iPhone vira uma folha de download que não leva a lugar nenhum.
		const { container } = tela({ resposta: 'confirmou' });

		const hrefs = [...container.querySelectorAll('a')].map((a) => a.getAttribute('href') ?? '');

		expect(hrefs.some((h) => h.includes('.ics'))).toBe(false);
	});

	it('confirmou: oferece o Google Agenda, que é o que de fato abre no Android', () => {
		// O `.ics` sozinho não resolvia: no Android ele cai em Downloads e nada abre — o paciente
		// toca em "adicionar à agenda" e não vê acontecer nada.
		const { getByRole } = tela({ resposta: 'confirmou' });

		const link = getByRole('link', { name: /Google Agenda/ });

		expect(link).toHaveAttribute('href', expect.stringContaining('calendar.google.com'));
		expect(link).toHaveAttribute(
			'href',
			expect.stringContaining('dates=20260805T113000Z/20260805T122000Z')
		);
		// Abre fora da tela do paciente; sem `noopener` a página de destino recebe uma referência
		// para esta janela, que carrega o token na URL.
		expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'));
	});

	it('no Android o link vira `intent://`, para abrir o APP e não o navegador', () => {
		// O flag vem do `load`, decidido pelo `user-agent` do request — decidir no browser faria o
		// SSR pintar um `href` e a hidratação trocá-lo por outro.
		const { getByRole } = render(Confirmar, {
			props: {
				data: { resumo: { ...resumo, resposta: 'confirmou' }, status: 200, quando, android: true },
				form: null
			} as never
		});

		expect(getByRole('link', { name: /Google Agenda/ })).toHaveAttribute(
			'href',
			expect.stringContaining('intent://')
		);
	});

	it('sem instante da API não oferece calendário nenhum — os dois links dariam em nada', () => {
		// O `.ics` responde 404 sem `inicio`/`fim`, e o link do Google sairia sem horário. Botão
		// que não leva a lugar nenhum é pior que a ausência dele.
		const { queryByRole } = tela({ resposta: 'confirmou', inicio: null, fim: null });

		expect(queryByRole('link', { name: /Google Agenda/ })).toBeNull();
	});

	it('quer remarcar: tom de espera (não de sucesso) e o WhatsApp na mão', () => {
		// Verde aqui dizia "resolvido" para quem ainda não tem horário nenhum.
		const { container, getByRole } = tela({ resposta: 'quer_remarcar' });

		expect(container.querySelector('.cn-paciente-aviso-espera')).not.toBeNull();
		expect(container.querySelector('.cn-paciente-aviso-sim')).toBeNull();
		expect(getByRole('link', { name: /WhatsApp/ })).toHaveAttribute(
			'href',
			expect.stringContaining('https://wa.me/5561999466274')
		);
	});

	it('a conversa já começa dizendo de qual sessão se trata', () => {
		// Quem recebe é a recepção, com dezenas de conversas abertas: sem isto, a primeira resposta
		// dela é sempre "quem é?".
		const { getByRole } = tela({ resposta: 'quer_remarcar' });

		const href = getByRole('link', { name: /WhatsApp/ }).getAttribute('href') ?? '';
		const texto = decodeURIComponent(new URL(href).searchParams.get('text') ?? '');

		expect(texto).toContain('Sou Ana');
		expect(texto).toContain('quarta-feira, 5 de agosto, às 08:30');
	});

	it('número fixo cai no `tel:` — wa.me de quem não tem WhatsApp abre o app para dizer que não', () => {
		const { getByRole, queryByRole } = tela({
			resposta: 'quer_remarcar',
			clinica_telefone: '(11) 3456-7890'
		});

		expect(queryByRole('link', { name: /WhatsApp/ })).toBeNull();
		expect(getByRole('link', { name: /Ligar para a clínica/ })).toHaveAttribute(
			'href',
			'tel:+551134567890'
		);
	});

	it('o resultado é anunciado a leitor de tela', () => {
		// Os botões somem no mesmo instante; sem a região viva, quem navega por teclado fica sem
		// foco e sem notícia do que aconteceu.
		const { container } = tela({ resposta: 'confirmou' });

		expect(container.querySelector('[aria-live="polite"]')).not.toBeNull();
	});

	it('respondeu, acabou: os botões somem e NÃO há como responder de novo pela tela', () => {
		// Um "mudar minha resposta" convidaria ao segundo toque sem a pessoa saber se o primeiro
		// valeu. Quem mudou de ideia fala com a clínica — que é quem mexe na agenda de qualquer jeito.
		const { queryByRole } = tela({ resposta: 'confirmou' });

		expect(queryByRole('button', { name: /Preciso remarcar/ })).toBeNull();
		expect(queryByRole('button', { name: /Confirmar presença/ })).toBeNull();
		expect(queryByRole('button', { name: /Mudar minha resposta/ })).toBeNull();
	});

	it('quem confirmou também tem o caminho de volta — mas sem falar em remarcar', () => {
		const { getByRole } = tela({ resposta: 'confirmou' });

		const href = getByRole('link', { name: /WhatsApp/ }).getAttribute('href') ?? '';
		const texto = decodeURIComponent(new URL(href).searchParams.get('text') ?? '');

		expect(texto).toContain('preciso falar com vocês');
		expect(texto).not.toContain('remarcar');
	});

	it('sem telefone da clínica, não sobra botão que não leva a lugar nenhum', () => {
		const { queryByRole } = tela({ resposta: 'quer_remarcar', clinica_telefone: null });

		expect(queryByRole('link', { name: /WhatsApp/ })).toBeNull();
		expect(queryByRole('link', { name: /Ligar para a clínica/ })).toBeNull();
	});
});

describe('/confirmar — quando não há o que confirmar', () => {
	it('sessão cancelada não oferece confirmação, e diz o que houve', () => {
		// O link vale 30 dias; a sessão, não. Antes disto a tela anunciava como marcada uma sessão
		// que a clínica já tinha cancelado.
		const { getByText, queryByRole, getByRole } = tela({ ativa: false });

		expect(getByText('Esta sessão foi cancelada')).toBeInTheDocument();
		expect(queryByRole('button', { name: /Confirmar presença/ })).toBeNull();
		expect(getByRole('link', { name: /WhatsApp/ })).toBeInTheDocument();
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
