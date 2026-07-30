import { fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { createPatient, runPatientSave } from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';

// O form precisa do diretório (chips de "profissional preferido"). O aviso de possível
// duplicado NÃO carrega mais o cadastro inteiro: consulta `/api/patients/lookup` quando o CPF
// ou o telefone ficam completos.
export const load: PageServerLoad = async (event) => {
	const prof = await fetchProfessionals(event);
	return { professionals: prof.data?.professionals ?? [] };
};

export const actions: Actions = {
	// Cria a ficha. Um 403 (não é owner/admin) ou 422 viram mensagem no próprio form.
	save: async (event) => {
		const form = await event.request.formData();

		const res = await runPatientSave(event, form, {
			persist: (ficha) => createPatient(event, ficha)
		});

		if (!res.ok) return fail(res.status, { error: res.error });
		redirect(303, '/pacientes');
	}
};
