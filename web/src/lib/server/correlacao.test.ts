import { describe, it, expect } from 'vitest';
import { novoRequestId, LIMITE_PLUG } from './correlacao';

describe('novoRequestId (correlação BFF → API)', () => {
	// A asserção que dá sentido a todas as outras. O `Plug.RequestId` do lado Elixir só REAPROVEITA
	// o header quando `byte_size(val) in 20..200`; fora dessa faixa ele descarta em silêncio e gera
	// o próprio id. O sintoma seria o pior possível: o header sai, ninguém dá erro, e a correlação
	// simplesmente não existe — com os dois lados parecendo corretos em revisão de código.
	it('gera id dentro da faixa que o Plug.RequestId aceita (20..200 bytes)', () => {
		for (let i = 0; i < 50; i++) {
			const tamanho = new TextEncoder().encode(novoRequestId()).length;
			expect(tamanho).toBeGreaterThanOrEqual(LIMITE_PLUG.min);
			expect(tamanho).toBeLessThanOrEqual(LIMITE_PLUG.max);
		}
	});

	it('gera ids distintos', () => {
		const ids = new Set(Array.from({ length: 200 }, () => novoRequestId()));
		expect(ids.size).toBe(200);
	});

	// Header HTTP não aceita qualquer byte. Um id com espaço, quebra de linha ou não-ASCII faria o
	// `Headers.set` levantar (ou, pior, viabilizaria injeção de header) — e isso só apareceria em
	// produção, na primeira chamada.
	it('usa só caracteres seguros para header HTTP', () => {
		for (let i = 0; i < 50; i++) {
			expect(novoRequestId()).toMatch(/^[A-Za-z0-9._-]+$/);
		}
	});
});
