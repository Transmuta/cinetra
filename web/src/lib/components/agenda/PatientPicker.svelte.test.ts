import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import PatientPicker from './PatientPicker.svelte';

const maria = { id: 'pat1', nome: 'Maria Silva', tel: '11999990000', cor_indice: 1 };

function setup(over: Record<string, unknown> = {}) {
	const search = vi.fn().mockResolvedValue({ patients: [maria], total: 1 });
	const onPick = vi.fn();
	const onRemove = vi.fn();
	const utils = render(PatientPicker, {
		props: { selected: [], multi: false, search, onPick, onRemove, ...over }
	});
	return { search, onPick, onRemove, ...utils };
}

beforeEach(() => vi.useFakeTimers({ shouldAdvanceTime: true }));
afterEach(() => {
	cleanup();
	vi.useRealTimers();
});

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

describe('PatientPicker', () => {
	it('menos de 2 caracteres não busca (protótipo :1946)', async () => {
		const { search } = setup();
		await user().type(screen.getByRole('combobox'), 'm');
		await vi.advanceTimersByTimeAsync(500);
		expect(search).not.toHaveBeenCalled();
	});

	it('a partir de 2 caracteres busca, depois do debounce', async () => {
		const { search } = setup();
		await user().type(screen.getByRole('combobox'), 'ma');

		// Antes dos 300ms ainda não saiu request.
		await vi.advanceTimersByTimeAsync(200);
		expect(search).not.toHaveBeenCalled();

		await vi.advanceTimersByTimeAsync(150);
		expect(search).toHaveBeenCalledWith('ma');
	});

	it('digitar rápido dispara UMA busca, não uma por tecla', async () => {
		const { search } = setup();
		await user().type(screen.getByRole('combobox'), 'maria');
		await vi.advanceTimersByTimeAsync(500);
		expect(search).toHaveBeenCalledTimes(1);
		expect(search).toHaveBeenCalledWith('maria');
	});

	it('mostra o resultado e o seleciona no clique', async () => {
		const { search, onPick } = setup();
		await user().type(screen.getByRole('combobox'), 'maria');
		await vi.advanceTimersByTimeAsync(400);
		expect(search).toHaveBeenCalled();

		await user().click(await screen.findByText('Maria Silva'));
		expect(onPick).toHaveBeenCalledWith(maria);
	});

	it('avisa quando há mais resultados do que cabe', async () => {
		const search = vi.fn().mockResolvedValue({ patients: [maria], total: 42 });
		setup({ search });
		await user().type(screen.getByRole('combobox'), 'ma');
		await vi.advanceTimersByTimeAsync(400);
		expect(await screen.findByText(/refine a busca/i)).toBeInTheDocument();
	});

	it('busca sem resultado avisa em vez de ficar em branco', async () => {
		const search = vi.fn().mockResolvedValue({ patients: [], total: 0 });
		setup({ search });
		await user().type(screen.getByRole('combobox'), 'zzz');
		await vi.advanceTimersByTimeAsync(400);
		expect(await screen.findByText(/nenhum paciente/i)).toBeInTheDocument();
	});

	it('os já selecionados aparecem e podem ser removidos', async () => {
		const { onRemove } = setup({ selected: [maria], multi: true });
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
		await user().click(screen.getByRole('button', { name: /remover maria silva/i }));
		expect(onRemove).toHaveBeenCalledWith('pat1');
	});

	// O timer órfão JÁ MORDEU neste projeto (pacientes/+page.svelte:74): sair da tela antes
	// do debounce vencer deixava um setTimeout vivo que navegava sozinho.
	it('desmontar antes do debounce não dispara busca nenhuma', async () => {
		const { search, unmount } = setup();
		await user().type(screen.getByRole('combobox'), 'maria');
		unmount();
		await vi.advanceTimersByTimeAsync(1000);
		expect(search).not.toHaveBeenCalled();
	});

	it('apagar para menos de 2 caracteres limpa a lista', async () => {
		setup();
		const input = screen.getByRole('combobox');
		await user().type(input, 'maria');
		await vi.advanceTimersByTimeAsync(400);
		expect(await screen.findByText('Maria Silva')).toBeInTheDocument();

		await user().clear(input);
		await vi.advanceTimersByTimeAsync(400);
		expect(screen.queryByText('Maria Silva')).not.toBeInTheDocument();
	});

	// ACC-21 (doc 83): o componente já dizia `role="combobox"` e apontava `aria-controls` para uma
	// `<ul>` comum — sem `role="listbox"`, sem `option`, sem `aria-activedescendant` e **sem nenhum
	// `onkeydown`**. Ou seja: prometia um padrão que não cumpria, e seta para baixo não navegava.
	describe('padrão ARIA de combobox (ACC-21)', () => {
		const dois = [maria, { ...maria, id: 'p2', nome: 'Mario Souza' }];

		async function abrirLista(over: Parameters<typeof setup>[0] = {}) {
			const r = setup({ search: vi.fn().mockResolvedValue({ patients: dois, total: 2 }), ...over });
			await user().type(screen.getByRole('combobox'), 'mar');
			await vi.advanceTimersByTimeAsync(400);
			await screen.findByText('Maria Silva');
			return r;
		}

		it('a lista é um listbox de options', async () => {
			await abrirLista();
			expect(screen.getByRole('listbox')).toBeInTheDocument();
			expect(screen.getAllByRole('option')).toHaveLength(2);
		});

		it('as setas movem o destaque e o input aponta para ele (aria-activedescendant)', async () => {
			await abrirLista();
			const input = screen.getByRole('combobox');
			expect(input).not.toHaveAttribute('aria-activedescendant');

			await user().keyboard('{ArrowDown}');
			const [primeira, segunda] = screen.getAllByRole('option');
			expect(primeira).toHaveAttribute('aria-selected', 'true');
			expect(input).toHaveAttribute('aria-activedescendant', primeira.id);

			await user().keyboard('{ArrowDown}');
			expect(segunda).toHaveAttribute('aria-selected', 'true');
			expect(input).toHaveAttribute('aria-activedescendant', segunda.id);

			// Circula: da última volta para a primeira.
			await user().keyboard('{ArrowDown}');
			expect(screen.getAllByRole('option')[0]).toHaveAttribute('aria-selected', 'true');

			// E para cima, da primeira vai para a última.
			await user().keyboard('{ArrowUp}');
			expect(screen.getAllByRole('option')[1]).toHaveAttribute('aria-selected', 'true');
		});

		it('Enter escolhe o destacado', async () => {
			const { onPick } = await abrirLista();
			await user().keyboard('{ArrowDown}{ArrowDown}');
			await user().keyboard('{Enter}');
			expect(onPick).toHaveBeenCalledWith(dois[1]);
		});

		it('Enter sem destaque não escolhe ninguém', async () => {
			const { onPick } = await abrirLista();
			await user().keyboard('{Enter}');
			expect(onPick).not.toHaveBeenCalled();
		});

		it('Escape fecha a lista sem deixar o Esc subir para o modal', async () => {
			await abrirLista();
			const subiu = vi.fn();
			window.addEventListener('keydown', subiu);

			await user().keyboard('{Escape}');
			expect(screen.queryByRole('listbox')).toBeNull();
			// O shell do Modal escuta Esc na JANELA: sem parar a propagação, um Esc fecharia a lista
			// e o modal de uma vez.
			expect(subiu).not.toHaveBeenCalled();

			window.removeEventListener('keydown', subiu);
		});
	});
});
