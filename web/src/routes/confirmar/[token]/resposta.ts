// A conversa do BFF com a API sobre **uma** resposta de paciente, num lugar só.
//
// Estava inteira dentro de `+page.server.ts` até a página ganhar um segundo consumidor (o `.ics`
// de "adicionar à agenda"), e duas cópias desta chamada divergiriam justamente no que ela tem de
// especial: o IP do cliente. Ver `chamar/3`.
//
// Continua **fora** de `$lib/server/`, e isso é deliberado: os módulos de lá falam com a API com o
// cookie de sessão do usuário (`apiFetch`), e dar a esta chamada a mesma casa convidaria a copiar
// aquele padrão para onde ele não vale — aqui não há sessão nenhuma, só o token assinado.

import type { RequestEvent } from '@sveltejs/kit';
import { apiBase, headersDeContexto } from '$lib/server/api';
import { quandoParaPaciente, type QuandoPaciente } from '$lib/data-hora';

export interface Resumo {
	clinica: string | null;
	/** O telefone da CLÍNICA — o mesmo que a mensagem anunciou. O do paciente não vem. */
	clinica_telefone: string | null;
	paciente: string | null;
	/** "DD/MM/AAAA" congelado no envio. Histórico; quem manda na tela é o `inicio`. */
	data: string | null;
	/** "HH:MM" congelado no envio. */
	hora: string | null;
	/** Instante ISO do começo da sessão **hoje** — reflete remarcação posterior à mensagem. */
	inicio: string | null;
	/** Instante ISO do fim, para o evento de calendário. */
	fim: string | null;
	timezone: string | null;
	/** `false` quando a sessão foi cancelada depois que a mensagem saiu. */
	ativa: boolean;
	resposta: 'confirmou' | 'quer_remarcar' | null;
	respondido_em: string | null;
}

/**
 * Fala com a API sem `apiFetch` porque não há cookie de sessão para repassar.
 *
 * O que ela NÃO pode dispensar é o IP do cliente (`headersDeContexto`). Sem sessão, o IP é a única
 * chave que a API tem para o rate limit — e sem o header todos os pacientes do produto caem no
 * mesmo balde, o do container do BFF: um visitante em laço derrubava a confirmação de todo mundo
 * (bate-volta doc 68, causa B).
 */
export async function chamar(
	event: RequestEvent,
	token: string,
	init?: RequestInit
): Promise<{ status: number; resumo: Resumo | null }> {
	const headers = headersDeContexto(event, init?.headers);
	headers.set('accept', 'application/json');

	try {
		const res = await event.fetch(`${apiBase()}/api/reply/${encodeURIComponent(token)}`, {
			...init,
			headers
		});

		if (!res.ok) return { status: res.status, resumo: null };
		return { status: res.status, resumo: (await res.json()) as Resumo };
	} catch {
		return { status: 0, resumo: null };
	}
}

/**
 * A leitura humana da data, calculada **no servidor**.
 *
 * No servidor e não no componente por dois motivos: o relógio do browser é o do paciente (que
 * pode estar em outro fuso, e adiantado ou atrasado), e o que é calculado na hidratação diverge
 * do que o SSR pintou. Devolve `null` quando a API não mandou instante — aí a tela cai no
 * "DD/MM/AAAA" congelado, que é pior de ler mas continua verdadeiro.
 */
export function quandoDo(resumo: Resumo | null, agora: string): QuandoPaciente | null {
	if (!resumo?.inicio || !resumo.timezone) return null;
	return quandoParaPaciente(resumo.inicio, resumo.timezone, agora);
}
