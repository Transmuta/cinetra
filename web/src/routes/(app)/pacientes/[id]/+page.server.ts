import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchPatient, deactivatePatient, reactivatePatient } from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';

// A ficha (só leitura). Vai junto o diretório, para resolver os nomes dos profissionais
// preferidos. Pacotes, histórico e anexos não entram na v1 (dependem de F1/F3/v2).
export const load: PageServerLoad = async (event) => {
	const [pat, prof] = await Promise.all([
		fetchPatient(event, event.params.id),
		fetchProfessionals(event)
	]);

	if (!pat.patient) error(pat.status || 404, 'Paciente não encontrado.');

	return { patient: pat.patient, professionals: prof.data?.professionals ?? [] };
};

// Arquivar/reativar vive aqui (não no formulário): é reversível e o `enhance` recarrega a ficha.
// Owner/admin apenas — a policy da API barra os demais (403 → mensagem).
export const actions: Actions = {
	deactivate: async (event) => {
		const res = await deactivatePatient(event, event.params.id);
		if (!res.ok) return fail(res.status, { error: res.error });
		return { archived: true };
	},
	reactivate: async (event) => {
		const res = await reactivatePatient(event, event.params.id);
		if (!res.ok) return fail(res.status, { error: res.error });
		return { archived: false };
	}
};
