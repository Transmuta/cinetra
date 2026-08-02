import adapter from '@sveltejs/adapter-node';
import { connectSrc, imgSrc } from './src/lib/csp.js';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	compilerOptions: {
		// Runes forçadas no projeto (exceto libs em node_modules). Removível no Svelte 6.
		runes: ({ filename }) => (filename.split(/[/\\]/).includes('node_modules') ? undefined : true)
	},
	kit: {
		// Servidor Node standalone (ADR-006).
		adapter: adapter(),

		// Content-Security-Policy (auditoria doc 13, causa E). `mode: 'auto'` faz o SvelteKit
		// injetar nonce nos seus próprios scripts inline (hidratação), então `script-src 'self'`
		// não os bloqueia. `style-src` permite inline por causa do `style="display:contents"` do
		// app.html e dos estilos que o Svelte insere — risco baixo de XSS via style.
		csp: {
			mode: 'auto',
			directives: {
				'default-src': ['self'],
				'script-src': ['self'],
				'style-src': ['self', 'unsafe-inline'],
				// A foto de perfil (Google → nosso bucket) é servida por URL assinada do R2, então
				// o `<img>` do avatar aponta para fora do BFF — mesma razão do `connect-src` abaixo,
				// e a mesma variável de build (`R2_ACCOUNT_ID`).
				'img-src': imgSrc(process.env.R2_ACCOUNT_ID),
				'font-src': ['self'],
				// O WebSocket da agenda (Entrega 3) é a única conexão do browser que NÃO passa pelo
				// BFF: ele vai direto ao Phoenix (ADR-004/005), então `self` não basta.
				//
				// S3 (Onda 5): a lista era fixa e carregava os DOIS ambientes — o build de produção
				// levava `localhost:4010` junto. Agora sai da origem pública da API, uma só por
				// build. Ver `src/lib/csp.js` (e por que isto é build-time).
				//
				// Doc 51: o `PUT` do anexo vai direto ao bucket do R2, também sem passar pelo BFF,
				// então a origem dele entra aqui. `R2_ACCOUNT_ID` é a MESMA variável que a API usa
				// para assinar — e, como a CSP é build-time, ela precisa de `ARG` no
				// `Dockerfile.prod` e `args:` no `compose.dokploy.yml`, não `environment:`.
				'connect-src': connectSrc(process.env.API_PUBLIC_ORIGIN, process.env.R2_ACCOUNT_ID),
				'base-uri': ['self'],
				'form-action': ['self'],
				'frame-ancestors': ['none'],
				'object-src': ['none']
			}
		}
	}
};

export default config;
