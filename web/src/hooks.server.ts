import type { Handle } from '@sveltejs/kit';

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
	// A condição é o **protocolo do request**, não o ambiente: sobre http o header é ignorado por
	// especificação (RFC 6797 §8.1), então uma flag de ambiente só criaria a ilusão de proteção
	// num deploy http acidental. `max-age` de 2 anos é o valor que o preload list exige; sem
	// `preload` de propósito — entrar na lista é decisão humana e difícil de desfazer.
	if (event.url.protocol === 'https:') {
		response.headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
	}

	return response;
};
