import { error, fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchPatient, updatePatient, runPatientSave } from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';

export const load: PageServerLoad = async (event) => {
	const [pat, prof] = await Promise.all([
		fetchPatient(event, event.params.id),
		fetchProfessionals(event)
	]);

	if (!pat.patient) error(pat.status || 404, 'Paciente não encontrado.');

	// O aviso de duplicado consulta `/api/patients/lookup` sob demanda (o form exclui o próprio
	// id do resultado) — não baixa mais o cadastro inteiro.
	return { patient: pat.patient, professionals: prof.data?.professionals ?? [] };
};

export const actions: Actions = {
	save: async (event) => {
		const form = await event.request.formData();
		const id = event.params.id;

		const res = await runPatientSave(event, form, {
			persist: (ficha) => updatePatient(event, id, ficha)
		});

		if (!res.ok) return fail(res.status, { error: res.error });
		redirect(303, `/pacientes/${id}`);
	}
};
