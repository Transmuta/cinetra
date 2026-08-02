import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import EncaixeCheckbox from './EncaixeCheckbox.svelte';
import Hospedeiro from './EncaixeCheckbox.hospedeiro.test.svelte';

afterEach(cleanup);

/**
 * O que a action de fato vai ler. As três actions que recebem este campo decidem por
 * `form.get('encaixe') === 'on'` (`agenda/+page.server.ts` :287/:336/:462 e `fila` :147), então
 * é esse valor cru que os testes de fronteira abaixo checam — não o estado interno.
 */
function encaixeSubmetido() {
	const form = screen.getByTestId('form') as HTMLFormElement;
	return new FormData(form).get('encaixe');
}

/**
 * Reusado por criar e por remarcar (Entrega 4), e estava sem teste (doc 93 §B-10). O que ele
 * carrega não é estética: é o gate de papel A9/D2. Some INTEIRO para quem não pode marcar
 * encaixe — não fica desabilitado, some — porque um controle desabilitado convida a pedir
 * permissão para uma ação que a policy vai recusar de todo jeito.
 */
describe('EncaixeCheckbox', () => {
	it('não existe para quem não pode marcar encaixe', () => {
		render(EncaixeCheckbox, { podeEncaixe: false });

		expect(screen.queryByRole('switch')).not.toBeInTheDocument();
	});

	it('aparece para quem pode, desligado', () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		expect(screen.getByRole('switch')).not.toBeChecked();
	});

	it('diz o que faz — "ignora conflito de horário" não é detalhe', () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		expect(screen.getByText(/ignora conflito de horário/i)).toBeInTheDocument();
	});

	it('clicar liga', async () => {
		render(EncaixeCheckbox, { podeEncaixe: true });

		await userEvent.click(screen.getByRole('switch'));

		expect(screen.getByRole('switch')).toBeChecked();
	});
});

/**
 * Estes atravessam a fronteira de propósito: leem o `FormData` do form de verdade, não o estado
 * interno do componente. É a única prova que vale, porque o controle é um
 * `<button role="switch">` — e botão NÃO entra no FormData (doc 98 §6). Quem carrega o valor é o
 * hidden ao lado dele; sem ele o encaixe seria ignorado em silêncio em criar, remarcar e oferecer
 * vaga, e o sintoma seria um 409 de conflito que ninguém entende.
 *
 * Teste do lado de dentro (aria-checked) não pega isso — daí a fronteira.
 */
describe('EncaixeCheckbox — o que chega na action', () => {
	it('desligado, o valor não é o "on" que a action exige', () => {
		render(Hospedeiro, { podeEncaixe: true });

		expect(encaixeSubmetido()).not.toBe('on');
	});

	it('ligado, manda "on"', () => {
		render(Hospedeiro, { podeEncaixe: true, checked: true });

		expect(encaixeSubmetido()).toBe('on');
	});

	it('ligar pelo clique chega na action', async () => {
		render(Hospedeiro, { podeEncaixe: true });

		await userEvent.click(screen.getByRole('switch'));

		expect(encaixeSubmetido()).toBe('on');
	});

	it('quem não pode marcar encaixe não manda campo nenhum', () => {
		render(Hospedeiro, { podeEncaixe: false, checked: true });

		expect(encaixeSubmetido()).toBeNull();
	});
});
