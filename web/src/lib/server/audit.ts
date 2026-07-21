import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import type { AuditData } from '$lib/audit';

// BFF da tela de Auditoria (doc 25 §11.4 / ADR-005): fala com `/api/audit` server-to-server,
// repassando o cookie de sessão. É leitura pura — não há mutação nesta tela. O `clinic_id`, o
// RBAC (owner·admin) e a paginação vivem na API; o BFF só traduz a query string.

export interface AuditParams {
	resource?: string;
	action?: string;
	record_id?: string;
	user_id?: string;
	from?: string;
	to?: string;
	limit?: number;
	offset?: number;
}

export interface AuditResult {
	// null quando a API não respondeu 2xx (ou nem respondeu) — o load decide (403 → erro).
	status: number;
	data: AuditData | null;
}

export async function fetchAudit(event: RequestEvent, params: AuditParams): Promise<AuditResult> {
	const qs = new URLSearchParams();
	for (const [key, value] of Object.entries(params)) {
		if (value !== undefined && value !== null && value !== '') qs.set(key, String(value));
	}

	try {
		const suffix = qs.toString();
		const res = await apiFetch(event, `/api/audit${suffix ? `?${suffix}` : ''}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as AuditData };
	} catch {
		return { status: 0, data: null };
	}
}
