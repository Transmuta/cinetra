/**
 * Razão de contraste WCAG 2.x sobre os tokens do design system, nos dois temas.
 *
 *     node scripts/contraste-tokens.mjs
 *
 * Por que um script além do axe (`e2e/a11y-*.spec.ts`): o axe mede **o que está na tela do
 * cenário que a spec semeou**. Um par que só aparece num estado raro — badge de falta, chip
 * ABRIU da fila, botão teal sólido — passa despercebido e vai reprovar em produção. O app
 * inteiro pinta com a meia dúzia de pares abaixo (`src/lib/styles/app.css`), então medir os
 * pares vale por medir todas as telas, inclusive as que ninguém varreu ainda.
 *
 * Os valores são copiados do `app.css` **à mão**, de propósito: o objetivo é que mudar um token
 * e esquecer de rodar isto seja visível na revisão do diff, e não que o script siga a paleta em
 * silêncio. Ao mexer nos tokens, ajuste as duas tabelas.
 *
 * Pisos usados: **4,5** para texto normal (1.4.3) e **3** para texto grande e para limite de
 * componente / indicador de foco (1.4.11). Cuidado com "texto grande": só vale a partir de 24px,
 * ou 18,66px **em bold** — 10,5px bold NÃO é texto grande, e é justamente o tamanho dos
 * metadados e badges deste app.
 *
 * A leitura dos resultados está no doc 83 (§5); o histórico, no doc 80.
 */

const LIGHT = {
	canvas: '#fbfcfd',
	surface: '#ffffff',
	surface2: '#f6f8f9',
	bs: '#e4e7eb',
	bd: '#cdd3d9',
	text: '#161a1e',
	muted: '#5c6670',
	faint: '#8a929b',
	primary: '#16181c',
	on_primary: '#ffffff',
	teal_text: '#0a7e73',
	teal_subtle: '#e5f7f4',
	teal_border: '#7fdacd',
	rail: '#16181c',
	rail_item: '#26292f'
};

const DARK = {
	canvas: '#0c0d0e',
	surface: '#16181c',
	surface2: '#1c1f24',
	bs: '#24282e',
	bd: '#313640',
	text: '#eceef0',
	muted: '#9aa3ac',
	faint: '#6b747d',
	primary: '#eceef0',
	on_primary: '#16181c',
	teal_text: '#3fd6c7',
	// Estes dois são `rgba` no tema escuro. A razão de contraste não sabe o que é transparência,
	// então entram ACHATADOS sobre `surface` (#16181c), que é onde de fato pintam. Achatar sobre
	// outra superfície daria outro número — é uma aproximação consciente, não um valor do CSS.
	teal_subtle: '#153132', // rgba(15,181,166,.16) sobre #16181c
	teal_border: '#456f6c', // rgba(127,218,205,.45) sobre #16181c
	rail: '#08090a',
	rail_item: '#1a1d22'
};

/** Semânticas e marca: iguais nos dois temas (são pigmento, não superfície). */
const SHARED = {
	success: '#2da160',
	warning: '#f5a623',
	danger: '#e5484d',
	info: '#2b7fff',
	teal_solid: '#0fb5a6',
	teal_hover: '#0ba294',
	sage: '#7fa59a',
	blue: '#3a5a78',
	white: '#ffffff',
	/** O `ink` do tema CLARO cravado — é o que a badge ENCAIXE usa, fixo, porque o âmbar não
	    muda com o tema e `text-ink` inverteria justamente onde não pode (doc 80 §2, item 3). */
	ink_fixo: '#161a1e'
};

function lum(hex) {
	const c = hex.replace('#', '');
	const [r, g, b] = [0, 2, 4].map((i) => parseInt(c.slice(i, i + 2), 16) / 255);
	const f = (v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
	return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

function ratio(a, b) {
	const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
	return (l1 + 0.05) / (l2 + 0.05);
}

function pares(T, tema) {
	const P = { ...T, ...SHARED };
	const p = (nome, fg, bg, piso, nota = '') => ({ tema, nome, fg: P[fg], bg: P[bg], piso, nota });
	return [
		// texto sobre superfícies
		p('ink / surface', 'text', 'surface', 4.5),
		p('ink / canvas', 'text', 'canvas', 4.5),
		p('muted / surface', 'muted', 'surface', 4.5),
		p('muted / surface2', 'muted', 'surface2', 4.5),
		p('muted / canvas', 'muted', 'canvas', 4.5),
		p('faint / surface', 'faint', 'surface', 4.5, 'metadado 10,5–12px'),
		p('faint / surface2', 'faint', 'surface2', 4.5, 'metadado 10,5–12px'),
		p('faint / canvas', 'faint', 'canvas', 4.5, 'metadado 10,5–12px'),
		// teal
		p('teal_text / surface', 'teal_text', 'surface', 4.5),
		p('teal_text / surface2', 'teal_text', 'surface2', 4.5),
		p('teal_text / teal_subtle', 'teal_text', 'teal_subtle', 4.5, 'chip teal'),
		p('branco / teal_solid', 'white', 'teal_solid', 4.5, 'botão teal, chip ABRIU'),
		p('branco / teal_hover', 'white', 'teal_hover', 4.5, 'botão teal :hover'),
		p('ink_fixo / teal_solid', 'ink_fixo', 'teal_solid', 4.5, 'alternativa: texto escuro'),
		// botão primário
		p('on_primary / primary', 'on_primary', 'primary', 4.5, 'botão primário'),
		// badges (10,5px bold — NÃO é texto grande, piso 4,5)
		p('branco / success', 'white', 'success', 4.5, 'badge'),
		p('branco / danger', 'white', 'danger', 4.5, 'badge, PriorityBadge'),
		p('branco / info', 'white', 'info', 4.5, 'badge'),
		p('branco / warning', 'white', 'warning', 4.5, 'badge — era o ENCAIXE'),
		p('ink_fixo / warning', 'ink_fixo', 'warning', 4.5, 'ENCAIXE consertado'),
		p('ink_fixo / success', 'ink_fixo', 'success', 4.5, 'alternativa: texto escuro'),
		p('ink_fixo / danger', 'ink_fixo', 'danger', 4.5, 'alternativa: texto escuro'),
		p('ink_fixo / info', 'ink_fixo', 'info', 4.5, 'alternativa: texto escuro'),
		// KPI de /relatorios: número 23px semibold, direto sobre a superfície do card.
		// 23px < 24px ⇒ piso 4,5, e não os 3 de texto grande.
		p('KPI warning / surface', 'warning', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI success / surface', 'success', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI danger / surface', 'danger', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI info / surface', 'info', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI teal / surface', 'teal_solid', 'surface', 4.5, 'número 23px de /relatorios'),
		// rail (escuro nos dois temas)
		p('branco / rail', 'white', 'rail', 4.5, 'ícone/label do rail'),
		p('branco / rail_item', 'white', 'rail_item', 4.5),
		// não-textual: 1.4.11 pede 3:1
		p('anel de foco (teal_solid) / surface', 'teal_solid', 'surface', 3, 'foco 1.4.11'),
		p('anel de foco (teal_solid) / canvas', 'teal_solid', 'canvas', 3, 'foco 1.4.11'),
		p('anel de foco (teal_solid) / surface2', 'teal_solid', 'surface2', 3, 'foco 1.4.11'),
		p('borda sutil (bs) / surface', 'bs', 'surface', 3, 'borda de input 1.4.11'),
		p('borda densa (bd) / surface', 'bd', 'surface', 3, 'borda de input 1.4.11'),
		p('teal_border / surface', 'teal_border', 'surface', 3, '1.4.11'),
		// marca
		p('branco / blue', 'white', 'blue', 4.5, 'gradiente landing/aside'),
		p('branco / sage', 'white', 'sage', 4.5, 'gradiente landing/aside')
	];
}

const linhas = [...pares(LIGHT, 'claro'), ...pares(DARK, 'escuro')];
const fmt = (n) => n.toFixed(2).replace('.', ',');

let reprovas = 0;
console.log('| tema | par | fg | bg | razão | piso | veredito | nota |');
console.log('| --- | --- | --- | --- | --- | --- | --- | --- |');
for (const l of linhas) {
	const r = ratio(l.fg, l.bg);
	const ok = r >= l.piso;
	if (!ok) reprovas++;
	console.log(
		`| ${l.tema} | ${l.nome} | \`${l.fg}\` | \`${l.bg}\` | **${fmt(r)}** | ${l.piso} | ` +
			`${ok ? 'passa' : '**REPROVA**'} | ${l.nota} |`
	);
}
console.log(`\ntotal: ${linhas.length} pares, ${reprovas} reprovas`);

// ---------------------------------------------------------------------------------------------
// Candidatos: qual o menor ajuste que bate o piso?
//
// Anda com a cor em passos de 1 por canal PARA LONGE do fundo — escurece se o fundo é o mais
// claro dos dois, clareia se é o mais escuro. (Andar para dentro do fundo só derruba a razão: foi
// o bug da primeira versão, que devolvia "não existe candidato" para todos os pares.)
// ---------------------------------------------------------------------------------------------
function candidato(base, fundo, piso) {
	const c = parseInt(base.slice(1), 16);
	const escurecer = lum(fundo) > lum(base);
	for (let i = 0; i < 256; i++) {
		const hex =
			'#' +
			[16, 8, 0]
				.map((s) => {
					const v = Math.max(0, Math.min(255, ((c >> s) & 255) + (escurecer ? -i : i)));
					return v.toString(16).padStart(2, '0');
				})
				.join('');
		if (ratio(hex, fundo) >= piso) return { hex, r: ratio(hex, fundo) };
	}
	return null;
}

console.log('\n## Candidatos\n');
for (const [rot, base, fundo, piso] of [
	['faint claro (o pior caso é sobre surface2)', LIGHT.faint, LIGHT.surface2, 4.5],
	['faint escuro (sobre surface2)', DARK.faint, DARK.surface2, 4.5],
	['anel de foco no tema claro (sobre surface2)', SHARED.teal_solid, LIGHT.surface2, 3],
	['teal_text sobre teal_subtle (claro)', LIGHT.teal_text, LIGHT.teal_subtle, 4.5],
	['teal_solid escurecido para aceitar texto branco', SHARED.teal_solid, SHARED.white, 4.5],
	['success escurecido para aceitar texto branco', SHARED.success, SHARED.white, 4.5],
	['danger escurecido para aceitar texto branco', SHARED.danger, SHARED.white, 4.5],
	['info escurecido para aceitar texto branco', SHARED.info, SHARED.white, 4.5],
	['borda densa (bd) do tema claro', LIGHT.bd, LIGHT.surface, 3]
]) {
	const c = candidato(base, fundo, piso);
	console.log(
		`- **${rot}**: \`${base}\` (${fmt(ratio(base, fundo))}) → ` +
			`\`${c?.hex ?? '—'}\` (${c ? fmt(c.r) : '—'}) para bater ${piso}`
	);
}
