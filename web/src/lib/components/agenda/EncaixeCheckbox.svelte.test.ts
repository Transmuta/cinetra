import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import EncaixeCheckbox from './EncaixeCheckbox.svelte';

afterEach(cleanup);

/**
 * Reusado por criar e por remarcar (Entrega 4), e estava sem teste (doc 93 §B-10). O que ele
 * carrega não é estética: é o gate de papel A9/D2. Some INTEIRO para quem não pode marcar
 * encaixe — não fica desabilitado, some — porque um controle desabilitado convida a pedir
 * permissão para uma ação que a policy vai recusar de todo jeito.
 */
describe('EncaixeCheckbox', () => {
	it('não existe para quem não pode marcar encaixe', () => {
		render(EncaixeCheckbox, { podeEncaixe: false });

		expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
	});

	it('aparece para quem pode, desmarcado', () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		expect(screen.getByRole('checkbox')).not.toBeChecked();
	});

	/** O valor viaja no form da action do pai — sem o `name`, o encaixe não chega ao servidor. */
	it('leva `name="encaixe"`, que é como o valor chega na action', () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		expect(screen.getByRole('checkbox')).toHaveAttribute('name', 'encaixe');
	});

	it('diz o que faz — "ignora conflito de horário" não é detalhe', () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		expect(screen.getByText(/ignora conflito de horário/i)).toBeInTheDocument();
	});

	it('clicar marca', async () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		await userEvent.click(screen.getByRole('checkbox'));

		expect(screen.getByRole('checkbox')).toBeChecked();
	});
});
