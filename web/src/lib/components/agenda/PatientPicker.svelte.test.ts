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
});
