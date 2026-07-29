import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { log, sanitizarRota, sanitizarTexto, truncar, LIMITES } from '$lib/server/log';
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
	if (excedeu(event.getClientAddress(), Date.now())) return json({ ok: false }, { status: 429 });

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
		// Chave de agrupamento (doc 73 §opção C). **Recomputada aqui**, nunca lida do corpo — é a
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
