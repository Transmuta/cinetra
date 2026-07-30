import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import type { AccessMatrixData } from '$lib/access-matrix';

// A matriz "o que cada papel pode" (AN-06), server-to-server pelo BFF (ADR-005). Vem do
// backend — perto das policies, com tripwire — para a tela de Equipe nunca dizer o contrário
// do produto. Leitura degrada para `null`: a matriz é apoio da tela, não a tela.

export interface AccessMatrixResult {
	status: number;
	data: AccessMatrixData | null;
}

export async function fetchAccessMatrix(event: RequestEvent): Promise<AccessMatrixResult> {
	try {
		const res = await apiFetch(event, '/api/access-matrix', {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as AccessMatrixData };
	} catch {
		return { status: 0, data: null };
	}
}
