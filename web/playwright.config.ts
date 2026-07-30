import { defineConfig, devices } from '@playwright/test';
import { API_ORIGIN } from './e2e/env';

/**
 * E2E só nos cenários críticos (doc 16): dirige o browser real contra o app de verdade. Poucos,
 * caros — cobrem o encanamento; as regras já são exauridas embaixo.
 *
 * **Roda local, não no CI** (decisão de 2026-07-27): precisa da stack inteira — API, banco e, para
 * os cenários autenticados, a caixa de e-mail de dev de onde sai o magic link. Ver `e2e/README.md`.
 *
 * ## Para onde ele aponta
 *
 * Por padrão, o **preview local**: o Playwright faz `build` + `preview` sozinho na 4173. Para
 * apontar para outro ambiente, basta a variável — nada mais muda:
 *
 *     E2E_BASE_URL=https://hml.exemplo.com \
 *     E2E_API_ORIGIN=https://api-hml.exemplo.com npm run test:e2e
 *
 * Com `E2E_BASE_URL` definido, o `webServer` **não sobe** — seria construir um app para não usar.
 */
const PORT = 4173;
const LOCAL = `http://localhost:${PORT}`;

const baseURL = process.env.E2E_BASE_URL || LOCAL;
const alvoLocal = baseURL === LOCAL;

export default defineConfig({
	testDir: 'e2e',
	timeout: 30_000,
	expect: { timeout: 5_000 },
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 1 : 0,
	reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
	use: {
		baseURL,
		trace: 'on-first-retry'
	},
	// Só sobe o app quando o alvo É o preview local.
	webServer: alvoLocal
		? {
				command: `npm run build && npm run preview -- --port ${PORT}`,
				port: PORT,
				reuseExistingServer: !process.env.CI,
				timeout: 120_000,
				// A origem que o BROWSER usa para o WebSocket, alinhada à que o processo do Playwright
				// usa para falar com a API — as duas rodam na mesma máquina, então é a mesma (ver
				// `e2e/env.ts`). Vale para o `build` e para o `preview` da linha acima, e é preciso nos
				// dois: a CSP é assada no build (`connect-src`) e a origem é lida em runtime pelo BFF.
				// Sem isto, dentro do container o browser herdava `localhost:4010` — o endereço de quem
				// navega do host — e o socket morria em silêncio, com o motivo só no console.
				env: { API_PUBLIC_ORIGIN: API_ORIGIN }
			}
		: undefined,
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }]
});
