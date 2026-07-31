// O token do socket, buscado uma vez por montagem.
//
// O bloco estava escrito TRÊS vezes verbatim (doc 94 §D-3) — `+layout`, `/agenda` e `/fila` —
// com o mesmo `fetch`, a mesma cadeia, a mesma guarda `vivo`, o mesmo `reportar` e o mesmo
// cleanup. Só o comentário mudava, e ele era o mesmo argumento reescrito ("mata o tempo real de
// todo o app" / "da agenda" / "da tela").
//
// O molde é o do `media.svelte.ts`: estado em runes fora de componente, exposto por **getter** em
// vez de exportar o `$state` — que é a forma correta de expor reatividade de módulo em Svelte 5.
//
// Duas coisas que este arquivo carrega e que não podem se perder numa reescrita:
//
//   * **o `reportar` não é opcional.** Falha aqui mata o tempo real inteiro e antes disso era
//     invisível: sem token o socket nunca abre, e não há console, log nem aviso em lugar nenhum —
//     só uma tela que nunca mais muda sozinha. Dois atendentes passam a ver estados diferentes da
//     mesma agenda, que é exatamente o que o tempo real existe para evitar (doc 62 §7.2);
//   * **a guarda `vivo`.** A resposta pode chegar depois da desmontagem, e escrever num estado
//     morto é o vazamento clássico do `fetch` em efeito.
//
// O token vem do BFF porque o cookie de sessão é HttpOnly; a origem pública da API vem junto,
// porque o WebSocket é a exceção ao ADR-005 e fala direto com o Phoenix.

import { reportar } from './report';
import type { RealtimeConfig } from './realtime';

export function usarTokenRealtime(): { cfg: RealtimeConfig | null } {
	let cfg = $state<RealtimeConfig | null>(null);

	$effect(() => {
		let vivo = true;

		fetch('/api/realtime/token')
			.then((r) => (r.ok ? r.json() : null))
			.then((body) => {
				if (vivo && body?.token) cfg = body as RealtimeConfig;
			})
			.catch((e) => reportar('realtime:token', e));

		return () => {
			vivo = false;
		};
	});

	return {
		get cfg() {
			return cfg;
		}
	};
}
