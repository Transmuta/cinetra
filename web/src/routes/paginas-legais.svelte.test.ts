import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Privacidade from './privacidade/+page.svelte';
import Termos from './termos/+page.svelte';
import { PRIVACIDADE, TERMOS } from '$lib/legal';

// A casca (sumário, âncoras, hierarquia de títulos) é testada em `LegalPage.svelte.test.ts`.
// Aqui prova-se só a fiação: cada rota desenha o SEU documento, e não o par.
const data = { canonical: 'https://cinetra.app/x', origem: 'https://cinetra.app' };

describe('rotas dos documentos legais', () => {
	it('/privacidade desenha a política de privacidade', () => {
		const { getByRole, queryByRole } = render(Privacidade, { props: { data } });

		expect(getByRole('heading', { level: 1, name: PRIVACIDADE.titulo })).toBeInTheDocument();
		expect(queryByRole('heading', { level: 1, name: TERMOS.titulo })).toBeNull();
	});

	it('/termos desenha os termos de uso', () => {
		const { getByRole, queryByRole } = render(Termos, { props: { data } });

		expect(getByRole('heading', { level: 1, name: TERMOS.titulo })).toBeInTheDocument();
		expect(queryByRole('heading', { level: 1, name: PRIVACIDADE.titulo })).toBeNull();
	});
});
