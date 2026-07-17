import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { flushSync } from 'svelte';

import Toast from './Toast.svelte';
import { toast, dismissToast } from '$lib/toast.svelte';

// Estado do toast é de módulo — isola cada teste.
beforeEach(() => dismissToast());
afterEach(() => dismissToast());

describe('Toast', () => {
	it('não renderiza nada sem toast ativo', () => {
		const { queryByRole } = render(Toast);
		expect(queryByRole('status')).toBeNull();
	});

	it('mostra a mensagem quando toast() é chamado e some no dismiss', () => {
		const { queryByRole, getByRole } = render(Toast);

		toast('Convite enviado.');
		flushSync();
		expect(getByRole('status')).toHaveTextContent('Convite enviado.');

		dismissToast();
		flushSync();
		expect(queryByRole('status')).toBeNull();
	});

	it('usa o visual invertido do protótipo (primary/on-primary) com o check teal', () => {
		const { getByRole } = render(Toast);

		toast('Acesso removido.');
		flushSync();

		const pill = getByRole('status');
		expect(pill.className).toContain('bg-primary');
		expect(pill.className).toContain('text-on-primary');
		expect(pill.querySelector('.text-teal')).not.toBeNull();
	});

	it('sucesso mostra o check teal e NÃO o ícone de erro', () => {
		const { getByRole } = render(Toast);

		toast('Horário da clínica salvo', 'success');
		flushSync();

		const pill = getByRole('status');
		expect(pill.querySelector('.text-teal')).not.toBeNull();
		expect(pill.querySelector('.text-danger')).toBeNull();
	});

	it('erro NÃO usa o check de sucesso — mostra um ícone de erro (danger)', () => {
		// Regressão: um horário inválido devolvia "Dados inválidos" com o check verde de sucesso.
		// Erro e sucesso precisam ser visualmente distintos (o protótipo não distinguia; aqui sim).
		const { getByRole } = render(Toast);

		toast('Dados inválidos. Verifique os campos.', 'error');
		flushSync();

		const pill = getByRole('status');
		expect(pill).toHaveTextContent('Dados inválidos. Verifique os campos.');
		expect(pill.querySelector('.text-teal')).toBeNull();
		expect(pill.querySelector('.text-danger')).not.toBeNull();
	});
});
