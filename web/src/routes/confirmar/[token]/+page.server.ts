import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { chamar, quandoDo } from './resposta';

// A página que o **paciente** abre pelo link do e-mail (doc 52 §5).
//
// Fora do grupo `(app)`: não tem sessão, não tem shell, não tem sidebar. Quem chega aqui não é
// usuário do sistema — é alguém que recebeu uma mensagem. O que autoriza é o token assinado, e
// ele responde por UMA mensagem: não abre sessão, não dá acesso a ficha nem a agenda.
//
// A chamada à API mora em `resposta.ts`, ao lado, porque o `.ics` de "adicionar à agenda" usa a
// mesma — inclusive o repasse do IP, que é o que segura o rate limit por paciente.

/** O relógio é lido UMA vez por request, e passado adiante: ver `quandoDo`. */
const agora = () => new Date().toISOString();

export const load: PageServerLoad = async (event) => {
	const { status, resumo } = await chamar(event, event.params.token);

	// Não usa `error()`: a página de erro padrão fala com um usuário do sistema ("volte ao
	// painel"), e quem está aqui não tem painel. O estado vira dado e a página escreve uma frase
	// que faz sentido para um paciente.
	return { resumo, status, quando: quandoDo(resumo, agora()) };
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

		// O `quando` vai junto pela mesma razão que o `resumo`: depois do POST é a resposta da ação
		// que a página desenha, e sem ele a data voltaria a ser a string congelada no meio do fluxo.
		return { resumo, quando: quandoDo(resumo, agora()) };
	}
};
