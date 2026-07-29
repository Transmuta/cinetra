import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import fs from 'node:fs';

/**
 * AN-08 (doc 64, D8): a AUDITORIA de acessibilidade — não o gate. Varre páginas com o axe-core
 * e despeja as violações em `a11y-report.json`, sem falhar: o D8 manda auditar → consertar →
 * só então ligar o gate no CI, já verde. Quando virar gate, a asserção passa a ser
 * `expect(violations).toEqual([])` por página.
 *
 * As páginas AUTENTICADAS entram quando a caixa de dev estiver recebendo (com `RESEND_API_KEY`
 * no ambiente o mailer real assume e o magic link não aparece em `/dev/mailbox`) — a varredura
 * desta rodada cobre as públicas; as internas foram auditadas por inspeção (doc 76).
 */

const PAGINAS = ['/', '/entrar', '/criar-conta', '/privacidade', '/termos'];

interface Achado {
	pagina: string;
	id: string;
	impact: string | null | undefined;
	description: string;
	nodes: number;
	alvo: string[];
}

test('varredura axe nas páginas públicas', async ({ page }) => {
	test.setTimeout(120_000);

	const achados: Achado[] = [];

	for (const url of PAGINAS) {
		await page.goto(url);
		await page.waitForLoadState('networkidle');

		const results = await new AxeBuilder({ page })
			.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
			.analyze();

		for (const v of results.violations) {
			achados.push({
				pagina: url,
				id: v.id,
				impact: v.impact,
				description: v.description,
				nodes: v.nodes.length,
				alvo: v.nodes.slice(0, 3).map((n) => n.target.join(' ')),
				html: v.nodes.slice(0, 3).map((n) => n.html.slice(0, 160)),
				resumo: v.nodes[0]?.failureSummary?.slice(0, 300)
			});
		}
	}

	fs.writeFileSync('a11y-report.json', JSON.stringify(achados, null, 1));
	console.log(`axe: ${achados.length} violações — ver a11y-report.json`);
	expect(true).toBe(true);
});
