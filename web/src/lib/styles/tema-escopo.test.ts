import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

/**
 * As telas de entrada (login, cadastro) e a de onboarding não seguem o tema do usuário: elas são
 * papel/navy do protótipo, sempre. Quem carrega essa decisão é o `AuthCard`, com um
 * `data-theme="light"` no próprio nó — mas o atributo só significa alguma coisa se o `app.css`
 * declarar os tokens claros para um `[data-theme='light']` **que não seja o `:root`**.
 *
 * Este teste guarda exatamente esse elo. Sem ele, o atributo continua no HTML, o `AuthCard.test`
 * continua verde e a tela continua escura — que é o pior desfecho: a regra parece existir.
 *
 * (jsdom não resolve cascata nem custom properties herdadas, então a prova visual de fato está no
 * `e2e/tema-auth-claro.spec.ts`. Isto aqui é o pedaço que roda no CI sem stack.)
 */

const css = readFileSync(new URL('./app.css', import.meta.url), 'utf8');

/** A lista de seletores do bloco que declara os tokens do tema claro. */
function seletoresDoTemaClaro(): string[] {
	const i = css.indexOf(":root[data-theme='light']");
	if (i < 0) throw new Error("app.css não declara mais :root[data-theme='light']");
	const abre = css.indexOf('{', i);
	// A lista começa depois do comentário que titula o bloco.
	const inicio = css.lastIndexOf('*/', i) + 2;
	return css
		.slice(inicio, abre)
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean);
}

/** Corpo do bloco que começa no primeiro `{` depois de `seletor`, até a chave que o fecha. */
function corpoDoBloco(seletor: string): string {
	const i = css.indexOf(seletor);
	if (i < 0) throw new Error(`app.css não declara mais ${seletor}`);
	const abre = css.indexOf('{', i);

	let nivel = 0;
	for (let p = abre; p < css.length; p++) {
		if (css[p] === '{') nivel++;
		else if (css[p] === '}' && --nivel === 0) return css.slice(abre + 1, p);
	}
	throw new Error(`bloco de ${seletor} não fecha`);
}

describe('escopo do tema claro', () => {
	it('os tokens claros valem para qualquer nó com data-theme="light", não só o :root', () => {
		expect(seletoresDoTemaClaro()).toContain("[data-theme='light']");
	});

	it('o bloco continua declarando as superfícies e o texto (é o que a auth herda)', () => {
		const i = css.indexOf(":root[data-theme='light']");
		const corpo = css.slice(css.indexOf('{', i), css.indexOf('\n}', i));

		for (const token of ['--mv-surface:', '--mv-canvas:', '--mv-text:', '--mv-primary:']) {
			expect(corpo).toContain(token);
		}
	});
});

/**
 * `color-scheme` é a metade da troca de tema que o CSS do app NÃO consegue fazer sozinho.
 *
 * Os tokens `--mv-*` pintam tudo que é nosso. O que eles não alcançam é o que o browser desenha
 * dentro do shadow-DOM da UA: o ícone do `<input type="date">`, o painel do `<select>`, a barra de
 * rolagem, o realce de autofill. Quem governa isso é `color-scheme` — e sem ele o browser assume
 * que o documento é claro e pinta ícone PRETO sobre a nossa superfície escura (#000 sobre #16181c
 * = 1,15:1, medido em Chromium no doc 93 §A-1).
 *
 * O furo era silencioso por construção: o axe não avalia pseudo-elemento da UA, e o
 * `contraste.test.ts` mede pares de token — e este par não é de token, é do browser. Por isso a
 * trava é aqui, na declaração, e não numa varredura.
 *
 * O `AuthCard` continua sobrescrevendo o seu inline (`color-scheme:light`), que é o comportamento
 * certo: ele é claro mesmo quando o documento é escuro.
 */
describe('color-scheme acompanha o tema', () => {
	it('o bloco claro declara color-scheme: light', () => {
		expect(corpoDoBloco(":root[data-theme='light']")).toMatch(/color-scheme:\s*light/);
	});

	it('o bloco escuro declara color-scheme: dark', () => {
		expect(corpoDoBloco(":root[data-theme='dark']")).toMatch(/color-scheme:\s*dark/);
	});

	it('quem não escolheu tema e está no escuro do SO também recebe o dark', () => {
		expect(corpoDoBloco(':root:not([data-theme])')).toMatch(/color-scheme:\s*dark/);
	});
});
