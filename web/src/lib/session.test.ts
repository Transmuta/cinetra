import { describe, it, expect } from 'vitest';
import { activeMembership, canManageMembers, canManageClinic, type Me } from './session';

const me: Me = {
	user: { id: 'u1', nome: 'Ana', email: 'ana@x' },
	active_clinic_id: 'c2',
	papel: 'admin',
	professional_id: null,
	memberships: [
		{ clinic_id: 'c1', clinic_nome: 'Centro', clinic_cnpj: null, clinic_endereco: null, papel: 'recepcao', professional_id: null },
		{ clinic_id: 'c2', clinic_nome: 'Zona Sul', clinic_cnpj: null, clinic_endereco: null, papel: 'admin', professional_id: null }
	]
};

describe('activeMembership', () => {
	it('retorna o membership da clínica ativa', () => {
		expect(activeMembership(me)?.clinic_nome).toBe('Zona Sul');
	});

	it('undefined quando não há clínica ativa', () => {
		expect(activeMembership({ ...me, active_clinic_id: null })).toBeUndefined();
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
