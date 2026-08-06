import type { LayoutServerLoad } from './$types';
import { SESSION_COOKIE } from '$lib/server/api';

// A central é PÚBLICA (doc 108 §2): sem guarda de sessão, pela mesma razão de `/termos` e com um
// motivo a mais — metade das dúvidas de suporte é "não consigo entrar", e uma ajuda atrás do login
// não atende exatamente quem mais precisa dela.
//
// O cookie é só olhado, nunca resolvido contra a API. A única coisa que ele decide aqui é o
// destino do botão do canto ("Voltar ao sistema" ou "Entrar"), e chamar `loadMe` para isso poria
// uma ida à API no caminho de uma página estática — inclusive quando a API estiver fora do ar,
// que é uma das horas em que se procura ajuda.
export const load: LayoutServerLoad = ({ cookies }) => ({
	logado: !!cookies.get(SESSION_COOKIE)
});
