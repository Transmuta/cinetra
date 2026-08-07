import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/svelte';
import { tick } from 'svelte';

// O drawer da agenda é LINKÁVEL: `?agendamento=<id>` na URL diz qual bloco está aberto. O que se
// prova aqui é o mecanismo — e ele tem uma sutileza que custou uma versão inteira.
//
// **`pushState`/`replaceState` do Kit escrevem em `page.state` e NÃO em `page.url`.** (Conferido no
// fonte — `client.js` guarda a URL da última navegação real em `PAGE_URL_KEY` para restaurá-la no
// popstate — e ao vivo, no browser: a barra de endereço mudava e o painel não abria.) Por isso o
// mock imita as duas pontas com o comportamento real, e o `fake-page` é reativo: com um objeto
// solto, o `$derived` da tela nunca recalcularia e o teste passaria mostrando o render inicial.
const nav = vi.hoisted(() => ({
	goto: vi.fn(),
	invalidate: vi.fn(),
	invalidateAll: vi.fn(),
	pushState: vi.fn(),
	replaceState: vi.fn()
}));
vi.mock('$app/navigation', () => nav);
// `enhance` é do drawer (cada mutação é um form); `deserialize`, do arraste.
vi.mock('$app/forms', () => ({ deserialize: vi.fn(), enhance: () => ({ destroy() {} }) }));
vi.mock('$app/state', async () => ({
	page: (await import('$lib/testing/fake-page.svelte')).page
}));

// Sem tocar o Phoenix: o efeito do token não acha `cfg.token` no stub de fetch abaixo, então
// `connectAgenda` não roda — mas o módulo é importado de qualquer forma.
vi.mock('$lib/realtime', () => ({
	agendaTopics: () => ['agenda:c1:2026-07-20'],
	connectAgenda: () => () => {}
}));

vi.mock('$lib/toast.svelte', () => ({ toast: vi.fn() }));

import { fake, resetFakePage } from '$lib/testing/fake-page.svelte';
import Page from './+page.svelte';
import type { Appointment } from '$lib/agenda';

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		version: 3,
		created_by_id: null,
		patient_ids: ['pac1'],
		participants: [
			{
				patient_id: 'pac1',
				status: 'prevista',
				falta_justificada: false,
				motivo: null,
				package_id: null,
				package: null,
				resposta: null
			}
		],
		...over
	};
}

// Visão Lista: mostra os mesmos blocos do Dia (B-D1) com o DOM mais simples — uma linha por
// bloco, cada uma um botão que seleciona.
function data(over: Record<string, unknown> = {}) {
	return {
		view: 'lista',
		date: '2026-07-20',
		today: '2026-07-20',
		hidden: [],
		presetPatient: null,
		appointments: [appt()],
		professionals: [
			{
				id: 'p1',
				nome: 'Dra. Ana',
				nome_exibicao: null,
				crefito: null,
				cor_indice: 1,
				segue_horario_clinica: true
			}
		],
		appointmentTypes: [
			{
				id: 't1',
				nome: 'Sessão',
				duracao_minutos: 50,
				cor: '#0072B2',
				icon: 'Activity',
				grupo: false,
				capacidade: null
			}
		],
		patients: [{ id: 'pac1', nome: 'João Silva', tel: '11999', ativo: true, faltas: 0 }],
		availability: [],
		days: [],
		agora: '2026-07-20T17:00:00Z',
		timezone: 'America/Sao_Paulo',
		me: { papel: 'recepcao', user: { id: 'u1' } },
		...over
	} as never;
}

const drawer = () => screen.queryByRole('dialog', { name: 'Detalhes do agendamento' });

beforeEach(() => {
	resetFakePage('http://localhost/agenda');
	Object.values(nav).forEach((fn) => fn.mockReset());
	// Como o Kit: guardam o estado, não tocam a URL.
	nav.pushState.mockImplementation((_url, state) => {
		fake.estado = state;
	});
	nav.replaceState.mockImplementation((_url, state) => {
		fake.estado = state;
	});
	// `/api/realtime/token` sem token → o socket nunca abre; `/agenda/mensagens/<id>` é a timeline
	// que o drawer busca ao abrir.
	vi.stubGlobal(
		'fetch',
		vi.fn(async () => ({ ok: true, json: async () => ({ participantes: [] }) }))
	);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('drawer na URL', () => {
	it('`?agendamento=<id>` abre o drawer já no bloco', () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		render(Page, { props: { data: data(), form: null } });

		expect(screen.getByTestId('drawer-titulo')).toHaveTextContent('João Silva');
	});

	it('sem o parâmetro, nenhum drawer', () => {
		render(Page, { props: { data: data(), form: null } });
		expect(drawer()).not.toBeInTheDocument();
	});

	// O regresso que o browser pegou e a URL sozinha não pegava: o clique tem de ABRIR o painel,
	// e é `page.state` que o abre (a URL que o `pushState` escreve não volta em `page.url`).
	it('clicar num bloco abre o drawer', async () => {
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /João Silva/ }));

		expect(screen.getByTestId('drawer-titulo')).toHaveTextContent('João Silva');
	});

	// O outro lado: `goto` reexecutaria o load desta página (ele lê `url.searchParams`), ou seja,
	// uma busca da agenda + uma do expediente a cada bloco aberto.
	it('e muda a URL sem reexecutar o load', async () => {
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /João Silva/ }));

		expect(nav.goto).not.toHaveBeenCalled();
		expect(nav.pushState).toHaveBeenCalledTimes(1);
		expect(nav.pushState.mock.calls[0][0]).toContain('agendamento=a1');
	});

	// A trava do teleporte: `date` viaja junto do id. Sem ela, remarcar o bloco para outro dia
	// faria o load resolver o dia PELO BLOCO e a tela pularia de data sozinha.
	it('a URL do drawer fixa o dia junto do id', async () => {
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /João Silva/ }));

		expect(nav.pushState.mock.calls[0][0]).toContain('date=2026-07-20');
	});

	// Abrir EMPILHA (o back fecha o drawer); trocar de bloco com ele aberto só REFINA — empilhar
	// aí faria o back passear pelos blocos visitados antes de fechar (o I68 da paginação).
	it('trocar de bloco com o drawer aberto não empilha histórico', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		fake.estado = { agendamento: 'a1' };
		render(Page, {
			props: { data: data({ appointments: [appt(), appt({ id: 'a2' })] }), form: null }
		});

		await fireEvent.click(screen.getAllByRole('button', { name: /João Silva/ })[1]);

		expect(nav.pushState).not.toHaveBeenCalled();
		expect(nav.replaceState).toHaveBeenCalledTimes(1);
		expect(nav.replaceState.mock.calls[0][0]).toContain('agendamento=a2');
	});

	// Fechar precisa de um `null` EXPLÍCITO no estado: a URL que sobra em `page.url` é a do
	// carregamento e ainda tem o parâmetro, então "estado vazio = vale a URL" reabriria o painel.
	it('fechar o drawer o fecha de fato, e a URL larga o parâmetro', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: 'Fechar' }));

		expect(drawer()).not.toBeInTheDocument();
		expect(nav.replaceState).toHaveBeenCalledTimes(1);
		expect(nav.replaceState.mock.calls[0][0]).not.toContain('agendamento');
		// O dia FICA: fechar o painel não é sair do dia que está na tela.
		expect(nav.replaceState.mock.calls[0][0]).toContain('date=2026-07-20');
	});

	// Link morto — bloco excluído, de outra clínica, ou do colega para o papel `profissional` (a
	// API devolve 404 e o load abre o dia sem ele). Nada abre; e **nada navega**: shallow routing
	// na hidratação é erro no console ("before router is initialized"), e o parâmetro órfão não
	// abre nada nem sobrevive ao próximo carregamento.
	it('id que não está na janela não abre nada — e não navega', () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=sumiu');
		render(Page, { props: { data: data(), form: null } });

		expect(drawer()).not.toBeInTheDocument();
		expect(nav.replaceState).not.toHaveBeenCalled();
		expect(nav.pushState).not.toHaveBeenCalled();
	});

	// **`page.state` é VOLÁTIL.** Medido no browser (2026-08-06): `invalidate`/`invalidateAll`
	// reescrevem `page.state` do zero — o `history.state` continua com o id, a barra de endereço
	// também, e só o espelho em memória é zerado.
	//
	// Isso não é um caso de borda: TODA mutação do drawer termina em `invalidateAll` (o default do
	// `use:enhance`), e o tempo real ainda recarrega sozinho 400ms depois de qualquer evento. Com o
	// id morando só em `page.state`, o painel fechava sozinho a cada ação feita dentro dele —
	// marcar presença, adicionar à turma, cancelar.
	it('o drawer sobrevive ao invalidate que toda ação dispara', async () => {
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /João Silva/ }));
		expect(drawer()).toBeInTheDocument();

		// O que o Kit faz ao recarregar o load: `page.state` volta a ser `{}`.
		fake.estado = {};
		await tick();

		expect(drawer()).toBeInTheDocument();
	});

	// O contrapeso do teste acima: sobreviver ao `invalidate` não pode virar sobreviver ao BACK.
	// O popstate devolve a palavra ao histórico — que é quem sabe se aquela entrada tinha painel
	// aberto ou não.
	it('mas o back continua fechando o painel', async () => {
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /João Silva/ }));
		expect(drawer()).toBeInTheDocument();

		// Como o Kit no popstate raso: restaura o estado daquela entrada (aqui, a de antes de
		// abrir) e a URL dela.
		fake.estado = {};
		window.dispatchEvent(new PopStateEvent('popstate'));
		await tick();

		expect(drawer()).not.toBeInTheDocument();
	});

	// Trocar de dia/visão FECHA o drawer: o bloco aberto é do dia que estava na tela. Se o id
	// sobrevivesse à navegação, o drawer tentaria abrir um bloco fora da janela nova.
	it('navegar entre dias larga o parâmetro', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		render(Page, { props: { data: data(), form: null } });

		await fireEvent.click(screen.getByRole('button', { name: /Próximo dia/ }));

		expect(nav.goto).toHaveBeenCalledTimes(1);
		expect(nav.goto.mock.calls[0][0]).not.toContain('agendamento');
		expect(nav.goto.mock.calls[0][0]).toContain('date=2026-07-21');
	});
});

// A timeline de comunicação é buscada sob demanda, por `fetch`, quando o drawer abre. Quem decide
// se ela é buscada é o mesmo `?agendamento=` do bloco acima — e é aí que mora a regressão que o
// browser pegou na HML: excluir um bloco deixava o parâmetro ÓRFÃO na URL (o drawer fecha porque o
// bloco saiu da janela, mas ninguém navega), e o efeito continuava pedindo a timeline de um
// agendamento que a API não vê mais. Rajada de 404 em `/agenda/mensagens/<id>` a cada action.
describe('timeline de comunicação: quando a busca sai', () => {
	const buscas = () =>
		vi
			.mocked(globalThis.fetch)
			.mock.calls.filter((c) => String(c[0]).includes('/agenda/mensagens/'));

	// O caminho normal, e a garantia de que os testes abaixo medem algo.
	it('o drawer aberto busca a timeline do bloco', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		render(Page, { props: { data: data(), form: null } });

		await vi.waitFor(() => expect(buscas()).toHaveLength(1));
		expect(String(buscas()[0][0])).toContain('/agenda/mensagens/a1');
	});

	// O achado: id órfão (bloco excluído, link morto, bloco de outra clínica) não pede nada. Sem
	// isto o pedido sai e volta 404 — inofensivo na tela (o drawer está fechado), mas é lixo na
	// rede e no log da API que só limpa ao trocar de dia ou num F5.
	it('id que não está na janela NÃO busca a timeline', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=sumiu');
		render(Page, { props: { data: data(), form: null } });

		await vi.waitFor(() => expect(vi.mocked(globalThis.fetch)).toHaveBeenCalled());
		expect(buscas()).toHaveLength(0);
	});

	// A segunda metade do estrago: o efeito lia `form?.action`, logo dependia do `form` INTEIRO.
	// Como o `enhance` repõe o `form` a cada mutação, criar/excluir/concluir qualquer coisa refazia
	// a busca da timeline do bloco aberto — e, com o id órfão, multiplicava os 404.
	it('resultado de uma action alheia não refaz a busca', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		const { rerender } = render(Page, { props: { data: data(), form: null } });

		await vi.waitFor(() => expect(buscas()).toHaveLength(1));

		await rerender({ data: data(), form: { ok: true, action: 'criar' } });
		await rerender({ data: data(), form: { ok: true, action: 'excluir', error: null } });

		expect(buscas()).toHaveLength(1);
	});

	// O outro lado da moeda, para o conserto acima não matar o que a chave existia para fazer:
	// depois de ENVIAR a confirmação, a linha nova tem de aparecer sem F5.
	it('mas o envio de confirmação refaz a busca', async () => {
		resetFakePage('http://localhost/agenda?date=2026-07-20&agendamento=a1');
		const { rerender } = render(Page, { props: { data: data(), form: null } });

		await vi.waitFor(() => expect(buscas()).toHaveLength(1));

		await rerender({ data: data(), form: { ok: true, action: 'confirmar', mensagem: 'Enviado' } });

		await vi.waitFor(() => expect(buscas()).toHaveLength(2));
	});
});
