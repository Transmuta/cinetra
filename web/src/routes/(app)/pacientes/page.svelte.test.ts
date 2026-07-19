import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// A busca navega (não filtra no cliente), então o que se testa aqui é o `goto`.
const gotoMock = vi.hoisted(() => vi.fn());
vi.mock('$app/navigation', () => ({ goto: gotoMock }));
vi.mock('$app/state', () => ({ page: { url: new URL('http://localhost/pacientes') } }));

import Page from './+page.svelte';
import type { Patient } from '$lib/patients';

function patient(over: Partial<Patient> = {}): Patient {
	return {
		id: 'pac1', nome: 'Ana Alves', nome_social: null, cpf: '111.111.111-11', rg: null,
		genero: null, estado_civil: null, nascimento: null, responsavel: null,
		tel: '(11) 90000-0000', email: null, cep: null, endereco: null, numero: null,
		complemento: null, bairro: null, cidade: null, uf: null, emergencia_nome: null,
		emergencia_parentesco: null, emergencia_tel: null, profissao: null, empresa: null,
		atend_tipo: 'particular', convenio: null, carteirinha: null, convenio_validade: null,
		medico: null, crm: null, como_conheceu: null, prefs: [], tags: [], lgpd: false,
		comunicacao: false, cor_indice: 1, ativo: true,
		...over
	};
}

function data(over: Record<string, unknown> = {}) {
	return {
		patients: [patient()],
		pageInfo: { limit: 50, offset: 0, total: 1, more: false },
		counts: { todos: 1, ativos: 1, inativos: 0, resp: 0 },
		professionals: [],
		q: '',
		filter: 'todos',
		current: 1,
		me: { papel: 'owner' },
		...over
	} as never;
}

beforeEach(() => gotoMock.mockReset());
afterEach(() => vi.useRealTimers());

describe('lista de pacientes', () => {
	it('mostra o paciente da página', () => {
		// Duas ocorrências de propósito: a linha do desktop e o cartão do mobile convivem no
		// DOM (quem esconde uma é o CSS responsivo).
		const { getAllByText } = render(Page, { props: { data: data() } });
		expect(getAllByText('Ana Alves')).toHaveLength(2);
	});

	it('busca navega com ?q= só depois do debounce', async () => {
		vi.useFakeTimers();
		const { getByLabelText } = render(Page, { props: { data: data() } });

		await fireEvent.input(getByLabelText('Buscar paciente'), { target: { value: 'ana' } });
		expect(gotoMock).not.toHaveBeenCalled(); // ainda dentro da janela do debounce

		await vi.advanceTimersByTimeAsync(300);
		expect(gotoMock).toHaveBeenCalledWith('/pacientes?q=ana', expect.anything());
	});

	// Regressão: digitar e sair da lista antes do debounce vencer deixava um timer órfão que
	// chamava `goto` e arrastava a pessoa de volta para a lista.
	it('NÃO navega se o componente for desmontado antes do debounce', async () => {
		vi.useFakeTimers();
		const { getByLabelText, unmount } = render(Page, { props: { data: data() } });

		await fireEvent.input(getByLabelText('Buscar paciente'), { target: { value: 'ana' } });
		unmount();
		await vi.advanceTimersByTimeAsync(1000);

		expect(gotoMock).not.toHaveBeenCalled();
	});

	// Regressão: a resposta do termo antigo chegava depois da nova tecla e devolvia o input ao
	// valor velho — a tecla seguinte comia um caractere.
	it('não sobrescreve o que está sendo digitado quando a URL muda no meio', async () => {
		vi.useFakeTimers();
		const { getByLabelText, rerender } = render(Page, { props: { data: data() } });
		const input = getByLabelText('Buscar paciente') as HTMLInputElement;

		await fireEvent.input(input, { target: { value: 'mar' } });
		// o load do termo ANTERIOR ("ma") aterrissa enquanto a digitação está pendente
		await rerender({ data: data({ q: 'ma' }) });

		expect(input.value).toBe('mar');
	});

	it('trocar de segmento (sem digitação pendente) limpa o campo de busca', async () => {
		const { getByLabelText, rerender } = render(Page, { props: { data: data({ q: 'mari' }) } });
		const input = getByLabelText('Buscar paciente') as HTMLInputElement;
		expect(input.value).toBe('mari');

		await rerender({ data: data({ q: '' }) });
		expect(input.value).toBe('');
	});

	it('paginação: Próxima navega com ?page= e some quando há uma página só', async () => {
		const { queryByRole } = render(Page, { props: { data: data() } });
		expect(queryByRole('button', { name: /Próxima/ })).toBeNull();

		const { getByRole } = render(Page, {
			props: { data: data({ pageInfo: { limit: 50, offset: 0, total: 80, more: true } }) }
		});
		await fireEvent.click(getByRole('button', { name: /Próxima/ }));
		expect(gotoMock).toHaveBeenCalledWith('/pacientes?page=2', expect.anything());
	});
});
