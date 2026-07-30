import {
	test as base,
	expect,
	type APIRequestContext,
	type BrowserContext,
	type Page
} from '@playwright/test';
import { API_ORIGIN } from './env';
import {
	apiComSessao,
	criarClinicaPelaApi,
	criarPaciente,
	criarProfissional,
	diaUtilProximo,
	emailUnico,
	entrar,
	stackCompleta,
	tipoPorNome,
	type Ref,
	type TipoAtendimento
} from './helpers';

/**
 * A clínica de partida dos cenários autenticados — o **Passo 0** desta leva de e2e.
 *
 * Antes daqui, cada cenário construía o mundo pela interface: criar conta, aceitar o link, criar
 * a clínica, cadastrar profissional, cadastrar paciente. Seis telas antes da primeira asserção,
 * repetidas em cada arquivo. O custo não era só tempo: era que a falha de qualquer uma dessas
 * telas quebrava todos os testes, apontando para o lugar errado.
 *
 * O que **não** foi cortado é a autenticação: a sessão continua nascendo de um magic link de
 * verdade (`entrar`), porque é ela que o e2e existe para provar. O que passou a viajar por HTTP é
 * o **cenário** — clínica, profissional, paciente —, que nenhum destes testes está verificando.
 *
 * Cada teste ganha a **própria clínica**, e é isso que deixa a suíte rodar em paralelo: o tenant é
 * o limite de isolamento do sistema (ADR-017), então dois testes nunca disputam a mesma agenda.
 */
export interface Clinica {
	/** O e-mail do dono (owner). Único por teste. */
	email: string;
	nome: string;
	id: string;
	/** A API falando como o dono desta clínica — para semear e para conferir pelo lado do servidor. */
	api: APIRequestContext;
	profissional: Ref;
	paciente: Ref;
	/** "Sessão" (50min, individual), do catálogo que o `onboard` semeia. */
	tipo: TipoAtendimento;
	/** O dia útil em que os cenários marcam. Um só, para todas as telas concordarem. */
	dia: string;
}

/**
 * Monta uma clínica do zero na página dada. Exportada além da fixture porque o cenário de
 * isolamento precisa de uma **segunda**, em outro contexto — e ela tem de nascer exatamente
 * igual à primeira, senão o teste compara maçã com laranja.
 */
export async function montarClinica(
	page: Page,
	context: BrowserContext,
	request: APIRequestContext,
	prefixo = 'clinica'
): Promise<Clinica> {
	const email = emailUnico(prefixo);
	await entrar(page, request, email);

	const api = await apiComSessao(context);
	const nome = `Clínica ${email.split('@')[0]}`;
	const { id } = await criarClinicaPelaApi(api, nome);

	const [profissional, paciente, tipo] = await Promise.all([
		criarProfissional(api, 'Dra. Bea Nogueira'),
		criarPaciente(api, 'Marina Prado'),
		tipoPorNome(api, 'Sessão')
	]);

	return { email, nome, id, api, profissional, paciente, tipo, dia: diaUtilProximo() };
}

/**
 * Por que a API não respondeu — em uma frase acionável.
 *
 * "Não respondeu" tem duas causas muito diferentes e o mesmo sintoma: o processo não está de pé,
 * ou está de pé e recusando tudo. O segundo caso é o do **codegen pendente**, e o corpo do 500 diz
 * qual é (`PendingCodegen`) — basta alguém olhar. Sem isto, o erro manda "suba o compose" para
 * quem já está com o compose de pé.
 */
async function diagnostico(request: APIRequestContext): Promise<string> {
	try {
		const res = await request.get(`${API_ORIGIN}/api/health`, { timeout: 10_000 });
		const corpo = await res.text();

		if (corpo.includes('PendingCodegen')) {
			return (
				'A API ESTÁ de pé, mas recusa toda requisição: há CODEGEN PENDENTE.\n' +
				'  Rode `mix ash.codegen <nome_da_mudanca>` (ou `--dev` para iterar) e aplique.'
			);
		}
		if (corpo.includes('CompileError') || corpo.includes('SyntaxError')) {
			return 'A API está de pé, mas com ERRO DE COMPILAÇÃO — veja `docker compose logs api`.';
		}
		return `A API respondeu ${res.status()} em /api/health.`;
	} catch {
		return 'Nada atendeu na porta — o processo parece fora do ar.';
	}
}

export const test = base.extend<{ clinica: Clinica }>({
	clinica: async ({ page, context, request }, use) => {
		const clinica = await montarClinica(page, context, request);
		await use(clinica);
		await clinica.api.dispose();
	}
});

/**
 * Sem a stack inteira (API + banco + caixa de dev) não há como autenticar. O que fazer nesse caso
 * **depende do alvo**, e a distinção não é preciosismo:
 *
 *  * apontado para hml/produção (`E2E_BASE_URL`), não há `dev_routes` e nunca haverá magic link
 *    para ler: pular com aviso é o certo — falhar ali seria acusar ausência de infraestrutura que
 *    o ambiente não deve ter mesmo;
 *  * apontado para o **preview local** (o caso normal), a stack é premissa. Pular vira o pior
 *    desfecho possível: "9 skipped" em verde enquanto a API está fora do ar. Foi exatamente o que
 *    aconteceu aqui — a API estava com erro de compilação e a suíte não disse nada.
 *
 * Fica em `beforeEach` de propósito: o Playwright monta as fixtures do corpo do teste **depois**
 * dos hooks, então a clínica nem chega a ser semeada.
 */
test.beforeEach(async ({ request, baseURL }) => {
	if (!(await stackCompleta(request))) {
		if (process.env.E2E_BASE_URL) {
			test.skip(true, 'alvo remoto sem caixa de e-mail de dev — não há como ler o magic link');
		}
		// Distinguir "fora do ar" de "de pé, mas recusando tudo" economiza a meia hora que este
		// QA gastou lendo log (doc 88, A-9): com codegen pendente o `AshPhoenix.Plug.
		// CheckCodegenStatus` derruba TODA requisição em 500 — inclusive `/api/health` —, e de
		// fora o sintoma é indistinguível de API ausente.
		throw new Error(
			`a API não respondeu em ${API_ORIGIN} (alvo: ${baseURL}).\n` +
				`${await diagnostico(request)}\n` +
				'Os cenários autenticados precisam dela de pé: `docker compose up`.'
		);
	}

	// Login por e-mail + seed + navegação: são dezenas de segundos de relógio de parede em máquina
	// fria, e o default de 30s é apertado para isso.
	test.slow();
});

export { expect };

// ---------------------------------------------------------------------------------------------
// Atalhos de tela que mais de um cenário usa
// ---------------------------------------------------------------------------------------------

/**
 * A agenda no dia do cenário, com as colunas desenhadas **e o cliente hidratado**.
 *
 * A espera é pela COLUNA (`data-prof-id`), não pelo nome do profissional: ele também aparece no
 * filtro da sidebar, e um `getByText` casaria os dois.
 *
 * O `hidratou` não é excesso de zelo — foi o primeiro bug que esta leva encontrou em si mesma. A
 * grade vem no HTML do SSR, então o `expect` abaixo passa na hora; clicar ali ainda atinge um DOM
 * **sem handler**, e o clique some sem erro nenhum (o modal nunca abre, e o teste falha 5s depois
 * apontando para o modal — não para a corrida). O pedido do token do WebSocket sai de um `$effect`,
 * que só roda no cliente: esperá-lo é a prova barata de que a página já responde a evento.
 */
export async function abrirAgenda(page: Page, clinica: Clinica): Promise<void> {
	const hidratou = page.waitForResponse((r) => r.url().includes('/api/realtime/token'));
	await page.goto(`/agenda?date=${clinica.dia}`);
	await expect(page.locator(`[data-prof-id="${clinica.profissional.id}"]`)).toBeVisible();
	await hidratou;
}

/** Os blocos do grid. `data-appt` é o gancho que o próprio componente já expunha. */
export function blocos(page: Page) {
	return page.locator('[data-appt]');
}

/**
 * Resolve quando um canal **entrou** — não quando o socket abriu.
 *
 * A diferença decide se o teste de tempo real mede regressão ou sorte: entre o `connect` e o
 * `phx_reply` do join há um round-trip, e um evento emitido nessa janela não chega a ninguém.
 * Esperar o join é o que torna o cenário determinístico.
 *
 * Precisa ser chamada **antes** do `goto` (o listener tem de estar armado quando o socket abre).
 * O `trecho` é um pedaço do tópico — a página abre mais de um socket (agenda e notificações), e é
 * ele que diz de qual estamos falando.
 */
export function joinDoCanal(page: Page, trecho: string): Promise<void> {
	return new Promise((resolve) => {
		page.on('websocket', (ws) => {
			ws.on('framereceived', (frame) => {
				const payload = typeof frame.payload === 'string' ? frame.payload : '';
				if (payload.includes(trecho) && payload.includes('phx_reply')) resolve();
			});
		});
	});
}

/** O canal do dia da agenda: `clinic:<id>:agenda:<data>`. */
export function joinDaAgenda(page: Page, dia: string): Promise<void> {
	return joinDoCanal(page, `agenda:${dia}`);
}

/** O sino do rail, cujo nome acessível carrega o contador ("Notificações (2 não lidas)"). */
export function sino(page: Page) {
	return page
		.getByRole('navigation', { name: 'Navegação principal' })
		.getByRole('link', { name: /^Notificações/ });
}
