import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import DayGrid from './DayGrid.svelte';
import type { Appointment } from '$lib/agenda';

const professionals = [
	{
		id: 'p1',
		nome: 'Dra. Ana Souza',
		nome_exibicao: null,
		crefito: 'CREFITO-3 12345',
		cor_indice: 1,
		segue_horario_clinica: true
	},
	{
		id: 'p2',
		nome: 'Dr. Bruno Lima',
		nome_exibicao: null,
		crefito: 'CREFITO-3 54321',
		cor_indice: 2,
		segue_horario_clinica: true
	}
];

const appointmentTypes = [
	{
		id: 't1',
		nome: 'Sessão',
		sigla: 'SES',
		duracao_minutos: 50,
		cor: '#0072B2',
		icon: 'Activity',
		grupo: false,
		capacidade: null,
		ativo: true
	}
];

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z', // 08:00 em São Paulo
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		package_id: null,
		version: 1,
		created_by_id: null,
		patient_ids: ['pat1'],
		...over
	};
}

const base = {
	date: '2026-07-20',
	today: '2026-07-20',
	timezone: 'America/Sao_Paulo',
	agora: '2026-07-20T14:42:00Z', // 11:42 local — o "agora" do protótipo
	appointments: [appt()],
	professionals,
	appointmentTypes,
	availability: [
		{
			professional_id: 'p1',
			date: '2026-07-20',
			periods: [
				['08:00', '12:00'],
				['13:00', '18:00']
			] as Array<[string, string]>
		},
		{
			professional_id: 'p2',
			date: '2026-07-20',
			periods: [['09:00', '17:00']] as Array<[string, string]>
		}
	],
	patientNames: { pat1: 'Maria Silva' },
	hidden: [] as string[],
	onEmptyClick: () => {},
	onSelect: () => {},
	onShowAll: () => {}
};

describe('DayGrid — colunas', () => {
	it('uma coluna por profissional visível', () => {
		render(DayGrid, { props: base });
		expect(screen.getByText('Dra. Ana Souza')).toBeInTheDocument();
		expect(screen.getByText('Dr. Bruno Lima')).toBeInTheDocument();
	});

	it('profissional oculto some da grade', () => {
		render(DayGrid, { props: { ...base, hidden: ['p2'] } });
		expect(screen.getByText('Dra. Ana Souza')).toBeInTheDocument();
		expect(screen.queryByText('Dr. Bruno Lima')).not.toBeInTheDocument();
	});

	it('desenha os agendamentos do dia', () => {
		render(DayGrid, { props: base });
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
	});
});

// O estado vazio que o doc 25 §6 avisa ser fácil de esquecer, porque só aparece por ação do
// usuário (ocultar todo mundo na sidebar).
describe('DayGrid — estado vazio', () => {
	const vazio = { ...base, hidden: ['p1', 'p2'] };

	it('todos ocultos → mensagem, explicação e saída', () => {
		render(DayGrid, { props: vazio });
		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
		expect(
			screen.getByText('Ative ao menos um profissional na barra lateral para ver a agenda.')
		).toBeInTheDocument();
	});

	it('"Mostrar todos" devolve a agenda', async () => {
		const onShowAll = vi.fn();
		render(DayGrid, { props: { ...vazio, onShowAll } });
		await userEvent.click(screen.getByRole('button', { name: 'Mostrar todos' }));
		expect(onShowAll).toHaveBeenCalled();
	});

	it('clínica sem profissional nenhum cai no mesmo estado vazio', () => {
		render(DayGrid, { props: { ...base, professionals: [], appointments: [] } });
		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
	});

	it('dia sem agendamento renderiza a grade, sem mensagem (fiel ao protótipo)', () => {
		render(DayGrid, { props: { ...base, appointments: [] } });
		expect(screen.queryByText('Nenhum profissional em exibição')).not.toBeInTheDocument();
		expect(screen.getByText('Dra. Ana Souza')).toBeInTheDocument();
	});
});

// A12: a faixa vertical sai do EXPEDIENTE, não de 08–18 cravado.
describe('DayGrid — faixa vertical derivada', () => {
	// A busca é escopada no gutter: "08:00" também aparece DENTRO do bloco (é a hora de
	// início do agendamento), e um getByText solto acharia dois elementos.
	it('as horas desenhadas vêm do expediente das colunas', () => {
		render(DayGrid, { props: base });
		const gutter = within(screen.getByTestId('hour-gutter'));
		expect(gutter.getByText('08:00')).toBeInTheDocument();
		expect(gutter.getByText('17:00')).toBeInTheDocument();
		expect(gutter.getByText('18:00')).toBeInTheDocument();
	});

	it('expediente que começa às 07:00 desenha a partir das 07:00', () => {
		render(DayGrid, {
			props: {
				...base,
				availability: [
					{ professional_id: 'p1', date: '2026-07-20', periods: [['07:00', '12:00']] },
					{ professional_id: 'p2', date: '2026-07-20', periods: [['09:00', '17:00']] }
				]
			}
		});
		expect(within(screen.getByTestId('hour-gutter')).getByText('07:00')).toBeInTheDocument();
	});

	// Sem isso, um encaixe fora do expediente ficaria fora da área desenhada — invisível.
	it('a faixa ESTENDE para conter agendamento fora do expediente', () => {
		render(DayGrid, {
			props: {
				...base,
				// 06:30 local
				appointments: [appt({ starts_at: '2026-07-20T09:30:00Z', ends_at: '2026-07-20T10:20:00Z' })]
			}
		});
		expect(within(screen.getByTestId('hour-gutter')).getByText('06:00')).toBeInTheDocument();
	});
});

describe('DayGrid — hachura do fechado', () => {
	it('hachura o buraco REAL entre períodos, por coluna', () => {
		render(DayGrid, { props: base });
		const holes = document.querySelectorAll('[data-closed]');
		expect(holes.length).toBeGreaterThan(0);
	});

	// GAP-05: no protótipo o "ALMOÇO" era 12–13 decorativo e IGUAL em todas as colunas.
	// Aqui p1 para 12–13 e p2 só começa 09:00 — as colunas ficam diferentes, e é o correto.
	it('colunas com expedientes diferentes hachuram em lugares diferentes', () => {
		render(DayGrid, { props: base });
		const cols = document.querySelectorAll('[data-column]');
		const p1 = cols[0].querySelectorAll('[data-closed]').length;
		const p2 = cols[1].querySelectorAll('[data-closed]').length;
		expect(p1).not.toBe(p2);
	});

	it('profissional sem expediente no dia tem a coluna inteira hachurada', () => {
		render(DayGrid, {
			props: {
				...base,
				availability: [
					{ professional_id: 'p1', date: '2026-07-20', periods: [['08:00', '18:00']] },
					{
						professional_id: 'p2',
						date: '2026-07-20',
						periods: [],
						closed_reason: 'folga_semanal' as const
					}
				]
			}
		});
		const cols = document.querySelectorAll('[data-column]');
		expect(cols[1].querySelectorAll('[data-closed]').length).toBe(1);
	});
});

describe('DayGrid — linha do agora', () => {
	it('aparece quando o dia exibido é hoje', () => {
		render(DayGrid, { props: base });
		expect(screen.getByTestId('now-line')).toBeInTheDocument();
		// 14:42Z = 11:42 em São Paulo.
		expect(screen.getByText('11:42')).toBeInTheDocument();
	});

	it('não aparece em outro dia', () => {
		render(DayGrid, { props: { ...base, date: '2026-07-21', today: '2026-07-20' } });
		expect(screen.queryByTestId('now-line')).not.toBeInTheDocument();
	});
});

describe('DayGrid — criar em vazio', () => {
	it('clicar no corpo da coluna abre o modal com profissional e hora', async () => {
		const onEmptyClick = vi.fn();
		render(DayGrid, { props: { ...base, onEmptyClick } });

		const body = document.querySelectorAll('[data-column-body]')[0] as HTMLElement;
		// jsdom não faz layout: getBoundingClientRect devolve zeros, então o clique cai no
		// topo da faixa. O que importa aqui é o CONTRATO (quem chamou, com qual coluna).
		await userEvent.click(body);

		expect(onEmptyClick).toHaveBeenCalledTimes(1);
		const arg = onEmptyClick.mock.calls[0][0];
		expect(arg.professional_id).toBe('p1');
		expect(arg.hora).toMatch(/^\d{2}:\d{2}$/);
	});

	it('clicar num agendamento seleciona, e NÃO abre o criar-em-vazio', async () => {
		const onEmptyClick = vi.fn();
		const onSelect = vi.fn();
		render(DayGrid, { props: { ...base, onEmptyClick, onSelect } });

		await userEvent.click(screen.getByRole('button', { name: /Maria Silva/ }));
		expect(onSelect).toHaveBeenCalledWith('a1');
		expect(onEmptyClick).not.toHaveBeenCalled();
	});
});

// Doc 25 §7: cancelado não conflita — e, portanto, também não disputa espaço. O `conflictIds`
// já filtrava o cancelado; o `layoutAppts` não conhecia status e alargava a coluna sozinho.
// O sintoma era mudo: 304px de coluna sem o triângulo de conflito acender.
describe('DayGrid — cancelado não alarga a coluna (doc 25 §7)', () => {
	const cancelado = appt({
		id: 'a2',
		status: 'cancelado',
		starts_at: '2026-07-20T11:20:00Z',
		ends_at: '2026-07-20T12:10:00Z',
		patient_ids: ['pat1']
	});

	it('coluna com um vivo e um cancelado sobrepostos fica na largura padrão', () => {
		render(DayGrid, { props: { ...base, appointments: [appt(), cancelado] } });
		const col = document.querySelectorAll('[data-column]')[0] as HTMLElement;
		expect(col.style.minWidth).toBe('210px');
	});

	it('mas o cancelado continua desenhado (riscado, não sumido)', () => {
		render(DayGrid, { props: { ...base, appointments: [appt(), cancelado] } });
		expect(document.querySelectorAll('[data-appt]')).toHaveLength(2);
	});

	it('dois VIVOS sobrepostos continuam alargando a coluna', () => {
		const vivo2 = { ...cancelado, id: 'a3', status: 'agendado' as const };
		render(DayGrid, { props: { ...base, appointments: [appt(), vivo2] } });
		const col = document.querySelectorAll('[data-column]')[0] as HTMLElement;
		expect(col.style.minWidth).toBe('304px');
	});
});
