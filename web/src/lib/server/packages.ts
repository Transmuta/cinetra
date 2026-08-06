import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, errorInfo, type MutationResult } from './mutate';
import type { Package, PackageSession, PreviewResult } from '$lib/packages';

// BFF dos pacotes (Fatia 3 / ADR-005): fala com `/api/packages` server-to-server, repassando o
// cookie de sessão. `clinic_id` e RBAC vivem no escopo da API — o BFF nunca manda tenant no corpo.

// O corpo que cria (ou pré-visualiza) a série. `data_inicio` é "AAAA-MM-DD"; a grade é aninhada.
export interface SeriesInput {
	nome: string;
	total: number;
	falta_punitiva: boolean;
	cor: string;
	data_inicio: string;
	patient_id: string;
	appointment_type_id: string;
	grade: {
		dows: number[];
		horarios: Record<string, string>;
		professional_id: string;
	};
	// "agendar mesmo assim" — materializa conflito/turma cheia como encaixe. Nunca fura expediente.
	forcar?: boolean;
}

export interface PackagesResult {
	status: number;
	packages: Package[];
}

export async function fetchPatientPackages(
	event: RequestEvent,
	patientId: string
): Promise<PackagesResult> {
	try {
		const res = await apiFetch(event, `/api/patients/${encodeURIComponent(patientId)}/packages`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, packages: [] };
		const body = (await res.json()) as { packages: Package[] };
		return { status: res.status, packages: body.packages ?? [] };
	} catch {
		return { status: 0, packages: [] };
	}
}

// A prévia (save-gate): classifica a série sem escrever. Devolve `null` em falha de forma/conexão
// — a tela mostra o erro genérico e não desenha a grade fantasma.
export interface PreviewResponse {
	status: number;
	preview: PreviewResult | null;
}

export async function previewSeries(
	event: RequestEvent,
	input: SeriesInput
): Promise<PreviewResponse> {
	try {
		const res = await apiFetch(event, '/api/packages/preview', {
			method: 'POST',
			headers: {
				'content-type': 'application/json',
				accept: 'application/json'
			},
			body: JSON.stringify(input)
		});
		if (!res.ok) return { status: res.status, preview: null };
		return { status: res.status, preview: (await res.json()) as PreviewResult };
	} catch {
		return { status: 0, preview: null };
	}
}

// Cria a série. Três desfechos: criado (201, devolve o pacote); bloqueado (422 `series_blocked`,
// devolve a prévia para a tela reapresentar com "agendar mesmo assim"); erro (mensagem). É o
// contrato do save-gate: a tela precisa distinguir "o mundo recusa, confirme" de "deu erro".
export interface CreateResult {
	ok: boolean;
	status: number;
	package?: Package;
	// quando 422 series_blocked:
	blocked?: {
		reason: 'fora_expediente' | 'precisa_confirmar';
		preview: PreviewResult;
	};
	error?: string;
}

export async function createSeries(event: RequestEvent, input: SeriesInput): Promise<CreateResult> {
	try {
		const res = await apiFetch(event, '/api/packages', {
			method: 'POST',
			headers: {
				'content-type': 'application/json',
				accept: 'application/json'
			},
			body: JSON.stringify(input)
		});

		if (res.status === 201) {
			const body = (await res.json()) as { package: Package };
			return { ok: true, status: 201, package: body.package };
		}

		if (res.status === 422) {
			const body = (await res.json()) as {
				error?: string;
				reason?: 'fora_expediente' | 'precisa_confirmar';
				preview?: PreviewResult;
			};
			if (body?.error === 'series_blocked' && body.reason && body.preview) {
				return {
					ok: false,
					status: 422,
					blocked: { reason: body.reason, preview: body.preview }
				};
			}
		}

		return {
			ok: false,
			status: res.status,
			error: 'Não foi possível criar o pacote.'
		};
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

// Ciclo de vida: pausar/retomar/cancelar operam sobre a série inteira. Reusa `mutate` (a escada
// de erros 401/403/404) — não precisam do corpo de volta, a tela recarrega a lista.
export function pausePackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/pause`, 'POST');
}

export function resumePackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/resume`, 'POST');
}

export function cancelPackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/cancel`, 'POST');
}

// Arquivar (D1, doc 69): a única porta para `concluido` — nada fecha o pacote sozinho. O servidor
// recusa com 422 se ainda houver sessão futura de pé, e a mensagem dele é a que a ficha mostra.
export function archivePackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/archive`, 'POST');
}

// ---------------------------------------------------------------------------
// O ciclo de vida reaberto (doc 69 §10 B4). O `+`/`−` é o troco do ADR-011: não há renovação, o
// total é editável a qualquer momento sobre o MESMO pacote.
// ---------------------------------------------------------------------------

export function addPackageSession(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/sessions`, 'POST');
}

// Sem id de sessão no caminho: quem escolhe é o servidor (a última FUTURA não consumida, D3) —
// justamente para o cliente não conseguir apontar uma sessão passada e reescrever histórico.
export function removePackageSession(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/sessions`, 'DELETE');
}

export interface GradeInput {
	dows: number[];
	horarios: Record<string, string>;
	professional_id: string;
}

export function adjustPackageGrade(
	event: RequestEvent,
	id: string,
	grade: GradeInput
): Promise<MutationResult> {
	return mutate(event, `${path(id)}/grade`, 'PATCH', grade);
}

// A trilha do pacote (estado de cada sessão). Sob demanda: a ficha não a carrega para todo pacote
// — é uma leitura por pacote, e a ficha já faz seis em paralelo.
//
// `PackageSession` vem de `$lib/packages` e é reexportado aqui por conveniência de quem já importa
// deste módulo. Ele NÃO é redeclarado: a interface morava escrita três vezes — aqui, lá, e uma
// terceira dentro do `PackageSessionsModal` — campo por campo, união por união, dos dois lados de
// uma fronteira que o TypeScript atravessa de graça. Bastava a API acrescentar um valor a `estado`
// para os três compilarem e o `switch` do componente cair no default calado (doc 94 §4.5).
export type { PackageSession };

export async function fetchPackageSessions(
	event: RequestEvent,
	id: string
): Promise<{ status: number; sessions: PackageSession[] }> {
	try {
		const res = await apiFetch(event, `${path(id)}/sessions`, { method: 'GET' });
		if (!res.ok) return { status: res.status, sessions: [] };
		const body = (await res.json()) as { sessions?: PackageSession[] };
		return { status: res.status, sessions: body.sessions ?? [] };
	} catch {
		return { status: 0, sessions: [] };
	}
}

// A **massa por pacote** (`bulk_adjust`/`bulk_cancel`) não tem função aqui, e é decisão (doc 69,
// leva de 2026-07-29). Da ficha, mudar profissional/horário das próximas sessões é o **ajuste de
// grade** (`PATCH /packages/:id/grade`), que faz o mesmo e ainda alcança os DIAS da semana — e
// grava a grade nova, coisa que a massa não fazia. Duas portas para a mesma intenção, uma delas
// incompleta, era o que deixava a recepção sem saber qual usar.
//
// O que a massa acrescenta são os escopos `esta`/`proximas`, que exigem uma sessão de REFERÊNCIA —
// algo que só a agenda sabe apontar. Quando esse botão for pedido, ele nasce no drawer, com a
// referência em mãos. Os endpoints do backend continuam existindo e testados.

function path(id: string): string {
	return `/api/packages/${encodeURIComponent(id)}`;
}
