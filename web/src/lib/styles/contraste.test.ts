import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Tripwire de contraste: mede os pares do design system **lendo o `app.css`**.
 *
 * Por que um teste e não só o `scripts/contraste-tokens.mjs`: o script prova o estado de hoje,
 * quando alguém se lembra de rodá-lo. Isto reprova o commit. A auditoria do doc 83 mediu 36
 * reprovas em 76 pares, e a maior delas (`--mv-faint`, 155 nós em 18 telas) tinha passado por
 * duas rodadas de calibragem visual sem ninguém notar — porque nada media.
 *
 * Lê o CSS em vez de repetir os hex aqui de propósito: um teste que carrega os valores à mão
 * concorda com o CSS até o dia em que divergem, e aí passa verde sobre uma paleta que mudou.
 *
 * Pisos: **4,5** para texto (1.4.3, e nenhum texto pequeno deste app chega a "texto grande" —
 * badge é 10,5px bold, metadado é 11–12px) e **3** para indicador de foco (1.4.11).
 */

const css = readFileSync(new URL('./app.css', import.meta.url), 'utf8');

/** As declarações `--mv-*` de um bloco, achado pelo seu seletor. */
function bloco(seletor: string): Record<string, string> {
	const i = css.indexOf(seletor);
	if (i < 0) throw new Error(`bloco não encontrado no app.css: ${seletor}`);
	const abre = css.indexOf('{', i);
	const fecha = css.indexOf('\n}', abre);
	const corpo = css.slice(abre, fecha);

	const out: Record<string, string> = {};
	for (const [, nome, valor] of corpo.matchAll(/--mv-([\w-]+):\s*([^;]+);/g)) {
		out[nome.replace(/-/g, '_')] = valor.trim();
	}
	return out;
}

// O primeiro `:root {` traz as semânticas e o acento — o que não muda com o tema.
const COMPARTILHADO = bloco(':root {');
const CLARO = { ...COMPARTILHADO, ...bloco(":root[data-theme='light']") };
const ESCURO = { ...COMPARTILHADO, ...bloco(":root[data-theme='dark']") };

/**
 * `rgba(…)` achatado sobre um fundo opaco. Dois tokens do tema escuro (`accent-subtle`,
 * `accent-border`) são translúcidos, e razão de contraste não sabe o que é transparência: sem
 * achatar, o teste mediria a cor errada e passaria por sorte.
 */
function opaco(cor: string, fundo: string): string {
	const m = /rgba?\(([^)]+)\)/.exec(cor);
	if (!m) return cor;
	const [r, g, b, a = '1'] = m[1].split(',').map((v) => Number(v.trim()));
	const f = canais(fundo);
	const mix = [r, g, b].map((c, i) => Math.round(Number(a) * c + (1 - Number(a)) * f[i]));
	return '#' + mix.map((c) => c.toString(16).padStart(2, '0')).join('');
}

/** `cor` a `pct` de opacidade sobre `fundo` — o que `bg-<cor>/14` e `color-mix` produzem. */
function mistura(cor: string, pct: number, fundo: string): string {
	const [c, f] = [canais(cor), canais(fundo)];
	return (
		'#' +
		c
			.map((v, i) => Math.round(pct * v + (1 - pct) * f[i]).toString(16).padStart(2, '0'))
			.join('')
	);
}

function canais(hex: string): [number, number, number] {
	const c = hex.replace('#', '');
	return [0, 2, 4].map((i) => parseInt(c.slice(i, i + 2), 16)) as [number, number, number];
}

function luminancia(hex: string): number {
	const f = (v: number) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
	const [r, g, b] = canais(hex).map((c) => f(c / 255));
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function razao(a: string, b: string): number {
	const [x, y] = [luminancia(a), luminancia(b)];
	return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

const temas: [string, Record<string, string>][] = [
	['claro', CLARO],
	['escuro', ESCURO]
];

describe('contraste dos tokens (WCAG 2 AA)', () => {
	describe.each(temas)('tema %s', (_tema, T) => {
		// O texto do app inteiro: três níveis de cinza sobre três superfícies.
		it.each(['text', 'muted', 'faint'])('%s passa 4,5:1 sobre as três superfícies', (fg) => {
			for (const bg of ['canvas', 'surface', 'surface2']) {
				const r = razao(T[fg], T[bg]);
				expect(r, `--mv-${fg} sobre --mv-${bg} (${T[fg]} / ${T[bg]})`).toBeGreaterThanOrEqual(4.5);
			}
		});

		it('accent_text passa 4,5:1 sobre surface e sobre o próprio chip', () => {
			for (const bg of ['surface', 'surface2', 'accent_subtle']) {
				const fundo = opaco(T[bg], T.surface);
				expect(
					razao(T.accent_text, fundo),
					`accent_text sobre ${bg} (${fundo})`
				).toBeGreaterThanOrEqual(4.5);
			}
		});

		/**
		 * A regra de família das cores sólidas (doc 83 §5): **texto escuro** sobre `accent`,
		 * `success`, `warning` e `info` — o precedente é a badge ENCAIXE. `danger` é a exceção:
		 * escureceu e ficou com texto branco, porque botão destrutivo com texto escuro sobre
		 * vermelho claro perde a força de aviso.
		 *
		 * O `ink` aqui é o do tema CLARO nos dois casos, cravado: estas cores não mudam com o
		 * tema, então o texto sobre elas também não pode mudar.
		 */
		it('fundo semântico sólido + on-solid passa 4,5:1', () => {
			for (const cor of ['accent_solid', 'success_solid', 'warning_solid', 'info_solid']) {
				expect(
					razao(T.on_solid, T[cor]),
					`--mv-on-solid sobre --mv-${cor} (${T.on_solid} / ${T[cor]})`
				).toBeGreaterThanOrEqual(4.5);
			}
		});

		it('danger sólido + texto branco passa 4,5:1', () => {
			expect(
				razao('#ffffff', T.danger_solid),
				`branco sobre --mv-danger-solid (${T.danger_solid})`
			).toBeGreaterThanOrEqual(4.5);
		});

		/**
		 * As semânticas como TEXTO, que era o furo silencioso: as mesmas quatro cores serviam de
		 * fundo e de texto, e como texto no tema claro chegavam a 2,03. Por isso elas viraram
		 * por-tema — e por isso este teste roda nos dois.
		 */
		it.each(['success', 'warning', 'danger', 'info'])(
			'text-%s passa 4,5:1 sobre as superfícies do tema',
			(sem) => {
				for (const bg of ['surface', 'surface2', 'canvas']) {
					expect(
						razao(T[sem], T[bg]),
						`--mv-${sem} sobre --mv-${bg} (${T[sem]} / ${T[bg]})`
					).toBeGreaterThanOrEqual(4.5);
				}
			}
		);

		/**
		 * E sobre a PRÓPRIA tinta. O app pinta calouts e chips com `bg-<sem>/10..14` ou
		 * `color-mix(<sem> 12%)` e põe `text-<sem>` em cima — aí o fundo já está tingido da cor do
		 * texto e come contraste. Foi o que sobrou depois do primeiro conserto da paleta: o chip
		 * ENCAIXE da legenda ficou em 4,19 com um âmbar que passava folgado sobre branco.
		 *
		 * 14% é o maior tom em uso (`bg-warning/14`), então é o pior caso.
		 */
		it.each(['success', 'warning', 'danger', 'info'])(
			'text-%s passa 4,5:1 sobre a própria tinta de 14%',
			(sem) => {
				const tinta = mistura(T[sem], 0.14, T.surface);
				expect(
					razao(T[sem], tinta),
					`--mv-${sem} (${T[sem]}) sobre a tinta 14% dele mesmo (${tinta})`
				).toBeGreaterThanOrEqual(4.5);
			}
		);

		/**
		 * `primary` + `on-primary` — **EXCEÇÃO DE CONTRASTE REGISTRADA** (ADR-020, débito D-17).
		 *
		 * Decisão humana explícita de 2026-07-30: o botão primário passou a ser o sage da marca
		 * (`--mv-sage`, #7fa59a) com texto **branco**, que mede **2,71:1** — abaixo dos 4,5 de
		 * 1.4.3 e abaixo até dos 3 de 1.4.11. A alternativa que passava (texto escuro, 6,56) foi
		 * medida e recusada por legibilidade percebida.
		 *
		 * Este teste **não afrouxa nada**: ele CRAVA o par fora de conformidade, para que a
		 * exceção seja um fato medido e versionado em vez de um furo silencioso — que era o
		 * estado anterior, em que `primary` simplesmente não era medido por ninguém e a troca
		 * teria passado verde. Qualquer mexida futura passa por aqui e encara o número.
		 */
		it('primary é o sage da marca com texto branco (exceção registrada, ADR-020)', () => {
			expect(T.primary, 'primary deve ser o próprio --mv-sage, sem variante').toBe(T.sage);
			expect(T.on_primary, 'o texto sobre primary é branco, por decisão').toBe('#ffffff');
		});

		it('a exceção de primary continua valendo 2,71:1 — e avisa quando deixar de valer', () => {
			const r = razao(T.on_primary, T.primary);
			// Faixa estreita de propósito: qualquer ajuste no sage ou no texto cai aqui.
			expect(r, `branco sobre primary (${T.on_primary} / ${T.primary})`).toBeGreaterThan(2.6);
			expect(
				r,
				`branco sobre primary subiu para ${r.toFixed(2)}. Se passou de 4,5, a exceção do ` +
					`ADR-020 morreu: apague estes dois testes, restaure o piso de 4,5 e feche o D-17.`
			).toBeLessThan(4.5);
		});

		/**
		 * ADR-021: o acento **é** o sage da marca, nos dois temas. Antes era o teal do protótipo.
		 *
		 * Cravar a igualdade (e não o hex) é o ponto: se alguém reintroduzir uma cor própria para o
		 * acento, este teste cai e a pessoa encara a decisão em vez de descobrir depois que o app
		 * voltou a ter duas identidades. E, ao contrário do par `primary`/`on-primary` logo acima,
		 * aqui **não há exceção de contraste**: os papéis do acento são medidos pelos testes
		 * vizinhos (texto sobre chip, `on-solid` sobre o sólido, anel de foco) e todos passam.
		 */
		it('o acento é o sage da marca, nos dois temas (ADR-021)', () => {
			expect(T.accent_solid, 'accent-solid deve ser o próprio --mv-sage').toBe(T.sage);
			// O hover escurece a mesma matiz — a convenção que o `primary` cita.
			expect(razao(T.accent_hover, '#ffffff')).toBeGreaterThan(razao(T.accent_solid, '#ffffff'));
		});

		/**
		 * Indicador de foco (1.4.11, piso 3). O anel é **duplo** — o acento + um companheiro na cor
		 * do texto — porque o app tem superfícies quase brancas *e* o rail escuro nos dois temas:
		 * nenhuma cor única aparece em todas. O contrato que este teste fixa é o que importa de
		 * fato: em cada superfície, **pelo menos um** dos dois anéis contrasta.
		 */
		it('o anel de foco aparece em toda superfície, inclusive no rail', () => {
			for (const bg of ['canvas', 'surface', 'surface2', 'rail', 'rail_item']) {
				const melhor = Math.max(razao(T.accent_solid, T[bg]), razao(T.text, T[bg]));
				expect(melhor, `melhor anel sobre --mv-${bg} (${T[bg]})`).toBeGreaterThanOrEqual(3);
			}
		});
	});

	/**
	 * O teste acima prova que os DOIS anéis, juntos, cobrem toda superfície — mas passaria de
	 * graça com a regra usando um só (foi o que aconteceu na primeira versão deste arquivo: verde
	 * sobre um app onde o foco era invisível no tema claro). Aqui a regra CSS é lida.
	 */
	it('a regra de :focus-visible emite os dois anéis', () => {
		const i = css.indexOf(':focus-visible');
		const regra = css.slice(i, css.indexOf('}', i));
		expect(regra, 'o anel do acento').toContain('--mv-accent-solid');
		expect(regra, 'o anel companheiro, na cor do texto do tema').toContain('--mv-text');
	});

	it('o parser achou os três blocos de token', () => {
		// Guarda do próprio teste: se o `app.css` for reorganizado e um bloco deixar de casar, os
		// `expect` acima passariam medindo `undefined` — que é pior que falhar.
		expect(Object.keys(COMPARTILHADO)).toContain('accent_solid');
		expect(Object.keys(CLARO)).toContain('faint');
		expect(Object.keys(ESCURO)).toContain('faint');
		expect(CLARO.faint).not.toBe(ESCURO.faint);
	});
});

/**
 * O piso de 4,5 é de 1.4.3, e 1.4.3 não distingue 10px de 17px — abaixo de "texto grande" está
 * tudo no mesmo balde. Na tela isso não se sustenta: a badge `grupo · cap N` da lista de tipos
 * media **4,65** (`--mv-on-solid` sobre `--mv-info-solid`), passava o teste de par acima, e não
 * dava para ler. Azul saturado é a pior base da família para tinta escura — os vizinhos medem
 * 5,31 (success) e 8,63 (warning), e é por isso que a ENCAIXE, que é a mesma anatomia em âmbar,
 * nunca reclamou.
 *
 * Então: **fundo semântico sólido carregando `text-micro` (10px) pede o piso AAA de 7:1.** Não é
 * regra de WCAG para este tamanho — é a leitura de que 10px bold sobre cor cheia gasta a margem
 * que 4,5 não tem sobrando. Quem não alcançar 7 usa o par tingido (`bg-<sem>/14` + `text-<sem>`,
 * medido logo acima), que é o que o `Badge` do design system já emite.
 *
 * Varre a MARCAÇÃO porque o par sozinho não denuncia nada: `info-solid` + `on-solid` é legítimo
 * num botão de 13px. O que reprova é a combinação com o tamanho.
 */
describe('fundo semântico sólido com texto de 10px', () => {
	const APP = new URL('../../', import.meta.url).pathname;

	/** Só o `class="…"` literal; `class={expr}` computado não é varrido (o `Badge` mora lá). */
	const CLASSES = /class="([^"]*)"/g;
	const SOLIDO = /\bbg-(success|warning|danger|info|accent)-solid\b/;
	const PISO_MICRO = 7;

	function svelteDoAppInterno(dir: string, acc: string[] = []): string[] {
		for (const nome of readdirSync(dir)) {
			const caminho = join(dir, nome);
			if (statSync(caminho).isDirectory()) svelteDoAppInterno(caminho, acc);
			else if (nome.endsWith('.svelte')) acc.push(caminho);
		}
		return acc;
	}

	/** Cada `class="…"` que junta um fundo sólido a `text-micro`, com o par de cor que ele pinta. */
	function paresMicro(): { onde: string; fundo: string; texto: string; razao: number }[] {
		const alvos = [
			...svelteDoAppInterno(join(APP, 'lib/components')),
			...svelteDoAppInterno(join(APP, 'routes/(app)'))
		];

		const achados = [];

		for (const caminho of alvos) {
			const rel = relative(APP, caminho).replaceAll('\\', '/');

			for (const [, classe] of readFileSync(caminho, 'utf8').matchAll(CLASSES)) {
				const m = SOLIDO.exec(classe);
				if (!m || !/\btext-micro\b/.test(classe)) continue;

				const fundo = COMPARTILHADO[`${m[1]}_solid`];
				const texto = /\btext-white\b/.test(classe) ? '#ffffff' : COMPARTILHADO.on_solid;

				achados.push({
					onde: `${rel} → bg-${m[1]}-solid`,
					fundo,
					texto,
					razao: razao(texto, fundo)
				});
			}
		}

		return achados;
	}

	it('todo par sólido + micro passa 7:1', () => {
		for (const p of paresMicro()) {
			expect(
				p.razao,
				`${p.onde}: ${p.texto} sobre ${p.fundo} dá ${p.razao.toFixed(2)} — 10px bold sobre cor ` +
					`cheia precisa de ${PISO_MICRO}; use o par tingido (bg-<sem>/14 + text-<sem>)`
			).toBeGreaterThanOrEqual(PISO_MICRO);
		}
	});

	it('o scanner enxerga: a badge ENCAIXE é o par sólido + micro que passa', () => {
		// Guarda contra o pior desfecho — verde por a varredura não achar nada.
		const pares = paresMicro();
		expect(
			pares.length,
			'nenhum par sólido+micro encontrado — o scanner parou de ler'
		).toBeGreaterThan(0);
		expect(pares.map((p) => p.onde)).toContain(
			'lib/components/agenda/ListView.svelte → bg-warning-solid'
		);
	});
});
