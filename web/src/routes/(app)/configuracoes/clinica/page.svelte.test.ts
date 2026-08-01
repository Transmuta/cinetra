import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';
import { meFixture, clinicFixture } from '$lib/testing/fixtures';
import type { Clinic } from '$lib/server/clinics';

const owner: Me = meFixture({
	user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
	memberships: []
});

const recep: Me = { ...owner, papel: 'recepcao' };

// Os campos `msg_*` (doc 52 §7) viajam com a identidade da clínica; esta tela não os usa, mas o
// tipo é um só — e é o mesmo `GET /api/clinic` que alimenta as duas.
const clinic: Clinic = clinicFixture();

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

	it('a leitura junta o endereço numa linha só, pulando o que está vazio', () => {
		// Sem o filtro, uma clínica que só tem cidade lê "— , — - SP".
		const { getByText } = render(Page, {
			props: {
				data: data(recep, { ...clinic, cidade: 'São Paulo', uf: 'SP' }),
				form: null
			}
		});

		expect(getByText('São Paulo/SP')).toBeInTheDocument();
	});
});

describe('endereço e telefone atravessam o POST', () => {
	// O que a action receberia se o usuário clicasse em Salvar agora.
	function enviado(container: HTMLElement) {
		return new FormData(container.querySelector('form') as HTMLFormElement);
	}

	it('os campos do endereço viajam, mesmo desenhados por um componente sem `name`', () => {
		// O `AddressFields` não sabe de formulário: quem faz os valores atravessarem são os hidden
		// da página. Esquecer um deles salva em silêncio e o campo some no recarregamento — defeito
		// que nenhum teste de action pega, porque a action nunca chega a ver o campo.
		const preenchida = {
			...clinic,
			telefone: '(11) 3456-7890',
			cep: '01310-100',
			endereco: 'Av. Paulista',
			numero: '1000',
			complemento: 'sala 5',
			bairro: 'Bela Vista',
			cidade: 'São Paulo',
			uf: 'SP'
		};

		const fd = enviado(render(Page, { props: { data: data(owner, preenchida), form: null } }).container);

		for (const campo of [
			'telefone',
			'cep',
			'endereco',
			'numero',
			'complemento',
			'bairro',
			'cidade',
			'uf'
		] as const) {
			expect(fd.get(campo), `o formulário não manda ${campo}`).toBe(preenchida[campo]);
		}
	});

	it('apagar o telefone com o WhatsApp ligado bloqueia o Salvar e explica a causa', async () => {
		// A causa mora numa TELA VIZINHA — sem o aviso, o 422 da API chegaria como um toast de erro
		// depois de a pessoa já ter apagado e clicado em Salvar.
		const comCanal = { ...clinic, telefone: '(11) 3456-7890', msg_whatsapp_ativo: true };
		const { getByLabelText, getByRole, getByText } = render(Page, {
			props: { data: data(owner, comCanal), form: null }
		});

		await fireEvent.input(getByLabelText(/Telefone da clínica/), { target: { value: '' } });

		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
		expect(getByText(/Desligue o canal lá antes de apagar o telefone/)).toBeInTheDocument();
	});
});
