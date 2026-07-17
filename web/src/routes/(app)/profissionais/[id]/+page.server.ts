import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinicHours } from '$lib/server/clinic-hours';
import {
	fetchProfessional,
	updateProfessional,
	parseIds,
	runProfessionalSave
} from '$lib/server/professionals';
import { weekToHoursRows } from '$lib/professionals';

export const load: PageServerLoad = async (event) => {
	const [prof, hours] = await Promise.all([
		fetchProfessional(event, event.params.id),
		fetchClinicHours(event)
	]);

	if (!prof.professional) error(prof.status || 404, 'Profissional não encontrado.');
	if (!hours.data) error(hours.status || 502, 'Não foi possível carregar o horário da clínica.');

	return { professional: prof.professional, clinicHours: weekToHoursRows(hours.data.clinic_hours) };
};

export const actions: Actions = {
	// Atualiza a ficha e reconcilia grade + exceções + situação (mesma orquestração do novo).
	// Os ids de exceção e a situação originais vêm de hidden fields para o diff/toggle.
	save: async (event) => {
		const form = await event.request.formData();
		const id = event.params.id;

		const res = await runProfessionalSave(event, form, {
			persist: (ficha) => updateProfessional(event, id, ficha),
			professionalId: id,
			originalActive: String(form.get('original_ativo')) !== 'false',
			originalExceptionIds: parseIds(String(form.get('original_exception_ids') ?? ''))
		});

		if (!res.ok) return fail(res.status, { error: res.error });
		redirect(303, '/profissionais');
	}
};
