import type { Handle } from '@sveltejs/kit';
import { conferirOrigem } from '$lib/csp.js';
import { apiPublicOrigin } from '$lib/server/api';

// D2 (doc 47) — a guarda entre o build e o runtime, no boot do servidor.
//
// A CSP é fixada no BUILD (`kit.csp` → `[build.args]` do fly.toml) e a origem do WebSocket é
// lida em RUNTIME (`[env]`). Divergir não dá erro de servidor: dá agenda que para de atualizar
// sozinha, com o motivo só no console do browser de quem está usando — um deploy passa verde
// por cima disso.
//
// **Levanta de propósito, em vez de logar.** Divergência aqui significa que o tempo real já
// está quebrado; recusar subir transforma isso numa release que falha (e o Fly reverte) em vez
// de um recurso que some sem ninguém saber. Um log seria a mesma falha silenciosa com uma linha
// a mais, enquanto o projeto ainda não tem agregação de log.
const divergencia = conferirOrigem(__CSP_CONNECT_SRC__, apiPublicOrigin());
if (divergencia) throw new Error(divergencia);

// Dark mode sem flash (doc 03 §4.4): estampa `data-theme` no <html> já no HTML servido,
// a partir do cookie `mv-theme`. Sem cookie, NÃO emite o atributo — aí o `prefers-color-scheme`
// do app.css decide. Também troca o `lang` para pt-BR (acessibilidade, §8.5).
export const handle: Handle = async ({ event, resolve }) => {
	const theme = event.cookies.get('mv-theme');
	const themeAttr = theme === 'dark' || theme === 'light' ? ` data-theme="${theme}"` : '';

	const response = await resolve(event, {
		transformPageChunk: ({ html }) =>
			html.replace('%mv-lang%', 'pt-BR').replace('%mv-theme%', themeAttr)
	});

	// Headers de segurança (auditoria doc 13, causa E). A CSP não está aqui: ela é do
	// `kit.csp` (svelte.config.js), porque só o SvelteKit sabe o nonce dos próprios scripts
	// inline de hidratação.
	response.headers.set('X-Content-Type-Options', 'nosniff');
	response.headers.set('X-Frame-Options', 'DENY');
	response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');

	// HSTS (H59, Onda 5). O `force_https` do fly.toml faz o **redirect** http→https, e o doc 17
	// e o prod.exs concluíram daí que o header também era da edge — não é: o proxy do Fly não
	// emite `Strict-Transport-Security` (só o domínio `*.fly.dev` o tem, o que não vale para
	// domínio próprio). Sem esta linha, o primeiro acesso de cada browser continua passível de
	// downgrade, e o redirect esconde o sintoma.
	//
	// A condição é o protocolo de `event.url`, que sob adapter-node vem do **`ORIGIN`** (setado no
	// `web/fly.toml`) — não do protocolo do fio, que atrás da edge do Fly é http interno. Medido
	// no bate-volta: sem `ORIGIN`, o adapter-node assume `https` e o header sai até sobre http
	// puro. Isso é inofensivo para o browser (RFC 6797 §8.1 manda ignorar HSTS fora de HTTPS),
	// mas significa que **quem garante a verdade aqui é o `ORIGIN`**, e não esta condição.
	//
	// `max-age` de 2 anos é o valor que a preload list exige; sem `preload` de propósito — entrar
	// na lista é decisão humana e difícil de desfazer.
	if (event.url.protocol === 'https:') {
		response.headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
	}

	return response;
};
