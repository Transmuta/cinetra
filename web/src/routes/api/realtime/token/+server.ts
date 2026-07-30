import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { apiFetch, apiPublicOrigin } from '$lib/server/api';

// Token efêmero do WebSocket (Entrega 3, contrato 09 §8). Same-origin pelo BFF, como todo o
// resto — o cookie de sessão é HttpOnly e só o servidor pode trocá-lo por um token.
//
// A **origem pública** da API sai daqui junto. Ela vive em `API_PUBLIC_ORIGIN`, que é env
// privada do BFF: o cliente precisa dela porque o socket é a exceção ao ADR-005 (vai direto ao
// Phoenix, não pelo BFF), e sem descê-la aqui o browser não teria para onde discar.
//
// Este endpoint é chamado duas vezes na vida de uma aba: ao montar a agenda e quando o socket
// cai — o token vale 15 min e a reconexão de uma aba parada precisa de um novo.
export const GET: RequestHandler = async (event) => {
	try {
		const res = await apiFetch(event, '/api/realtime/token', {
			headers: { accept: 'application/json' }
		});

		// Repassa o status (401 sem sessão, 409 sem clínica ativa) sem o corpo da API: a página
		// só precisa saber que não há tempo real, e degrada para a agenda estática.
		if (!res.ok) return json({ error: 'unavailable' }, { status: res.status });

		const body = (await res.json()) as { token: string; expires_at: string; clinic_id: string };

		return json({ ...body, origin: apiPublicOrigin() });
	} catch {
		return json({ error: 'unavailable' }, { status: 503 });
	}
};
