import { describe, it, expect } from 'vitest';
import { load } from './+page.server';

describe('/configuracoes redireciona', () => {
	it('leva para a primeira seção construída (Equipe & acessos)', () => {
		try {
			load({} as never);
			expect.fail('deveria redirecionar');
		} catch (e) {
			expect(e).toMatchObject({ status: 307, location: '/configuracoes/equipe' });
		}
	});
});
