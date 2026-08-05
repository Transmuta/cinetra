import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import Rail from './Rail.svelte';

describe('Rail', () => {
	// Com `papel` porque dois destinos são restritos e somem sem ele — Profissionais é um deles
	// desde 2026-08-04 (doc 103). Quem prova o recorte são as describes do fim do arquivo; aqui
	// o que se afirma é que o rail desenha os destinos como links.
	it('lista os destinos do app (todos como links)', () => {
		const { getByTitle } = render(Rail, {
			props: { pathname: '/configuracoes/equipe', papel: 'owner' as const }
		});
		expect(getByTitle('Agenda')).toHaveAttribute('href', '/agenda');
		expect(getByTitle('Profissionais')).toHaveAttribute('href', '/profissionais');
		expect(getByTitle('Configurações')).toHaveAttribute('href', '/configuracoes');
	});

	it('destaca a seção ativa (aria-current)', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/configuracoes/equipe' } });
		expect(getByTitle('Configurações')).toHaveAttribute('aria-current', 'page');
		expect(getByTitle('Agenda')).not.toHaveAttribute('aria-current');
	});

	it('traz o toggle de tema no rodapé (o avatar do usuário mora no topbar)', () => {
		const { getByRole } = render(Rail, { props: { pathname: '/agenda', theme: 'light' } });
		expect(getByRole('button', { name: /tema/i })).toBeInTheDocument();
	});

	it('o sino é um link para /notificacoes', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/agenda' } });
		expect(getByTitle('Notificações')).toHaveAttribute('href', '/notificacoes');
	});

	it('sem não-lidas não mostra badge; com não-lidas mostra o número', () => {
		const semBadge = render(Rail, { props: { pathname: '/agenda', unread: 0 } });
		expect(semBadge.getByLabelText('Notificações')).toBeInTheDocument();

		const comBadge = render(Rail, { props: { pathname: '/agenda', unread: 3 } });
		expect(comBadge.getByText('3')).toBeInTheDocument();
		expect(comBadge.getByLabelText('Notificações (3 não lidas)')).toBeInTheDocument();
	});

	it('acima de 9 o badge vira "9+"', () => {
		const { getByText } = render(Rail, { props: { pathname: '/agenda', unread: 42 } });
		expect(getByText('9+')).toBeInTheDocument();
	});

	it('destaca o sino quando em /notificacoes', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/notificacoes' } });
		expect(getByTitle('Notificações')).toHaveAttribute('aria-current', 'page');
	});
});

// A Auditoria virou seção de primeiro nível (saiu de Configurações), e é owner·admin: o ícone
// só aparece para quem pode entrar — a policy da API é a autoridade, os demais levariam 403.
describe('Rail — Auditoria (owner·admin)', () => {
	// `cleanup` em `afterEach`, e NÃO no fim do corpo do teste: uma asserção que levanta pula o
	// resto do corpo, o DOM do render anterior sobrevive, e o teste seguinte encontra dois rails
	// — uma falha real cascateia em três, e a suíte fica intermitente. Foi visto acontecer.
	afterEach(cleanup);

	it.each(['owner', 'admin'] as const)('%s vê o destino', (papel) => {
		const { getByTitle } = render(Rail, { props: { pathname: '/agenda', papel } });
		expect(getByTitle('Auditoria')).toHaveAttribute('href', '/auditoria');
	});

	it.each(['recepcao', 'profissional'] as const)(
		'%s NÃO vê (mas vê os demais destinos)',
		(papel) => {
			const { queryByTitle, getByTitle } = render(Rail, { props: { pathname: '/agenda', papel } });
			expect(queryByTitle('Auditoria')).toBeNull();
			expect(getByTitle('Agenda')).toBeInTheDocument();
		}
	);

	it('sem papel conhecido, esconde', () => {
		const { queryByTitle } = render(Rail, { props: { pathname: '/agenda' } });
		expect(queryByTitle('Auditoria')).toBeNull();
	});

	it('destaca a seção quando em /auditoria', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/auditoria', papel: 'owner' } });
		expect(getByTitle('Auditoria')).toHaveAttribute('aria-current', 'page');
	});
});

// 2026-08-04 (doc 103): a tela de Profissionais deixou de ser do papel `profissional` — nem o
// diretório, nem a própria ficha. O recorte NÃO é o da Auditoria: a recepção continua entrando.
describe('Rail — Profissionais (todos menos o profissional)', () => {
	afterEach(cleanup);

	it.each(['owner', 'admin', 'recepcao'] as const)('%s vê o destino', (papel) => {
		const { getByTitle } = render(Rail, { props: { pathname: '/agenda', papel } });
		expect(getByTitle('Profissionais')).toHaveAttribute('href', '/profissionais');
	});

	it('o profissional NÃO vê — mas continua com Agenda e Fila', () => {
		const { queryByTitle, getByTitle } = render(Rail, {
			props: { pathname: '/agenda', papel: 'profissional' }
		});
		expect(queryByTitle('Profissionais')).toBeNull();
		expect(getByTitle('Agenda')).toBeInTheDocument();
		expect(getByTitle('Fila de espera')).toBeInTheDocument();
	});

	// Sem papel resolvido o rail some com o destino, como já faz com a Auditoria: a tela em
	// branco é recuperável, o vazamento de um caminho que dá 403 é ruído.
	it('sem papel conhecido, esconde', () => {
		const { queryByTitle } = render(Rail, { props: { pathname: '/agenda' } });
		expect(queryByTitle('Profissionais')).toBeNull();
	});
});
