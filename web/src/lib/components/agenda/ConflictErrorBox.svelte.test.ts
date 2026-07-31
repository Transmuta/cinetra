import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import ConflictErrorBox from './ConflictErrorBox.svelte';

afterEach(cleanup);

const saida = () => screen.queryByRole('button', { name: /encaixe/i });

/**
 * Compartilhada por criar e por remarcar (Entrega 4) e estava sem teste (doc 93 §B-10). Ela
 * existe porque as duas telas recusam por conflito da mesma forma, e duas cópias fariam a
 * estética do 422-com-saída divergir entre criar e remarcar.
 *
 * A regra que ela carrega é A-D2b: o encaixe **suprime o bloqueio, não a exibição** — e a saída
 * só aparece quando o erro é conflito E quem vê pode marcar encaixe (D14).
 */
describe('ConflictErrorBox', () => {
	it('sem erro, não existe — nada de caixa vazia ocupando a modal', () => {
		const { container } = render(ConflictErrorBox, { onEncaixe: vi.fn() });

		expect(container.textContent?.trim()).toBe('');
	});

	it('mostra a mensagem DO SERVIDOR, não uma frase genérica', () => {
		render(ConflictErrorBox, {
			erro: 'Já existe agendamento neste horário para Dra. Marina.',
			onEncaixe: vi.fn()
		});

		expect(screen.getByText(/Dra\. Marina/)).toBeInTheDocument();
	});

	it('erro que NÃO é conflito não oferece encaixe', () => {
		render(ConflictErrorBox, { erro: 'Paciente obrigatório.', onEncaixe: vi.fn() });

		expect(saida()).not.toBeInTheDocument();
	});

	/** D14: fora do expediente, nem quem tem o papel pode — daí a decisão vir de fora. */
	it('a saída só aparece quando o chamador diz que ela vale', () => {
		render(ConflictErrorBox, { erro: 'Conflito.', ofereceEncaixe: true, onEncaixe: vi.fn() });

		expect(saida()).toBeInTheDocument();
	});

	it('clicar na saída avisa o chamador — quem marca o encaixe é o form dele', async () => {
		const onEncaixe = vi.fn();
		render(ConflictErrorBox, { erro: 'Conflito.', ofereceEncaixe: true, onEncaixe });

		await userEvent.click(saida()!);

		expect(onEncaixe).toHaveBeenCalledOnce();
	});
});
