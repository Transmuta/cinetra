/// <reference types="vitest/config" />
import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vitest/config';
import { loadEnv } from 'vite';
import { connectSrc } from './src/lib/csp.js';

export default defineConfig(({ mode }) => ({
	// D2 (doc 47): assa no bundle o `connect-src` que a `kit.csp` vai emitir, para o servidor
	// conferir no boot se a origem que ele lê em RUNTIME é uma das que a CSP autoriza. As duas
	// saem da mesma `API_PUBLIC_ORIGIN`, mas em momentos diferentes — e era essa diferença de
	// momento que passava sem ninguém checar, bloqueando o WebSocket em silêncio.
	//
	// `define` (e não `$env/static/private`) porque este valor precisa ter **default**: a
	// variável não existe no job `web` do CI, e um build que quebra por falta dela trocaria uma
	// falha silenciosa por outra barulhenta no lugar errado. Com default, dev e CI caem no mesmo
	// valor dos dois lados e a guarda só acende em divergência de verdade.
	// `loadEnv` do Vite (prefixo vazio = todas as variáveis) em vez de `process.env`: o tsconfig
	// do projeto não carrega os tipos do Node, e acrescentar `@types/node` por uma linha traria a
	// superfície inteira da stdlib para o typecheck do app.
	define: {
		__CSP_CONNECT_SRC__: JSON.stringify(
			connectSrc(loadEnv(mode, '.', '').API_PUBLIC_ORIGIN)
		)
	},
	build: {
		// Fonte NUNCA vira `data:` no CSS. O default do Vite embute qualquer asset com menos de
		// 4 KB, e as fatias pequenas do Fontsource (cirílico, vietnamita) caem abaixo disso — o
		// build vinha embutindo 4 delas, 18 KB de base64 (26% do CSS render-blocking) que a
		// **nossa própria CSP** (`font-src 'self'`, svelte.config.js) bloqueia no browser.
		//
		// Ou seja: peso que atrasa o primeiro paint de TODA página do app, e nunca desenha
		// glifo nenhum — só enche o console de violação de CSP. Como arquivo, a fatia sai do
		// caminho crítico (carrega em paralelo, só se o texto pedir aquele alfabeto) e passa
		// pelo `self`. Medido no baseline do doc 57.
		//
		// Só fontes: os outros assets pequenos (o favicon SVG, por ex.) continuam no default.
		assetsInlineLimit: (filePath: string) =>
			/\.(woff2?|ttf|otf|eot)$/i.test(filePath) ? false : undefined
	},
	plugins: [
		// Tailwind v4 via plugin de Vite (ADR-010): a config é o próprio app.css.
		tailwindcss(),
		// A config do SvelteKit (adapter, compilerOptions runes, CSP) vive em svelte.config.js.
		sveltekit()
	],
	server: {
		// Reachable from the host when running inside a container.
		host: true,
		port: 5173,
		strictPort: true
	},
	// Pirâmide de testes (doc 16): dois projetos Vitest.
	//  - client (jsdom): componentes Svelte — arquivos *.svelte.test.ts
	//  - server (node):  lógica de BFF e route handlers — *.test.ts em src/lib/server e src/routes
	test: {
		// Gate de cobertura (análogo ao minimum_coverage do backend). Escopo: o que a
		// pirâmide unit/integração cobre — lib (server + componentes), hooks e os route
		// handlers .ts. As páginas .svelte (SSR) são território de e2e e ficam fora.
		coverage: {
			provider: 'v8',
			reporter: ['text-summary', 'text'],
			include: ['src/lib/**', 'src/hooks.server.ts', 'src/routes/**/*.ts'],
			exclude: [
				'src/lib/index.ts',
				'src/lib/assets/**',
				'src/lib/styles/**',
				// Andaime de teste (fábricas de fixture). Sai da cobertura pela mesma razão que
				// `assets/` e `styles/`: não é superfície de produção. Contá-lo inflaria as
				// métricas com código que é 100% por construção — todo teste o chama.
				'src/lib/testing/**',
				'src/**/*.d.ts',
				'src/**/*.{test,spec}.ts'
			],
			// 80 nas métricas estáveis (alinhado ao gate do backend). Branches ganha folga:
			// o v8 conta fallbacks defensivos que não rodam no ambiente de teste
			// (matchMedia, getSetCookie), inerentemente abaixo — hoje estamos em ~82%.
			thresholds: { lines: 80, functions: 80, statements: 80, branches: 75 }
		},
		projects: [
			{
				extends: './vite.config.ts',
				plugins: [svelteTesting()],
				test: {
					name: 'client',
					environment: 'jsdom',
					clearMocks: true,
					include: ['src/**/*.svelte.{test,spec}.{js,ts}'],
					exclude: ['src/lib/server/**'],
					setupFiles: ['./vitest-setup-client.ts']
				}
			},
			{
				extends: './vite.config.ts',
				test: {
					name: 'server',
					environment: 'node',
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
				}
			}
		]
	}
}));
