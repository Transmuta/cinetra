import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup, waitFor, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import PackageCreateModal from './PackageCreateModal.svelte';
import type { AppointmentType } from '$lib/appointment-types';
import type { PreviewResult } from '$lib/packages';

const tipo = (over: Partial<AppointmentType> = {}): AppointmentType => ({
	id: 't1',
	nome: 'Pilates',
	sigla: 'PIL',
	duracao_minutos: 50,
	cor: '#0FB5A6',
	icon: 'Activity',
	grupo: false,
	capacidade: null,
	ativo: true,
	...over
});

const profs = [{ id: 'pr1', nome: 'Dra. Ana' }];

// Uma prévia limpa (2 ocorrências, sem bloqueio).
const okPreview: PreviewResult = {
	ocorrencias: [
		{
			data: '2026-07-27',
			hhmm: '08:00',
			feriado: false,
			issue: 'ok',
			bloqueia: false
		},
		{
			data: '2026-07-29',
			hhmm: '09:00',
			feriado: false,
			issue: 'ok',
			bloqueia: false
		}
	],
	bloqueios: 0,
	pode_salvar: true
};

// mock global fetch: a rota da prévia e a da criação.
function mockFetch(handlers: {
	preview?: (body: unknown) => { status?: number; json: unknown };
	create?: (body: unknown) => { status?: number; json: unknown };
}) {
	return vi.fn(async (url: string, init?: RequestInit) => {
		const body = init?.body ? JSON.parse(String(init.body)) : {};
		const isPreview = url.endsWith('/preview');
		const h = isPreview ? handlers.preview : handlers.create;
		const out = h ? h(body) : { json: {} };
		const status = out.status ?? (isPreview ? 200 : 201);
		return {
			ok: status >= 200 && status < 300,
			status,
			json: async () => out.json
		} as unknown as Response;
	});
}

function open(over: Partial<Record<string, unknown>> = {}) {
	const onCreated = vi.fn();
	const onClose = vi.fn();
	const utils = render(PackageCreateModal, {
		patientId: 'pac1',
		professionals: profs,
		appointmentTypes: [tipo()],
		onClose,
		onCreated,
		today: '2026-07-24',
		...over
	});
	return { onCreated, onClose, ...utils };
}

// Preenche a grade mínima: marca Segunda (dow 1) — o horário nasce às 08:00.
async function marcaSegunda(user: ReturnType<typeof userEvent.setup>) {
	await user.click(screen.getByRole('button', { name: 'Seg', pressed: false }));
}

beforeEach(() => {
	vi.stubGlobal('fetch', mockFetch({ preview: () => ({ json: { preview: okPreview } }) }));
});
afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('PackageCreateModal', () => {
	it('nasce incompleto: sem dia marcado, a prévia pede para preencher', () => {
		open();
		expect(screen.getByText(/preencha o tipo/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeDisabled();
	});

	it('sugere o nome a partir do tipo + total', () => {
		open();
		expect(screen.getByDisplayValue('Pilates 10')).toBeInTheDocument();
	});

	it('marcar um dia dispara a prévia ao vivo e habilita criar', async () => {
		const user = userEvent.setup();
		open();
		await marcaSegunda(user);

		await waitFor(() => expect(fetch).toHaveBeenCalled());
		// a chamada foi para a rota de prévia do paciente do path
		const url = (fetch as ReturnType<typeof vi.fn>).mock.calls[0][0];
		expect(url).toBe('/pacientes/pac1/pacotes/preview');

		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());
		// desenha as ocorrências
		expect(screen.getByText('08:00')).toBeInTheDocument();
		expect(screen.getByText('09:00')).toBeInTheDocument();
	});

	it('criar com sucesso chama onCreated', async () => {
		const user = userEvent.setup();
		vi.stubGlobal(
			'fetch',
			mockFetch({
				preview: () => ({ json: { preview: okPreview } }),
				create: () => ({
					status: 201,
					json: { ok: true, package: { id: 'k1' } }
				})
			})
		);
		const { onCreated } = open();
		await marcaSegunda(user);
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());

		await user.click(screen.getByRole('button', { name: 'Criar pacote' }));
		await waitFor(() => expect(onCreated).toHaveBeenCalledOnce());
	});

	it('bloqueio mole (conflito) troca o botão para "Agendar mesmo assim" e envia forcar', async () => {
		const conflito: PreviewResult = {
			ocorrencias: [
				{
					data: '2026-07-27',
					hhmm: '08:00',
					feriado: false,
					issue: 'conflito',
					bloqueia: true
				}
			],
			bloqueios: 1,
			pode_salvar: false
		};
		let createBody: { forcar?: boolean } = {};
		const user = userEvent.setup();
		vi.stubGlobal(
			'fetch',
			mockFetch({
				preview: () => ({ json: { preview: conflito } }),
				create: (body) => {
					createBody = body as { forcar?: boolean };
					return { status: 201, json: { ok: true, package: { id: 'k1' } } };
				}
			})
		);
		const { onCreated } = open();
		await marcaSegunda(user);

		const forcarBtn = await screen.findByRole('button', {
			name: 'Agendar mesmo assim'
		});
		expect(screen.getByText(/esbarram no calendário/i)).toBeInTheDocument();
		await waitFor(() => expect(forcarBtn).toBeEnabled());

		await user.click(forcarBtn);
		await waitFor(() => expect(onCreated).toHaveBeenCalledOnce());
		expect(createBody.forcar).toBe(true);
	});

	it('bloqueio duro (fora do expediente) trava o salvar — sem "agendar mesmo assim"', async () => {
		const fora: PreviewResult = {
			ocorrencias: [
				{
					data: '2026-07-27',
					hhmm: '08:00',
					feriado: false,
					issue: 'fora_expediente',
					bloqueia: true
				}
			],
			bloqueios: 1,
			pode_salvar: false
		};
		const user = userEvent.setup();
		vi.stubGlobal('fetch', mockFetch({ preview: () => ({ json: { preview: fora } }) }));
		open();
		await marcaSegunda(user);

		// exato/minúsculo casa só o <strong> do aviso (o chip da lista é "Fora do expediente")
		await screen.findByText('fora do expediente');
		expect(screen.queryByRole('button', { name: 'Agendar mesmo assim' })).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeDisabled();
	});

	it('erro na criação mostra a mensagem e mantém o modal aberto', async () => {
		const user = userEvent.setup();
		vi.stubGlobal(
			'fetch',
			mockFetch({
				preview: () => ({ json: { preview: okPreview } }),
				create: () => ({
					status: 500,
					json: { ok: false, error: 'Deu ruim.' }
				})
			})
		);
		const { onCreated } = open();
		await marcaSegunda(user);
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());

		await user.click(screen.getByRole('button', { name: 'Criar pacote' }));
		await screen.findByText('Deu ruim.');
		expect(onCreated).not.toHaveBeenCalled();
	});

	it('prévia que falha (null) mostra o aviso e não deixa criar', async () => {
		const user = userEvent.setup();
		vi.stubGlobal(
			'fetch',
			mockFetch({ preview: () => ({ status: 500, json: { preview: null } }) })
		);
		open();
		await marcaSegunda(user);
		await screen.findByText(/não foi possível calcular a prévia/i);
		expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeDisabled();
	});

	it('re-render com a série inalterada NÃO re-busca a prévia (guard anti-loop)', async () => {
		const user = userEvent.setup();
		const { rerender } = open();
		await marcaSegunda(user);
		await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));

		// A casca tem tempo real: o `+layout` reconecta e re-renderiza, passando NOVAS referências
		// de props (mesma lista de tipos). Sem o guard por payload, cada re-render re-buscava a
		// prévia para sempre e travava o botão. Aqui a série não mudou → nenhuma busca nova.
		await rerender({ appointmentTypes: [tipo()] });
		await rerender({ appointmentTypes: [tipo()] });
		await new Promise((r) => setTimeout(r, 350));
		expect(fetch).toHaveBeenCalledTimes(1);
	});

	it('Cancelar chama onClose', async () => {
		const user = userEvent.setup();
		const { onClose } = open();
		await user.click(screen.getByRole('button', { name: 'Cancelar' }));
		expect(onClose).toHaveBeenCalledOnce();
	});

	it('feriado aparece como informativo, não como bloqueio', async () => {
		const feriado: PreviewResult = {
			ocorrencias: [
				{
					data: '2026-07-27',
					hhmm: '08:00',
					feriado: true,
					issue: 'feriado',
					bloqueia: false
				},
				{
					data: '2026-07-29',
					hhmm: '08:00',
					feriado: false,
					issue: 'ok',
					bloqueia: false
				}
			],
			bloqueios: 0,
			pode_salvar: true
		};
		const user = userEvent.setup();
		vi.stubGlobal('fetch', mockFetch({ preview: () => ({ json: { preview: feriado } }) }));
		open();
		await marcaSegunda(user);
		const lista = await screen.findByRole('list');
		expect(within(lista).getByText(/feriado/i)).toBeInTheDocument();
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());
	});
});
