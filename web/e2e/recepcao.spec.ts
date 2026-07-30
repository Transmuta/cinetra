import type { Page } from '@playwright/test';
import { test, expect } from './fixtures';
import { apiComSessao, convidar, emailUnico, entrarPeloConvite } from './helpers';

/** O rail é o mesmo componente nas duas instâncias (desktop e gaveta) — aqui basta a de tela larga. */
function rail(page: Page) {
	return page.getByRole('navigation', { name: 'Navegação principal' });
}

/**
 * O papel de recepção, do convite ao que ela vê.
 *
 * O RBAC deste projeto é afirmado em três lugares diferentes — a policy do recurso, a guarda do
 * controller (`with_admin_scope`) e o gating de UX no cliente (`canManageMembers` e parentes) — e
 * cada um tem os próprios testes. Nenhum deles prova que os três **concordam**. Este prova: uma
 * pessoa de verdade entra por um convite de verdade e esbarra (ou não) em cada um.
 *
 * O contraste com a dona, na mesma tela e no mesmo teste, é o que impede a asserção vazia: um item
 * ausente porque o rail inteiro quebrou passaria por "escondido corretamente". Foi assim que o bug
 * do CNPJ passou (props ligadas só numa das instâncias do cromo) — com a suíte inteira verde.
 */
test.describe('Papel de recepção', () => {
	test('entra pelo convite, trabalha na agenda e não alcança o que é de owner/admin', async ({
		page,
		browser,
		request,
		clinica
	}) => {
		const email = emailUnico('recepcao');
		await convidar(clinica.api, { email, nome: 'Rita Recepção', papel: 'recepcao' });

		const contextoDaRita = await browser.newContext();
		const rita = await contextoDaRita.newPage();
		// Aterrissar na /agenda já é a prova de que o vínculo pendente virou ativo no callback
		// (`Invites.activate_pending`) — sem isso o escopo não resolveria tenant e ela cairia no
		// onboarding, criando uma clínica própria.
		await entrarPeloConvite(rita, request, email);

		// ---- O que ela PODE ----------------------------------------------------------------
		//
		// Sem isto o teste passaria com o app quebrado para ela: "não vê nada" satisfaria todas as
		// asserções negativas abaixo.
		await expect(rita.getByText(clinica.nome)).toBeVisible();
		await expect(rail(rita).getByRole('link', { name: 'Agenda' })).toBeVisible();

		await rita.goto('/pacientes');
		// A linha da lista (o nome também aparece no painel de detalhe ao lado).
		await expect(rita.getByRole('link', { name: new RegExp(clinica.paciente.nome) })).toBeVisible();

		// ---- O que ela NÃO pode ------------------------------------------------------------

		// A dona vê a Auditoria no mesmo rail; a recepção, não (a policy é a autoridade — esconder
		// o ícone é só não oferecer o 403).
		await page.goto('/agenda');
		await expect(rail(page).getByRole('link', { name: 'Auditoria' })).toBeVisible();
		await expect(rail(rita).getByRole('link', { name: 'Auditoria' })).toHaveCount(0);

		// E o destino recusa mesmo quando digitado na URL — o menu escondido não é a guarda.
		await rita.goto('/auditoria');
		await expect(rita.getByText('403')).toBeVisible();

		// A equipe é o caso interessante: a LISTA é de todo membro (quem trabalha junto sabe quem
		// trabalha junto), e o que some são as AÇÕES. Uma tela que abre igual para os dois papéis
		// é exatamente onde um gating de UX escorrega sem ninguém ver.
		await rita.goto('/configuracoes/equipe');
		await expect(rita.getByText(clinica.email)).toBeVisible();
		await expect(rita.getByRole('button', { name: 'Convidar membro' })).toHaveCount(0);
		await expect(rita.getByRole('button', { name: 'Remover acesso' })).toHaveCount(0);

		await page.goto('/configuracoes/equipe');
		await expect(page.getByRole('button', { name: 'Convidar membro' })).toBeVisible();

		// E a autoridade final, sem browser no meio: a API recusa a escrita e a trilha.
		const apiDaRita = await apiComSessao(contextoDaRita);
		expect(
			(await apiDaRita.post('/api/patients', { data: { nome: 'Cadastro Indevido' } })).status()
		).toBe(403);
		expect(
			(
				await apiDaRita.post('/api/members', {
					data: { email: 'invasao@example.com', nome: 'X', papel: 'admin' }
				})
			).status()
		).toBe(403);
		expect((await apiDaRita.get('/api/audit')).status()).toBe(403);

		await apiDaRita.dispose();
		await contextoDaRita.close();
	});
});
