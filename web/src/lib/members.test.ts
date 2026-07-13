import { describe, it, expect } from 'vitest';
import {
	ROLE_META,
	INVITABLE_ROLES,
	professionalsWithoutAccess,
	linkedProfessionalName,
	type MembersData
} from './members';

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
