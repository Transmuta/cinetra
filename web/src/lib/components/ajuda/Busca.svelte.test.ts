import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import Busca from './Busca.svelte';
import AjudaShell from './AjudaShell.svelte';
import { createRawSnippet } from 'svelte';

describe('Busca', () => {
	it('só mostra resultado depois que alguém digita', () => {
		const { queryByRole } = render(Busca);
		expect(queryByRole('region', { name: 'Resultados da busca' })).not.toBeInTheDocument();
	});

	it('acha o tópico pelo termo, sem acento', async () => {
		const user = userEvent.setup();
		const { getByRole, findByText } = render(Busca);
		await user.type(getByRole('searchbox', { name: 'Buscar na ajuda' }), 'excecao');
		expect(await findByText('Exceções: feriado, recesso, dia diferente')).toBeInTheDocument();
	});

	it('termo sem resposta diz isso, em vez de mostrar lista vazia', async () => {
		const user = userEvent.setup();
		const { getByRole, findByText } = render(Busca);
		await user.type(getByRole('searchbox', { name: 'Buscar na ajuda' }), 'zzzzzz');
		expect(await findByText(/Nada encontrado/)).toBeInTheDocument();
	});

	it('o resultado leva ao tópico', async () => {
		const user = userEvent.setup();
		const { getByRole, findByRole } = render(Busca);
		await user.type(getByRole('searchbox', { name: 'Buscar na ajuda' }), 'encaixe');
		const link = await findByRole('link', { name: /Encaixe/ });
		expect(link).toHaveAttribute('href', '/ajuda/encaixe');
	});
});

const corpo = createRawSnippet(() => ({ render: () => '<p>conteúdo</p>' }));

// A casca virou a das páginas públicas (doc 108 §2), então ela pede o cabeçalho da página:
// título, subtítulo, descrição e a canônica que as tags de `<head>` usam.
const cabecalho = {
	titulo: 'Marcar um atendimento',
	subtitulo: 'Do clique no horário vago até o bloco na grade.',
	descricao: 'Como marcar um atendimento no Cinetra.',
	canonical: 'https://cinetra.app/ajuda/marcar-um-atendimento',
	origem: 'https://cinetra.app'
};

describe('AjudaShell', () => {
	it('sem sessão, o canto oferece entrar', () => {
		const { getByRole } = render(AjudaShell, { props: { ...cabecalho, logado: false, children: corpo } });
		expect(getByRole('link', { name: 'Entrar no sistema' })).toHaveAttribute('href', '/entrar');
	});

	it('com sessão, o canto volta para o sistema', () => {
		const { getByRole } = render(AjudaShell, { props: { ...cabecalho, logado: true, children: corpo } });
		expect(getByRole('link', { name: /Voltar ao sistema/ })).toHaveAttribute('href', '/agenda');
	});

	it('tem o atalho de pular para o conteúdo', () => {
		const { getByRole } = render(AjudaShell, { props: { ...cabecalho, children: corpo } });
		expect(getByRole('link', { name: 'Pular para o conteúdo' })).toHaveAttribute(
			'href',
			'#conteudo'
		);
	});
});
