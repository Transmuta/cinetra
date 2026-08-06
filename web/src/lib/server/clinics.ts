import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch, reemitSession } from './api';
import { mutate, type MutationResult } from './mutate';

// BFF do onboarding (ADR-005): cria a clínica via `POST /api/clinics` server-to-server,
// repassando o cookie de sessão. O usuário atual (ator do escopo da API) vira owner; o BFF
// nunca manda ator nem tenant no corpo (09 §8). No primeiro acesso o tenant ativo passa a
// resolver sozinho no próximo /me (único membership ativo). Já quando o dono cria uma clínica
// ADICIONAL (fluxo do menu), o tenant ativo continua o antigo — por isso devolvemos o id da
// clínica recém-criada, para o chamador poder trocar para ela com `switchTenant`.

export interface OnboardResult {
	ok: boolean;
	status: number;
	// id da clínica criada (quando ok) — usado para trocar o tenant ativo no fluxo "nova".
	clinicId?: string;
	// mensagem amigável (quando ok=false).
	error?: string;
}

export async function onboardClinic(event: RequestEvent, nome: string): Promise<OnboardResult> {
	try {
		const res = await apiFetch(event, '/api/clinics', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify({ nome })
		});

		if (res.ok) {
			const body = (await res.json().catch(() => null)) as { clinic?: { id?: string } } | null;
			return { ok: true, status: res.status, clinicId: body?.clinic?.id };
		}
		if (res.status === 422) return { ok: false, status: 422, error: 'Confira o nome da clínica.' };
		if (res.status === 401) return { ok: false, status: 401, error: 'Sua sessão expirou. Entre de novo.' };
		return { ok: false, status: res.status, error: 'Não foi possível criar a clínica.' };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

// ---- Dados da clínica ativa (tela /configuracoes/clinica) ----

export interface Clinic {
	id: string;
	nome: string;
	cnpj: string | null;
	// O telefone que o PACIENTE vê, dentro da mensagem ("Ligue para (11) 3456-7890"). Guardado
	// como foi digitado, não em E.164: aqui ele é texto para ler e discar, não destino de envio.
	// É ele que destrava `msg_whatsapp_ativo` — a API recusa ligar o canal sem ele.
	telefone: string | null;
	// Endereço estruturado, com os mesmos nomes da ficha do paciente — é o que deixa
	// `AddressFields.svelte` servir as duas telas sem tradução de campo no meio.
	cep: string | null;
	endereco: string | null;
	numero: string | null;
	complemento: string | null;
	bairro: string | null;
	cidade: string | null;
	uf: string | null;
	// Comunicação com o paciente (doc 52 §7). Viajam junto com a identidade porque as duas telas
	// de configuração leem do mesmo `GET /api/clinic`.
	//
	// O `msg_lembrete_horas` saiu em 2026-08-01 junto com o lembrete automático: sem cron, ele era
	// um número que ninguém lia.
	msg_whatsapp_ativo: boolean;
	msg_silencio_inicio: number | null;
	msg_silencio_fim: number | null;
}

export interface ClinicResult {
	status: number;
	data: { clinic: Clinic } | null;
}

// GET /api/clinic — nome, CNPJ e endereço da clínica ativa (leitura para todo membro).
export async function fetchClinic(event: RequestEvent): Promise<ClinicResult> {
	try {
		const res = await apiFetch(event, '/api/clinic', { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as { clinic: Clinic } };
	} catch {
		return { status: 0, data: null };
	}
}

export interface ClinicInfoInput {
	nome?: string;
	cnpj?: string;
	telefone?: string;
	cep?: string;
	endereco?: string;
	numero?: string;
	complemento?: string;
	bairro?: string;
	cidade?: string;
	uf?: string;
}

// PATCH /api/clinic — edita nome/CNPJ/endereço (só owner/admin, garantido pela API). O CNPJ pode
// ir mascarado: a API normaliza e valida. Campo ausente não é tocado; branco limpa.
export function updateClinic(event: RequestEvent, input: ClinicInfoInput): Promise<MutationResult> {
	return mutate(event, '/api/clinic', 'PATCH', input);
}

export interface SwitchResult {
	ok: boolean;
	status: number;
}

// Troca o tenant ativo da sessão (ADR-017). A API (`POST /api/auth/switch-tenant`) valida o
// vínculo ativo e reemite a sessão com o novo `clinic_id`; o BFF captura o Set-Cookie e o
// repassa no domínio do web — o mesmo padrão do callback de login (`reemitSession`). O
// browser nunca fala direto com a API.
export async function switchTenant(event: RequestEvent, clinicId: string): Promise<SwitchResult> {
	try {
		const res = await apiFetch(event, '/api/auth/switch-tenant', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify({ clinic_id: clinicId })
		});
		if (res.ok) reemitSession(event, res);
		return { ok: res.ok, status: res.status };
	} catch {
		return { ok: false, status: 0 };
	}
}

// Comunicação com o paciente (doc 52 §7): quantas horas antes sai o lembrete e a janela de
// silêncio. Rota própria na API (`PATCH /api/clinic/messaging`) — e não campos somados ao
// `updateClinic` — porque a fronteira aceita o que a AÇÃO aceita, não o que o formulário desenha
// (09 §8): somar aqui deixaria a tela de identidade capaz de desligar o lembrete.
export async function updateClinicMessaging(
	event: RequestEvent,
	body: {
		// Sempre presente, nunca omitido: a API lê ausente como `false`, e é isso que torna o
		// interruptor DESLIGÁVEL pela tela. Omitir aqui recriaria o bug do doc 98 §6.
		msg_whatsapp_ativo: boolean;
		msg_silencio_inicio: number | null;
		msg_silencio_fim: number | null;
	}
): Promise<MutationResult> {
	return mutate(event, '/api/clinic/messaging', 'PATCH', body);
}
