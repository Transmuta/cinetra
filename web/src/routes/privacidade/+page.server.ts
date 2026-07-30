import type { PageServerLoad } from './$types';
import { cabecalhoPublico } from '$lib/seo';

// Documento de leitura, sem guarda de sessão nenhuma (ao contrário da raiz e das telas de auth,
// que redirecionam quem já entrou). Duas razões: quem está logado abre a política pelo rodapé e
// deve continuar lendo, e o robô não pode gastar rastreio em 302 numa página que está no sitemap.
export const load: PageServerLoad = ({ url }) => cabecalhoPublico(url);
