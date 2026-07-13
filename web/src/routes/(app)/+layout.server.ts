import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';
import { loadMe } from '$lib/server/auth';

// Guarda de auth do shell administrativo: sem sessão, volta para /entrar. Com sessão mas
// sem clínica ativa, volta para a home (que trata o estado "sem clínica"). ADR-005: o BFF
// resolve `me` server-to-server.
export const load: LayoutServerLoad = async (event) => {
	const me = await loadMe(event);
	if (!me) redirect(303, '/entrar');
	if (!me.active_clinic_id) redirect(303, '/');
	return { me };
};
