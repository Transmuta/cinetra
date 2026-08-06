import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import NewAppointmentModal from './NewAppointmentModal.svelte';

const professionals = [
	{
		id: 'p1',
		nome: 'Dra. Ana Souza',
		nome_exibicao: null,
		crefito: 'CREFITO-3 12345',
		cor_indice: 1,
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
	},
	{
		id: 't2',
		nome: 'Pilates',
		sigla: 'PIL',
		duracao_minutos: 50,
		cor: '#0FB5A6',
		icon: 'Users',
		grupo: true,
		capacidade: 4,
		ativo: true
	}
];

const base = {
	date: '2026-07-20',
	timezone: 'America/Sao_Paulo',
	professionals,
	appointmentTypes,
	papel: 'recepcao' as const,
	preset: { professional_id: 'p1', hora: '08:00' },
	onClose: () => {},
	search: vi.fn().mockResolvedValue({ patients: [], total: 0 })
};

const hidden = (name: string) =>
	document.querySelector<HTMLInputElement>(`input[name="${name}"]`);

describe('NewAppointmentModal', () => {
	it('abre com o título do protótipo', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByRole('dialog', { name: 'Novo agendamento' })).toBeInTheDocument();
	});

	it('vem pré-preenchido com o profissional e a hora do clique em vazio', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByLabelText('Profissional')).toHaveValue('p1');
		expect(screen.getByLabelText('Hora')).toHaveValue('08:00');
		expect(screen.getByLabelText('Data')).toHaveValue('2026-07-20');
	});

	// A conversão relógio-da-clínica → instante acontece aqui, com o fuso vindo do servidor.
	// 08:00 em São Paulo é 11:00Z — se isto sair errado, todo agendamento nasce 3h fora.
	it('o starts_at submetido é o instante UTC correspondente ao fuso da clínica', () => {
		render(NewAppointmentModal, { props: base });
		expect(hidden('starts_at')?.value).toBe('2026-07-20T11:00:00.000Z');
	});

	it('trocar a hora recalcula o starts_at', async () => {
		render(NewAppointmentModal, { props: base });
		const hora = screen.getByLabelText('Hora');
		await userEvent.clear(hora);
		await userEvent.type(hora, '14:30');
		expect(hidden('starts_at')?.value).toBe('2026-07-20T17:30:00.000Z');
	});

	it('a hora anda de 15 em 15 (A-D1: sugestão, não regra)', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByLabelText('Hora')).toHaveAttribute('step', '900');
	});

	// A9 / D2: encaixe fura a grade e é de quem responde pela agenda.
	it('recepção vê o interruptor de Encaixe', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByLabelText(/encaixe/i)).toBeInTheDocument();
	});

	it('profissional NÃO vê o interruptor de Encaixe', () => {
		render(NewAppointmentModal, { props: { ...base, papel: 'profissional' as const } });
		expect(screen.queryByLabelText(/encaixe/i)).not.toBeInTheDocument();
	});

	it('tipo de grupo troca o título e mostra a capacidade', async () => {
		render(NewAppointmentModal, { props: base });
		await userEvent.selectOptions(screen.getByLabelText('Tipo'), 't2');
		expect(screen.getByRole('dialog', { name: 'Novo agendamento em grupo' })).toBeInTheDocument();
		expect(screen.getByText(/0\/4/)).toBeInTheDocument();
	});

	// O fluxo que a mudança no `mutate` destravou (A-D2 opção b): o servidor recusou por
	// conflito, e a saída existe — mas só se a UI souber QUAL foi o erro.
	describe('conflito devolvido pelo servidor', () => {
		const comConflito = {
			...base,
			form: {
				action: 'criar',
				code: 'schedule_conflict',
				error: 'Esse horário sobrepõe outro agendamento.'
			}
		};

		it('mostra a mensagem do servidor', () => {
			render(NewAppointmentModal, { props: comConflito });
			expect(screen.getByText('Esse horário sobrepõe outro agendamento.')).toBeInTheDocument();
		});

		it('oferece marcar como Encaixe', async () => {
			render(NewAppointmentModal, { props: comConflito });
			const botao = screen.getByRole('button', { name: /marcar como encaixe/i });
			await userEvent.click(botao);
			expect(screen.getByLabelText(/encaixe/i)).toBeChecked();
		});

		it('para quem não pode criar encaixe, não oferece a saída', () => {
			render(NewAppointmentModal, {
				props: { ...comConflito, papel: 'profissional' as const }
			});
			expect(screen.queryByRole('button', { name: /marcar como encaixe/i })).not.toBeInTheDocument();
		});
	});

	it('erro fora do expediente é mostrado sem oferecer encaixe (encaixe não libera feriado)', () => {
		render(NewAppointmentModal, {
			props: {
				...base,
				form: {
					action: 'criar',
					code: 'outside_business_hours',
					error: 'O profissional não atende nesse horário.'
				}
			}
		});
		expect(screen.getByText('O profissional não atende nesse horário.')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /marcar como encaixe/i })).not.toBeInTheDocument();
	});

	// REGRESSÃO: `/api/appointments` devolve só os tipos ativos e NÃO manda o campo `ativo`
	// (appointments_controller.ex:render_type). Um `.filter(t => t.ativo)` no cliente lia
	// `undefined` e esvaziava o seletor inteiro — bug invisível nos testes que montavam o
	// tipo à mão com `ativo: true`.
	it('tipos vindos da API (sem o campo `ativo`) populam o seletor', () => {
		const semAtivo = appointmentTypes.map(({ ativo, sigla, ...resto }) => resto);
		render(NewAppointmentModal, { props: { ...base, appointmentTypes: semAtivo } });

		const select = screen.getByLabelText('Tipo') as HTMLSelectElement;
		expect(select.options).toHaveLength(2);
		expect(select.options[0].textContent).toContain('Sessão');
	});

	it('o botão de agendar nasce desabilitado enquanto não há paciente', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByRole('button', { name: 'Agendar' })).toBeDisabled();
	});

	it('fecha no Cancelar', async () => {
		const onClose = vi.fn();
		render(NewAppointmentModal, { props: { ...base, onClose } });
		await userEvent.click(screen.getByRole('button', { name: 'Cancelar' }));
		expect(onClose).toHaveBeenCalled();
	});

	// A-D7: o campo pode conter dado clínico e NÃO é prontuário — a UI tem que dizer isso.
	it('a observação avisa que não é prontuário', () => {
		render(NewAppointmentModal, { props: base });
		const obs = screen.getByLabelText(/observação/i);
		expect(obs).toHaveAttribute('maxlength', '500');
		expect(obs.getAttribute('placeholder')).toMatch(/prontuário/i);
	});
});

// ACHADO 3: o modal recriava o markup do `Field` à mão em ~5 lugares, e a cópia JÁ tinha
// divergido — `px-2.5` (10px) contra os `px-[11px]` do Field, e sem os tokens `text-ink` /
// `placeholder:text-faint`. Não é preciosismo: os controles do mesmo formulário ficavam com
// padding diferente e a cor do texto caía no herdado em vez do token do design system.
describe('controles usam o Field do projeto, não uma cópia divergida', () => {
	const controles = ['Profissional', 'Tipo', 'Data', 'Hora', /observação/i] as const;

	it.each(controles.map((c) => [String(c), c] as const))(
		'%s carrega os tokens do Field (px-[11px], text-ink)',
		(_nome, seletor) => {
			render(NewAppointmentModal, { props: base });
			const el = screen.getByLabelText(seletor as string | RegExp);
			expect(el.className).toContain('px-[11px]');
			expect(el.className).toContain('text-ink');
		}
	);

	// O `<select>` continua com nome acessível: trocar o <label> por um <div role="group">
	// resolveria a duplicação e QUEBRARIA o rótulo do controle.
	it('os selects seguem alcançáveis pelo rótulo', () => {
		render(NewAppointmentModal, { props: base });
		expect(screen.getByLabelText('Tipo').tagName).toBe('SELECT');
		expect(screen.getByLabelText('Profissional').tagName).toBe('SELECT');
	});
});
