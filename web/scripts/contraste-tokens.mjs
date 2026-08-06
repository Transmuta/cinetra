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
	faint: '#6b737c',
	primary: '#7fa59a', // ADR-020: o sage da marca; NÃO inverte mais por tema
	primary_hover: '#72958b',
	on_primary: '#ffffff',
	// ADR-021: a família ERA o teal (`#0a7e73` / `#e5f7f4` / `#7fdacd`) e virou sage.
	accent_text: '#3b6d5f',
	accent_subtle: '#ebf4f2',
	accent_border: '#9cc9bc',
	// Semânticas como TEXTO: por tema desde o doc 83 — uma cor que contrasta com branco não
	// contrasta com quase-preto. Estavam em SHARED aqui, medindo o valor do tema errado.
	success: '#037736',
	warning: '#a15200',
	danger: '#c3262b',
	info: '#0b5fdf',
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
	faint: '#7e8790',
	primary: '#7fa59a', // idem ao claro — ver ADR-020
	primary_hover: '#72958b',
	on_primary: '#ffffff',
	accent_text: '#8ec2b3',
	// Estes dois são `rgba` no tema escuro. A razão de contraste não sabe o que é transparência,
	// então entram ACHATADOS sobre `surface` (#16181c), que é onde de fato pintam. Achatar sobre
	// outra superfície daria outro número — é uma aproximação consciente, não um valor do CSS.
	accent_subtle: '#272f30', // rgba(127,165,154,.16) sobre #16181c
	accent_border: '#455755', // rgba(127,165,154,.45) sobre #16181c
	success: '#2da160',
	warning: '#f5a623',
	danger: '#f5585d',
	info: '#3c90ff',
	rail: '#08090a',
	rail_item: '#1a1d22'
};

/** Fundos sólidos e marca: iguais nos dois temas (são pigmento, não superfície). */
const SHARED = {
	success_solid: '#2da160',
	warning_solid: '#f5a623',
	danger_solid: '#d83b40',
	info_solid: '#2b7fff',
	accent_solid: '#7fa59a',
	accent_hover: '#72958b',
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
		// acento (sage desde a ADR-021)
		p('accent_text / surface', 'accent_text', 'surface', 4.5),
		p('accent_text / surface2', 'accent_text', 'surface2', 4.5),
		p('accent_text / accent_subtle', 'accent_text', 'accent_subtle', 4.5, 'chip do acento'),
		// O par que o app de fato usa no sólido é `ink_fixo`, não branco: `bg-accent text-on-solid`.
		// A linha do branco fica porque há DOIS `hover:bg-accent hover:text-white` no app
		// (AppointmentDrawer, /notificacoes) que reprovam — e reprovavam igual no teal (2,57).
		p('ink_fixo / accent_solid', 'ink_fixo', 'accent_solid', 4.5, 'bg-accent + text-on-solid'),
		p('ink_fixo / accent_hover', 'ink_fixo', 'accent_hover', 4.5, ':hover'),
		p('branco / accent_solid', 'white', 'accent_solid', 4.5, 'os 2 hover:text-white — REPROVA'),
		// Botão primário. REPROVA de propósito desde a ADR-020 (débito D-17): o piso segue 4,5
		// justamente para a linha continuar saindo em vermelho na tabela — a exceção é decisão
		// registrada, não um número que se conserta baixando o piso.
		p('on_primary / primary', 'on_primary', 'primary', 4.5, 'botão primário — EXCEÇÃO ADR-020'),
		p('on_primary / primary_hover', 'on_primary', 'primary_hover', 4.5, ':hover — idem'),
		// badges (10,5px bold — NÃO é texto grande, piso 4,5). O fundo é o `-solid`, que não muda
		// com o tema; medir o token de TEXTO aqui era o erro antigo desta tabela.
		p('branco / danger_solid', 'white', 'danger_solid', 4.5, 'badge, PriorityBadge'),
		p('ink_fixo / warning_solid', 'ink_fixo', 'warning_solid', 4.5, 'ENCAIXE'),
		p('ink_fixo / success_solid', 'ink_fixo', 'success_solid', 4.5, 'badge'),
		p('ink_fixo / info_solid', 'ink_fixo', 'info_solid', 4.5, 'badge'),
		p('branco / warning_solid', 'white', 'warning_solid', 4.5, 'o par ERRADO — deve reprovar'),
		// KPI de /relatorios: número 23px semibold, direto sobre a superfície do card.
		// 23px < 24px ⇒ piso 4,5, e não os 3 de texto grande.
		p('KPI warning / surface', 'warning', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI success / surface', 'success', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI danger / surface', 'danger', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI info / surface', 'info', 'surface', 4.5, 'número 23px de /relatorios'),
		p('KPI acento / surface', 'accent_text', 'surface', 4.5, 'número 23px de /relatorios'),
		// rail (escuro nos dois temas)
		p('branco / rail', 'white', 'rail', 4.5, 'ícone/label do rail'),
		p('branco / rail_item', 'white', 'rail_item', 4.5),
		// não-textual: 1.4.11 pede 3:1
		// O anel do acento REPROVA sozinho no tema claro — e é esperado: o anel é duplo, e quem
		// cobre a superfície clara é o companheiro na cor do texto. Quem prova o par é o
		// `contraste.test.ts`; estas linhas ficam para a metade do acento continuar visível aqui.
		p('anel de foco (accent) / surface', 'accent_solid', 'surface', 3, 'metade do anel duplo'),
		p('anel de foco (accent) / canvas', 'accent_solid', 'canvas', 3, 'metade do anel duplo'),
		p('anel de foco (accent) / surface2', 'accent_solid', 'surface2', 3, 'metade do anel duplo'),
		p('anel de foco (accent) / rail', 'accent_solid', 'rail', 3, 'aqui é o acento que cobre'),
		p('borda sutil (bs) / surface', 'bs', 'surface', 3, 'borda de input 1.4.11'),
		p('borda densa (bd) / surface', 'bd', 'surface', 3, 'borda de input 1.4.11'),
		p('accent_border / surface', 'accent_border', 'surface', 3, '1.4.11 — débito D-18'),
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
	['anel de foco no tema claro (sobre surface2)', SHARED.accent_solid, LIGHT.surface2, 3],
	['accent_text sobre accent_subtle (claro)', LIGHT.accent_text, LIGHT.accent_subtle, 4.5],
	['accent_solid escurecido para aceitar texto branco', SHARED.accent_solid, SHARED.white, 4.5],
	['accent_border para bater os 3 de 1.4.11 (débito D-18)', LIGHT.accent_border, LIGHT.surface, 3],
	['success_solid escurecido para aceitar texto branco', SHARED.success_solid, SHARED.white, 4.5],
	['info_solid escurecido para aceitar texto branco', SHARED.info_solid, SHARED.white, 4.5],
	['borda densa (bd) do tema claro', LIGHT.bd, LIGHT.surface, 3]
]) {
	const c = candidato(base, fundo, piso);
	console.log(
		`- **${rot}**: \`${base}\` (${fmt(ratio(base, fundo))}) → ` +
			`\`${c?.hex ?? '—'}\` (${c ? fmt(c.r) : '—'}) para bater ${piso}`
	);
}
