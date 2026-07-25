import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchPatient, deactivatePatient, reactivatePatient } from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';
import { fetchAppointmentTypes } from '$lib/server/appointment-types';
import {
	fetchPatientPackages,
	pausePackage,
	resumePackage,
	cancelPackage,
	bulkAdjustPackage
} from '$lib/server/packages';

// A ficha (só leitura). Vai junto o diretório (nomes dos profissionais preferidos) e os pacotes
// do paciente (Fatia 3). Histórico e anexos ainda não entram (dependem de v2).
export const load: PageServerLoad = async (event) => {
	const [pat, prof, types, pkgs] = await Promise.all([
		fetchPatient(event, event.params.id),
		fetchProfessionals(event),
		fetchAppointmentTypes(event),
		fetchPatientPackages(event, event.params.id)
	]);

	if (!pat.patient) error(pat.status || 404, 'Paciente não encontrado.');

	return {
		patient: pat.patient,
		professionals: prof.data?.professionals ?? [],
		appointmentTypes: types.data?.appointment_types ?? [],
		packages: pkgs.packages
	};
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
	},

	// Ciclo de vida do pacote (Fatia 3): pausar/retomar/cancelar operam sobre a série inteira. O
	// `id` do pacote chega do form; o `enhance` recarrega a ficha com os contadores atualizados.
	pausePackage: (event) => lifecycle(event, pausePackage),
	resumePackage: (event) => lifecycle(event, resumePackage),
	cancelPackage: (event) => lifecycle(event, cancelPackage),

	// Massa por pacote (doc 41 etapa 3): muda profissional e/ou horário das sessões futuras. Do
	// cartão da ficha o escopo é sempre `todas` — `esta`/`proximas` precisam de uma sessão de
	// referência, que só existe olhando a agenda. `forcar` é o "aplicar mesmo assim" depois de um
	// conflito, o mesmo idioma da criação da série.
	bulkAdjustPackage: async (event) => {
		const data = await event.request.formData();
		const id = String(data.get('package_id') ?? '');
		if (!id) return fail(400, { error: 'Pacote não informado.' });

		const professional_id = String(data.get('professional_id') ?? '');
		const hhmm = String(data.get('hhmm') ?? '');

		if (!professional_id && !hhmm) {
			return fail(400, { error: 'Escolha o que aplicar: profissional e/ou horário.' });
		}

		const res = await bulkAdjustPackage(event, id, {
			escopo: 'todas',
			...(professional_id ? { aplicar_profissional: true, professional_id } : {}),
			...(hhmm ? { aplicar_horario: true, hhmm } : {}),
			forcar: data.get('forcar') === 'true'
		});

		if (!res.ok) return fail(res.status || 400, { error: res.error, code: res.code });
		return { ok: true, afetadas: res.afetadas ?? 0 };
	}
};

async function lifecycle(
	event: Parameters<Actions[string]>[0],
	fn: (e: typeof event, id: string) => Promise<{ ok: boolean; status: number; error?: string }>
) {
	const data = await event.request.formData();
	const id = String(data.get('package_id') ?? '');
	if (!id) return fail(400, { error: 'Pacote não informado.' });

	const res = await fn(event, id);
	if (!res.ok) return fail(res.status, { error: res.error });
	return { ok: true };
}
