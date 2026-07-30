import type { PageServerLoad } from './$types';
import { cabecalhoPublico } from '$lib/seo';

// Sem guarda de sessão, pela mesma razão de `/privacidade`: ver o comentário lá.
export const load: PageServerLoad = ({ url }) => cabecalhoPublico(url);
