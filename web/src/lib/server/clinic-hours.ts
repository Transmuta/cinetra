import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { WeekHours } from '$lib/scheduling';

// BFF da tela de Horário (doc 22 §3 / ADR-005): fala com `/api/clinic-hours` server-to-server,
// repassando o cookie de sessão. O `clinic_id` e o RBAC vivem no escopo da API — o BFF nunca
// manda tenant nem papel no corpo.

export interface ClinicHoursData {
	clinic_hours: WeekHours;
}

export interface ClinicHoursResult {
	status: number;
	data: ClinicHoursData | null;
}

export async function fetchClinicHours(event: RequestEvent): Promise<ClinicHoursResult> {
	try {
		const res = await apiFetch(event, '/api/clinic-hours', { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as ClinicHoursData };
	} catch {
		return { status: 0, data: null };
	}
}

// PATCH substitui a semana enviada. O corpo espelha o contrato: `{ clinic_hours: {dow: periods} }`.
export function updateClinicHours(event: RequestEvent, week: WeekHours): Promise<MutationResult> {
	return mutate(event, '/api/clinic-hours', 'PATCH', { clinic_hours: week });
}
