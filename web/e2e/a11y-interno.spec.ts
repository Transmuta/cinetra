import AxeBuilder from '@axe-core/playwright';
import fs from 'node:fs';
import type { Page } from '@playwright/test';
import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * A varredura axe das telas **autenticadas** — o buraco que a auditoria do AN-08 (doc 80) deixou
 * aberto: ali só as páginas públicas foram medidas, porque o login estava quebrado pelo pool
 * `Swoosh.Finch` ausente. Com aquilo consertado, o app inteiro entra na medição.
 *
 * Esta spec **BARRA** (D8, passo final): a auditoria virou conserto e o app interno chegou a zero
 * violação — então daqui para frente ela é o gate. O relatório continua saindo em
 * `a11y-report-interno.json` para diagnóstico, mas o teste falha com a lista na mensagem.
 *
 * Se você caiu aqui por uma falha nova: o JSON tem `tela`, `alvo` e `html` do nó reprovado. O que
 * NÃO se faz é baixar o gate — vale a mesma regra do gate de cobertura
 * (`.claude/rules/testes.md`): mudar o mínimo é decisão humana explícita, não atalho para verde.
 *
 * Duas coisas que uma varredura de página estática não veria e esta cobre:
 *
 *   * **os diálogos** — `Modal`/`Drawer` renderizam por cima e só existem depois de um clique;
 *     metade do app (criar agendamento, ver a ficha do bloco) mora ali dentro;
 *   * **as tabelas e listas com dado real** — semear paciente/profissional/agendamento faz as
 *     telas medirem no estado cheio, não no vazio, onde não há linha para reprovar.
 */

interface Achado {
	tela: string;
	id: string;
	impact: string | null | undefined;
	description: string;
	nodes: number;
	alvo: string[];
	html: string[];
	resumo: string | undefined;
}

const achados: Achado[] = [];

/**
 * Diálogo aberto precisa TERMINAR de animar antes de medir contraste.
 *
 * O `animate-scale`/`animate-fade` do design system sai de `opacity: 0`, e o axe lê a cor
 * **composta**: varrendo no meio da animação, um rótulo `text-muted` sobre `bg-surface` foi
 * medido como `#7f868e` sobre `#e4e4e4` (2,89) — cores que não existem na paleta, porque são a
 * mescla do painel translúcido com o overlay atrás. Três "violações" do Modal de tipo eram isso.
 *
 * Esperar o fim das animações do documento é mais honesto que um `waitForTimeout` cravado: se
 * alguém mudar a duração, isto continua correto.
 */
async function esperarAnimacao(page: Page): Promise<void> {
	await page.waitForFunction(() =>
		document.getAnimations().every((a) => a.playState !== 'running')
	);
}

async function varrer(page: Page, tela: string): Promise<void> {
	const results = await new AxeBuilder({ page })
		.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
		.analyze();

	for (const v of results.violations) {
		achados.push({
			tela,
			id: v.id,
			impact: v.impact,
			description: v.description,
			nodes: v.nodes.length,
			alvo: v.nodes.slice(0, 4).map((n) => n.target.join(' ')),
			html: v.nodes.slice(0, 4).map((n) => n.html.slice(0, 200)),
			resumo: v.nodes[0]?.failureSummary?.slice(0, 400)
		});
	}
}

test('varredura axe nas telas internas', async ({ page, clinica }) => {
	test.setTimeout(300_000);

	// Um agendamento para a agenda e a ficha medirem cheias — e para haver bloco em que clicar.
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	const telas: [string, string][] = [
		['/agenda', `/agenda?date=${clinica.dia}`],
		['/pacientes', '/pacientes'],
		['/pacientes/[id]', `/pacientes/${clinica.paciente.id}`],
		['/pacientes/novo', '/pacientes/novo'],
		['/profissionais', '/profissionais'],
		['/profissionais/[id]', `/profissionais/${clinica.profissional.id}`],
		['/fila', '/fila'],
		['/relatorios', '/relatorios'],
		['/notificacoes', '/notificacoes'],
		['/perfil', '/perfil'],
		['/auditoria', '/auditoria'],
		['/configuracoes/clinica', '/configuracoes/clinica'],
		['/configuracoes/equipe', '/configuracoes/equipe'],
		['/configuracoes/horario', '/configuracoes/horario'],
		['/configuracoes/excecoes', '/configuracoes/excecoes'],
		['/configuracoes/tipos', '/configuracoes/tipos'],
		['/configuracoes/comunicacao', '/configuracoes/comunicacao']
	];

	for (const [nome, url] of telas) {
		await page.goto(url);
		await page.waitForLoadState('networkidle');
		await varrer(page, nome);
	}

	// ---- Os diálogos, que só existem depois de um clique -------------------------------------

	// O Drawer do agendamento: clicar no bloco da grade.
	await abrirAgenda(page, clinica);
	await blocos(page).first().click();
	await expect(page.getByRole('dialog')).toBeVisible();
	await esperarAnimacao(page);
	await varrer(page, 'Drawer do agendamento');
	await page.keyboard.press('Escape');

	// Um Modal de formulário: o catálogo de tipos tem o botão de criar.
	await page.goto('/configuracoes/tipos');
	const criarTipo = page.getByRole('button', { name: /novo tipo|adicionar tipo|criar tipo/i });
	if (await criarTipo.count()) {
		await criarTipo.first().click();
		await expect(page.getByRole('dialog')).toBeVisible();
		await esperarAnimacao(page);
		await varrer(page, 'Modal de tipo de atendimento');
		await page.keyboard.press('Escape');
	}

	// A gaveta de navegação mobile — o rail vira `Drawer` abaixo de `md`, e é outro DOM.
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/agenda');
	const abrirMenu = page.getByRole('button', { name: /menu|navega/i });
	if (await abrirMenu.count()) {
		await abrirMenu.first().click();
		await esperarAnimacao(page);
		await varrer(page, 'Gaveta de navegação (mobile 390px)');
	}
	await varrer(page, '/agenda (mobile 390px)');

	fs.writeFileSync('a11y-report-interno.json', JSON.stringify(achados, null, 1));
	console.log(`axe interno: ${achados.length} violações — ver a11y-report-interno.json`);

	// A mensagem da falha traz regra + tela + alvo, e não só um número: quem roda isto quer saber
	// onde olhar, e o `toEqual([])` cru imprimiria o objeto inteiro de todos os achados.
	expect(
		achados.map((a) => `${a.id} @ ${a.tela} (${a.nodes}×) — ${a.alvo[0] ?? '?'}`),
		'violações de acessibilidade nas telas internas'
	).toEqual([]);
});
