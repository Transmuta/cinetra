import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import OfferSlotModal from './OfferSlotModal.svelte';
import type { Entry, Professional, Slot } from '$lib/waitlist';
import type { AppointmentType } from '$lib/appointment-types';

const professionals: Professional[] = [
	{ id: 'p1', nome: 'Dra. Ana Souza', nome_exibicao: null, crefito: null, cor_indice: 1, segue_horario_clinica: true }
];

const appointmentTypes: AppointmentType[] = [
	{ id: 't1', nome: 'Sessão', sigla: 'SES', duracao_minutos: 50, cor: '#0072B2', icon: 'Activity', grupo: false, capacidade: null, ativo: true }
];

const entry: Entry = {
	id: 'e1',
	prio: 'urgente',
	janela: 'manha',
	obs: null,
	professional_ids: ['p1'],
	dias_na_fila: 5,
	rules: [],
	patient: { id: 'pat1', nome: 'Maria Silva', tel: null, ativo: true, faltas: 0 },
	inserted_at: '2026-07-16T10:00:00Z'
};

// 2026-07-21 é uma terça (dow 2). 09:00 = 540 min.
const slot = (over: Partial<Slot> = {}): Slot => ({
	date: '2026-07-21',
	start: 540,
	dur: 50,
	professional_id: 'p1',
	dow: 2,
	rule_index: null,
	freed: false,
	...over
});

function mockFetch(slots: Slot[]) {
	vi.stubGlobal(
		'fetch',
		vi.fn().mockResolvedValue({ ok: true, json: async () => ({ slots }) } as Response)
	);
}

const base = {
	entry,
	professionals,
	appointmentTypes,
	timezone: 'America/Sao_Paulo',
	papel: 'recepcao' as const,
	onClose: vi.fn()
};

const hidden = (name: string) => document.querySelector<HTMLInputElement>(`input[name="${name}"]`);
const user = () => userEvent.setup();

beforeEach(() => mockFetch([slot()]));
afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('OfferSlotModal — busca e listagem', () => {
	it('abre com o título e o resumo da disponibilidade do paciente', async () => {
		render(OfferSlotModal, { props: base });
		expect(screen.getByRole('dialog', { name: 'Oferecer vaga — Maria' })).toBeInTheDocument();
		// janela "Manhã" · "Qualquer profissional" NÃO — tem preferido p1 → "Ana Souza".
		expect(screen.getByText(/Manhã/)).toBeInTheDocument();
	});

	it('busca as vagas do item no endpoint /fila/[id]/slots', async () => {
		render(OfferSlotModal, { props: base });
		await screen.findByRole('button', { name: /09:00/ });
		expect(fetch).toHaveBeenCalledWith('/fila/e1/slots');
	});

	it('lista o horário livre (m2t) com o profissional', async () => {
		render(OfferSlotModal, { props: base });
		const btn = await screen.findByRole('button', { name: /09:00/ });
		expect(btn).toHaveTextContent('Ana Souza');
	});

	it('vaga que abriu ganha o selo ABRIU', async () => {
		mockFetch([slot({ freed: true })]);
		render(OfferSlotModal, { props: base });
		expect(await screen.findByText('ABRIU')).toBeInTheDocument();
	});

	it('sem vaga compatível, mostra o estado vazio', async () => {
		mockFetch([]);
		render(OfferSlotModal, { props: base });
		expect(await screen.findByText(/Nenhuma vaga compatível/)).toBeInTheDocument();
	});
});

describe('OfferSlotModal — conversão', () => {
	it('clicar numa vaga abre o passo de conversão com o starts_at em UTC', async () => {
		render(OfferSlotModal, { props: base });
		await user().click(await screen.findByRole('button', { name: /09:00/ }));

		// 09:00 em São Paulo é 12:00Z — se sair errado, o agendamento nasce horas fora.
		expect(hidden('starts_at')?.value).toBe('2026-07-21T12:00:00.000Z');
		expect(hidden('professional_id')?.value).toBe('p1');
		expect(hidden('id')?.value).toBe('e1');
		expect(screen.getByLabelText('Tipo de atendimento')).toHaveValue('t1');
	});

	it('o botão Agendar submete o form de conversão', async () => {
		render(OfferSlotModal, { props: base });
		await user().click(await screen.findByRole('button', { name: /09:00/ }));
		const agendar = screen.getByRole('button', { name: 'Agendar' });
		expect(agendar).toHaveAttribute('form', 'fila-converter');
		expect(agendar).toBeEnabled();
	});

	it('Horários volta para a lista de vagas', async () => {
		render(OfferSlotModal, { props: base });
		await user().click(await screen.findByRole('button', { name: /09:00/ }));
		await user().click(screen.getByRole('button', { name: /Horários/ }));
		// De volta à lista: a vaga clicável reaparece.
		expect(screen.getByRole('button', { name: /09:00/ })).toBeInTheDocument();
	});
});

describe('OfferSlotModal — conflito na conversão', () => {
	// O 422 schedule_conflict reaparece com a saída de Encaixe (como no criar da agenda).
	it('schedule_conflict mostra a mensagem e oferece o Encaixe', async () => {
		render(OfferSlotModal, {
			props: {
				...base,
				form: {
					action: 'converter',
					code: 'schedule_conflict',
					error: 'Esse horário sobrepõe outro agendamento.'
				}
			}
		});
		await user().click(await screen.findByRole('button', { name: /09:00/ }));
		expect(screen.getByText('Esse horário sobrepõe outro agendamento.')).toBeInTheDocument();

		const marcar = screen.getByRole('button', { name: /marcar como encaixe/i });
		await user().click(marcar);
		expect(screen.getByLabelText(/encaixe/i)).toBeChecked();
	});

	// Defensivo: o 409 slot_held (reserva de outra pessoa) só mostra quem segura — sem encaixe.
	it('slot_held mostra a mensagem sem oferecer Encaixe', async () => {
		render(OfferSlotModal, {
			props: {
				...base,
				form: {
					action: 'converter',
					code: 'slot_held',
					error: 'Ana está oferecendo este horário.'
				}
			}
		});
		await user().click(await screen.findByRole('button', { name: /09:00/ }));
		expect(screen.getByText('Ana está oferecendo este horário.')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /marcar como encaixe/i })).not.toBeInTheDocument();
	});

	it('profissional não recebe a saída de Encaixe no conflito', async () => {
		render(OfferSlotModal, {
			props: {
				...base,
				papel: 'profissional' as const,
				form: { action: 'converter', code: 'schedule_conflict', error: 'Conflito.' }
			}
		});
		await user().click(await screen.findByRole('button', { name: /09:00/ }));
		expect(screen.queryByRole('button', { name: /marcar como encaixe/i })).not.toBeInTheDocument();
	});
});
