import { fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { requireSession } from '$lib/server/auth';
import { onboardClinic } from '$lib/server/clinics';

// Onboarding do primeiro acesso: SÓ para quem está logado e ainda não tem clínica. Quem já
// tem uma — inclusive o convidado, cujo vínculo pendente é ativado no login (Invites) — vai
// direto para a home. Fica FORA do grupo (app), cuja guarda exige clínica ativa.
export const load: PageServerLoad = async (event) => {
	const me = await requireSession(event);
	if (me.active_clinic_id) redirect(303, '/');
	return { nome: me.user.nome };
};

export const actions: Actions = {
	default: async (event) => {
		const form = await event.request.formData();
		const nome = String(form.get('nome') ?? '').trim();

		if (nome === '') return fail(400, { nome, error: 'Dê um nome à sua clínica.' });

		const res = await onboardClinic(event, nome);
		if (!res.ok) return fail(res.status || 400, { nome, error: res.error });

		// Criada: o próximo /me já resolve a clínica como tenant ativo. Vai para a home.
		redirect(303, '/');
	}
};
