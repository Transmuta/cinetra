import { redirect, type RequestEvent } from '@sveltejs/kit';
import { apiFetch, reemitSession } from '$lib/server/api';
import { registrarAceite } from '$lib/server/auth';

// Callback do OAuth Google (ADR-005/015). O Google devolve code+state AQUI (no web) — este
// caminho é o redirect URI cadastrado no console: <GOOGLE_REDIRECT_URI base>/user/google/callback.
// Proxiamos para a API repassando o cookie de `state`; a API valida, troca o code por
// tokens/userinfo, cria/vincula o User e assina a sessão — que re-emitimos no domínio do web.
export async function GET(event: RequestEvent) {
	const res = await apiFetch(event, `/api/auth/strategy/user/google/callback${event.url.search}`, {
		redirect: 'manual'
	});

	if (!reemitSession(event, res)) redirect(303, '/entrar?erro=google');

	// O aceite dos documentos legais (`[D-14]`) — o mesmo carimbo do callback do magic link. É o
	// caminho que a caixa de seleção do `/criar-conta` NÃO alcançaria: o botão do Google é um
	// `<a>` de navegação completa, que trava nenhuma caixa sem JavaScript (doc 76 §1). Registrar
	// aqui é o que faz o aceite valer igual nos dois caminhos.
	await registrarAceite(event);

	redirect(303, '/');
}
