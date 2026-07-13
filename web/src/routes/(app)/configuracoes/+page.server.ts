import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

// A raiz de Configurações leva à primeira seção construída (Equipe & acessos). As demais
// seções do sidebar (Tipos, Horário, Exceções, Operação) ainda não existem → 404.
export const load: PageServerLoad = () => {
	redirect(307, '/configuracoes/equipe');
};
