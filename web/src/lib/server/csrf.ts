import { json, type RequestEvent } from '@sveltejs/kit';

/**
 * Exige `content-type: application/json` num endpoint que muda estado. Devolve `null` quando
 * está tudo certo, ou a resposta 415 a devolver.
 *
 * ## Por que isto é uma guarda de segurança, e não formalismo
 *
 * A proteção CSRF do SvelteKit tem **duas** brechas que se somam num endpoint `+server.ts`:
 *
 *  1. ela roda dentro de um `if (!DEV)` — em desenvolvimento não existe (medido: um `POST`
 *     cross-origin com `origin: https://evil.example` arquivou um paciente de verdade no
 *     `localhost:5173`);
 *  2. mesmo em produção, ela só dispara quando o content-type é de **formulário**
 *     (`application/x-www-form-urlencoded`, `multipart/form-data`, `text/plain`). Um `POST`
 *     **sem content-type nenhum** não é formulário — e também é *simple request* de CORS, então
 *     o browser nem pede preflight. Passa pelas duas peneiras.
 *
 * Exigir JSON fecha a soma: um site de terceiro que queira mandar `application/json` é obrigado
 * a preflightar, e o preflight de outra origem não é respondido com `Access-Control-Allow-Origin`
 * — o browser aborta antes de a request sair. O que sobra para o atacante é o form content-type,
 * que é justamente o que a guarda do SvelteKit pega.
 *
 * Vale para `POST`/`PATCH`/`DELETE` mesmo quando não há corpo: o `DELETE` já exigiria preflight
 * por não ser método simples, mas depender disso é depender de um detalhe da tabela de CORS.
 * Aqui a regra é uma só, e é legível.
 */
export function exigirJson(event: RequestEvent): Response | null {
	const tipo = event.request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();

	if (tipo === 'application/json') return null;

	return json(
		{ ok: false, error: 'Requisição inválida.' },
		{ status: 415 }
	);
}
