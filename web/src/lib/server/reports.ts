import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import type { ReportsData } from '$lib/reports';

// BFF da tela de Relatórios (doc 33, Fatia 9 / ADR-005): fala com `/api/reports/summary`
// server-to-server, repassando o cookie de sessão. Leitura pura — não há mutação. O `clinic_id`,
// o recorte do papel `profissional` e a agregação vivem na API; o BFF só traduz a query string.

export interface ReportsParams {
	date_from: string;
	date_to: string;
	professional_id?: string;
}

export interface ReportsResult {
	// null quando a API não respondeu 2xx (ou nem respondeu) — o load decide o que fazer.
	status: number;
	data: ReportsData | null;
}

export async function fetchReports(
	event: RequestEvent,
	params: ReportsParams
): Promise<ReportsResult> {
	const qs = new URLSearchParams();
	for (const [key, value] of Object.entries(params)) {
		if (value !== undefined && value !== null && value !== '') qs.set(key, String(value));
	}

	try {
		const res = await apiFetch(event, `/api/reports/summary?${qs.toString()}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as ReportsData };
	} catch {
		return { status: 0, data: null };
	}
}
