import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

// A raiz de Configurações redireciona para a primeira seção (Equipe & acessos).
export const load: PageServerLoad = () => {
	redirect(307, '/configuracoes/equipe');
};
