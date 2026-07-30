import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

// Catch-all do shell: um destino que não existe cai aqui e devolve 404 — porém DENTRO do chrome
// (rail + sidebar), via (app)/+error.svelte.
//
// A mensagem era "Em construção", herança da fatia em que só /configuracoes/equipe existia. Hoje
// ela informa errado: quem digitou a URL torta lê que a funcionalidade está a caminho, e fica
// esperando por uma tela que nunca vai existir (doc 88, A-7).
export const load: PageLoad = () => {
	error(404, 'Página não encontrada');
};
