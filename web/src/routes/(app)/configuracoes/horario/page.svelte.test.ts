import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

// enhance como no-op action (não há runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Period } from '$lib/scheduling';
import { meFixture } from '$lib/testing/fixtures';

// `me`/`theme` vêm do layout; aqui o papel owner libera o editor.
const me = meFixture({
	user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
	memberships: []
});

describe('Horário — bloqueia o Salvar quando há período inválido', () => {
	it('semana válida: sem banner de erro', () => {
		const data = { theme: null, me, clinicHours: { '1': [['08:00', '12:00']] as Period[] } };
		const { queryByText } = render(Page, { props: { data, form: null } });
		expect(queryByText('Corrija os horários destacados.')).toBeNull();
	});

	it('dia inválido: mostra "Corrija os horários destacados." e desabilita Salvar', () => {
		const data = { theme: null, me, clinicHours: { '1': [['14:00', '12:00']] as Period[] } };
		const { getByText, getByRole } = render(Page, { props: { data, form: null } });

		expect(getByText('Corrija os horários destacados.')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});
});
