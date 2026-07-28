import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { apiBase } from '$lib/server/api';
import { log } from '$lib/server/log';

/**
 * Readiness do BFF — **e o único alvo honesto para o monitor externo** (doc 62 §9.4).
 *
 * ## Por que este endpoint precisou existir
 *
 * Com o desenho BFF-only (docs/59 §3.1), o Traefik só encaminha `/socket` e `/webhooks` para a
 * API: **`/api/ready` não é alcançável de fora**. Sobrava apontar o monitor externo para
 * `https://<host>/`, que é a página de login — e ela responde **200 com a API inteiramente
 * fora**, porque é conteúdo estático servido pelo Node. O monitor ficaria verde com o produto
 * inutilizável, que é a pior coisa que um monitor pode fazer.
 *
 * Este endpoint atravessa a mesma rede interna que toda requisição real atravessa e consulta o
 * `/api/ready` da API (que por sua vez toca o banco e o pool). Uma URL só, que fica vermelha se
 * qualquer elo do caminho quebrar.
 *
 * ## O corpo não descreve a infra
 *
 * Ele é público. `up`/`down` e nada mais — o motivo vai para o log, onde quem investiga alcança e
 * quem varre a internet não.
 */

// Curto: o monitor externo bate a cada minuto, e um check mais lento que o intervalo empilha.
// Também é o teto de espera do BFF por uma API que travou, não que caiu.
const TIMEOUT_MS = 3_000;

export const GET: RequestHandler = async ({ fetch }) => {
	try {
		const res = await fetch(`${apiBase()}/api/ready`, {
			headers: { accept: 'application/json' },
			signal: AbortSignal.timeout(TIMEOUT_MS)
		});

		if (!res.ok) {
			log.warning('readiness do BFF reprovado: API não está pronta', { api_status: res.status });
			return json({ status: 'down', service: 'web', api: 'down' }, { status: 503 });
		}

		return json({ status: 'ok', service: 'web', api: 'ok' });
	} catch (erro) {
		// Timeout, DNS, conexão recusada — do ponto de vista de quem usa o produto é tudo a mesma
		// coisa: não dá para trabalhar.
		log.warning('readiness do BFF reprovado: API inalcançável', {
			detail: erro instanceof Error ? erro.message : String(erro)
		});

		return json({ status: 'down', service: 'web', api: 'unreachable' }, { status: 503 });
	}
};
