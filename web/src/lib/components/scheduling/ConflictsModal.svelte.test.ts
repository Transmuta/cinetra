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
		conflitos: { conflicts: [conflito()], total: 1 },
		onClose: () => {},
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
					total: 1
				}
			})
		});

		expect(screen.getByText('Sem atendimento nesse dia')).toBeInTheDocument();
	});

	// O total manda no cabeçalho, e o resto vira uma linha — é o que transforma "80 linhas
	// ilegíveis" em "aqui vão 1, e faltam 79".
	it('conta pelo total do servidor e avisa quantos ficaram de fora da lista', () => {
		render(ConflictsModal, {
			props: base({ conflitos: { conflicts: [conflito()], total: 80 } })
		});

		expect(screen.getByText(/80 agendamentos futuros/)).toBeInTheDocument();
		expect(screen.getByText('e mais 79 agendamentos não listados aqui')).toBeInTheDocument();
	});

	it('sem resto, não inventa a linha do resto', () => {
		render(ConflictsModal, { props: base() });
		expect(screen.queryByText(/não listados aqui/)).not.toBeInTheDocument();
	});

	// Doc 85: o modal manda remarcar ou cancelar, e até aqui não dava o caminho — a recepção
	// anotava dia e hora e ia procurar na agenda.
	it('cada conflito abre o agendamento na agenda', () => {
		render(ConflictsModal, { props: base() });

		expect(screen.getByRole('link', { name: /Abrir 20\/07 às 14:00/ })).toHaveAttribute(
			'href',
			'/agenda?date=2026-07-20&agendamento=a1'
		);
	});

	// **Outra aba**, e é o único link do app assim: o 409 não salvou nada, então o formulário de
	// horário atrás do modal ainda tem a edição por aplicar. Navegar nesta aba jogaria fora
	// exatamente o trabalho que o modal está pedindo para viabilizar.
	it('o link abre em outra aba, para não perder a edição por trás do modal', () => {
		render(ConflictsModal, { props: base() });

		const link = screen.getByRole('link', { name: /Abrir 20\/07/ });
		expect(link).toHaveAttribute('target', '_blank');
		expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'));
	});

	// O gate é absoluto (D12): o modal informa, não oferece saída. Um "salvar mesmo assim" aqui
	// seria a única porta para gravar por cima de agenda marcada — e ela não deve existir.
	it('NÃO oferece forçar a mudança — só o "Entendi", que fecha', async () => {
		const onClose = vi.fn();
		render(ConflictsModal, { props: base({ onClose }) });

		expect(screen.queryByRole('button', { name: /mesmo assim/i })).not.toBeInTheDocument();

		await userEvent.click(screen.getByRole('button', { name: 'Entendi' }));
		expect(onClose).toHaveBeenCalledOnce();
	});
});
