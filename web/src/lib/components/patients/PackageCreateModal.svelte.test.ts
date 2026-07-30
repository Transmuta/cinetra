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
		expect(screen.getByText(/complete o tipo/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeDisabled();
	});

	// doc 69 §8: "Nome" e "Cor" saíram do formulário. O pacote É o tipo de atendimento — que já tem
	// nome, sigla, duração e cor cadastrados. Eram os dois primeiros campos da tela, e as duas
	// decisões sem consequência que o usuário entendesse.
	it('não pede nome nem cor — o pacote é identificado pelo tipo', () => {
		open();
		expect(screen.queryByLabelText(/nome do pacote/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/^Cor$/)).not.toBeInTheDocument();
	});

	it('envia o nome e a cor DERIVADOS do tipo (o backend os exige)', async () => {
		const user = userEvent.setup();
		let corpo: { nome?: string; cor?: string } = {};
		vi.stubGlobal(
			'fetch',
			mockFetch({
				preview: () => ({ json: { preview: okPreview } }),
				create: (body) => {
					corpo = body as { nome?: string; cor?: string };
					return { status: 201, json: { ok: true, package: { id: 'k1' } } };
				}
			})
		);
		open();
		await marcaSegunda(user);
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());
		await user.click(screen.getByRole('button', { name: 'Criar pacote' }));

		await waitFor(() => expect(corpo.nome).toBe('Pilates 10'));
		expect(corpo.cor).toBe('#0FB5A6');
	});

	// O servidor tem teto próprio (120) e recusaria com a mensagem do Ash, em inglês. A tela recusa
	// antes, na faixa do produto — ver `PACKAGE_MAX_TOTAL` (doc 43 §7).
	it('total acima do teto desabilita criar, em vez de deixar o 422 do servidor aparecer', async () => {
		const user = userEvent.setup();
		open();
		await marcaSegunda(user);
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());

		const total = screen.getByLabelText('Sessões');
		await user.clear(total);
		await user.type(total, '500');

		await waitFor(() =>
			expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeDisabled()
		);
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
		// desenha as ocorrências como chips de data (o horário vai no title, não repetido 60 vezes)
		const serie = screen.getByRole('list', { name: /série/i });
		expect(within(serie).getByText('27/07')).toBeInTheDocument();
		expect(within(serie).getByText('29/07')).toBeInTheDocument();
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
		expect(screen.getByText(/horário com conflito/i)).toBeInTheDocument();
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

	// ---- doc 69 §8: o formulário reorganizado ----

	it('a data de início não aceita o passado (B1.5)', () => {
		open();
		expect(screen.getByLabelText(/começa em/i)).toHaveAttribute('min', '2026-07-24');
	});

	it('diz POR QUE o botão está desabilitado, em vez de só apagar (B1.6)', async () => {
		const user = userEvent.setup();
		open();

		// sem dia marcado: falta a grade
		expect(screen.getByText(/marque ao menos um dia/i)).toBeInTheDocument();

		// com dia marcado e prévia pronta, o motivo some
		await marcaSegunda(user);
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());
		expect(screen.queryByText(/marque ao menos um dia/i)).not.toBeInTheDocument();
	});

	it('total acima do teto explica o limite (B1.6)', async () => {
		const user = userEvent.setup();
		open();
		await marcaSegunda(user);

		const total = screen.getByLabelText('Sessões');
		await user.clear(total);
		await user.type(total, '500');

		await waitFor(() => expect(screen.getByText(/no máximo 60 sessões/i)).toBeInTheDocument());
	});

	it('o stepper soma e subtrai sessões', async () => {
		const user = userEvent.setup();
		open();
		await user.click(screen.getByRole('button', { name: /mais uma sessão/i }));
		expect(screen.getByLabelText('Sessões')).toHaveValue(11);

		await user.click(screen.getByRole('button', { name: /uma sessão a menos/i }));
		expect(screen.getByLabelText('Sessões')).toHaveValue(10);
	});

	it('resume a série em uma frase: quantas e de quando a quando', async () => {
		const user = userEvent.setup();
		open();
		await marcaSegunda(user);
		// as 2 ocorrências da prévia limpa: 27/07 → 29/07
		expect(await screen.findByText(/2 sessões · 27\/07 → 29\/07/)).toBeInTheDocument();
	});

	it('o resumo conta o feriado pulado e diz que a série se estendeu', async () => {
		const feriado: PreviewResult = {
			ocorrencias: [
				{ data: '2026-07-27', hhmm: '08:00', feriado: true, issue: 'feriado', bloqueia: false },
				{ data: '2026-07-29', hhmm: '08:00', feriado: false, issue: 'ok', bloqueia: false }
			],
			bloqueios: 0,
			pode_salvar: true
		};
		const user = userEvent.setup();
		vi.stubGlobal('fetch', mockFetch({ preview: () => ({ json: { preview: feriado } }) }));
		open();
		await marcaSegunda(user);
		expect(await screen.findByText(/1 feriado pulado/i)).toBeInTheDocument();
	});

	it('os problemas ganham uma lista própria, com o motivo de cada dia', async () => {
		const conflito: PreviewResult = {
			ocorrencias: [
				{ data: '2026-07-27', hhmm: '08:00', feriado: false, issue: 'ok', bloqueia: false },
				{ data: '2026-07-29', hhmm: '08:00', feriado: false, issue: 'conflito', bloqueia: true }
			],
			bloqueios: 1,
			pode_salvar: false
		};
		const user = userEvent.setup();
		vi.stubGlobal('fetch', mockFetch({ preview: () => ({ json: { preview: conflito } }) }));
		open();
		await marcaSegunda(user);

		const problemas = await screen.findByRole('list', { name: /conflito/i });
		// só o dia problemático entra na lista — não os 2
		expect(within(problemas).getAllByRole('listitem')).toHaveLength(1);
		expect(within(problemas).getByText(/29\/07/)).toBeInTheDocument();
		expect(within(problemas).getByText(/Conflito de horário/)).toBeInTheDocument();
	});

	it('"igualar horários" só aparece com 2+ dias e propaga o primeiro horário', async () => {
		const user = userEvent.setup();
		open();
		expect(screen.queryByRole('button', { name: /igualar/i })).not.toBeInTheDocument();

		await marcaSegunda(user);
		await user.click(screen.getByRole('button', { name: 'Qua', pressed: false }));
		await user.clear(screen.getByLabelText(/horário de Seg/i));
		await user.type(screen.getByLabelText(/horário de Seg/i), '10:30');

		await user.click(screen.getByRole('button', { name: /igualar/i }));
		expect(screen.getByLabelText(/horário de Qua/i)).toHaveValue('10:30');
	});

	it('a falta punitiva avisa que a escolha não muda depois', () => {
		open();
		expect(screen.getByText(/não muda depois/i)).toBeInTheDocument();
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
		const lista = await screen.findByRole('list', { name: /série/i });
		expect(within(lista).getByTitle(/feriado/i)).toBeInTheDocument();
		await waitFor(() => expect(screen.getByRole('button', { name: 'Criar pacote' })).toBeEnabled());
	});
});
