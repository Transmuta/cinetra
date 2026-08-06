import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import type { Appointment, AgendaProfessional } from '$lib/agenda';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import RescheduleModal from './RescheduleModal.svelte';

const professionals: AgendaProfessional[] = [
	{ id: 'p1', nome: 'Dra. Ana', nome_exibicao: null, crefito: null, cor_indice: 1, segue_horario_clinica: true },
	{ id: 'p2', nome: 'Dr. Bento', nome_exibicao: null, crefito: null, cor_indice: 2, segue_horario_clinica: true }
];

const appt: Appointment = {
	id: 'a1',
	starts_at: '2026-07-20T11:00:00Z',
	ends_at: '2026-07-20T11:50:00Z',
	status: 'agendado',
	encaixe: false,
	obs: null,
	cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
	professional_id: 'p1',
	appointment_type_id: 't1',
	version: 5,
	created_by_id: null,
	patient_ids: ['pac1'],
	participants: [],
};

const base = {
	appt,
	timezone: 'America/Sao_Paulo',
	professionals,
	papel: 'recepcao' as const,
	onClose: () => {}
};

const hidden = (name: string) => document.querySelector<HTMLInputElement>(`input[name="${name}"]`);

describe('RescheduleModal', () => {
	it('pré-preenche data/hora do estado atual (relógio da clínica) e a versão', () => {
		render(RescheduleModal, { props: { ...base, form: null } });
		// 11:00Z = 08:00 em São Paulo.
		expect(screen.getByDisplayValue('08:00')).toBeInTheDocument();
		expect(hidden('expected_version')?.value).toBe('5');
		expect(hidden('id')?.value).toBe('a1');
	});

	it('oferece "Marcar como encaixe" quando o servidor recusou por conflito', () => {
		render(RescheduleModal, {
			props: { ...base, form: { action: 'remarcar', code: 'schedule_conflict', error: 'Esse horário sobrepõe outro.' } }
		});
		expect(screen.getByText('Esse horário sobrepõe outro.')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Marcar como encaixe' })).toBeInTheDocument();
	});

	it('NÃO oferece encaixe fora do expediente (D14: encaixe não libera)', () => {
		render(RescheduleModal, {
			props: { ...base, form: { action: 'remarcar', code: 'outside_business_hours', error: 'Fora do expediente.' } }
		});
		expect(screen.getByText('Fora do expediente.')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Marcar como encaixe' })).not.toBeInTheDocument();
	});

	describe('a pergunta de avisar o paciente', () => {
		it('nasce ligado e manda `avisar_paciente=on`', async () => {
			// Nasce ligado porque quem remarca de propósito quase sempre quer avisar. O default do
			// SERVIDOR é o contrário (`false`), e a assimetria é deliberada: lá a omissão é falha, e
			// mensagem enviada não volta.
			const { container, getByRole } = render(RescheduleModal, { props: { ...base, form: null } });

			expect(getByRole('switch', { name: /Avisar o paciente/ })).toBeChecked();

			const fd = new FormData(container.querySelector('form') as HTMLFormElement);
			expect(fd.get('avisar_paciente')).toBe('on');
		});

		it('desligado, manda o campo em BRANCO — não some do FormData', async () => {
			// O controle é um `<button role="switch">`, e botão não entra no FormData; um campo
			// ausente vira o default do servidor sem ninguém saber. O hidden é quem torna "não
			// avisar" uma resposta.
			const { container, getByRole } = render(RescheduleModal, { props: { ...base, form: null } });

			await fireEvent.click(getByRole('switch', { name: /Avisar o paciente/ }));

			const fd = new FormData(container.querySelector('form') as HTMLFormElement);
			expect(fd.get('avisar_paciente')).toBe('');
		});
	});
});
