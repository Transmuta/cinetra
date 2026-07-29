import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import {
	fetchMembers,
	inviteMember,
	updateMember,
	revokeMember,
	resendInvite
} from '$lib/server/members';
import { fetchAccessMatrix } from '$lib/server/access-matrix';

// Carrega membros + profissionais da clínica ativa (BFF → /api/members). 403 quando o papel
// não permite (recepção/profissional) — o shell mostra a página de erro.
export const load: PageServerLoad = async (event) => {
	// A matriz (AN-06) vem junto: é a referência de quem está convidando. Degrada para null —
	// a seção some, a equipe continua.
	const [result, matrix] = await Promise.all([fetchMembers(event), fetchAccessMatrix(event)]);

	if (result.status === 403) {
		error(403, 'Só a dona e administradores gerenciam a equipe.');
	}
	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar a equipe.');
	}

	return {
		members: result.data.members,
		professionals: result.data.professionals,
		accessMatrix: matrix.data
	};
};

export const actions: Actions = {
	invite: async (event) => {
		const form = await event.request.formData();
		const email = String(form.get('email') ?? '').trim();
		const nome = String(form.get('nome') ?? '').trim();
		const papel = String(form.get('papel') ?? '');
		const professional_id = String(form.get('professional_id') ?? '').trim() || null;

		if (email === '') return fail(400, { action: 'invite', error: 'Informe o e-mail.' });
		if (papel === 'profissional' && !professional_id) {
			return fail(400, { action: 'invite', error: 'Escolha o profissional a vincular.' });
		}

		const res = await inviteMember(event, { email, nome, papel, professional_id });
		if (!res.ok) return fail(res.status || 400, { action: 'invite', error: res.error });
		return { action: 'invite', ok: true };
	},

	update: async (event) => {
		const form = await event.request.formData();
		const id = String(form.get('id') ?? '');
		const papel = form.has('papel') ? String(form.get('papel')) : undefined;
		const professional_id = form.has('professional_id')
			? String(form.get('professional_id')).trim() || null
			: undefined;

		if (id === '') return fail(400, { action: 'update', error: 'Membro inválido.' });

		const res = await updateMember(event, id, { papel, professional_id });
		if (!res.ok) return fail(res.status || 400, { action: 'update', error: res.error });
		return { action: 'update', ok: true };
	},

	revoke: async (event) => {
		const form = await event.request.formData();
		const id = String(form.get('id') ?? '');
		if (id === '') return fail(400, { action: 'revoke', error: 'Membro inválido.' });

		const res = await revokeMember(event, id);
		if (!res.ok) return fail(res.status || 400, { action: 'revoke', error: res.error });
		return { action: 'revoke', ok: true };
	},

	resend: async (event) => {
		const form = await event.request.formData();
		const email = String(form.get('email') ?? '').trim();
		if (email === '') return fail(400, { action: 'resend', error: 'E-mail inválido.' });

		const res = await resendInvite(event, email);
		if (!res.ok) return fail(res.status || 400, { action: 'resend', error: res.error });
		return { action: 'resend', ok: true };
	}
};
