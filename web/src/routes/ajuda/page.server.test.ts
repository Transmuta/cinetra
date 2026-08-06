import { describe, it, expect } from 'vitest';

import { load as loadIndice } from './+page.server';
import { load as loadLayout } from './+layout.server';
import { load as loadTopico } from './[topico]/+page.server';
import { TOPICOS } from '$lib/ajuda';

const url = (p: string) => new URL(`https://cinetra.app${p}`);

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ev = (o: Record<string, unknown>): any => o;

// Os `load` daqui são síncronos, mas o tipo que o Kit infere inclui `void` (por causa do `error`
// que o do tópico levanta) e `MaybePromise`. Este apelido é só para o teste falar do caso de
// SUCESSO sem espalhar asserção de tipo em cada linha.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ok = <T,>(v: T): any => v;

describe('/ajuda', () => {
	it('o índice devolve a canônica da própria URL', () => {
		const r = ok(loadIndice(ev({ url: url('/ajuda') })));
		expect(r.canonical).toBe('https://cinetra.app/ajuda');
	});

	it('a página é pública: sem cookie ela carrega, marcando deslogado', () => {
		const r = ok(loadLayout(ev({ cookies: { get: () => undefined } })));
		expect(r.logado).toBe(false);
	});

	it('com o cookie de sessão, marca logado — sem ir à API', () => {
		const r = ok(loadLayout(ev({ cookies: { get: (n: string) => (n === '_api_key' ? 'abc' : undefined) } })));
		expect(r.logado).toBe(true);
	});
});

describe('/ajuda/[topico]', () => {
	it('carrega o tópico, a seção, os papéis por extenso e os vizinhos', () => {
		const r = ok(loadTopico(ev({ params: { topico: 'encaixe' }, url: url('/ajuda/encaixe') })));
		expect(r.topico.id).toBe('encaixe');
		expect(r.secao.titulo).toBe('Agenda');
		expect(r.papeis).toEqual(['Dono', 'Administrador', 'Recepção']);
		expect(r.anterior?.id).toBe('horario-ocupado');
		expect(r.proximo?.id).toBe('o-painel-do-agendamento');
	});

	it('id desconhecido é 404 de verdade, não 200 com "não encontrado" no corpo', () => {
		expect(() =>
			loadTopico(ev({ params: { topico: 'nao-existe' }, url: url('/ajuda/nao-existe') }))
		).toThrowError(expect.objectContaining({ status: 404 }));
	});

	it('todo tópico do índice carrega — nenhum link do índice cai em 404', () => {
		for (const t of TOPICOS) {
			expect(() =>
				loadTopico(ev({ params: { topico: t.id }, url: url(`/ajuda/${t.id}`) }))
			).not.toThrow();
		}
	});
});
