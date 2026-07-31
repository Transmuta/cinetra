import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * As camadas flutuantes: que existam, e em que ORDEM.
 *
 * Duas coisas justificam um teste aqui, e nenhuma delas é zelo:
 *
 *  1. **Utilitário que não existe some em silêncio.** `z-index` não é namespace temável no
 *     Tailwind v4 (medido: `--z-index-modal` no `@theme` não gera classe nenhuma), então as
 *     camadas vêm de `@utility`. Se alguém escrever `z-popover` sem declarar, o Tailwind
 *     simplesmente não emite CSS — não é erro de build, não é erro de `svelte-check`, e o
 *     elemento cai para `z-index: auto`. O sintoma aparece só no browser, num popover que
 *     some atrás do véu.
 *
 *  2. **A ordem era convenção oral.** Quatro números soltos em seis arquivos (doc 93 §M-6).
 *     Aqui ela vira asserção: o véu abaixo do painel, o painel abaixo do toast, o toast abaixo
 *     do atalho de teclado.
 */

const RAIZ = new URL('../../', import.meta.url).pathname;
const css = readFileSync(join(RAIZ, 'lib/styles/app.css'), 'utf8');

/** As camadas declaradas em `@utility`, na ordem em que aparecem no arquivo. */
function utilitariosDeclarados(): string[] {
	return [...css.matchAll(/@utility\s+(z-[a-z-]+)\s*\{/g)].map((m) => m[1]);
}

function valorDoToken(nome: string): number {
	const m = css.match(new RegExp(`--mv-${nome}:\\s*(\\d+)`));
	if (!m) throw new Error(`app.css não declara --mv-${nome}`);
	return Number(m[1]);
}

/** Só código de PRODUÇÃO: um teste que fala sobre `z-popover` não usa `z-popover`. */
function arquivosDeCodigo(dir: string, acc: string[] = []): string[] {
	for (const nome of readdirSync(dir)) {
		const caminho = join(dir, nome);
		if (statSync(caminho).isDirectory()) arquivosDeCodigo(caminho, acc);
		else if (/\.(svelte|ts)$/.test(nome) && !/\.test\.(ts|svelte)$/.test(nome)) acc.push(caminho);
	}
	return acc;
}

/** Comentário também não é marcação — e é lá que o nome de uma classe aparece por citação. */
function semComentario(fonte: string): string {
	return fonte
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/\/\*[\s\S]*?\*\//g, '')
		.replace(/(^|[^:])\/\/.*$/gm, '$1');
}

describe('camadas flutuantes', () => {
	it('a ordem do empilhamento é véu → painel → toast → atalho', () => {
		const cobertura = valorDoToken('z-cobertura');
		const painel = valorDoToken('z-painel');
		const toast = valorDoToken('z-toast');
		const atalho = valorDoToken('z-atalho');

		expect(cobertura).toBeLessThan(painel);
		expect(painel).toBeLessThan(toast);
		expect(toast).toBeLessThan(atalho);
	});

	it('cada token tem o seu utilitário — token sem utilitário não pinta nada', () => {
		expect(utilitariosDeclarados().sort()).toEqual([
			'z-atalho',
			'z-cobertura',
			'z-painel',
			'z-toast'
		]);
	});

	/**
	 * A trava principal. Sem ela, `class="z-popover"` compila, passa no `svelte-check`, passa na
	 * suíte inteira — e não existe no CSS.
	 */
	it('todo z-<nome> usado no código está declarado — o Tailwind não avisa quando não está', () => {
		const declarados = new Set(utilitariosDeclarados());
		const usadosSemDeclaracao: string[] = [];

		for (const caminho of arquivosDeCodigo(join(RAIZ, 'lib')).concat(
			arquivosDeCodigo(join(RAIZ, 'routes'))
		)) {
			const fonte = semComentario(readFileSync(caminho, 'utf8'));
			// `z-` seguido de letra: o numérico (`z-40`) é do Tailwind e não precisa de declaração.
			for (const m of fonte.matchAll(/\bz-([a-z][a-z-]*)\b/g)) {
				const classe = `z-${m[1]}`;
				if (classe === 'z-index') continue; // a propriedade CSS, não a classe
				if (!declarados.has(classe)) usadosSemDeclaracao.push(`${caminho} → ${classe}`);
			}
		}

		expect(usadosSemDeclaracao).toEqual([]);
	});
});
