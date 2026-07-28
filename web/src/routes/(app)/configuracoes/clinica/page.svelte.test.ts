import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';
import { meFixture } from '$lib/testing/fixtures';
import type { Clinic } from '$lib/server/clinics';

const owner: Me = meFixture({
	user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
	memberships: []
});

const recep: Me = { ...owner, papel: 'recepcao' };

// Os campos `msg_*` (doc 52 §7) viajam com a identidade da clínica; esta tela não os usa, mas o
// tipo é um só — e é o mesmo `GET /api/clinic` que alimenta as duas.
const clinic: Clinic = {
	id: 'c1',
	nome: 'Clínica Vida',
	cnpj: null,
	endereco: null,
	msg_confirmacao_auto: true,
	msg_lembrete_horas: null,
	msg_silencio_inicio: 21,
	msg_silencio_fim: 8
};

// `theme`/`me` vêm do layout; montamos o `data` da página com eles.
function data(me: Me, c = clinic) {
	return { theme: null, unread: 0, me, clinic: c };
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
