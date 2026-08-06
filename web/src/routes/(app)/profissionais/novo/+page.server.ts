import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinicHours } from '$lib/server/clinic-hours';
import { createProfessional, runProfessionalSave } from '$lib/server/professionals';
import { weekToHoursRows, canViewProfessionals } from '$lib/professionals';

// O editor de horário precisa do expediente da clínica (para o invariante prof ⊆ clínica e o
// "Segue a clínica"). Vem do mesmo BFF de Horário, convertido em linhas `{dow, periods}`.
export const load: PageServerLoad = async (event) => {
	// A guarda é EXPLÍCITA aqui, e não herdada de um 403 da API como nas duas telas irmãs: este
	// load não toca `/api/professionals` — só o expediente da clínica, que todo membro lê. Sem
	// esta linha, o papel `profissional` abriria o formulário de cadastro por URL e só descobriria
	// no `save` que não podia (doc 103).
	const { me } = await event.parent();
	if (!canViewProfessionals(me?.papel)) {
		error(403, 'Esta tela não está disponível para o seu perfil.');
	}

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

		// A3/D12: o 409 leva `code`/`meta` para a ficha desenhar a lista de conflitos.
		if (!res.ok) {
			return fail(res.status, { error: res.error, code: res.code, meta: res.meta });
		}
		redirect(303, '/profissionais');
	}
};
