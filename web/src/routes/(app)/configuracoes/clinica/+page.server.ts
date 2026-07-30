import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinic, updateClinic } from '$lib/server/clinics';

// Carrega os dados da clínica ativa (BFF → /api/clinic). Como as demais telas de config, NÃO há
// recorte de papel no load: todo membro lê; só a escrita exige owner/admin (policies da API + o
// `canManage` da página).
export const load: PageServerLoad = async (event) => {
	const result = await fetchClinic(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar os dados da clínica.');
	}

	return { clinic: result.data.clinic };
};

export const actions: Actions = {
	// Nome, CNPJ e endereço salvos de uma vez. O CNPJ viaja como o usuário digitou (mascarado): a
	// API é a autoridade — normaliza e valida (alfanumérico), e um 422 já vira toast de erro. Os
	// campos opcionais vão sempre (mesmo em branco) para permitir limpá-los.
	save: async (event) => {
		const form = await event.request.formData();
		const nome = String(form.get('nome') ?? '').trim();

		if (nome === '') return fail(400, { error: 'Informe o nome da clínica.' });

		const res = await updateClinic(event, {
			nome,
			cnpj: String(form.get('cnpj') ?? '').trim(),
			endereco: String(form.get('endereco') ?? '').trim()
		});

		if (!res.ok) return fail(res.status || 400, { error: res.error });
		return { ok: true };
	}
};
