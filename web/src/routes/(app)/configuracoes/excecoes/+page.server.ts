import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import {
	fetchClinicExceptions,
	createClinicException,
	deleteClinicException,
	type ClinicExceptionInput
} from '$lib/server/clinic-exceptions';
import type { ExceptionKind, Period } from '$lib/scheduling';

// Carrega as exceções da clínica ativa (BFF → /api/clinic-exceptions). Todo membro lê (H7); a
// escrita exige owner/admin (policies da API + `canManage` da página).
export const load: PageServerLoad = async (event) => {
	const result = await fetchClinicExceptions(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar as exceções.');
	}

	return { exceptions: result.data.clinic_exceptions };
};

export const actions: Actions = {
	// Adicionar exceção (protótipo `addHoliday` :1212). `periods` só vem quando tipo=horario.
	add: async (event) => {
		const form = await event.request.formData();
		const data = String(form.get('data') ?? '').trim();
		const nome = String(form.get('nome') ?? '').trim();
		const tipo = String(form.get('tipo') ?? 'fechado') as ExceptionKind;

		if (data === '') return fail(400, { action: 'add', error: 'Informe a data.' });

		const input: ClinicExceptionInput = {
			data,
			nome,
			tipo,
			periods: tipo === 'horario' ? parsePeriods(form.get('periods')) : []
		};

		const res = await createClinicException(event, input);
		if (!res.ok) return fail(res.status || 400, { action: 'add', error: res.error });
		return { action: 'add', ok: true };
	},

	// Excluir é DELETE de verdade (H4 — protótipo `rmHoliday` :1225).
	delete: async (event) => {
		const form = await event.request.formData();
		const id = String(form.get('id') ?? '').trim();
		if (id === '') return fail(400, { action: 'delete', error: 'Exceção inválida.' });

		const res = await deleteClinicException(event, id);
		if (!res.ok) return fail(res.status || 400, { action: 'delete', error: res.error });
		return { action: 'delete', ok: true };
	}
};

// Períodos chegam num campo JSON do cliente. Forma inesperada → lista vazia (a API recusará um
// horário sem período com 422), nunca lixo repassado adiante.
function parsePeriods(raw: FormDataEntryValue | null): Period[] {
	try {
		const parsed = JSON.parse(String(raw ?? '[]'));
		return Array.isArray(parsed) ? (parsed as Period[]) : [];
	} catch {
		return [];
	}
}
