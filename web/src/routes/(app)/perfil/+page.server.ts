import { fail } from '@sveltejs/kit';
import type { Actions } from './$types';
import { updateProfile } from '$lib/server/profile';

// A tela reutiliza o `me` já carregado pelo layout do app (não refaz /me) — por isso não há
// `load` aqui. Só a escrita passa pelo servidor.
export const actions: Actions = {
	// Salva o nome de exibição. O `invalidateAll` que o `use:enhance` dispara recarrega o layout
	// (novo /me) e, com ele, o nome no menu do usuário e no topo — sem recarregar a página.
	update: async (event) => {
		const form = await event.request.formData();
		const nome = String(form.get('nome') ?? '').trim();

		if (nome === '') return fail(400, { error: 'Informe seu nome.' });

		const res = await updateProfile(event, nome);
		if (!res.ok) return fail(res.status || 400, { error: res.error });
		return { ok: true };
	}
};
