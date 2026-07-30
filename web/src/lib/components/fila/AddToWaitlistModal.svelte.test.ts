import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

// O `enhance` guarda a `SubmitFunction` que o componente passou, para que o teste possa DISPARAR o
// envio sem um POST de verdade — é a única forma de exercitar o estado "enviando" do botão.
const submitSpy = vi.hoisted(() => ({ fn: undefined as unknown }));
vi.mock('$app/forms', () => ({
	enhance: (_form: HTMLFormElement, fn?: unknown) => {
		submitSpy.fn = fn;
		return { destroy() {} };
	}
}));

import { tick } from 'svelte';
import type { SubmitFunction } from '@sveltejs/kit';
import AddToWaitlistModal from './AddToWaitlistModal.svelte';
import type { Entry, Professional } from '$lib/waitlist';

const professionals: Professional[] = [
	{ id: 'p1', nome: 'Dra. Ana Souza', nome_exibicao: null, crefito: null, cor_indice: 1, segue_horario_clinica: true },
	{ id: 'p2', nome: 'Dr. Bruno Lima', nome_exibicao: null, crefito: null, cor_indice: 2, segue_horario_clinica: true }
];

const entry: Entry = {
	id: 'e1',
	prio: 'alta',
	janela: 'manha',
	obs: 'dor aguda',
	professional_ids: ['p1'],
	dias_na_fila: 3,
	rules: [{ id: 'r1', tipo: 'semana', dows: [1, 3], data: null, periodos: [['09:00', '11:00']] }],
	patient: { id: 'pat1', nome: 'Maria Silva', tel: '11999990000', ativo: true, faltas: 0 },
	inserted_at: '2026-07-18T10:00:00Z'
};

const base = {
	professionals,
	search: vi.fn().mockResolvedValue({ patients: [], total: 0 }),
	onClose: vi.fn()
};

const hidden = (name: string) => document.querySelector<HTMLInputElement>(`input[name="${name}"]`);
const user = () => userEvent.setup();

afterEach(cleanup);

describe('AddToWaitlistModal — adicionar', () => {
	it('abre com o título de adicionar', () => {
		render(AddToWaitlistModal, { props: base });
		expect(screen.getByRole('dialog', { name: 'Adicionar à fila de espera' })).toBeInTheDocument();
	});

	it('o botão nasce desabilitado enquanto não há paciente', () => {
		render(AddToWaitlistModal, { props: base });
		expect(screen.getByRole('button', { name: 'Adicionar à fila' })).toBeDisabled();
	});

	it('sem regras, mostra a dica e o campo hidden é uma lista vazia', () => {
		render(AddToWaitlistModal, { props: base });
		expect(screen.getByText(/Sem horários específicos/i)).toBeInTheDocument();
		expect(hidden('rules')?.value).toBe('[]');
	});

	it('escolher um profissional preferido entra no hidden professional_ids', async () => {
		render(AddToWaitlistModal, { props: base });
		await user().click(screen.getByRole('button', { name: /Ana Souza/ }));
		expect(JSON.parse(hidden('professional_ids')!.value)).toEqual(['p1']);
	});

	it('o período preferido (janela) viaja no hidden janela', async () => {
		render(AddToWaitlistModal, { props: base });
		expect(hidden('janela')?.value).toBe('qualquer');
		await user().click(screen.getByRole('button', { name: 'Tarde' }));
		expect(hidden('janela')?.value).toBe('tarde');
	});

	it('adicionar "Dias da semana" cria um card e serializa a regra no hidden', async () => {
		render(AddToWaitlistModal, { props: base });
		await user().click(screen.getByRole('button', { name: /Dias da semana/ }));

		// O card aparece (rótulo dentro do cartão).
		expect(screen.getByRole('button', { name: 'Remover regra 1' })).toBeInTheDocument();

		const rules = JSON.parse(hidden('rules')!.value);
		expect(rules).toHaveLength(1);
		expect(rules[0].tipo).toBe('semana');
		expect(rules[0].dows).toEqual([1]); // nasce com segunda
		expect(rules[0].periodos).toEqual([['14:00', '16:00']]);
	});

	it('adicionar "Data específica" cria uma regra do tipo data', async () => {
		render(AddToWaitlistModal, { props: base });
		await user().click(screen.getByRole('button', { name: /Data específica/ }));
		const rules = JSON.parse(hidden('rules')!.value);
		expect(rules[0].tipo).toBe('data');
		expect(rules[0].data).toBeNull();
	});

	it('remover a regra volta o hidden para vazio', async () => {
		render(AddToWaitlistModal, { props: base });
		await user().click(screen.getByRole('button', { name: /Dias da semana/ }));
		expect(JSON.parse(hidden('rules')!.value)).toHaveLength(1);

		await user().click(screen.getByRole('button', { name: 'Remover regra 1' }));
		expect(hidden('rules')?.value).toBe('[]');
	});

	it('fecha no Cancelar', async () => {
		const onClose = vi.fn();
		render(AddToWaitlistModal, { props: { ...base, onClose } });
		await user().click(screen.getByRole('button', { name: 'Cancelar' }));
		expect(onClose).toHaveBeenCalled();
	});
});

describe('AddToWaitlistModal — editar', () => {
	const editProps = { ...base, entry };

	it('abre com o título de edição e submete a `?/atualizar` com o id', () => {
		render(AddToWaitlistModal, { props: editProps });
		expect(screen.getByRole('dialog', { name: 'Editar item da fila' })).toBeInTheDocument();
		expect(document.querySelector('form')?.getAttribute('action')).toBe('?/atualizar');
		expect(hidden('id')?.value).toBe('e1');
	});

	it('prefila prioridade, janela, preferidos e a regra existente', () => {
		render(AddToWaitlistModal, { props: editProps });
		expect(screen.getByLabelText('Prioridade')).toHaveValue('alta');
		expect(hidden('janela')?.value).toBe('manha');
		expect(JSON.parse(hidden('professional_ids')!.value)).toEqual(['p1']);

		const rules = JSON.parse(hidden('rules')!.value);
		expect(rules[0]).toMatchObject({ id: 'r1', tipo: 'semana', dows: [1, 3] });
	});

	// O paciente é a chave do item (upsert por paciente) — na edição não há picker, e o
	// `patient_id` não viaja (o update não o aceita).
	it('mostra o paciente fixo, sem picker nem patient_id', () => {
		render(AddToWaitlistModal, { props: editProps });
		expect(screen.getByText('Maria Silva')).toBeInTheDocument();
		// O <select> de prioridade também é um combobox — o que não deve existir é a BUSCA de
		// paciente do picker (aria-label "Buscar paciente").
		expect(screen.queryByRole('combobox', { name: 'Buscar paciente' })).not.toBeInTheDocument();
		expect(hidden('patient_id')).toBeNull();
	});

	it('o botão de salvar já vem habilitado (paciente fixo)', () => {
		render(AddToWaitlistModal, { props: editProps });
		expect(screen.getByRole('button', { name: 'Salvar' })).toBeEnabled();
	});

	it('mostra o erro do servidor (forma da regra) sem fechar', () => {
		render(AddToWaitlistModal, {
			props: { ...editProps, form: { action: 'atualizar', error: 'Regra inválida: informe os dias.' } }
		});
		expect(screen.getByText('Regra inválida: informe os dias.')).toBeInTheDocument();
	});
});

// Enquanto o POST está em voo o botão precisa DIZER isso. Sem sinal nenhum a pessoa conclui que o
// clique não pegou e clica de novo — foi assim que o "só vai no terceiro clique" ficou plausível.
describe('AddToWaitlistModal — enviando', () => {
	it('trava o botão e mostra o giro enquanto o POST está em voo', async () => {
		render(AddToWaitlistModal, { props: { ...base, entry } });

		const botao = screen.getByRole('button', { name: 'Salvar' });
		expect(botao).toBeEnabled();
		expect(botao).not.toHaveAttribute('aria-busy', 'true');

		const submit = submitSpy.fn as SubmitFunction;
		const depois = submit({} as Parameters<SubmitFunction>[0]);
		await tick();

		expect(botao).toBeDisabled();
		expect(botao).toHaveAttribute('aria-busy', 'true');
		expect(botao.querySelector('.animate-spin')).not.toBeNull();

		// Resposta chegou: destrava (o fechar/limpar é da PÁGINA, pelo `form`; `reset: false`
		// preserva o preenchido quando o servidor recusa).
		await (await depois)?.({ update: async () => {} } as never);
		await tick();
		expect(botao).toBeEnabled();
	});
});
