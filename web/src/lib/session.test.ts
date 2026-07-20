import { describe, it, expect } from 'vitest';
import { activeMembership, canManageMembers, canManageClinic, type Me } from './session';
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
