import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';

// Encanamento comum aos BFFs de mutação (Membros, Tipos de atendimento, …): dispara o
// request server-to-server e traduz a escada de erros da API (401/403/404/422) numa
// mensagem que a tela pode mostrar. Extraído de `server/members.ts` quando a segunda tela
// precisou exatamente do mesmo — a forma continua a de lá.

// Um detalhe do 422 da API (doc 09 §escada de erros). `field: null` é o caso load-bearing:
// significa "o pedido está bem formado, o MUNDO é que recusa" — conflito de agenda, turma
// cheia, fora do expediente. Não há campo para pintar de vermelho; a mensagem é tudo.
export interface FieldError {
	field: string | null;
	message: string;
}

export interface MutationResult {
	ok: boolean;
	status: number;
	// mensagem de erro amigável (quando ok=false).
	error?: string;
	// Código estável do 422 (doc 25 §5): `schedule_conflict`, `group_full`,
	// `outside_business_hours`, `closed_by_exception`. É por ele que a UI decide OFERECER uma
	// saída (ex.: "marcar como Encaixe") em vez de só mostrar o erro.
	code?: string;
	details?: FieldError[];
}

export interface ErrorInfo {
	error: string;
	code?: string;
	details?: FieldError[];
}

export async function mutate(
	event: RequestEvent,
	path: string,
	method: string,
	body?: unknown
): Promise<MutationResult> {
	try {
		const res = await apiFetch(event, path, {
			method,
			headers: body
				? { 'content-type': 'application/json', accept: 'application/json' }
				: { accept: 'application/json' },
			body: body ? JSON.stringify(body) : undefined
		});
		if (res.ok) return { ok: true, status: res.status };
		return { ok: false, status: res.status, ...(await errorInfo(res)) };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

// Traduz a resposta de erro da API. Devolve a mensagem amigável E — quando o 422 traz — o
// `code` estável e os `details`. Antes daqui o BFF achatava TUDO em "Dados inválidos.
// Verifique os campos.", o que tornava inalcançável qualquer fluxo de recuperação: a tela
// não tinha como distinguir "CPF inválido" de "esse slot está ocupado, quer marcar encaixe?".
export async function errorInfo(res: Response): Promise<ErrorInfo> {
	if (res.status === 403) return { error: 'Você não tem permissão para esta ação.' };
	if (res.status === 404) return { error: 'Registro não encontrado.' };
	try {
		const body = await res.json();
		if (body?.error === 'invalid') {
			const details = parseDetails(body?.details);
			const code = typeof body?.code === 'string' ? body.code : undefined;
			// A mensagem do servidor ganha da genérica: ela é específica e, no caso
			// `field: null`, é a única explicação existente.
			const error = details?.[0]?.message ?? 'Dados inválidos. Verifique os campos.';
			return { error, ...(code ? { code } : {}), ...(details ? { details } : {}) };
		}
	} catch {
		// corpo não-JSON: cai na mensagem genérica.
	}
	return { error: 'Não foi possível concluir a operação.' };
}

// `details` vem de JSON não-tipado: só aceita a forma esperada e, no menor desvio, devolve
// undefined em vez de deixar um objeto meio-formado vazar para a UI.
function parseDetails(raw: unknown): FieldError[] | undefined {
	if (!Array.isArray(raw) || raw.length === 0) return undefined;
	const out: FieldError[] = [];
	for (const item of raw) {
		if (typeof item !== 'object' || item === null) return undefined;
		const { field, message } = item as { field?: unknown; message?: unknown };
		if (typeof message !== 'string') return undefined;
		out.push({ field: typeof field === 'string' ? field : null, message });
	}
	return out;
}

// Mantido para os chamadores que só querem a string (BFFs de Pacientes e Profissionais).
export async function errorMessage(res: Response): Promise<string> {
	return (await errorInfo(res)).error;
}
