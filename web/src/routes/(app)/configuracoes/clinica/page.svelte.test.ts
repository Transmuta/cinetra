import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';

const owner: Me = {
	user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
	active_clinic_id: 'c1',
	papel: 'owner' as const,
	professional_id: null,
	memberships: []
};

const recep: Me = { ...owner, papel: 'recepcao' };

const clinic: { id: string; nome: string; cnpj: string | null; endereco: string | null } = {
	id: 'c1',
	nome: 'Clínica Vida',
	cnpj: null,
	endereco: null
};

// `theme`/`me` vêm do layout; montamos o `data` da página com eles.
function data(me: Me, c = clinic) {
	return { theme: null, me, clinic: c };
}

describe('Clínica — edição (owner/admin)', () => {
	it('mostra o formulário com o nome carregado e o Salvar começa desabilitado (nada sujo)', () => {
		const { getByLabelText, getByRole } = render(Page, { props: { data: data(owner), form: null } });
		expect((getByLabelText(/Nome da clínica/) as HTMLInputElement).value).toBe('Clínica Vida');
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});

	it('CNPJ inválido: mostra "CNPJ inválido." e mantém o Salvar desabilitado', async () => {
		const { getByLabelText, getByText, getByRole } = render(Page, {
			props: { data: data(owner), form: null }
		});

		await fireEvent.input(getByLabelText('CNPJ'), { target: { value: '12ABC34501DE34' } });
		expect(getByText('CNPJ inválido.')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});

	it('CNPJ válido mascara o campo e habilita o Salvar (edição válida)', async () => {
		const { getByLabelText, getByRole } = render(Page, { props: { data: data(owner), form: null } });

		const input = getByLabelText('CNPJ') as HTMLInputElement;
		await fireEvent.input(input, { target: { value: '12abc34501de35' } });
		expect(input.value).toBe('12.ABC.345/01DE-35');
		expect(getByRole('button', { name: 'Salvar' })).toBeEnabled();
	});
});

describe('Clínica — leitura (não-gestor)', () => {
	it('recepção vê a ficha sem formulário de edição', () => {
		const { queryByRole, getByText } = render(Page, {
			props: { data: data(recep, { ...clinic, endereco: 'Rua Y' }), form: null }
		});
		expect(queryByRole('button', { name: 'Salvar' })).toBeNull();
		expect(getByText('Rua Y')).toBeInTheDocument();
	});
});
