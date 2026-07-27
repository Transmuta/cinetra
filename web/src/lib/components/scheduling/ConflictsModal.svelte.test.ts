import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import ConflictsModal from './ConflictsModal.svelte';
import type { FutureConflict } from '$lib/scheduling-conflicts';

function conflito(over: Partial<FutureConflict> = {}): FutureConflict {
	return {
		appointment_id: 'a1',
		date: '2026-07-20',
		hora: '14:00',
		reason: 'fora_do_expediente',
		periods_depois: [['08:00', '12:00']],
		professional: { id: 'p1', nome: 'Dra. Bea' },
		patients: ['Caio Paciente'],
		...over
	};
}

function base(over = {}) {
	return {
		conflitos: { conflicts: [conflito()], truncado: false },
		onClose: () => {},
		onConfirm: () => {},
		...over
	};
}

describe('ConflictsModal (A3/D12)', () => {
	it('lista o que quebraria: dia, hora, profissional, paciente e o motivo', () => {
		render(ConflictsModal, { props: base() });

		expect(screen.getByText('20/07 · 14:00')).toBeInTheDocument();
		expect(screen.getByText('Dra. Bea')).toBeInTheDocument();
		expect(screen.getByText('Caio Paciente')).toBeInTheDocument();
		expect(screen.getByText('Fora do novo expediente (08:00–12:00)')).toBeInTheDocument();
	});

	it('o dia fechado tem a frase própria', () => {
		render(ConflictsModal, {
			props: base({
				conflitos: {
					conflicts: [conflito({ reason: 'sem_atendimento', periods_depois: [] })],
					truncado: false
				}
			})
		});

		expect(screen.getByText('Sem atendimento nesse dia')).toBeInTheDocument();
	});

	it('avisa quando a lista veio cortada pelo teto do servidor', () => {
		render(ConflictsModal, {
			props: base({ conflitos: { conflicts: [conflito()], truncado: true } })
		});

		expect(screen.getByText(/e possivelmente mais/)).toBeInTheDocument();
	});

	// O ponto do D12: a confirmação existe, mas só DEPOIS da lista — o botão vive aqui dentro.
	it('"Salvar mesmo assim" chama o confirm; "Voltar e ajustar" fecha', async () => {
		const onConfirm = vi.fn();
		const onClose = vi.fn();
		render(ConflictsModal, { props: base({ onConfirm, onClose }) });

		await userEvent.click(screen.getByRole('button', { name: 'Salvar mesmo assim' }));
		expect(onConfirm).toHaveBeenCalledOnce();

		await userEvent.click(screen.getByRole('button', { name: 'Voltar e ajustar' }));
		expect(onClose).toHaveBeenCalledOnce();
	});

	it('o rótulo do confirmar é configurável (a exceção diz "Criar")', () => {
		render(ConflictsModal, { props: base({ confirmLabel: 'Criar mesmo assim' }) });
		expect(screen.getByRole('button', { name: 'Criar mesmo assim' })).toBeInTheDocument();
	});
});
