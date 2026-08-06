import type { PageServerLoad } from './$types';
import { canonical } from '$lib/seo';

// `origem` acompanha a canônica porque as tags de `<head>` (og:image) precisam do host, e ele só
// existe no servidor — o mesmo contrato de `cabecalhoPublico` das outras páginas públicas.
export const load: PageServerLoad = ({ url }) => ({
	canonical: canonical(url),
	origem: url.origin
});
