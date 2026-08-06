import { describe, it, expect } from 'vitest';
import config from '../../playwright.config';

// O `webServer` do Playwright — as variáveis que o `preview` da e2e recebe.
//
// Mora aqui, e não em `e2e/`, porque o Vitest só enxerga `src/**` (`vite.config.ts`); é o mesmo
// motivo pelo qual `paridade-espelhada.test.ts` lê um arquivo da raiz do repositório de dentro de
// `src/lib/`.
//
// ## O bug que este arquivo existe para não deixar voltar
//
// O objeto `webServer` tinha **duas** chaves `env`, cada uma com seu comentário explicando por que
// era necessária. Em JavaScript a segunda vence em silêncio: `ORIGIN` e `API_URL` sumiam, e o
// `preview` — que roda em `NODE_ENV=production` — batia na guarda de boot (`lib/server/boot.ts`)
// e morria antes do primeiro teste, com "ORIGIN não está definida". A suíte e2e inteira ficou
// impossível de rodar.
//
// O modo de falha é o que torna isto perigoso: a e2e **não roda no CI** (decisão de 2026-07-27),
// então nada avisa. Quem fosse rodar localmente encontraria o erro no `webServer`, longe da
// mudança que o causou — e o comentário no arquivo continuaria afirmando que as três variáveis
// estavam sendo passadas.
describe('playwright.config — webServer', () => {
	it('passa as TRÊS variáveis que a guarda de boot e a CSP exigem', () => {
		const env = config.webServer && 'env' in config.webServer ? config.webServer.env : undefined;

		// `ORIGIN` e `API_URL`: exigidas por `lib/server/boot.ts` sob `NODE_ENV=production`, que é
		// como o `vite preview` roda. `API_PUBLIC_ORIGIN`: a origem que o BROWSER usa, assada na CSP
		// durante o build.
		expect(env).toMatchObject({
			ORIGIN: expect.any(String),
			API_URL: expect.any(String),
			API_PUBLIC_ORIGIN: expect.any(String)
		});
	});
});
