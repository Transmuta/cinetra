// Guarda de boot do BFF — R-A3 e R-M20 (doc 95, onda 3 do doc 102).
//
// ## Por que existir, se o projeto já tinha uma guarda
//
// Justamente por isso. `hooks.server.ts` já derruba o container quando a CSP assada no build
// diverge do `API_PUBLIC_ORIGIN` lido em runtime, com a justificativa escrita: divergência ali
// significa que o tempo real já está quebrado, e é melhor uma release que falha do que um recurso
// que some sem ninguém saber.
//
// O padrão certo estava escolhido. **Três variáveis ficaram de fora dele** — e são as que
// sustentam o CSRF, o HSTS e a própria existência do produto:
//
//   * `ORIGIN` — sem ela o adapter-node monta a origem a partir do header `Host`
//     (`files/handler.js`: `base: origin || get_origin(req.headers)`), e o Traefik roteia POR
//     `Host()`, então o header chega intacto ao Node. A comparação de CSRF do Kit passa a ser
//     contra "a origem que o próprio request disse ter", o que não é comparação nenhuma: um POST
//     cross-site volta a passar em `/auth/sign-out`, `/auth/switch-clinic` e em toda form action.
//     No mesmo pacote, o HSTS passa a sair sempre, porque quem decide o protocolo de `event.url`
//     é ela.
//
//   * `API_URL` — `apiBase()` cai em `http://localhost:4000`. Toda chamada BFF→API vira
//     `ECONNREFUSED`, `loadMe` falha e o produto vira uma tela de login que não loga. E `/health`
//     continua 200, porque não faz I/O de propósito — que é exatamente o que o Traefik consulta.
//     **O container fica na rotação servindo o nada.**
//
//   * `API_PUBLIC_ORIGIN` — já era conferido, mas por comparação de STRING.
//
// ## O furo do R-M20, que é o motivo de isto usar `new URL()`
//
// `compose.dokploy.yml` deriva o `args:` do build e o `environment:` do runtime da MESMA variável
// `${WEB_HOST}`. Com ela indefinida, os dois viram a string literal `"https://"` — e o
// `autorizadas.includes(origemRuntime)` do `csp.js` **casa**, porque os dois lados são iguais. A
// guarda devolvia `null`, o container subia, a CSP era servida com host inválido e o WebSocket
// morria. Deploy verde.
//
// **Concordância não é validade.** É a lição que este arquivo existe para não deixar esquecer, e
// é por isso que a checagem é de parsing, não de igualdade. Compare com o que o próprio
// adapter-node faz para a env análoga (`utils.js`): valida com `new URL()` e levanta com mensagem
// descritiva.
//
// ## Por que módulo próprio, e não mais linhas no `hooks.server.ts`
//
// Para poder ter teste. A guarda antiga roda no topo do módulo, no import — testá-la exigiria
// recarregar o módulo com o ambiente trocado a cada caso. Aqui a decisão é uma função pura que
// recebe os valores e devolve a mensagem; o `hooks.server.ts` só decide o que fazer com ela, que
// é o mesmo desenho já usado pelo `conferirOrigem` do `csp.js`.

type Ambiente = {
	origin?: string;
	apiUrl?: string;
	apiPublicOrigin?: string;
	/** Só em produção a AUSÊNCIA é erro — em dev o Kit resolve a origem sozinho. */
	producao?: boolean;
};

/** Absoluta, com protocolo http(s) e com host. `https://` tem protocolo e NÃO tem host. */
function origemValida(valor: string): boolean {
	try {
		const url = new URL(valor);
		return (url.protocol === 'http:' || url.protocol === 'https:') && url.hostname.length > 0;
	} catch {
		return false;
	}
}

/**
 * Devolve `null` quando o ambiente está são, ou a mensagem a levantar.
 *
 * Não levanta aqui, pelo mesmo motivo do `conferirOrigem`: quem decide o que fazer com o problema
 * é o `hooks.server.ts`, e assim esta parte continua testável sem derrubar processo.
 */
export function conferirAmbiente({
	origin,
	apiUrl,
	apiPublicOrigin,
	producao = false
}: Ambiente): string | null {
	// Presença: só cobrada em produção. Em dev o `docker-compose.yml` não define `ORIGIN` (o
	// servidor do Vite sabe a própria origem), e exigi-la ali só ensinaria a contornar a guarda.
	if (producao) {
		if (!origin) {
			return (
				'ORIGIN não está definida.\n' +
				'  Sem ela o adapter-node monta a origem a partir do header `Host` — e o Traefik roteia\n' +
				'  por `Host()`, então o header chega intacto. A checagem de CSRF do SvelteKit passa a\n' +
				'  comparar o request com ele mesmo: POST cross-site volta a passar em /auth/sign-out,\n' +
				'  /auth/switch-clinic e em toda form action. O HSTS também deixa de ser confiável.\n' +
				'  Defina ORIGIN no environment: do serviço `web` (compose.dokploy.yml).'
			);
		}

		if (!apiUrl) {
			return (
				'API_URL não está definida.\n' +
				'  Toda chamada BFF→API vira ECONNREFUSED e o produto fica uma tela de login que não\n' +
				'  loga — enquanto /health segue respondendo 200, porque não faz I/O de propósito, e é\n' +
				'  ele que o Traefik consulta. O container ficaria na rotação servindo o nada.\n' +
				'  Defina API_URL no environment: do serviço `web` (compose.dokploy.yml).'
			);
		}

		if (!apiPublicOrigin) {
			return 'API_PUBLIC_ORIGIN não está definida — o WebSocket da agenda não tem para onde discar.';
		}
	}

	// Validade: cobrada SEMPRE que o valor existe. Uma env presente e inválida é pior que ausente,
	// porque parece configurada — e foi assim que o R-M20 passou pela guarda antiga.
	for (const [nome, valor] of [
		['ORIGIN', origin],
		['API_PUBLIC_ORIGIN', apiPublicOrigin]
	] as const) {
		if (valor !== undefined && !origemValida(valor)) {
			return (
				`${nome} não é uma origem válida: ${JSON.stringify(valor)}\n` +
				'  Esperado algo como https://cinetra.com.br — com protocolo E host.\n' +
				'  O caso que motivou esta checagem: com WEB_HOST indefinido, o compose deriva a\n' +
				'  string literal "https://" nos DOIS lados (args: e environment:). Eles concordam,\n' +
				'  a comparação de string casa, e a CSP é servida com host inválido — WebSocket morto\n' +
				'  e deploy verde. Concordância não é validade.'
			);
		}
	}

	if (apiUrl !== undefined && !origemValida(apiUrl)) {
		return `API_URL não é uma URL válida: ${JSON.stringify(apiUrl)} (esperado http://host:porta).`;
	}

	return null;
}
