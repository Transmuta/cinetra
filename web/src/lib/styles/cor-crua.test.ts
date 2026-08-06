import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * O tripwire que faltava: **cor crua não entra no app interno**.
 *
 * O `contraste.test.ts` mede pares de TOKEN, então uma cor escrita à mão é invisível para ele por
 * construção — foi assim que `#9a6a05` sobreviveu 194 linhas abaixo do comentário que dizia tê-lo
 * removido, e que o avatar do usuário logado ficou com `#0072B2` cravado enquanto `avatar.ts`
 * existia (doc 93 §M-8/M-9). Nenhum dos seis gates do projeto olhava para isto.
 *
 * O escopo é o **app interno**. A landing e as telas de entrada usam a paleta da marca em hex de
 * propósito (papel/navy do protótipo, fora do sistema de tokens do app), e por isso a família
 * `cinetra/` + `Auth*` + `Seo` está isenta — é decisão registrada, não descuido.
 */

const RAIZ = new URL('../../', import.meta.url).pathname;

/** A família de marca: paleta própria em hex, deliberadamente fora dos tokens do app. */
const ISENTOS = [
	'lib/components/AuthCard.svelte',
	'lib/components/AuthForm.svelte',
	'lib/components/GoogleIcon.svelte',
	'lib/components/Seo.svelte',
	'lib/components/cinetra/',
	// A central de ajuda (doc 108) entrou aqui em 2026-08-06, quando ela passou a usar a casca das
	// páginas públicas — mesmo topo, mesmo herói navy, mesmo rodapé da landing. Ela é uma página
	// PÚBLICA, alcançável sem sessão e compartilhável por link; com os tokens do app ela destoava
	// no meio do site. A isenção é a mesma da família `cinetra/` e pela mesma razão, não um
	// contorno do gate: a central não tem tema escuro nem componente do design system interno.
	'lib/components/ajuda/'
];

function svelteDoAppInterno(dir: string, acc: string[] = []): string[] {
	for (const nome of readdirSync(dir)) {
		const caminho = join(dir, nome);
		if (statSync(caminho).isDirectory()) svelteDoAppInterno(caminho, acc);
		else if (nome.endsWith('.svelte')) acc.push(caminho);
	}
	return acc;
}

/**
 * Tira comentário antes de procurar. O histórico de uma cor removida mora justamente em
 * comentário (`PackageList` explica por que o âmbar saiu) — e isso é documentação, não pintura.
 *
 * As quebras de linha do trecho removido são PRESERVADAS: sem isso o número de linha do achado
 * anda para trás e aponta para o lugar errado, que é pior que não apontar.
 */
function semComentario(fonte: string): string {
	const vazio = (m: string) => m.replace(/[^\n]/g, '');

	return fonte
		.replace(/<!--[\s\S]*?-->/g, vazio)
		.replace(/\/\*[\s\S]*?\*\//g, vazio)
		.replace(/(^|[^:])\/\/.*$/gm, '$1');
}

const COR_CRUA = /#[0-9a-fA-F]{3,8}\b|\brgba?\s*\(/g;

function corCruaNoAppInterno(): string[] {
	const alvos = [
		...svelteDoAppInterno(join(RAIZ, 'lib/components')),
		...svelteDoAppInterno(join(RAIZ, 'routes/(app)'))
	];

	const achados: string[] = [];

	for (const caminho of alvos) {
		const rel = relative(RAIZ, caminho).replaceAll('\\', '/');
		if (ISENTOS.some((i) => rel.startsWith(i))) continue;

		semComentario(readFileSync(caminho, 'utf8'))
			.split('\n')
			.forEach((linha, i) => {
				for (const m of linha.matchAll(COR_CRUA)) achados.push(`${rel}:${i + 1} → ${m[0]}`);
			});
	}

	return achados;
}

describe('cor crua no app interno', () => {
	it('toda cor do app passa por token — nenhuma é escrita à mão', () => {
		expect(corCruaNoAppInterno()).toEqual([]);
	});

	it('o próprio tripwire enxerga: a família da marca, que é isenta, TEM hex', () => {
		// Guarda contra o pior desfecho — a lista vazia por o scanner não estar lendo nada.
		const marca = readFileSync(join(RAIZ, 'lib/components/AuthCard.svelte'), 'utf8');
		expect(semComentario(marca)).toMatch(COR_CRUA);
	});
});
