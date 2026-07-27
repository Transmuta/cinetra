import { describe, it, expect } from 'vitest';
import { load } from './+page.server';

// A URL antiga já circula (links colados, histórico do browser e os deep-links `?record_id=`
// que a própria tela emitia). O redirect é permanente e leva a query junto — sem ela, um link
// velho de "histórico deste registro" cairia no feed geral sem avisar.
describe('/configuracoes/auditoria', () => {
	function ev(search = ''): never {
		return { url: new URL(`http://x/configuracoes/auditoria${search}`) } as never;
	}

	it('redireciona 308 para a seção nova', () => {
		expect(() => load(ev())).toThrowError(
			expect.objectContaining({ status: 308, location: '/auditoria' })
		);
	});

	it('preserva a query string', () => {
		expect(() => load(ev('?resource=attendance&record_id=a1'))).toThrowError(
			expect.objectContaining({ location: '/auditoria?resource=attendance&record_id=a1' })
		);
	});
});
