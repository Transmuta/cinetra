import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * O tripwire ao contrário do `cor-crua.test.ts`: **token do app não entra na central de ajuda**.
 *
 * Nasceu de um bug encontrado ao vivo em 2026-08-06. A central usa a casca das páginas públicas —
 * papel/navy FIXO, sem tema escuro, como `/termos` e `/privacidade`. Os componentes dela, porém,
 * tinham nascido com os utilitários do app interno (`bg-surface`, `text-ink`, `border-edge`), que
 * mudam com o `data-theme` do aparelho. O sintoma: no tema escuro, o campo de busca virava uma
 * caixa PRETA no meio da página creme, e o texto das tabelas e dos avisos sumia.
 *
 * O `cor-crua.test.ts` não pega isto por construção — ele procura o oposto (hex escrito à mão) e a
 * família `ajuda/` é isenta lá justamente por usar a paleta da marca. Sem este teste, a próxima
 * pessoa a acrescentar um bloco copia uma classe do app interno e o defeito volta, invisível para
 * quem revisa no tema claro.
 */

const PASTA = new URL('.', import.meta.url).pathname;

/**
 * Os utilitários do app que dependem do tema. É a lista dos que existem em `app.css` e mudam entre
 * claro e escuro — não uma varredura por `text-` ou `bg-`, que pegaria classe de layout inocente.
 */
const CLASSES_DO_APP =
	/\b(?:bg|text|border|divide|ring|fill|stroke|placeholder)-(?:surface|surface-2|canvas|ink|muted|faint|edge|edge-strong|rail|primary|on-primary|accent|accent-text|accent-subtle|accent-border|danger|warning|success|info)\b/g;

/** Os tokens em CSS custom property do app, que também trocam com o tema. */
const TOKENS_DO_APP = /var\(--color-[a-z0-9-]+\)/g;

function semComentario(fonte: string): string {
	const vazio = (m: string) => m.replace(/[^\n]/g, '');
	return fonte
		.replace(/<!--[\s\S]*?-->/g, vazio)
		.replace(/\/\*[\s\S]*?\*\//g, vazio)
		.replace(/(^|[^:])\/\/.*$/gm, '$1');
}

function tokenDoAppNaCentral(): string[] {
	const achados: string[] = [];

	for (const nome of readdirSync(PASTA)) {
		if (!nome.endsWith('.svelte')) continue;

		semComentario(readFileSync(join(PASTA, nome), 'utf8'))
			.split('\n')
			.forEach((linha, i) => {
				for (const m of linha.matchAll(CLASSES_DO_APP)) achados.push(`${nome}:${i + 1} → ${m[0]}`);
				for (const m of linha.matchAll(TOKENS_DO_APP)) achados.push(`${nome}:${i + 1} → ${m[0]}`);
			});
	}

	return achados;
}

describe('paleta da central de ajuda', () => {
	it('nenhum componente usa token de tema do app — a central é papel/navy fixo', () => {
		expect(tokenDoAppNaCentral()).toEqual([]);
	});
});
