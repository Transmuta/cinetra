import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

import { STATUS_META, STATUS_ORDER } from './agenda';
import { statusChip } from './packages';

/**
 * Todo `tone` precisa nomear um token que EXISTE.
 *
 * Por que este arquivo existe: meia dúzia de componentes não escrevem a cor — eles **interpolam o
 * nome do tom dentro do nome da variável CSS**:
 *
 *     `var(--color-${tag.tone})`                                  (PatientHistory, AppointmentDrawer)
 *     `var(--color-${badge.tone}-text, var(--color-${badge.tone}))` (AppointmentBlock)
 *     const corDoTom = (tom) => `var(--color-${tom})`               (AgendaLegend, AppointmentBlock)
 *
 * Isso é um acoplamento por STRING entre um tipo do domínio (`StatusMeta['tone']`, `ChipTone`) e o
 * `@theme` do `app.css`. Quando os dois discordam, o CSS não reclama: `var()` sem valor e sem
 * fallback resolve para nada, o elemento renderiza **sem cor nenhuma** e continua no ar. Nenhum
 * gate pegava isso — nem o `svelte-check` (a string é válida), nem o `contraste.test.ts` (mede
 * tokens, não quem os chama), nem o axe (a cor ausente não é contraste ruim, é ausência).
 *
 * Foi exatamente o que quase escapou na ADR-021: ao renomear a família `teal` → `accent`, os tons
 * `tone: 'teal'` de `STATUS_META.em_atendimento` e de `statusChip` continuariam compilando e
 * apontando para um `--color-teal` que deixou de existir. O ponto do "Em atendimento" e o chip
 * "Ativo" do pacote sumiriam em silêncio.
 *
 * O teste lê os tons do próprio domínio e os nomes de token do próprio `app.css` — não repete
 * nenhuma das duas listas aqui, senão ele concordaria consigo mesmo até o dia em que não importa.
 */

const css = readFileSync(new URL('./styles/app.css', import.meta.url), 'utf8');

/** Os nomes declarados no `@theme inline` — `--color-accent-text:` vira `accent-text`. */
const TOKENS = new Set([...css.matchAll(/^\s*--color-([\w-]+):/gm)].map(([, nome]) => nome));

/** O que os componentes de fato montam a partir de um tom. */
function variaveis(tom: string): string[] {
	return [tom, `${tom}-text`];
}

describe('tons do domínio ↔ tokens do app.css', () => {
	it('o parser achou os tokens de cor (guarda do próprio teste)', () => {
		// Sem isto, um `app.css` reorganizado deixaria TOKENS vazio e tudo abaixo reprovaria por
		// motivo errado — ou, pior, passaria se a asserção fosse a inversa.
		expect(TOKENS.size).toBeGreaterThan(15);
		expect(TOKENS).toContain('muted');
		expect(TOKENS).toContain('surface');
	});

	it('todo tone de STATUS_META resolve para um --color-* existente', () => {
		for (const status of STATUS_ORDER) {
			const tom = STATUS_META[status].tone;
			expect(
				TOKENS.has(tom),
				`STATUS_META.${status}.tone = "${tom}" → var(--color-${tom}) não existe no app.css`
			).toBe(true);
		}
	});

	/**
	 * `AppointmentBlock` usa `var(--color-<tom>-text, var(--color-<tom>))`: a variante `-text`
	 * é opcional (o fallback cobre), então aqui só se exige que, QUANDO ela existir no CSS, o par
	 * esteja completo — o que impede o caso meia-boca de renomear `accent` e esquecer `accent-text`.
	 */
	it('quando um tom tem variante -text, ela também está declarada', () => {
		const comTexto = [...TOKENS].filter((t) => t.endsWith('-text'));
		for (const t of comTexto) {
			const base = t.replace(/-text$/, '');
			expect(
				TOKENS.has(base),
				`existe --color-${t} mas não existe o --color-${base} do fallback`
			).toBe(true);
		}
		// A família do acento é a que tem o par; se ela sumir, este teste vira vácuo e não avisa.
		expect(comTexto.length).toBeGreaterThan(0);
	});

	it('todo tone de statusChip resolve para um --color-* existente', () => {
		const casos = [
			{ status: 'ativo', acabando: false, restantes: 8 },
			{ status: 'ativo', acabando: true, restantes: 2 },
			{ status: 'ativo', acabando: false, restantes: 0 },
			{ status: 'pausado', acabando: false, restantes: 3 },
			{ status: 'cancelado', acabando: false, restantes: 3 },
			{ status: 'concluido', acabando: false, restantes: 0 }
		] as const;

		for (const caso of casos) {
			const { label, tone } = statusChip(caso);
			expect(
				TOKENS.has(tone),
				`statusChip → "${label}" usa tone "${tone}", que não existe no app.css`
			).toBe(true);
		}
	});
});
