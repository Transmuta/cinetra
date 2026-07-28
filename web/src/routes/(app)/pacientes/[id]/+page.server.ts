import { error, fail } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import {
	fetchPatient,
	fetchPatientHistory,
	deactivatePatient,
	reactivatePatient
} from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';
import { fetchAppointmentTypes } from '$lib/server/appointment-types';
import {
	fetchPatientPackages,
	pausePackage,
	resumePackage,
	cancelPackage,
	bulkAdjustPackage
} from '$lib/server/packages';
import { fetchPatientAttachments } from '$lib/server/attachments';

// Quantas sessões o histórico mostra ao abrir. Eram 50 — medido no doc 56: ~2.200px num cartão
// só, num paciente de agenda cheia. O resto é o "ver histórico completo", que sobe o teto pela
// URL (`?historico=`) em vez de guardar estado no cliente: funciona sem JS e é compartilhável.
const HISTORICO_PADRAO = 8;
// O teto da API (`Api.Pagination`, max 200). Pedir mais devolveria 200 de qualquer forma; cortar
// aqui evita a mentira de um link que promete mais do que a API entrega.
const HISTORICO_MAX = 200;

// A ficha (só leitura). Vão junto o diretório (nomes dos profissionais preferidos), os pacotes
// (Fatia 3), as sessões — histórico e próximas (C13, Frente 7; doc 56) — e os anexos (doc 51).
//
// As seis leituras vão em paralelo: nenhuma depende da outra (H61). A dos anexos degrada sozinha
// — para o `profissional` a API responde 403 e a lista vem vazia, e a tela nem renderiza a seção.
export const load: PageServerLoad = async (event) => {
	const [pat, prof, types, pkgs, hist, anexos] = await Promise.all([
		fetchPatient(event, event.params.id),
		fetchProfessionals(event),
		fetchAppointmentTypes(event),
		fetchPatientPackages(event, event.params.id),
		fetchPatientHistory(event, event.params.id, historyLimit(event.url)),
		fetchPatientAttachments(event, event.params.id)
	]);

	if (!pat.patient) error(pat.status || 404, 'Paciente não encontrado.');

	return {
		patient: pat.patient,
		professionals: prof.data?.professionals ?? [],
		appointmentTypes: types.data?.appointment_types ?? [],
		packages: pkgs.packages,
		history: hist.sessions,
		historyMore: hist.more,
		upcoming: hist.upcoming,
		upcomingMore: hist.upcomingMore,
		attachments: anexos.attachments,
		attachmentLimits: anexos.limites
	};
};

// `?historico=` inválido cai no padrão em vez de 400: é um parâmetro de apresentação, e a ficha
// não pode deixar de abrir porque alguém editou a URL.
function historyLimit(url: URL): number {
	const n = Number(url.searchParams.get('historico'));
	if (!Number.isInteger(n) || n <= 0) return HISTORICO_PADRAO;
	return Math.min(n, HISTORICO_MAX);
}

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
