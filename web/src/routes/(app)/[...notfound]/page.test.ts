import { describe, it, expect } from 'vitest';
import { load } from './+page';

describe('catch-all do shell', () => {
	it('destino não construído → 404 (dentro do chrome)', () => {
		try {
			load({} as never);
			expect.fail('deveria lançar 404');
		} catch (e) {
			expect(e).toMatchObject({ status: 404 });
		}
	});
});
