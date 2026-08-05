import { describe, it, expect } from 'vitest';
import {
	activeMembership,
	canManageMembers,
	canManageClinic,
	clinicIdentity,
	type Me
} from './session';
import { meFixture, membershipFixture } from './testing/fixtures';

const me: Me = meFixture({
	user: { id: 'u1', nome: 'Ana', email: 'ana@x' },
	active_clinic_id: 'c2',
	papel: 'admin',
	memberships: [
		membershipFixture({ clinic_id: 'c1', clinic_nome: 'Centro', papel: 'recepcao' }),
		membershipFixture({ clinic_id: 'c2', clinic_nome: 'Zona Sul', papel: 'admin' })
	]
});

describe('activeMembership', () => {
	it('retorna o membership da clínica ativa', () => {
		expect(activeMembership(me)?.clinic_nome).toBe('Zona Sul');
	});

	it('undefined quando não há clínica ativa', () => {
		expect(activeMembership({ ...me, active_clinic_id: null })).toBeUndefined();
	});
});

// O `/me` traz a clínica com as chaves achatadas (`clinic_*`), porque é um membership por
// clínica. O shell não deveria conhecer esse formato — e o endereço, que agora são sete campos,
// só chega inteiro no sidebar se TODOS forem traduzidos aqui.
describe('clinicIdentity', () => {
	it('traduz o membership na identidade que o shell mostra — inteira', () => {
		const m = membershipFixture({
			clinic_nome: 'Clínica Vida',
			clinic_cnpj: '12ABC34501DE35',
			clinic_telefone: '(11) 3456-7890',
			clinic_cep: '01310-100',
			clinic_endereco: 'Av. Paulista',
			clinic_numero: '1000',
			clinic_complemento: 'Sala 42',
			clinic_bairro: 'Bela Vista',
			clinic_cidade: 'São Paulo',
			clinic_uf: 'SP'
		});

		expect(clinicIdentity(m)).toEqual({
			nome: 'Clínica Vida',
			cnpj: '12ABC34501DE35',
			telefone: '(11) 3456-7890',
			cep: '01310-100',
			endereco: 'Av. Paulista',
			numero: '1000',
			complemento: 'Sala 42',
			bairro: 'Bela Vista',
			cidade: 'São Paulo',
			uf: 'SP'
		});
	});

	// Sem clínica ativa (borda do onboarding) o shell cai na marca — e para isso precisa de um
	// `null` limpo, não de um objeto com dez chaves nulas que `{#if clinic}` leria como verdade.
	it('sem membership, não há identidade', () => {
		expect(clinicIdentity(undefined)).toBeNull();
	});
});

describe('canManageMembers', () => {
	it.each([
		['owner', true],
		['admin', true],
		['profissional', false],
		['recepcao', false],
		[null, false]
	])('papel %s → %s', (papel, expected) => {
		expect(canManageMembers(papel as Me['papel'])).toBe(expected);
	});
});

describe('canManageClinic', () => {
	it.each([
		['owner', true],
		['admin', true],
		['profissional', false],
		['recepcao', false],
		[null, false]
	])('papel %s → %s', (papel, expected) => {
		expect(canManageClinic(papel as Me['papel'])).toBe(expected);
	});
});
