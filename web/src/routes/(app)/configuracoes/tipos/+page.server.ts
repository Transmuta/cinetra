import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions, RequestEvent } from './$types';
import {
	fetchAppointmentTypes,
	createAppointmentType,
	updateAppointmentType,
	archiveAppointmentType,
	restoreAppointmentType,
	type AppointmentTypeInput
} from '$lib/server/appointment-types';
import type { MutationResult } from '$lib/server/mutate';
import { DEFAULT_CAPACIDADE } from '$lib/appointment-types';

// Carrega o catálogo da clínica ativa (BFF → /api/appointment-types). Ao contrário da tela de
// equipe, aqui NÃO há recorte de papel no load: a lista é visível a todo membro (T8) — só a
// escrita exige owner/admin, e disso cuidam as policies da API (e o `canManage` da página, na UX).
export const load: PageServerLoad = async (event) => {
	const result = await fetchAppointmentTypes(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar os tipos de atendimento.');
	}

	return {
		appointmentTypes: result.data.appointment_types,
		capacidadePadrao: result.data.cap_turma_padrao ?? DEFAULT_CAPACIDADE
	};
};

export const actions: Actions = {
	// Criar e editar são a MESMA intenção com o mesmo corpo — o `saveType` do protótipo
	// (:1210) já é uma função só, e o toast é o mesmo. O `id` é que decide qual chamar;
	// duas actions só duplicariam o parse.
	save: async (event) => {
		const form = await event.request.formData();
		const id = String(form.get('id') ?? '').trim();
		const nome = String(form.get('nome') ?? '').trim();
		const grupo = form.get('grupo') === 'true';

		if (nome === '') return fail(400, { action: 'save', error: 'Informe o nome do tipo.' });

		const input: AppointmentTypeInput = {
			nome,
			duracao_minutos: Number(form.get('duracao_minutos')),
			cor: String(form.get('cor') ?? ''),
			icon: String(form.get('icon') ?? ''),
			grupo,
			// present sse grupo (01:474): fora do grupo, capacidade não é 0 — não existe.
			capacidade: grupo ? Number(form.get('capacidade')) : null
		};

		// A paleta e os limites de duração são validados na API (doc 20 §1): ela é a
		// autoridade, e um 422 já vira mensagem no modal.
		const res = id
			? await updateAppointmentType(event, id, input)
			: await createAppointmentType(event, input);

		if (!res.ok) return fail(res.status || 400, { action: 'save', error: res.error });
		return { action: 'save', ok: true };
	},

	archive: (event) => transition(event, 'archive', archiveAppointmentType),
	restore: (event) => transition(event, 'restore', restoreAppointmentType)
};

// Arquivar e restaurar têm a mesma forma: um id, uma transição de estado (T10), um toast.
async function transition(
	event: RequestEvent,
	action: 'archive' | 'restore',
	call: (event: RequestEvent, id: string) => Promise<MutationResult>
) {
	const form = await event.request.formData();
	const id = String(form.get('id') ?? '').trim();
	if (id === '') return fail(400, { action, error: 'Tipo inválido.' });

	const res = await call(event, id);
	if (!res.ok) return fail(res.status || 400, { action, error: res.error });
	return { action, ok: true };
}
