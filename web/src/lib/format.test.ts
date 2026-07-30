import { describe, it, expect } from 'vitest';
import { initials } from './format';

describe('initials', () => {
	it('duas primeiras iniciais, maiúsculas', () => {
		expect(initials('Ana Paula Souza')).toBe('AP');
	});

	it('nome único → uma inicial', () => {
		expect(initials('joão')).toBe('J');
	});

	it('tolera espaços extras', () => {
		expect(initials('  Dra.  Marina  ')).toBe('DM');
	});
});
