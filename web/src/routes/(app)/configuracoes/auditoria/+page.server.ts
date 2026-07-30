import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { AUDIT_BASE } from '$lib/audit';

// A Auditoria saiu de Configurações e virou seção própria (`/auditoria`): ela não é um AJUSTE da
// clínica — é uma tela de consulta, com filtros próprios e volume de dado, e estava enterrada
// dois cliques abaixo do que merece.
//
// Este redirect existe porque a URL antiga já circula: está em links colados, em histórico de
// browser e nos deep-links `?record_id=` que a própria tela emite. 308 preserva o método e diz
// aos clientes que a mudança é permanente; a query string viaja junto, senão o "ver histórico
// deste registro" de um link velho cairia no feed geral sem avisar.
export const load: PageServerLoad = ({ url }) => {
	redirect(308, `${AUDIT_BASE}${url.search}`);
};
