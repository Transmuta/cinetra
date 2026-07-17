import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { flushSync } from 'svelte';

// enhance como no-op action (não há runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import { currentToast, dismissToast } from '$lib/toast.svelte';

// `me`/`theme` vêm do layout; aqui só o `papel` importa (owner → pode gerir).
const data = {
	theme: null,
	me: {
		user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
		active_clinic_id: 'c1',
		papel: 'owner' as const,
		professional_id: null,
		memberships: []
	},
	exceptions: []
};

beforeEach(() => dismissToast());
afterEach(() => dismissToast());

describe('Exceções — toast do resultado da ação', () => {
	it('erro ao EXCLUIR vira toast de ERRO (regressão: vinha com o visual de sucesso)', () => {
		render(Page, {
			props: { data, form: { action: 'delete', error: 'Registro não encontrado.' } }
		});
		flushSync();

		expect(currentToast()?.message).toBe('Registro não encontrado.');
		expect(currentToast()?.variant).toBe('error');
	});

	it('remoção bem-sucedida vira toast de SUCESSO', () => {
		render(Page, { props: { data, form: { ok: true, action: 'delete' } } });
		flushSync();

		expect(currentToast()?.message).toBe('Exceção removida');
		expect(currentToast()?.variant).toBe('success');
	});

	it('exceção adicionada vira toast de SUCESSO', () => {
		render(Page, { props: { data, form: { ok: true, action: 'add' } } });
		flushSync();

		expect(currentToast()?.message).toBe('Exceção adicionada');
		expect(currentToast()?.variant).toBe('success');
	});
});
