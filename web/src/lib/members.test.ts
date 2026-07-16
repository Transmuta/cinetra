import { describe, it, expect } from 'vitest';
import {
	ROLE_META,
	INVITABLE_ROLES,
	professionalsWithoutAccess,
	linkedProfessionalName,
	canManageMember,
	type Member,
	type MembersData
} from './members';
import type { Papel } from './session';

const data: MembersData = {
	members: [
		{ id: 'm1', nome: 'Dona', email: 'dona@x', papel: 'owner', status: 'ativo', professional_id: null },
		{
			id: 'm2',
			nome: 'Marina',
			email: 'marina@x',
			papel: 'profissional',
			status: 'ativo',
			professional_id: 'p1'
		},
		{
			id: 'm3',
			nome: 'Pend',
			email: 'pend@x',
			papel: 'profissional',
			status: 'pendente',
			professional_id: null
		}
	],
	professionals: [
		{ id: 'p1', nome: 'Marina Lopes' },
		{ id: 'p2', nome: 'Rafael Couto' }
	]
};

describe('members metadata', () => {
	it('owner não é um papel convidável (gestão à parte, D23)', () => {
		expect(INVITABLE_ROLES).not.toContain('owner');
		expect(INVITABLE_ROLES).toEqual(['admin', 'profissional', 'recepcao']);
	});

	it('ROLE_META cobre os quatro papéis', () => {
		expect(Object.keys(ROLE_META).sort()).toEqual(
			['admin', 'owner', 'profissional', 'recepcao'].sort()
		);
	});
});

describe('professionalsWithoutAccess', () => {
	it('exclui profissionais já vinculados a um membro', () => {
		const out = professionalsWithoutAccess(data);
		expect(out.map((p) => p.id)).toEqual(['p2']);
	});
});

describe('canManageMember', () => {
	const target = (papel: Papel): Member => ({
		id: 'x',
		nome: 'X',
		email: 'x@x',
		papel,
		status: 'ativo',
		professional_id: null
	});
	const ALL: Papel[] = ['owner', 'admin', 'profissional', 'recepcao'];

	it('owner gerencia qualquer papel (inclusive outro owner)', () => {
		for (const p of ALL) expect(canManageMember('owner', target(p))).toBe(true);
	});

	it('admin gerencia só os papéis abaixo — não owner nem admin', () => {
		expect(canManageMember('admin', target('owner'))).toBe(false);
		expect(canManageMember('admin', target('admin'))).toBe(false);
		expect(canManageMember('admin', target('profissional'))).toBe(true);
		expect(canManageMember('admin', target('recepcao'))).toBe(true);
	});

	it('recepção/profissional/sem papel não gerenciam ninguém', () => {
		for (const actor of ['recepcao', 'profissional', null] as (Papel | null)[])
			for (const p of ALL) expect(canManageMember(actor, target(p))).toBe(false);
	});
});

describe('linkedProfessionalName', () => {
	it('retorna o nome do profissional vinculado', () => {
		expect(linkedProfessionalName(data.members[1], data)).toBe('Marina Lopes');
	});

	it('null para membro não-profissional', () => {
		expect(linkedProfessionalName(data.members[0], data)).toBeNull();
	});

	it('null para profissional sem vínculo', () => {
		expect(linkedProfessionalName(data.members[2], data)).toBeNull();
	});
});
