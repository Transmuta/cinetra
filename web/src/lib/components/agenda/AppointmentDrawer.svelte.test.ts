import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import type { Appointment, AgendaPatient, AgendaAppointmentType, AgendaProfessional } from '$lib/agenda';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import AppointmentDrawer from './AppointmentDrawer.svelte';

const tipo: AgendaAppointmentType = {
	id: 't1',
	nome: 'Sessão',
	duracao_minutos: 50,
	cor: '#0072B2',
	icon: 'Activity',
	grupo: false,
	capacidade: null
};

const professional: AgendaProfessional = {
	id: 'p1',
	nome: 'Dra. Ana',
	nome_exibicao: null,
	crefito: null,
	cor_indice: 1,
	segue_horario_clinica: true
};

const patients: AgendaPatient[] = [{ id: 'pac1', nome: 'João Silva', tel: '11999', ativo: true, faltas: 2 }];

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		cancel_reason: null,
		falta_justificada: false,
		professional_id: 'p1',
		appointment_type_id: 't1',
		package_id: null,
		version: 3,
		created_by_id: null,
		patient_ids: ['pac1'],
		...over
	};
}

const base = {
	tipo,
	professional,
	patients,
	// 08:00 local < agora (14:00Z): a sessão já começou.
	agora: '2026-07-20T17:00:00Z',
	timezone: 'America/Sao_Paulo',
	papel: 'recepcao' as const,
	form: null,
	onClose: () => {},
	onReschedule: () => {},
	onToast: () => {}
};

describe('AppointmentDrawer', () => {
	it('mostra horário local, tipo e o cartão do paciente com faltas', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		expect(screen.getByText('08:00–08:50 (50min)')).toBeInTheDocument();
		expect(screen.getByText('João Silva')).toBeInTheDocument();
		expect(screen.getByText(/2 falta/)).toBeInTheDocument();
		// "Abrir ficha" aponta para a ficha do paciente.
		expect(screen.getByRole('link', { name: /Abrir ficha/ })).toHaveAttribute('href', '/pacientes/pac1');
	});

	it('carrega os campos de versão em cada form (guard de 409)', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		const v = document.querySelector<HTMLInputElement>('input[name="expected_version"]');
		expect(v?.value).toBe('3');
	});

	it('concluir/faltar ficam DESABILITADOS antes de a sessão começar', () => {
		render(AppointmentDrawer, {
			props: { appt: appt(), ...base, agora: '2026-07-20T09:00:00Z' } // antes das 08:00 local? 09Z=06 local
		});
		const concluir = screen.getByRole('button', { name: 'Concluir' });
		expect(concluir).toBeDisabled();
		expect(concluir).toHaveAttribute('title', 'Disponível após o horário da sessão');
	});

	it('concluir/faltar ficam habilitados depois de começar', () => {
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		expect(screen.getByRole('button', { name: 'Concluir' })).toBeEnabled();
		expect(screen.getByRole('button', { name: 'Faltou' })).toBeEnabled();
	});

	it('estado terminal mostra "Reabrir"; agendado não', () => {
		const { unmount } = render(AppointmentDrawer, { props: { appt: appt({ status: 'faltou' }), ...base } });
		expect(screen.getByRole('button', { name: /Reabrir/ })).toBeInTheDocument();
		unmount();
		render(AppointmentDrawer, { props: { appt: appt(), ...base } });
		expect(screen.queryByRole('button', { name: /Reabrir/ })).not.toBeInTheDocument();
	});

	it('faltou expõe o toggle "Falta justificada"', () => {
		render(AppointmentDrawer, { props: { appt: appt({ status: 'faltou' }), ...base } });
		expect(screen.getByText('Falta justificada')).toBeInTheDocument();
		expect(screen.getByRole('switch', { name: 'Justificar falta' })).toBeInTheDocument();
	});

	it('cancelado mostra o motivo e esconde "Enviar confirmação"', () => {
		render(AppointmentDrawer, {
			props: { appt: appt({ status: 'cancelado', cancel_reason: 'paciente pediu' }), ...base }
		});
		expect(screen.getByText(/paciente pediu/)).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /Enviar confirmação/ })).not.toBeInTheDocument();
	});

	it('turma mostra a lista de participantes com N/cap', () => {
		const grupo: AgendaAppointmentType = { ...tipo, grupo: true, capacidade: 4 };
		render(AppointmentDrawer, {
			props: {
				appt: appt({ patient_ids: ['pac1'] }),
				...base,
				tipo: grupo
			}
		});
		expect(screen.getByText('Pacientes na turma')).toBeInTheDocument();
		expect(screen.getByText('1/4')).toBeInTheDocument();
	});
});
