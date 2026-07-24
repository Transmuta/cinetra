import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';

// A camada de "vagas" enriquece a lista por um GET em lote (`/fila/slots`) após render. Os efeitos
// da página (token de tempo real + vagas) fazem `fetch`; aqui o stub decide o que cada URL devolve.
vi.mock('$app/navigation', () => ({ goto: vi.fn(), invalidate: vi.fn(), invalidateAll: vi.fn() }));
vi.mock('$app/forms', () => ({ deserialize: vi.fn() }));
vi.mock('$app/state', () => ({ page: { url: new URL('http://localhost/fila') } }));
// Sem token de tempo real, `connectWaitlist` nunca roda — mas mockamos para não tocar o phoenix.
vi.mock('$lib/realtime', () => ({ connectWaitlist: () => () => {} }));

import Page from './+page.svelte';
import type { Entry, Slot } from '$lib/waitlist';

const slot = (over: Partial<Slot> = {}): Slot => ({
	date: '2026-07-21',
	start: 540, // 09:00
	dur: 50,
	professional_id: 'p1',
	dow: 2,
	rule_index: null,
	freed: false,
	...over
});

function entry(over: Partial<Entry> = {}): Entry {
	return {
		id: 'e1',
		prio: 'urgente',
		janela: 'qualquer',
		obs: null,
		professional_ids: ['p1'],
		dias_na_fila: 2,
		rules: [],
		patient: { id: 'pat1', nome: 'Maria Silva', tel: null, ativo: true, faltas: 0 },
		inserted_at: '2026-07-19T10:00:00Z',
		...over
	};
}

function data(over: Record<string, unknown> = {}) {
	return {
		waitlist: [entry()],
		professionals: [
			{ id: 'p1', nome: 'Dra. Ana', nome_exibicao: null, crefito: null, cor_indice: 1, segue_horario_clinica: true }
		],
		appointmentTypes: [],
		timezone: 'America/Sao_Paulo',
		today: '2026-07-21',
		prio: 'todas',
		// F4: reservas vivas (vazio por padrão — o caminho normal é ninguém oferecendo).
		holds: [],
		// F6: a fila é paginada — o load sempre entrega o recorte e a página corrente.
		pageInfo: { limit: 50, offset: 0, total: 1, more: false },
		counts: { todas: 1, urgente: 0, alta: 0, normal: 1, baixa: 0 },
		current: 1,
		me: { papel: 'owner' },
		...over
	} as never;
}

// Stub de fetch por URL: `/fila/slots` devolve o mapa de vagas; o resto (token) degrada.
function mockSlots(byEntry: Record<string, Slot[]>) {
	vi.stubGlobal(
		'fetch',
		vi.fn((url: string) =>
			url.startsWith('/fila/slots')
				? Promise.resolve({ ok: true, json: async () => ({ slots_by_entry: byEntry }) } as Response)
				: Promise.resolve({ ok: false, json: async () => ({}) } as Response)
		)
	);
}

beforeEach(() => mockSlots({}));
afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('Fila — camada de vagas na lista', () => {
	it('mostra o paciente (linha desktop + cartão mobile)', () => {
		const { getAllByText } = render(Page, { props: { data: data(), form: null } });
		expect(getAllByText('Maria Silva')).toHaveLength(2);
	});

	it('com vaga, a regra/janela vira chip de oferta com data e horário', async () => {
		mockSlots({ e1: [slot()] });
		const { findAllByTitle } = render(Page, { props: { data: data(), form: null } });
		// Título do chip de vaga casada: "Oferecer ter 21/07 às 09:00".
		const chips = await findAllByTitle(/Oferecer ter 21\/07 às 09:00/);
		expect(chips.length).toBeGreaterThan(0);
	});

	it('vaga que abriu (freed) ganha o selo ABRIU', async () => {
		mockSlots({ e1: [slot({ freed: true })] });
		const { findAllByText } = render(Page, { props: { data: data(), form: null } });
		expect((await findAllByText('ABRIU')).length).toBeGreaterThan(0);
	});

	it('sem vaga compatível, mostra o marcador na célula', async () => {
		mockSlots({ e1: [] });
		const { findAllByText } = render(Page, { props: { data: data(), form: null } });
		expect((await findAllByText(/sem vaga compatível/)).length).toBeGreaterThan(0);
	});

	it('regra :data no passado fica riscada (line-through)', async () => {
		const past = entry({ rules: [{ tipo: 'data', dows: [], data: '2026-07-10', periodos: [['09:00', '11:00']] }] });
		mockSlots({ e1: [] });
		const { findAllByText } = render(Page, { props: { data: data({ waitlist: [past] }), form: null } });
		const [chip] = await findAllByText(/10\/07/);
		expect(chip).toHaveClass('line-through');
	});

	// F6: o rodapé só aparece quando há mais de uma página — a fila curta continua parecendo o
	// que era antes de paginar.
	it('sem segunda página, não mostra o rodapé de paginação', () => {
		mockSlots({ e1: [] });
		const { queryByText } = render(Page, { props: { data: data(), form: null } });
		expect(queryByText('Próxima')).not.toBeInTheDocument();
	});

	it('com mais páginas, mostra o rótulo "X–Y de Z" e a navegação', () => {
		mockSlots({ e1: [] });
		const { getByText } = render(Page, {
			props: {
				data: data({ pageInfo: { limit: 50, offset: 0, total: 120, more: true } }),
				form: null
			}
		});

		expect(getByText('1–1 de 120')).toBeInTheDocument();
		expect(getByText('Próxima')).toBeInTheDocument();
	});

	// F4: a vaga que outra pessoa já está oferecendo é marcada — é o aviso que evita duas
	// recepções correndo para a mesma vaga (e tomando 409 no fim).
	it('vaga já reservada por outra pessoa vira chip com o aviso de quem segura', async () => {
		mockSlots({ e1: [slot()] });

		const { findAllByTitle } = render(Page, {
			props: {
				data: data({
					holds: [
						{
							id: 'h1',
							professional_id: 'p1',
							waitlist_entry_id: 'e1',
							starts_at: '2026-07-21T12:00:00Z',
							ends_at: '2026-07-21T12:50:00Z',
							expires_at: '2026-07-21T12:10:00Z',
							held_by: { id: 'u9', nome: 'Ana' }
						}
					]
				}),
				form: null
			}
		});

		const chips = await findAllByTitle(/Ana está oferecendo esta vaga/);
		expect(chips.length).toBeGreaterThan(0);
	});

	// O outro lado do mesmo achado: a tela tem de PEDIR a janela filtrada.
	it('pede as vagas com o mesmo filtro da lista', async () => {
		mockSlots({ e1: [] });
		render(Page, { props: { data: data({ prio: 'baixa' }), form: null } });

		await vi.waitFor(() => {
			const chamadas = (globalThis.fetch as unknown as { mock: { calls: unknown[][] } }).mock.calls;
			expect(chamadas.some((c) => String(c[0]).includes('prio=baixa'))).toBe(true);
		});
	});
});
