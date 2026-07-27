import { expect, type APIRequestContext, type Page } from '@playwright/test';

/**
 * Entrar de verdade no e2e — sem atalho de sessão forjada.
 *
 * O projeto é passwordless (ADR-015), então "estar logado" só existe depois de um magic link
 * consumido. Forjar o cookie no teste pularia justamente o encanamento que o e2e existe para
 * cobrir (o BFF repassa o `_api_key`, o `LoadScope` resolve o tenant). O caminho aqui é o real:
 * pede o link, lê o e-mail na caixa de dev do Swoosh (`/dev/mailbox`, que só existe com
 * `dev_routes`) e navega para ele.
 */

/**
 * A API **a partir deste processo**, que não é o mesmo que a API a partir do browser.
 *
 * `API_URL` é a variável server-to-server do compose (`http://api:4000`, pela rede interna) e é a
 * certa quando o Playwright roda dentro do container. `API_PUBLIC_ORIGIN` é a de fora
 * (`localhost:4010`), que serve quando se roda no host. A ordem importa: dentro do container as
 * duas existem, e a pública **não resolve** — foi o que fez a primeira execução pular o teste
 * achando que a stack estava fora do ar.
 */
const API_ORIGIN = process.env.API_URL ?? process.env.API_PUBLIC_ORIGIN ?? 'http://localhost:4010';

export function emailUnico(prefixo = 'e2e'): string {
	return `${prefixo}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`;
}

/**
 * A API está de pé com as rotas de dev?
 *
 * Os e2e autenticados precisam de API + banco + a caixa de e-mail de dev — a stack do
 * `docker compose`. O job `web-e2e` do CI hoje sobe **só o web** (build + preview), então lá eles
 * pulam com aviso em vez de falhar por infraestrutura ausente, que é ruído e não sinal. Ligar a
 * API naquele job é trabalho declarado no doc 48; enquanto não acontece, o valor destes testes é
 * local — e é onde eles pegam o que a unidade não pega.
 */
export async function stackCompleta(request: APIRequestContext): Promise<boolean> {
	try {
		// A caixa de dev é a sonda certa, e não `/api/health`: aquele exige sessão (está atrás do
		// pipeline `:authenticated`), então responderia 401 com a API perfeitamente de pé. Esta
		// responde exatamente o que o teste precisa: API viva **e** `dev_routes` ligado.
		const mailbox = await request.get(`${API_ORIGIN}/dev/mailbox/json`, { timeout: 3_000 });
		return mailbox.ok();
	} catch {
		return false;
	}
}

interface MailboxMail {
	// O Swoosh serializa o destinatário como string ou como par [nome, endereço], conforme o
	// e-mail tenha sido montado com um ou outro. Aceitar as duas formas evita um teste que quebra
	// no dia em que alguém acrescentar o nome no `to/2`.
	to?: (string | [string, string])[];
	text_body?: string;
	html_body?: string;
}

function paraEndereco(destino: string | [string, string]): string {
	return Array.isArray(destino) ? destino[1] : destino;
}

/**
 * O magic link do e-mail **mais recente** endereçado a `addr`. Tenta algumas vezes: o envio é
 * assíncrono, então a caixa pode estar vazia por alguns milissegundos depois do submit.
 *
 * A caixa do Swoosh lista do mais novo para o mais velho — daí o `find` e não o `pop`. Com
 * endereços únicos por teste isso raramente importa; importa quando um retry reenvia o link e o
 * teste precisa do NOVO (o velho pode já ter sido consumido).
 */
export async function magicLinkPara(request: APIRequestContext, addr: string): Promise<string> {
	for (let tentativa = 0; tentativa < 24; tentativa++) {
		const res = await request.get(`${API_ORIGIN}/dev/mailbox/json`);
		const body = (await res.json()) as { data?: MailboxMail[] };

		const mail = (body.data ?? []).find((m) =>
			(m.to ?? []).some((destino) => paraEndereco(destino) === addr)
		);

		const corpo = `${mail?.text_body ?? ''}\n${mail?.html_body ?? ''}`;
		const link = corpo.match(/https?:\/\/[^\s"'<>]*token=[\w.\-]+/)?.[0];
		if (link) return link;

		await new Promise((r) => setTimeout(r, 250));
	}

	throw new Error(`nenhum magic link chegou para ${addr} — a caixa de dev está ligada?`);
}

/** Cria a conta, consome o magic link e deixa a página autenticada (na tela de onboarding). */
export async function entrar(page: Page, request: APIRequestContext, addr: string): Promise<void> {
	await page.goto('/criar-conta');
	await page.getByLabel('Nome').fill('Dona E2E');
	await page.getByLabel('E-mail').fill(addr);
	await page.getByRole('button', { name: 'Criar conta grátis' }).click();
	// Estado NEUTRO do ADR-015: confirma sem revelar se a conta existe.
	await expect(page.getByRole('heading', { name: 'Verifique seu e-mail' })).toBeVisible();

	// O link do e-mail aponta para o `WEB_APP_URL` do ambiente (o vite de dev, na 5173); o teste
	// roda contra o preview buildado (4173). Só o caminho + a query interessam — o token está ali,
	// e navegar relativo faz o Playwright usar a `baseURL` da própria execução.
	const link = new URL(await magicLinkPara(request, addr));
	await page.goto(`${link.pathname}${link.search}`);
}

/** Cria uma clínica pela tela de onboarding e espera o app abrir. */
export async function criarClinica(page: Page, nome: string): Promise<void> {
	await page.getByLabel('Nome da clínica').fill(nome);
	await page.getByRole('button', { name: 'Criar clínica' }).click();
	await expect(page).toHaveURL(/\/(agenda|)$/, { timeout: 20_000 });
}

/** O botão do avatar que abre o menu do usuário (onde vivem as clínicas). */
export function menuDoUsuario(page: Page) {
	return page.locator('button[aria-haspopup="menu"]').first();
}
