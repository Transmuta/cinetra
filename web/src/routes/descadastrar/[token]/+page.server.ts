import { fail, type RequestEvent } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { apiBase, headersDeContexto } from '$lib/server/api';

// A página de descadastro que o **paciente** abre pelo rodapé do e-mail (doc 52 §10).
//
// Irmã de `/confirmar/[token]`, e pelas mesmas razões: fora do grupo `(app)`, sem sessão, sem
// shell. Quem chega aqui não é usuário do sistema — é alguém que recebeu uma mensagem. O que
// autoriza é o token assinado, e ele responde por UMA lista de envio.
//
// **O `load` não descadastra.** Ele só lê o estado; quem registra é a action do botão. Não é
// cerimônia: antivírus corporativo e pré-visualização de webmail visitam todo link de todo
// e-mail, e um efeito no GET tiraria da lista quem nunca clicou — com sintoma meses depois
// ("a clínica parou de me avisar").
//
// Fala com a API sem `apiFetch` porque não há cookie de sessão para repassar, e leva o IP do
// cliente (`headersDeContexto`) porque sem sessão o IP é a única chave que o rate limit da API
// tem — sem ele, todos os pacientes do produto caem no balde do container do BFF.

interface Resumo {
	clinica: string | null;
	canal: 'email' | 'whatsapp' | null;
	descadastrado: boolean;
}

async function chamar(
	event: RequestEvent,
	token: string,
	init?: RequestInit
): Promise<{ status: number; resumo: Resumo | null }> {
	const headers = headersDeContexto(event, init?.headers);
	headers.set('accept', 'application/json');

	try {
		const res = await event.fetch(`${apiBase()}/api/opt-out/${encodeURIComponent(token)}`, {
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
	// painel"), e quem está aqui não tem painel.
	return { resumo, status };
};

export const actions: Actions = {
	default: async (event) => {
		const { status, resumo } = await chamar(event, event.params.token, { method: 'POST' });

		if (!resumo) {
			return fail(status || 502, {
				error: 'Não conseguimos registrar seu pedido. Tente novamente em instantes.'
			});
		}

		return { resumo };
	}
};
