import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
vi.mock('$app/state', () => ({ page: { url: { pathname: '/criar-conta' } } }));

import CriarConta from './+page.svelte';
import Entrar from '../entrar/+page.svelte';

const data = { canonical: 'https://cinetra.app/criar-conta', origem: 'https://cinetra.app' };
const props = { data, form: null } as never;

// O aceite dos documentos legais é da tela que CRIA conta. `/entrar` não cria nada, e repetir a
// nota lá só ensinaria a ignorá-la.
describe('/criar-conta', () => {
	it('mostra o aceite dos dois documentos, ligado a cada um', () => {
		const { getByRole } = render(CriarConta, { props });

		expect(getByRole('link', { name: /termos de uso/i })).toHaveAttribute('href', '/termos');
		expect(getByRole('link', { name: /política de privacidade/i })).toHaveAttribute(
			'href',
			'/privacidade'
		);
	});

	it('/entrar não repete o aceite', () => {
		const { queryByRole } = render(Entrar, { props });

		expect(queryByRole('link', { name: /termos de uso/i })).toBeNull();
	});
});
