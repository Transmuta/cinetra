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
		me: { papel: 'owner' },
		...over
	} as never;
}

// Stub de fetch por URL: `/fila/slots` devolve o mapa de vagas; o resto (token) degrada.
function mockSlots(byEntry: Record<string, Slot[]>) {
	vi.stubGlobal(
		'fetch',
		vi.fn((url: string) =>
			url === '/fila/slots'
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
});
