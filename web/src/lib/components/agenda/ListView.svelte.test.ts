import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import ListView from './ListView.svelte';
import type { Appointment } from '$lib/agenda';

const SP = 'America/Sao_Paulo';

const appt = (over: Partial<Appointment> = {}): Appointment => ({
	id: 'a1',
	// 11:00Z = 08:00 em São Paulo.
	starts_at: '2026-07-20T11:00:00Z',
	ends_at: '2026-07-20T11:50:00Z',
	status: 'agendado',
	encaixe: false,
	obs: null,
	professional_id: 'p1',
	appointment_type_id: 't1',
	package_id: null,
	version: 1,
	created_by_id: null,
	cancel_reason: null,
	falta_justificada: false,
	patient_ids: ['pat1'],
	...over
});

const base = {
	appointments: [appt()],
	professionals: [
		{
			id: 'p1',
			nome: 'Dra. Lima',
			nome_exibicao: null,
			crefito: null,
			cor_indice: 1,
			segue_horario_clinica: true
		},
		{
			id: 'p2',
			nome: 'Dr. Sousa',
			nome_exibicao: null,
			crefito: null,
			cor_indice: 2,
			segue_horario_clinica: true
		}
	],
	appointmentTypes: [
		{
			id: 't1',
			nome: 'Sessão',
			duracao_minutos: 50,
			cor: '#0FB5A6',
			icon: 'Activity',
			grupo: false,
			capacidade: null
		},
		{
			id: 't2',
			nome: 'Pilates',
			duracao_minutos: 50,
			cor: '#0072B2',
			icon: 'Activity',
			grupo: true,
			capacidade: 4
		}
	],
	patientNames: { pat1: 'Maria Silva', pat2: 'João Souza', pat3: 'Ana Paula' },
	timezone: SP,
	onSelect: () => {},
	onShowAll: () => {}
};

describe('ListView', () => {
	it('mostra hora local, paciente e "tipo · profissional"', () => {
		render(ListView, { props: base });
		expect(screen.getByText('08:00')).toBeInTheDocument();
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
		expect(screen.getByText('Sessão · Dra. Lima')).toBeInTheDocument();
	});

	it('ordena por horário', () => {
		render(ListView, {
			props: {
				...base,
				appointments: [
					appt({
						id: 'b',
						starts_at: '2026-07-20T13:00:00Z',
						ends_at: '2026-07-20T13:50:00Z'
					}),
					appt({ id: 'a' })
				]
			}
		});
		const horas = screen.getAllByText(/^\d\d:\d\d$/).map((e) => e.textContent);
		expect(horas).toEqual(['08:00', '10:00']);
	});

	// Fidelidade mantida: é a única visão que mostra cancelado, e é onde ele informa.
	it('inclui cancelado, riscado', () => {
		render(ListView, {
			props: { ...base, appointments: [appt({ status: 'cancelado' })] }
		});
		const nome = screen.getByText('Maria Silva');
		expect(nome).toBeInTheDocument();
		expect(nome.className).toMatch(/line-through/);
		expect(screen.getByText('Cancelado')).toBeInTheDocument();
	});

	// B-D1: divergência deliberada do protótipo, que ignorava `hiddenProfs` aqui — dois
	// filtros discordando sobre a mesma tela.
	it('respeita os profissionais ocultos', () => {
		render(ListView, {
			props: {
				...base,
				appointments: [appt(), appt({ id: 'a2', professional_id: 'p2' })],
				hidden: ['p2']
			}
		});
		expect(screen.getAllByRole('button')).toHaveLength(1);
	});

	it('turma mostra o tipo e quantos são', () => {
		render(ListView, {
			props: {
				...base,
				appointments: [
					appt({
						appointment_type_id: 't2',
						patient_ids: ['pat1', 'pat2', 'pat3']
					})
				]
			}
		});
		expect(screen.getByText('Pilates · 3 pacientes')).toBeInTheDocument();
	});

	it('marca o encaixe', () => {
		render(ListView, {
			props: { ...base, appointments: [appt({ encaixe: true })] }
		});
		expect(screen.getByText('Encaixe')).toBeInTheDocument();
	});

	it('paciente sem nome no sidecar não vira o nome do tipo', () => {
		render(ListView, { props: { ...base, patientNames: {} } });
		expect(screen.getByText('Paciente')).toBeInTheDocument();
	});

	// O protótipo não tinha estado vazio aqui: renderizava um container vazio, que parece
	// tela quebrada.
	it('dia vazio tem estado vazio, não um branco', () => {
		render(ListView, { props: { ...base, appointments: [] } });
		expect(screen.getByText('Nenhum agendamento neste dia')).toBeInTheDocument();
	});

	// Havia agendamentos — apenas filtrados. Dizer "Nenhum agendamento neste dia" aqui é
	// afirmar o contrário do que o banco tem.
	it('todos ocultos → estado vazio próprio, não "Nenhum agendamento"', () => {
		render(ListView, { props: { ...base, hidden: ['p1', 'p2'] } });
		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
		expect(screen.queryByText('Nenhum agendamento neste dia')).not.toBeInTheDocument();
	});

	it('clicar numa linha seleciona o agendamento', async () => {
		const onSelect = vi.fn();
		render(ListView, { props: { ...base, onSelect } });
		await userEvent.click(screen.getByText('Maria Silva'));
		expect(onSelect).toHaveBeenCalledWith('a1');
	});
});
