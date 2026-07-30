import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

// Catch-all do shell: qualquer destino ainda não construído (Agenda, Pacientes, e as demais
// abas de Configurações) cai aqui e devolve 404 — porém DENTRO do chrome (rail + sidebar),
// via (app)/+error.svelte. Só /configuracoes/equipe está pronto nesta fatia.
export const load: PageLoad = () => {
	error(404, 'Em construção');
};
