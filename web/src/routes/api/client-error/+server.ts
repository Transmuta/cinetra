import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { log, sanitizarRota, sanitizarTexto, truncar, LIMITES } from '$lib/server/log';
import { ipDoCliente } from '$lib/server/api';
import { fingerprint } from '$lib/fingerprint';

/**
 * Recebe crash do browser e o transforma em log do servidor (doc 62 §7.2).
 *
 * ## Este endpoint aceita dado de fora, então nada aqui confia no cliente
 *
 * É a única rota do BFF que existe para ser chamada por código que roda na máquina de outra
 * pessoa. Cinco guardas, e todas assumem entrada hostil:
 *
 *   1. **Teto de corpo** — recusa payload grande antes de fazer parse;
 *   2. **Rate limit por IP** — sem ele, um laço no browser (ou um script) enche a retenção do dia;
 *   3. **Allowlist de campos** — só `origem`, `message`, `stack`, `route`, `route_id` e `status`
 *      são lidos. O resto do JSON é descartado, então um cliente não consegue injetar campo
 *      arbitrário no log (nem um `severity: "info"` para se esconder);
 *   4. **Re-sanitização da rota** — o cliente já sanitiza, mas quem garante é este lado. A
 *      barreira de PII não pode depender de código que o usuário consegue editar;
 *   5. **Fingerprint recomputado** — o agrupamento é calculado aqui, a partir do texto já
 *      sanitizado, e o valor que o cliente eventualmente mande é ignorado. Escolher o próprio
 *      grupo permitiria esconder um erro novo dentro de um grupo velho e ruidoso.
 *
 * Não chama a API: o evento é do BFF e morre no stdout do BFF.
 */

const MAX_BYTES = 8 * 1024;

// Janela deslizante simples, em memória do processo. É suficiente porque o adapter-node é um
// processo por instância e o objetivo não é segurança forte — é impedir que um laço no browser
// vire volume. Perder a contagem num restart é irrelevante.
const JANELA_MS = 60_000;
const MAX_POR_JANELA = 20;
const MAX_CHAVES = 5_000;

const contagem = new Map<string, { n: number; ate: number }>();

/**
 * Recusa o relato grande — mas **registra que ele existiu**.
 *
 * O conteúdo não entra (é o que o teto existe para evitar), só o tamanho. Descartar calado seria
 * perder exatamente o sinal mais interessante: o cliente trunca stack em 2 KB, então um corpo
 * acima do teto significa cliente modificado, bug de laço ou abuso — as três coisas que se quer
 * saber, e nenhuma delas aparece se o servidor simplesmente devolver 413 e esquecer.
 */
function recusarGrande(bytes: number) {
	log.warning('relato de erro do browser acima do teto', { bytes });
	return json({ ok: false }, { status: 413 });
}

/**
 * O corpo é uma violação de CSP? Devolve o relatório, ou `null` se for um erro de browser comum.
 *
 * **Dois formatos**, porque a especificação virou no meio do caminho e os browsers estão nos dois:
 *
 *   * `report-uri` (o que funciona hoje em todo lugar): `{"csp-report": {...}}`, com as chaves em
 *     `kebab-case`;
 *   * `report-to` / Reporting API (o sucessor): um ARRAY de `{type, body}`, com `body` em
 *     `camelCase` — daí o mapeamento das duas grafias abaixo.
 *
 * Detectar pelo CORPO e não pelo `?csp=1` é deliberado: a query é nossa e pode ser esquecida numa
 * mudança de CSP, o formato do corpo vem do browser e não muda por descuido nosso.
 */
function extrairCspReport(corpo: unknown): Record<string, string | undefined> | null {
	const relatorio = Array.isArray(corpo)
		? (corpo.find((r) => r?.type === 'csp-violation')?.body ?? null)
		: ((corpo as Record<string, unknown>)?.['csp-report'] ?? null);

	if (!relatorio || typeof relatorio !== 'object') return null;

	const r = relatorio as Record<string, unknown>;
	const texto = (...chaves: string[]) => {
		const achado = chaves.map((k) => r[k]).find((v) => typeof v === 'string');
		return achado as string | undefined;
	};

	return {
		'effective-directive': texto('effective-directive', 'effectiveDirective'),
		'violated-directive': texto('violated-directive', 'violatedDirective'),
		'blocked-uri': texto('blocked-uri', 'blockedURL', 'blockedURI'),
		'document-uri': texto('document-uri', 'documentURL', 'documentURI')
	};
}

function excedeu(chave: string, agora: number): boolean {
	// Poda preguiçosa: sem isto o Map cresce com um IP novo a cada requisição — o vazamento de
	// memória clássico de rate limiter caseiro.
	if (contagem.size > MAX_CHAVES) {
		for (const [k, v] of contagem) if (v.ate <= agora) contagem.delete(k);
		if (contagem.size > MAX_CHAVES) contagem.clear();
	}

	const atual = contagem.get(chave);

	if (!atual || atual.ate <= agora) {
		contagem.set(chave, { n: 1, ate: agora + JANELA_MS });
		return false;
	}

	atual.n++;
	return atual.n > MAX_POR_JANELA;
}

export const POST: RequestHandler = async (event) => {
	// Rate limit **primeiro**, antes de qualquer outra checagem: ele é a guarda que também
	// protege as guardas. Sem esta ordem, quem manda payload grande em laço seria recusado com
	// 413 mas geraria uma linha de log por tentativa — o limite tem de valer para o barulho todo.
	// R-M19 e R-B9 (onda 5). Era `event.getClientAddress()` cru, e ele tem dois problemas aqui:
	// **levanta** quando o header configurado falta (virando 500 nesta rota pública), e devolve
	// `''` quando o header vem presente e vazio — com `''` de chave, todo mundo cai no MESMO balde
	// de 20/min, e o teto por-IP vira um teto global sem ninguém perceber.
	//
	// `ipDoCliente` resolve os dois. O balde `sem-ip` é deliberadamente separado e nomeado: quem
	// chega sem IP identificável divide um teto entre si, e não com os usuários reais.
	if (excedeu(ipDoCliente(event) ?? 'sem-ip', Date.now())) {
		return json({ ok: false }, { status: 429 });
	}

	const declarado = Number(event.request.headers.get('content-length') ?? 0);
	if (declarado > MAX_BYTES) return recusarGrande(declarado);

	let corpo: Record<string, unknown>;

	try {
		const texto = await event.request.text();
		if (texto.length > MAX_BYTES) return recusarGrande(texto.length);
		corpo = JSON.parse(texto) as Record<string, unknown>;
	} catch {
		// Não silencioso: JSON quebrado vindo do nosso próprio cliente é bug nosso, e some se
		// ninguém registrar.
		log.warning('relato de erro do browser ilegível', { bytes: declarado });
		return json({ ok: false }, { status: 400 });
	}

	// R-B6 (onda 5) — o browser também manda VIOLAÇÃO DE CSP para cá, e no formato dele, não no
	// nosso. `report-uri` posta `{"csp-report": {...}}`; o `report-to` mais novo posta um array de
	// relatórios. Sem esta normalização, o relatório entraria com todos os campos `undefined` e
	// viraria uma linha de log inútil — pior que não ter relatório, porque parece que tem.
	//
	// O ganho concreto: hoje, se um build sair sem `R2_ACCOUNT_ID`, o bucket fica fora do
	// `connect-src`, todo upload de anexo morre e o motivo existe SÓ no console do browser da
	// recepcionista. Com isto, ele vira linha de log com `blocked-uri` e `violated-directive`.
	const cspReport = extrairCspReport(corpo);
	if (cspReport) {
		log.warning('violação de CSP no browser', {
			origem: 'csp',
			// Os três campos que respondem "o que foi bloqueado e por qual regra". `blocked_uri`
			// passa por `sanitizarTexto` como qualquer texto vindo de fora: uma violação em
			// `connect-src` carrega a URL tentada, e ela pode ter id de paciente.
			directive: truncar(cspReport['effective-directive'] ?? cspReport['violated-directive'], 60),
			blocked_uri: sanitizarTexto(truncar(cspReport['blocked-uri'], LIMITES.route)),
			route: sanitizarRota(truncar(cspReport['document-uri'], LIMITES.route)),
			user_agent: truncar(event.request.headers.get('user-agent'), LIMITES.extra)
		});

		return new Response(null, { status: 204 });
	}

	const origem = truncar(corpo.origem, 20);
	// `sanitizarTexto` nos dois campos de TEXTO LIVRE: o stack de um erro de browser carrega a
	// URL da página, e sanitizar só o campo `route` deixava o id do paciente passar dentro dele.
	const detail = sanitizarTexto(truncar(corpo.message, LIMITES.message));
	const stack = sanitizarTexto(truncar(corpo.stack, LIMITES.stack));

	log.error('erro no browser', {
		origem,
		route: sanitizarRota(truncar(corpo.route, LIMITES.route)),
		route_id: truncar(corpo.route_id, LIMITES.route),
		status: typeof corpo.status === 'number' ? corpo.status : undefined,
		detail,
		stack,
		// Chave de agrupamento (doc 98 §opção C). **Recomputada aqui**, nunca lida do corpo — é a
		// quinta guarda deste endpoint, e pela mesma razão das outras quatro: um cliente que
		// escolhesse o próprio grupo poderia esconder um erro novo dentro de um grupo velho e
		// ruidoso, que é a forma mais barata de tornar um bug invisível.
		//
		// Calculada sobre o texto JÁ sanitizado, e isso não é detalhe: o stack cru traz o uuid do
		// paciente dentro da URL, então o mesmo bug em duas fichas cairia em dois grupos — o
		// agrupamento morreria justamente na tela que mais gera erro.
		fingerprint: fingerprint(origem, detail, stack),
		user_agent: truncar(event.request.headers.get('user-agent'), LIMITES.extra)
	});

	// 204: o browser não tem nada a fazer com a resposta, e um corpo aqui só gastaria banda numa
	// aba que provavelmente está fechando.
	return new Response(null, { status: 204 });
};
