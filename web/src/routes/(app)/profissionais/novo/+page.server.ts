import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinicHours } from '$lib/server/clinic-hours';
import { createProfessional, runProfessionalSave } from '$lib/server/professionals';
import { weekToHoursRows } from '$lib/professionals';

// O editor de horário precisa do expediente da clínica (para o invariante prof ⊆ clínica e o
// "Segue a clínica"). Vem do mesmo BFF de Horário, convertido em linhas `{dow, periods}`.
export const load: PageServerLoad = async (event) => {
	const result = await fetchClinicHours(event);
	if (!result.data) error(result.status || 502, 'Não foi possível carregar o horário da clínica.');
	return { clinicHours: weekToHoursRows(result.data.clinic_hours) };
};

export const actions: Actions = {
	// Cria a ficha e, em seguida, grava grade + exceções + situação (orquestração comum em
	// `runProfessionalSave`). Um 403 (não é owner/admin) ou 422 viram mensagem no próprio form.
	save: async (event) => {
		const form = await event.request.formData();

		const res = await runProfessionalSave(event, form, {
			persist: (ficha) => createProfessional(event, ficha),
			// Novo nasce ativo; a grade/exceções ainda não existem no servidor.
			originalActive: true,
			originalExceptionIds: []
		});

		if (!res.ok) return fail(res.status, { error: res.error });
		redirect(303, '/profissionais');
	}
};
