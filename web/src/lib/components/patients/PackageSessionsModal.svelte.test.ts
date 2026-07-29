import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import PackageSessionsModal from './PackageSessionsModal.svelte';
import type { Package } from '$lib/packages';

const pkg: Package = {
	id: 'k1',
	nome: 'Pilates 10',
	status: 'ativo',
	total: 4,
	usadas: 2,
	restantes: 2,
	acabando: true,
	falta_punitiva: true,
	cor: '#0FB5A6',
	data_inicio: '2026-07-20',
	appointment_type_id: 't1',
	grade: { dows: [1], horarios: { '1': '08:00' }, professional_id: 'pr1' }
};

const sessoes = [
	{
		attendance_id: 'a1',
		appointment_id: 'p1',
		starts_at: '2026-07-20T11:00:00Z',
		estado: 'concluida'
	},
	{ attendance_id: 'a2', appointment_id: 'p2', starts_at: '2026-07-27T11:00:00Z', estado: 'falta' },
	{
		attendance_id: 'a3',
		appointment_id: 'p3',
		starts_at: '2026-08-03T11:00:00Z',
		estado: 'proxima'
	},
	{
		attendance_id: 'a4',
		appointment_id: 'p4',
		starts_at: '2026-08-10T11:00:00Z',
		estado: 'agendada'
	}
];

function mockFetch(resposta: { ok?: boolean; body?: unknown }) {
	return vi.fn(async () => ({
		ok: resposta.ok ?? true,
		status: resposta.ok === false ? 500 : 200,
		json: async () => resposta.body ?? { sessions: sessoes }
	})) as unknown as typeof fetch;
}

function abrir(over: Record<string, unknown> = {}) {
	const onClose = vi.fn();
	render(PackageSessionsModal, {
		pkg,
		patientId: 'pac1',
		titulo: 'Pilates Solo',
		onClose,
		...over
	});
	return { onClose };
}

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('PackageSessionsModal', () => {
	it('busca a trilha do pacote daquele paciente', async () => {
		const f = mockFetch({});
		vi.stubGlobal('fetch', f);
		abrir();

		await waitFor(() => expect(f).toHaveBeenCalled());
		expect((f as unknown as { mock: { calls: string[][] } }).mock.calls[0][0]).toBe(
			'/pacientes/pac1/pacotes/k1/sessoes'
		);
	});

	it('lista cada sessão com o estado — é o que o contador não diz', async () => {
		vi.stubGlobal('fetch', mockFetch({}));
		abrir();

		expect(await screen.findByText('Concluída')).toBeInTheDocument();
		expect(screen.getByText('Falta')).toBeInTheDocument();
		expect(screen.getByText('Próxima')).toBeInTheDocument();
		expect(screen.getByText('Agendada')).toBeInTheDocument();
	});

	it('mostra o contador do pacote e o nome do tipo', async () => {
		vi.stubGlobal('fetch', mockFetch({}));
		abrir();

		expect(screen.getByText('Pilates Solo')).toBeInTheDocument();
		expect(screen.getByText('2/4')).toBeInTheDocument();
	});

	it('série ainda não materializada explica o vazio (o job roda em segundo plano)', async () => {
		vi.stubGlobal('fetch', mockFetch({ body: { sessions: [] } }));
		abrir();

		expect(await screen.findByText(/segundo plano/i)).toBeInTheDocument();
	});

	it('falha na busca vira aviso, não tela em branco', async () => {
		vi.stubGlobal('fetch', mockFetch({ ok: false }));
		abrir();

		expect(await screen.findByText(/não foi possível carregar/i)).toBeInTheDocument();
	});

	// Dois "Fechar": o × do cabeçalho do Modal e o botão do rodapé. O do rodapé é o último.
	it('Fechar chama onClose', async () => {
		vi.stubGlobal('fetch', mockFetch({}));
		const { onClose } = abrir();

		const botoes = screen.getAllByRole('button', { name: 'Fechar' });
		await userEvent.click(botoes[botoes.length - 1]);
		expect(onClose).toHaveBeenCalledOnce();
	});
});
