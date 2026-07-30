import type { RequestEvent } from '@sveltejs/kit';
import { mutate, type MutationResult } from './mutate';

// PATCH /api/auth/me — a pessoa edita o próprio nome de exibição (tela "Meu perfil"). O e-mail
// (identidade de login passwordless) NÃO é editável aqui. A API é a autoridade: só o próprio
// usuário se altera (policy) e nome em branco vira 422.
export function updateProfile(event: RequestEvent, nome: string): Promise<MutationResult> {
	return mutate(event, '/api/auth/me', 'PATCH', { nome });
}
