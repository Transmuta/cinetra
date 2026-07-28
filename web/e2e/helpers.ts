import {
	expect,
	request as apiRequest,
	type APIRequestContext,
	type BrowserContext,
	type Page
} from '@playwright/test';
import { API_ORIGIN } from './env';

/**
 * Entrar de verdade no e2e — sem atalho de sessão forjada.
 *
 * O projeto é passwordless (ADR-015), então "estar logado" só existe depois de um magic link
 * consumido. Forjar o cookie no teste pularia justamente o encanamento que o e2e existe para
 * cobrir (o BFF repassa o `_api_key`, o `LoadScope` resolve o tenant). O caminho aqui é o real:
 * pede o link, lê o e-mail na caixa de dev do Swoosh (`/dev/mailbox`, que só existe com
 * `dev_routes`) e navega para ele.
 *
 * O que este módulo acrescentou depois foi **semear pela API**, não pular a autenticação: montar
 * profissional, paciente e agendamento por HTTP em vez de por formulário. A sessão continua saindo
 * do magic link; o que muda é que o cenário de partida deixa de custar seis telas.
 */

export function emailUnico(prefixo = 'e2e'): string {
	return `${prefixo}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`;
}

/**
 * A API está de pé com as rotas de dev?
 *
 * Os e2e autenticados precisam de API + banco + a caixa de e-mail de dev — a stack do
 * `docker compose`. Contra hml/produção não há `dev_routes`, então não há como ler o magic link:
 * ali eles pulam com aviso em vez de falhar por infraestrutura ausente. Ver `README.md`.
 */
export async function stackCompleta(request: APIRequestContext): Promise<boolean> {
	// Duas tentativas, com folga. A caixa responde em ~100ms **quente**, mas a primeira requisição
	// a um Phoenix em modo dev dispara o `code_reloader` e chega a levar 8s (medido). Com o timeout
	// curto que havia aqui, um começo de suíte frio fazia a stack de pé parecer ausente e a suíte
	// inteira PULAVA em silêncio — que é o pior desfecho possível (README).
	for (const tentativa of [0, 1]) {
		try {
			// A caixa de dev é a sonda certa, e não `/api/health`: aquele exige sessão (está atrás do
			// pipeline `:authenticated`), então responderia 401 com a API perfeitamente de pé. Esta
			// responde exatamente o que o teste precisa: API viva **e** `dev_routes` ligado.
			const mailbox = await request.get(`${API_ORIGIN}/dev/mailbox/json`, { timeout: 20_000 });
			if (mailbox.ok()) return true;
		} catch {
			// Rede recusada na primeira: a API pode estar subindo. Tenta de novo antes de desistir.
		}
		if (tentativa === 0) await new Promise((r) => setTimeout(r, 1_000));
	}
	return false;
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

/**
 * Consome um magic link já enviado para `addr` e deixa a página autenticada.
 *
 * O link do e-mail aponta para o `WEB_APP_URL` do ambiente (o vite de dev, na 5173); o teste roda
 * contra o preview buildado (4173). Só o caminho + a query interessam — o token está ali, e
 * navegar relativo faz o Playwright usar a `baseURL` da própria execução.
 */
export async function consumirMagicLink(
	page: Page,
	request: APIRequestContext,
	addr: string
): Promise<void> {
	const link = new URL(await magicLinkPara(request, addr));
	await page.goto(`${link.pathname}${link.search}`);
}

/** Cria a conta, consome o magic link e deixa a página autenticada (na tela de onboarding). */
export async function entrar(page: Page, request: APIRequestContext, addr: string): Promise<void> {
	await page.goto('/criar-conta');
	await page.getByLabel('Nome').fill('Dona E2E');
	await page.getByLabel('E-mail').fill(addr);
	await page.getByRole('button', { name: 'Criar conta grátis' }).click();
	// Estado NEUTRO do ADR-015: confirma sem revelar se a conta existe.
	await expect(page.getByRole('heading', { name: 'Verifique seu e-mail' })).toBeVisible();

	await consumirMagicLink(page, request, addr);
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

// ---------------------------------------------------------------------------------------------
// Semear pela API
// ---------------------------------------------------------------------------------------------

/**
 * Um cliente da API **com a sessão que o browser acabou de ganhar**.
 *
 * Não é uma segunda autenticação: é o mesmo `_api_key` que o BFF re-emitiu no domínio do web,
 * lido do contexto e mandado à mão. Duas coisas o justificam:
 *
 *   * o cookie é HttpOnly e o teste não o inventa — ele saiu do magic link, do `store_in_session`
 *     e do `reemitSession`; o que se pula é só a renderização de formulário;
 *   * um segundo magic link para o mesmo endereço seria uma corrida com a caixa de dev (dois
 *     e-mails, e o `find` pega o mais novo — que pode ainda não ter chegado).
 *
 * O `cookie` vai em `extraHTTPHeaders` porque o jar do Playwright é por origem: o cookie foi
 * gravado para o **web** (4173) e não seria enviado à API (`api:4000`), que é outro host.
 */
export async function apiComSessao(context: BrowserContext): Promise<APIRequestContext> {
	const cookies = await context.cookies();
	const sessao = cookies.find((c) => c.name === '_api_key');
	if (!sessao) throw new Error('sem cookie `_api_key` no contexto — o login falhou?');

	return apiRequest.newContext({
		baseURL: API_ORIGIN,
		extraHTTPHeaders: { cookie: `_api_key=${sessao.value}` }
	});
}

/** `POST` na API já falando JSON, com o corpo checado — erro de seed tem de gritar na hora. */
async function post<T>(api: APIRequestContext, path: string, data: unknown): Promise<T> {
	const res = await api.post(path, { data: data as Record<string, unknown> });
	if (!res.ok()) {
		throw new Error(`POST ${path} respondeu ${res.status()}: ${await res.text()}`);
	}
	return (await res.json()) as T;
}

export interface Ref {
	id: string;
	nome: string;
}

export interface TipoAtendimento extends Ref {
	duracao_minutos: number;
}

export async function criarClinicaPelaApi(api: APIRequestContext, nome: string): Promise<Ref> {
	const body = await post<{ clinic: Ref }>(api, '/api/clinics', { nome });
	return body.clinic;
}

export async function criarProfissional(api: APIRequestContext, nome: string): Promise<Ref> {
	// `segue_horario_clinica` fica no default (true): sem herdar o expediente da clínica, TODO
	// agendamento cairia em 422 de "fora do expediente" e o teste acusaria a regra errada.
	//
	// `tel` pelo mesmo motivo de `criarPaciente`: a `TelObrigatorio` (D6) vale para os dois
	// cadastros, e sem ele o `montarClinica` morre em 422 antes da primeira asserção.
	const body = await post<{ professional: Ref }>(api, '/api/professionals', {
		nome,
		tel: '11987654321'
	});
	return body.professional;
}

export async function criarPaciente(api: APIRequestContext, nome: string): Promise<Ref> {
	// O telefone não é decoração: desde a `TelObrigatorio` (D-H5/D6) o cadastro **exige** um
	// número brasileiro válido, e sem ele o `montarClinica` morre antes da primeira asserção —
	// derrubando todo cenário autenticado, não só os que olham para paciente.
	const body = await post<{ patient: Ref }>(api, '/api/patients', {
		nome,
		tel: '11987654321'
	});
	return body.patient;
}

/**
 * Um tipo do catálogo pelo nome. Os cinco nascem no `onboard` (SeedAppointmentTypes), então o
 * teste escolhe em vez de criar — e escolhe **pelo nome** porque a ordem da lista não é contrato.
 */
export async function tipoPorNome(
	api: APIRequestContext,
	nome: string
): Promise<TipoAtendimento> {
	const res = await api.get('/api/appointment-types');
	if (!res.ok()) throw new Error(`GET /api/appointment-types: ${res.status()}`);

	const body = (await res.json()) as { appointment_types: TipoAtendimento[] };
	const tipo = body.appointment_types.find((t) => t.nome === nome);
	if (!tipo) throw new Error(`tipo "${nome}" não veio no catálogo semeado do onboard`);
	return tipo;
}

export interface Agendamento {
	id: string;
	starts_at: string;
	version: number;
}

export async function criarAgendamento(
	api: APIRequestContext,
	input: {
		starts_at: string;
		professional_id: string;
		appointment_type_id: string;
		patient_ids: string[];
		obs?: string;
	}
): Promise<Agendamento> {
	const body = await post<{ appointment: Agendamento }>(api, '/api/appointments', input);
	return body.appointment;
}

/**
 * Convida alguém para a clínica ativa. O convite **já dispara o magic link** do convidado
 * (`ResolveInvitedUser`), então quem aceita não precisa passar por `/criar-conta`: o e-mail está
 * na caixa de dev esperando — ver `entrarPeloConvite`.
 */
export async function convidar(
	api: APIRequestContext,
	input: { email: string; nome: string; papel: 'admin' | 'profissional' | 'recepcao' }
): Promise<void> {
	await post(api, '/api/members', input);
}

/**
 * Aceita um convite: consome o link que o próprio convite mandou e espera o app abrir.
 *
 * O vínculo pendente vira ativo no callback (`Invites.activate_pending`), então é só aqui que o
 * escopo do convidado passa a resolver o tenant — chegar na `/agenda` é a prova disso.
 */
export async function entrarPeloConvite(
	page: Page,
	request: APIRequestContext,
	addr: string
): Promise<void> {
	await consumirMagicLink(page, request, addr);
	await expect(page).toHaveURL(/\/agenda/, { timeout: 20_000 });
}

// ---------------------------------------------------------------------------------------------
// Tempo
// ---------------------------------------------------------------------------------------------

/**
 * Um dia útil no futuro próximo, em `YYYY-MM-DD`.
 *
 * Útil de verdade, e não "amanhã": o expediente semeado no `onboard` é Seg–Sex 08–12 e 13–18,
 * sábado só de manhã e domingo fechado — marcar num domingo faria a API recusar por expediente e
 * o teste acusaria a regra errada. Uma semana à frente também tira do caminho a diferença entre o
 * "hoje" do processo (UTC) e o da clínica (UTC−3), que só apareceria na janela da meia-noite.
 */
export function diaUtilProximo(daqui = 7): string {
	const d = new Date();
	d.setUTCDate(d.getUTCDate() + daqui);
	// Sáb (6) → segunda; Dom (0) → segunda. Seg–Sex ficam onde estão.
	d.setUTCDate(d.getUTCDate() + (d.getUTCDay() === 6 ? 2 : d.getUTCDay() === 0 ? 1 : 0));
	return d.toISOString().slice(0, 10);
}

/**
 * `2026-08-03` + `09:00` no fuso da clínica → o instante absoluto que a API espera.
 *
 * Escrito aqui, e não importado de `$lib/agenda`: o `toUtcIso` da aplicação é justamente o que o
 * teste de agendamento verifica (digitar 09:00 e ver 09:00 no bloco). Reusá-lo faria o teste
 * concordar com o bug, se houvesse um. O offset sai do `Intl` em vez de um `-03:00` cravado —
 * São Paulo não tem mais horário de verão, mas um fuso que tenha quebraria o cravado em silêncio.
 */
export function instanteUtc(data: string, hora: string, timezone = 'America/Sao_Paulo'): string {
	const ingenuo = new Date(`${data}T${hora}:00Z`);
	return new Date(ingenuo.getTime() - offsetMinutos(timezone, ingenuo) * 60_000).toISOString();
}

// "GMT-03:00" → -180. O offset é lido no instante ingênuo, o que só seria impreciso na hora exata
// de uma virada de horário de verão — que o `diaUtilProximo` não escolhe e São Paulo não tem.
function offsetMinutos(timezone: string, quando: Date): number {
	const fmt = new Intl.DateTimeFormat('en-US', { timeZone: timezone, timeZoneName: 'longOffset' });
	const nome = fmt.formatToParts(quando).find((p) => p.type === 'timeZoneName')?.value;
	const partes = /GMT([+-])(\d{2}):(\d{2})/.exec(nome ?? '');
	if (!partes) return 0;
	return (partes[1] === '-' ? -1 : 1) * (Number(partes[2]) * 60 + Number(partes[3]));
}
