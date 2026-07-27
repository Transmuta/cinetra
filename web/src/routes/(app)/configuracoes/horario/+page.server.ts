import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { fetchClinicHours, updateClinicHours } from '$lib/server/clinic-hours';
import type { WeekHours } from '$lib/scheduling';

// Carrega o expediente da clínica ativa (BFF → /api/clinic-hours). Como a tela de Tipos, NÃO há
// recorte de papel no load: todo membro lê (H7) — só a escrita exige owner/admin, e disso
// cuidam as policies da API e o `canManage` da página.
export const load: PageServerLoad = async (event) => {
	const result = await fetchClinicHours(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar o horário da clínica.');
	}

	return { clinicHours: result.data.clinic_hours };
};

export const actions: Actions = {
	// A tela edita a semana inteira e salva de uma vez (protótipo `saveHours` :885). O rascunho
	// viaja num único campo JSON; aqui a gente valida a forma e repassa. A validação dos
	// períodos em si é da API (doc 22 §1) — um 422 já vira mensagem.
	save: async (event) => {
		const form = await event.request.formData();
		const week = parseWeek(String(form.get('clinic_hours') ?? ''));

		if (!week) return fail(400, { error: 'Não foi possível ler o horário.' });

		const res = await updateClinicHours(event, week);

		if (!res.ok) {
			return fail(res.status || 400, { error: res.error, code: res.code, meta: res.meta });
		}

		return { ok: true };
	}
};

// Aceita só um objeto `{dow: periods}`. Qualquer outra forma (array, string, null) é recusada
// aqui mesmo — não repassa lixo para a API.
function parseWeek(raw: string): WeekHours | null {
	try {
		const parsed = JSON.parse(raw);
		if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed as WeekHours;
		return null;
	} catch {
		return null;
	}
}
