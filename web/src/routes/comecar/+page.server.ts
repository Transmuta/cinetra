import { fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { requireSession } from '$lib/server/auth';
import { onboardClinic, switchTenant } from '$lib/server/clinics';

// `?nova=1`: dono multi-clínica criando OUTRA clínica pelo menu do usuário (a API aceita —
// política `actor_present()`). Sem esse marcador, o onboarding é só do primeiro acesso.
function novaFlow(url: URL): boolean {
	return url.searchParams.get('nova') === '1';
}

// Onboarding: por padrão SÓ para quem está logado e ainda não tem clínica — quem já tem uma
// (inclusive o convidado, ativado no login) vai direto para a home. A exceção é `?nova=1`,
// que deixa um dono existente criar uma clínica adicional. Fica FORA do grupo (app), cuja
// guarda exige clínica ativa.
export const load: PageServerLoad = async (event) => {
	const me = await requireSession(event);
	const nova = novaFlow(event.url);
	if (me.active_clinic_id && !nova) redirect(303, '/');
	return { nome: me.user.nome, nova };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const nome = String(form.get('nome') ?? '').trim();

		if (nome === '') return fail(400, { nome, error: 'Dê um nome à sua clínica.' });

		const res = await onboardClinic(event, nome);
		if (!res.ok) return fail(res.status || 400, { nome, error: res.error });

		// Primeiro acesso: o próximo /me resolve a nova clínica sozinho (único vínculo ativo).
		// Fluxo "nova" (já era dono de outra): o tenant ativo continua o antigo — troca para a
		// recém-criada para cair no shell dela.
		if (novaFlow(event.url) && res.clinicId) await switchTenant(event, res.clinicId);

		redirect(303, '/');
	}
};
