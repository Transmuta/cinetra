import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * A escala de DIMENSÃO — e o instrumento que não existia.
 *
 * A auditoria do doc 93 fechou com a leitura mais útil dela: **nenhum dos seis gates do projeto
 * olhava para consistência de dimensão**. Os 1.014 utilitários de valor arbitrário passavam por
 * todos eles sem tocar em nenhum, porque cada um é sintaticamente válido e individualmente
 * legítimo — `text-[12.5px]` não é erro de lugar nenhum. O que era erro é haver 22 deles.
 *
 * Este arquivo é esse instrumento. Ele não julga estética: julga se o app fala **uma** língua de
 * dimensão. Duas travas, e a segunda é a que mais importa:
 *
 *  1. a escala existe e está ordenada — degraus fora de ordem são um nome que mente;
 *  2. **nenhum valor arbitrário volta.** Sem isto, a escala vira sugestão: o próximo componente
 *     copia o `rounded-[14px]` do vizinho e ninguém fica sabendo.
 *
 * O escopo é o app interno. A landing e as telas de entrada são o protótipo da marca, com regras
 * próprias — a mesma isenção do `cor-crua.test.ts`, e pela mesma razão.
 */

const RAIZ = new URL('../../', import.meta.url).pathname;
const css = readFileSync(join(RAIZ, 'lib/styles/app.css'), 'utf8');

const ISENTOS = [
	'lib/components/AuthCard.svelte',
	'lib/components/AuthForm.svelte',
	'lib/components/GoogleIcon.svelte',
	'lib/components/Seo.svelte',
	'lib/components/cinetra/',
	'routes/+page.svelte'
];

function svelteDoAppInterno(dir: string, acc: string[] = []): string[] {
	for (const nome of readdirSync(dir)) {
		const caminho = join(dir, nome);
		if (statSync(caminho).isDirectory()) svelteDoAppInterno(caminho, acc);
		else if (nome.endsWith('.svelte') && !nome.endsWith('.test.svelte')) acc.push(caminho);
	}
	return acc;
}

function alvos(): { rel: string; fonte: string }[] {
	return [...svelteDoAppInterno(join(RAIZ, 'lib')), ...svelteDoAppInterno(join(RAIZ, 'routes'))]
		.map((c) => ({ rel: relative(RAIZ, c).replaceAll('\\', '/'), fonte: readFileSync(c, 'utf8') }))
		.filter(({ rel }) => !ISENTOS.some((i) => rel.startsWith(i)));
}

function ocorrencias(padrao: RegExp): string[] {
	const achados: string[] = [];
	for (const { rel, fonte } of alvos()) {
		fonte.split('\n').forEach((linha, i) => {
			for (const m of linha.matchAll(padrao)) achados.push(`${rel}:${i + 1} → ${m[0]}`);
		});
	}
	return achados;
}

function px(nome: string): number {
	const m = css.match(new RegExp(`--mv-${nome}:\\s*([\\d.]+)px`));
	if (!m) throw new Error(`app.css não declara --mv-${nome}`);
	return Number(m[1]);
}

describe('escala de raio', () => {
	it('os degraus sobem — micro < controle < cartão', () => {
		expect(px('radius-micro')).toBeLessThan(px('radius-controle'));
		expect(px('radius-controle')).toBeLessThan(px('radius-cartao'));
	});

	/**
	 * `rounded-md` e `rounded-lg` valiam **o mesmo 8px** (doc 93 §M-2): 184 usos escolhendo entre
	 * dois nomes idênticos. Os nomes de tamanho do Tailwind deixaram de ser sobrescritos, então um
	 * `rounded-md` esquecido não quebra nada visível — ele passa a valer o default do Tailwind, em
	 * silêncio. Daí a trava ser aqui.
	 */
	it('os nomes de TAMANHO do Tailwind não voltam — a escala é por papel', () => {
		expect(ocorrencias(/\brounded-(?:sm|md|lg|xl|2xl)\b/g)).toEqual([]);
	});

	it('nenhum raio arbitrário — eram 13 valores efetivos em 378 usos', () => {
		expect(ocorrencias(/\brounded(?:-[trbl]{1,2})?-\[[^\]]+\]/g)).toEqual([]);
	});
});

describe('escala tipográfica', () => {
	it('os sete degraus sobem', () => {
		const degraus = ['micro', 'meta', 'rotulo', 'corpo', 'leitura', 'titulo', 'destaque'];
		const valores = degraus.map((d) => px(`text-${d}`));

		expect(valores).toEqual([...valores].sort((a, b) => a - b));
		expect(new Set(valores).size).toBe(degraus.length); // nenhum degrau duplicado
	});

	/**
	 * O achado que motivou tudo: **22 tamanhos em 643 usos**, 261 em meio-pixel. `12px` e
	 * `12.5px` são indistinguíveis na tela e carregavam papéis diferentes em arquivos diferentes.
	 */
	it('nenhum tamanho de fonte arbitrário', () => {
		expect(ocorrencias(/\btext-\[[\d.]+(?:px|rem|em)\]/g)).toEqual([]);
	});

	/**
	 * `text-sm` e `text-corpo` na mesma base seriam dois vocabulários para a mesma decisão — que é
	 * exatamente o que a escala existe para acabar. `text-base` fica de fora da lista porque o
	 * degrau de 14px se chama `leitura`, justamente para não haver um nome com dois significados.
	 */
	it('a escala de TAMANHO do Tailwind não convive com a de papel', () => {
		expect(ocorrencias(/\btext-(?:xs|sm|base|lg|xl|2xl|3xl|4xl)\b/g)).toEqual([]);
	});
});
