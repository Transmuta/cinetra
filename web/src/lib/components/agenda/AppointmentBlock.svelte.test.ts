import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import AppointmentBlock from './AppointmentBlock.svelte';
import type { Appointment } from '$lib/agenda';

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
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
		patient_ids: ['pat1'],
		...over
	};
}

const tipo = {
	id: 't1',
	nome: 'Sessão',
	sigla: 'SES',
	duracao_minutos: 50,
	cor: '#0072B2',
	icon: 'Activity',
	grupo: false,
	capacidade: null,
	ativo: true
};

const base = {
	appt: appt(),
	tipo,
	slot: { lane: 0, lanes: 1 },
	top: 0,
	height: 60,
	conflict: false,
	action: false,
	patientNames: ['Maria Silva'],
	profColor: '#0FB5A6',
	startLabel: '08:00',
	onSelect: () => {}
};

describe('AppointmentBlock', () => {
	// Doc 25 §6: `<button>`, não `<div>` clicável — um div com onclick não recebe foco,
	// não responde a Enter/Espaço e não é anunciado como acionável.
	it('é um <button> de verdade', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByRole('button')).toBeInTheDocument();
	});

	it('aciona onSelect com o id ao clicar', async () => {
		const onSelect = vi.fn();
		render(AppointmentBlock, { props: { ...base, onSelect } });
		await userEvent.click(screen.getByRole('button'));
		expect(onSelect).toHaveBeenCalledWith('a1');
	});

	it('mostra a hora de início e o paciente', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByText('08:00')).toBeInTheDocument();
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
	});

	// A precedência do protótipo (:1666): AÇÃO > conflito > tint do status. Ela existe porque
	// as três pintam o mesmo retângulo e sem ordem definida o resultado vira sorteio.
	describe('precedência visual', () => {
		it('sem nada, veste o status', () => {
			render(AppointmentBlock, { props: base });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'status');
		});

		it('conflito ganha do status', () => {
			render(AppointmentBlock, { props: { ...base, conflict: true } });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'conflict');
		});

		it('AÇÃO ganha do conflito', () => {
			render(AppointmentBlock, { props: { ...base, conflict: true, action: true } });
			expect(screen.getByRole('button')).toHaveAttribute('data-variant', 'action');
		});
	});

	it('encaixe leva o selo ENCAIXE', () => {
		render(AppointmentBlock, { props: { ...base, appt: appt({ encaixe: true }) } });
		expect(screen.getByText('ENCAIXE')).toBeInTheDocument();
	});

	it('sem encaixe, não há selo', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.queryByText('ENCAIXE')).not.toBeInTheDocument();
	});

	it('conflito é anunciado, não só colorido', () => {
		render(AppointmentBlock, { props: { ...base, conflict: true } });
		expect(screen.getByTitle(/conflito/i)).toBeInTheDocument();
	});

	it('cancelado sai riscado', () => {
		render(AppointmentBlock, { props: { ...base, appt: appt({ status: 'cancelado' }) } });
		expect(screen.getByRole('button')).toHaveAttribute('data-strike', 'true');
	});

	// Com o sidecar no ar, o bloco individual mostra o PACIENTE — não mais o nome do tipo,
	// que era o disfarce enquanto a fonte não existia.
	it('bloco individual mostra o nome do paciente, não o do tipo', () => {
		render(AppointmentBlock, { props: { ...base, height: 40 } });
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
		expect(screen.queryByText('Sessão')).not.toBeInTheDocument();
	});

	// O sidecar traz só os citados na janela, mas um id órfão (paciente removido entre a
	// leitura e o render) não pode deixar o bloco vazio nem derrubar a grade.
	it('paciente sem correspondência no sidecar cai num rótulo neutro', () => {
		render(AppointmentBlock, { props: { ...base, patientNames: [] } });
		expect(screen.getByText('Paciente')).toBeInTheDocument();
	});

	it('turma mostra "tipo · N/capacidade"', () => {
		render(AppointmentBlock, {
			props: {
				...base,
				appt: appt({ patient_ids: ['a', 'b', 'c'] }),
				tipo: { ...tipo, nome: 'Pilates', grupo: true, capacidade: 4 },
				patientNames: ['A', 'B', 'C']
			}
		});
		expect(screen.getByText('Pilates · 3/4')).toBeInTheDocument();
	});

	// Rótulo por altura (protótipo :1687): bloco baixo não comporta a linha do nome em 12px.
	it('bloco muito baixo não desenha a terceira linha', () => {
		render(AppointmentBlock, { props: { ...base, height: 20 } });
		expect(screen.queryByText('Sessão')).not.toBeInTheDocument();
	});

	it('bloco alto mostra o nome do tipo na terceira linha', () => {
		render(AppointmentBlock, { props: { ...base, height: 80 } });
		expect(screen.getByText('Sessão')).toBeInTheDocument();
	});

	it('o nome acessível descreve o agendamento inteiro', () => {
		render(AppointmentBlock, { props: base });
		expect(screen.getByRole('button').getAttribute('aria-label')).toContain('08:00');
		expect(screen.getByRole('button').getAttribute('aria-label')).toContain('Maria Silva');
	});
});
