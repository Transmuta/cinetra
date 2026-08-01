import { fail, type RequestEvent } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { apiBase, headersDeContexto } from '$lib/server/api';

// A página que o **paciente** abre pelo link do e-mail (doc 52 §5).
//
// Fora do grupo `(app)`: não tem sessão, não tem shell, não tem sidebar. Quem chega aqui não é
// usuário do sistema — é alguém que recebeu uma mensagem. O que autoriza é o token assinado, e
// ele responde por UMA mensagem: não abre sessão, não dá acesso a ficha nem a agenda.
//
// Fala com a API sem `apiFetch` porque não há cookie de sessão para repassar. É por isso que ela
// é explícita aqui em vez de num módulo de `$lib/server`: dar a ela a mesma cara das outras
// convidaria a copiar o padrão para onde ele não vale.
//
// O que ela NÃO pode dispensar é o IP do cliente (`headersDeContexto`). Sem sessão, o IP é a única
// chave que a API tem para o rate limit — e sem o header todos os pacientes do produto caem no
// mesmo balde, o do container do BFF: um visitante em laço derrubava a confirmação de todo mundo
// (bate-volta doc 68, causa B).

interface Resumo {
	clinica: string | null;
	paciente: string | null;
	data: string | null;
	hora: string | null;
	resposta: 'confirmou' | 'quer_remarcar' | null;
	respondido_em: string | null;
}

async function chamar(
	event: RequestEvent,
	token: string,
	init?: RequestInit
): Promise<{ status: number; resumo: Resumo | null }> {
	const headers = headersDeContexto(event, init?.headers);
	headers.set('accept', 'application/json');

	try {
		const res = await event.fetch(`${apiBase()}/api/reply/${encodeURIComponent(token)}`, {
			...init,
			headers
		});

		if (!res.ok) return { status: res.status, resumo: null };
		return { status: res.status, resumo: (await res.json()) as Resumo };
	} catch {
		return { status: 0, resumo: null };
	}
}

export const load: PageServerLoad = async (event) => {
	const { status, resumo } = await chamar(event, event.params.token);

	// Não usa `error()`: a página de erro padrão fala com um usuário do sistema ("volte ao
	// painel"), e quem está aqui não tem painel. O estado vira dado e a página escreve uma frase
	// que faz sentido para um paciente.
	return { resumo, status };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const resposta = String(form.get('resposta') ?? '');

		const { status, resumo } = await chamar(event, event.params.token, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ resposta })
		});

		if (!resumo) {
			return fail(status || 502, {
				error: 'Não conseguimos registrar sua resposta. Tente novamente em instantes.'
			});
		}

		return { resumo };
	}
};
