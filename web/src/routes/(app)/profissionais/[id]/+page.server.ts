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

	// 403 antes do 404: desde 2026-08-04 (doc 103) o papel `profissional` não abre ficha nenhuma
	// — nem a dele. Sem esta linha o erro sairia com a mensagem "não encontrado", que é falsa e
	// manda a pessoa procurar um id que existe.
	if (prof.status === 403) error(403, 'Esta tela não está disponível para o seu perfil.');
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

		// A3/D12: o 409 leva `code`/`meta` para a ficha desenhar a lista de conflitos.
		if (!res.ok) {
			return fail(res.status, { error: res.error, code: res.code, meta: res.meta });
		}
		redirect(303, '/profissionais');
	}
};
