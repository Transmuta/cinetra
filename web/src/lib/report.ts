/**
 * Reporta falha do browser ao BFF (doc 62 §7.2).
 *
 * Usado por dois caminhos:
 *
 *   * `hooks.client.ts` — crash não tratado (render, evento, promise solta);
 *   * componentes — falha que o código **decide** engolir para não quebrar a tela, mas que
 *     precisa deixar rastro. Era o buraco: quatro `.catch(() => {})` faziam o tempo real morrer
 *     em silêncio, e o único sintoma era uma agenda que parava de atualizar sozinha.
 *
 * O destino é o nosso próprio BFF, nunca um SaaS — ver o cabeçalho de `hooks.client.ts`.
 */

/** Teto por aba: um erro em laço de render dispararia centenas de POSTs por segundo. */
const MAX_POR_SESSAO = 10;
const MAX_MENSAGEM = 500;
const MAX_STACK = 2000;

let enviados = 0;
const vistos = new Set<string>();

/** Espelha `ApiWeb.RequestLogger.rota/1` e o `sanitizarRota` do servidor. */
function sanitizarRota(caminho: string): string {
	return caminho
		.split('/')
		.map((seg) =>
			/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(seg) ||
			/^[0-9a-fA-F]{32}$/.test(seg) ||
			/^\d+$/.test(seg)
				? ':id'
				: seg
		)
		.join('/');
}

function truncar(valor: unknown, max: number): string {
	const texto = typeof valor === 'string' ? valor : String(valor ?? '');
	return texto.length <= max ? texto : texto.slice(0, max);
}

/** Zera os contadores. Existe para o teste — cada caso precisa começar do zero. */
export function _resetar() {
	enviados = 0;
	vistos.clear();
}

export function reportar(origem: string, erro: unknown, extra?: Record<string, unknown>) {
	if (typeof window === 'undefined') return;
	if (enviados >= MAX_POR_SESSAO) return;

	const message = truncar(erro instanceof Error ? erro.message : erro, MAX_MENSAGEM);
	const stack = erro instanceof Error ? truncar(erro.stack, MAX_STACK) : '';

	// Deduplica: o mesmo erro repetido a cada re-render vira um registro só. Sem isto, o teto
	// acima seria consumido pelo primeiro erro cíclico e os seguintes ficariam invisíveis.
	const chave = `${origem}:${message}`;
	if (vistos.has(chave)) return;
	vistos.add(chave);
	enviados++;

	const corpo = JSON.stringify({
		origem,
		message,
		stack,
		route: sanitizarRota(location.pathname),
		...extra
	});

	try {
		// `sendBeacon` sobrevive à navegação/fechamento da aba — que é exatamente quando muitos
		// erros acontecem. Sem ele (ou se recusar por tamanho), cai no fetch com `keepalive`,
		// que tem a mesma propriedade.
		const beacon = navigator.sendBeacon?.(
			'/api/client-error',
			new Blob([corpo], { type: 'application/json' })
		);

		if (!beacon) {
			void fetch('/api/client-error', {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: corpo,
				keepalive: true
			}).catch(() => {
				/* reportar falha do reportador levaria a laço; aqui o silêncio é a escolha certa */
			});
		}
	} catch {
		/* idem */
	}
}
