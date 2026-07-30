import AxeBuilder from '@axe-core/playwright';
import fs from 'node:fs';
import type { Page } from '@playwright/test';
import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * O que o axe **não** mede: ordem de foco, aprisionamento no diálogo, caminho de teclado para
 * ações que só existem no ponteiro, e reflow. A auditoria do AN-08 (doc 80) tratou esses itens
 * por inspeção de código; aqui eles viram medição no browser real, para que o relatório afirme
 * números e não impressões.
 *
 * Também **não** falha de propósito: é sonda de auditoria. Os números saem no console e em
 * `a11y-teclado.json`.
 */

interface Medida {
	sonda: string;
	valor: unknown;
}
const medidas: Medida[] = [];
const anota = (sonda: string, valor: unknown) => {
	medidas.push({ sonda, valor });
	console.log(`  · ${sonda}: ${JSON.stringify(valor)}`);
};

/** Onde o foco está agora, em termos legíveis. */
function focoAtual(page: Page) {
	return page.evaluate(() => {
		const a = document.activeElement as HTMLElement | null;
		if (!a) return null;
		return {
			tag: a.tagName.toLowerCase(),
			texto: (a.getAttribute('aria-label') || a.textContent || '').trim().slice(0, 60),
			dentroDeDialogo: !!a.closest('[role="dialog"]'),
			dentroDeMain: !!a.closest('main'),
			href: a.getAttribute('href')
		};
	});
}

test('sondas de teclado, foco e reflow', async ({ page, context, clinica, baseURL }) => {
	test.setTimeout(300_000);

	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	// ---- 1. Skip link e quantos Tabs até o conteúdo -----------------------------------------
	await page.goto('/agenda');
	await page.waitForLoadState('networkidle');

	await page.keyboard.press('Tab');
	const primeiroFoco = await focoAtual(page);
	anota('primeiro ponto de tabulação da /agenda', primeiroFoco);

	// O skip link tem de ser o PRIMEIRO ponto de tabulação — e tem de funcionar. A primeira versão
	// dele ficou no DOM depois do rail: existia, era anunciado, e ninguém o alcançava sem passar
	// pelos 13 destinos que ele deveria pular.
	anota('o primeiro ponto é o skip link?', primeiroFoco?.href?.endsWith('#conteudo') ?? false);
	await page.keyboard.press('Enter');
	anota('depois de acionar o skip link, o foco está no <main>?', await focoAtual(page));

	// Quantos Tabs até o foco entrar no <main>? É a medida do custo do cromo sem skip link.
	let tabs = 1;
	let dentro = (await focoAtual(page))?.dentroDeMain ?? false;
	while (!dentro && tabs < 60) {
		await page.keyboard.press('Tab');
		dentro = (await focoAtual(page))?.dentroDeMain ?? false;
		tabs++;
	}
	anota('Tabs até alcançar o <main> na /agenda', dentro ? tabs : `>60 (não alcançou)`);

	// ---- 2. O que o teclado alcança dentro da agenda ----------------------------------------
	const focaveisNaAgenda = await page.evaluate(() => {
		const sel =
			'a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])';
		return [...(document.querySelector('main')?.querySelectorAll(sel) ?? [])].map((e) =>
			(e.getAttribute('aria-label') || e.textContent || e.tagName).trim().slice(0, 40)
		);
	});
	anota('elementos focáveis dentro do <main> da /agenda', focaveisNaAgenda);

	// ---- 3. Aprisionamento de foco no diálogo (WCAG 2.4.3 / 2.1.2) --------------------------
	await abrirAgenda(page, clinica);
	await blocos(page).first().click();
	await expect(page.getByRole('dialog')).toBeVisible();
	anota('foco ao ABRIR o drawer', await focoAtual(page));

	// Tab até sair — se sair, não há trap.
	let escapou: unknown = false;
	for (let i = 1; i <= 40; i++) {
		await page.keyboard.press('Tab');
		const f = await focoAtual(page);
		if (f && !f.dentroDeDialogo) {
			escapou = { naTabulacao: i, foco: f };
			break;
		}
	}
	anota('o foco escapa do drawer aberto?', escapou);

	// E o fundo continua rolando com o diálogo aberto? (scroll lock)
	const rolaAtras = await page.evaluate(() => {
		const antes = window.scrollY;
		window.scrollBy(0, 200);
		const depois = window.scrollY;
		window.scrollTo(0, antes);
		return { antes, depois, body: getComputedStyle(document.body).overflow };
	});
	anota('fundo rola com diálogo aberto', rolaAtras);

	await page.keyboard.press('Escape');
	anota('foco ao FECHAR o drawer (devolvido?)', await focoAtual(page));

	// ---- 4. A gaveta de navegação mobile (não usa o shell Drawer) ---------------------------
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/agenda');
	await page.waitForLoadState('networkidle');
	const hamburguer = page.getByRole('button', { name: 'Abrir menu' });
	await hamburguer.click();
	anota('foco ao abrir a gaveta mobile', await focoAtual(page));
	await page.keyboard.press('Tab');
	anota('1 Tab depois de abrir a gaveta mobile', await focoAtual(page));

	// ---- 5. Reflow / zoom (WCAG 1.4.10) ----------------------------------------------------
	for (const [rot, w, h] of [
		['320px (=400% em 1280)', 320, 800],
		['640px (=200% em 1280)', 640, 800],
		['1280px (referência)', 1280, 800]
	] as [string, number, number][]) {
		await page.setViewportSize({ width: w, height: h });
		for (const url of ['/agenda', '/pacientes', '/relatorios']) {
			await page.goto(url);
			await page.waitForLoadState('networkidle');
			const o = await page.evaluate(() => ({
				scrollW: document.documentElement.scrollWidth,
				clientW: document.documentElement.clientWidth
			}));
			if (o.scrollW > o.clientW + 1) {
				anota(`reflow ${rot} em ${url}`, { ...o, rolagemHorizontal: true });
			}
		}
	}
	anota('reflow: só as combinações acima têm rolagem horizontal', 'demais limpas');

	// ---- 6. axe no TEMA ESCURO (a varredura interna rodou só no claro) ----------------------
	await context.addCookies([{ name: 'mv-theme', value: 'dark', url: baseURL! }]);
	await page.setViewportSize({ width: 1280, height: 800 });
	const escuro: Record<string, unknown>[] = [];
	for (const url of ['/agenda', '/pacientes', '/fila', '/relatorios', '/configuracoes/equipe']) {
		await page.goto(url);
		await page.waitForLoadState('networkidle');
		const r = await new AxeBuilder({ page })
			.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
			.analyze();
		for (const v of r.violations) {
			escuro.push({
				url,
				id: v.id,
				nodes: v.nodes.length,
				resumo: v.nodes[0]?.failureSummary?.slice(0, 220)
			});
		}
	}
	anota('violações no tema ESCURO', escuro);

	fs.writeFileSync('a11y-teclado.json', JSON.stringify(medidas, null, 1));
});
