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
});
