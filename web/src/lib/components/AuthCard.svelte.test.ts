import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import AuthCard from './AuthCard.svelte';

const snippet = (html: string) => createRawSnippet(() => ({ render: () => `<div>${html}</div>` }));

describe('AuthCard', () => {
	it('renderiza título, subtítulo, conteúdo, rodapé e o testemunho do painel de marca', () => {
		const { getByRole, getByText } = render(AuthCard, {
			props: {
				title: 'Bem-vindo de volta',
				subtitle: 'Entre para acessar a agenda.',
				children: snippet('conteúdo-do-form'),
				footer: snippet('rodapé-aqui')
			}
		});

		expect(getByRole('heading', { name: 'Bem-vindo de volta' })).toBeInTheDocument();
		expect(getByText('Entre para acessar a agenda.')).toBeInTheDocument();
		expect(getByText('conteúdo-do-form')).toBeInTheDocument();
		expect(getByText('rodapé-aqui')).toBeInTheDocument();
		// Painel de marca (testemunho fixo).
		expect(getByText('Dra. Marina Lopes')).toBeInTheDocument();
	});

	it('não renderiza mais o link "Voltar ao site"', () => {
		const { queryByRole } = render(AuthCard, {
			props: { title: 'Entrar', children: snippet('x') }
		});

		expect(queryByRole('link', { name: /Voltar ao site/ })).toBeNull();
	});

	it('mantém o gancho que colapsa o split no mobile', () => {
		const { container } = render(AuthCard, {
			props: { title: 'Entrar', children: snippet('x') }
		});

		// Só a presença da classe: quem colapsa de fato é a media query de cinetra.css, e o
		// jsdom não aplica CSS — o comportamento em si está em `e2e/login.spec.ts`. Isto aqui é
		// o pedaço que roda no CI, para a classe não sumir num refactor e levar a regra junto.
		expect(container.querySelector('.cn-authsplit')).not.toBeNull();
	});
});
