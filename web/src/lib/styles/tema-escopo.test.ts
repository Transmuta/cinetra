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
