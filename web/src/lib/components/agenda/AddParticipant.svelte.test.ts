import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import type { AgendaPatient } from '$lib/agenda';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import AddParticipant from './AddParticipant.svelte';

// "Adicionar paciente" numa turma que já existe (doc 109). O que este arquivo prende é o que a
// integração no drawer não alcança: a busca injetada e a recusa de quem já está na turma.

const encontrados: AgendaPatient[] = [
	{ id: 'pac1', nome: 'João Silva', tel: '11999998888', ativo: true, faltas: 0 },
	{ id: 'pac9', nome: 'Joana Lima', tel: null, ativo: true, faltas: 0 }
];

const base = {
	id: 'a1',
	version: 3,
	capacidade: 4,
	atual: 2,
	podeEncaixe: true,
	search: async () => ({ patients: encontrados, total: encontrados.length })
};

const abrir = () => fireEvent.click(screen.getByRole('button', { name: /Adicionar paciente/ }));

describe('AddParticipant', () => {
	it('nasce fechado — a turma é lida muito mais do que composta', () => {
		render(AddParticipant, { props: base });

		expect(screen.getByRole('button', { name: /Adicionar paciente/ })).toBeInTheDocument();
		expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
	});

	it('conta as vagas que sobram, no singular certo', async () => {
		render(AddParticipant, { props: { ...base, atual: 3 } });
		await abrir();

		expect(screen.getByText('1 vaga')).toBeInTheDocument();
	});

	it('escolher um paciente o coloca no hidden que a action lê', async () => {
		const { container } = render(AddParticipant, { props: base });
		await abrir();

		await userEvent.type(screen.getByRole('combobox'), 'joa');
		await waitFor(() => expect(screen.getByText('João Silva')).toBeInTheDocument());
		await fireEvent.click(screen.getByText('João Silva'));

		expect(container.querySelector<HTMLInputElement>('input[name="patient_ids"]')?.value).toBe(
			'["pac1"]'
		);
		expect(screen.getByRole('button', { name: 'Adicionar' })).toBeEnabled();
	});

	// Escolher de novo quem já está dentro produziria um 422 de identidade
	// (`one_per_patient_per_appt`) com uma mensagem que fala de banco, não de sala de espera.
	it('quem já está na turma não entra de novo', async () => {
		const { container } = render(AddParticipant, { props: { ...base, jaNoBloco: ['pac1'] } });
		await abrir();

		await userEvent.type(screen.getByRole('combobox'), 'joa');
		await waitFor(() => expect(screen.getByText('João Silva')).toBeInTheDocument());
		await fireEvent.click(screen.getByText('João Silva'));

		expect(container.querySelector<HTMLInputElement>('input[name="patient_ids"]')?.value).toBe('[]');
		expect(screen.getByRole('button', { name: 'Adicionar' })).toBeDisabled();
	});

	it('cancelar fecha e esquece o que estava escolhido', async () => {
		const { container } = render(AddParticipant, { props: base });
		await abrir();

		await userEvent.type(screen.getByRole('combobox'), 'joa');
		await waitFor(() => expect(screen.getByText('João Silva')).toBeInTheDocument());
		await fireEvent.click(screen.getByText('João Silva'));
		await fireEvent.click(screen.getByRole('button', { name: 'Cancelar' }));

		await abrir();
		expect(container.querySelector<HTMLInputElement>('input[name="patient_ids"]')?.value).toBe('[]');
	});

	// O teto é operacional, não físico (`Validations.GroupCapacity`): a tela não desabilita por
	// antecipação — deixa tentar, e o 422 vira a oferta de encaixe.
	it('turma cheia diz que está cheia e continua deixando tentar', async () => {
		render(AddParticipant, { props: { ...base, atual: 4 } });
		await abrir();

		expect(screen.getByText('turma cheia (4/4)')).toBeInTheDocument();
		expect(screen.getByRole('combobox')).toBeInTheDocument();
	});

	it('sem permissão de encaixe, o 422 vem sem a saída', async () => {
		render(AddParticipant, {
			props: {
				...base,
				podeEncaixe: false,
				erro: 'A turma está cheia (4 vagas).',
				code: 'group_full'
			}
		});
		await abrir();

		expect(screen.getByText('A turma está cheia (4 vagas).')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Marcar como encaixe' })).not.toBeInTheDocument();
	});

	// Erro que não é `group_full` (409 de versão, por exemplo) aparece, mas não vira oferta de furar
	// o teto: o encaixe não conserta um bloco que mudou debaixo de quem estava olhando.
	it('erro de outra natureza não oferece encaixe', async () => {
		render(AddParticipant, {
			props: { ...base, erro: 'Este agendamento mudou desde que você o abriu.', code: 'version_conflict' }
		});
		await abrir();

		expect(screen.getByText(/mudou desde que você o abriu/)).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Marcar como encaixe' })).not.toBeInTheDocument();
	});
});
