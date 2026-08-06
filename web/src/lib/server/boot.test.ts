import { describe, it, expect } from 'vitest';
import { conferirAmbiente } from './boot';

// R-A3 e R-M20 (doc 95, onda 3 do doc 102).
//
// O projeto JÁ tinha a guarda certa para `API_PUBLIC_ORIGIN` — `hooks.server.ts` levanta de
// propósito quando a CSP assada no build diverge do runtime, com a justificativa escrita. O padrão
// estava escolhido; três variáveis ficaram de fora dele, e são justamente as que sustentam CSRF,
// HSTS e a existência do produto.
const OK = {
	origin: 'https://cinetra.com.br',
	apiUrl: 'http://api-prod:4000',
	apiPublicOrigin: 'https://cinetra.com.br'
};

describe('conferirAmbiente — fora de produção não atrapalha', () => {
	// Em dev nenhuma das três é definida pelo `docker-compose.yml` (só `API_URL` e
	// `API_PUBLIC_ORIGIN`), e o Kit resolve a origem sozinho. Uma guarda que exigisse tudo em dev
	// só treinaria a equipe a contorná-la.
	it('sem produção, ausência não é erro', () => {
		expect(conferirAmbiente({ producao: false })).toBeNull();
	});

	// Mas valor INVÁLIDO é erro em qualquer ambiente: se está lá, tem de estar certo.
	it('mesmo fora de produção, um ORIGIN inválido acusa', () => {
		expect(conferirAmbiente({ producao: false, origin: 'https://' })).toMatch(/ORIGIN/);
	});
});

describe('conferirAmbiente — ORIGIN (R-A3, o CSRF)', () => {
	it('ausente em produção é erro', () => {
		const erro = conferirAmbiente({ ...OK, origin: undefined, producao: true });

		expect(erro).toMatch(/ORIGIN/);
		// A mensagem precisa dizer o que quebra, não só o que falta: sem ORIGIN o adapter-node
		// monta a origem a partir do header `Host` — e o Traefik roteia POR `Host()`, então o
		// header chega intacto. A comparação de CSRF passa a ser contra o que o próprio request
		// mandou, e um POST cross-site volta a passar em `/auth/sign-out` e nas form actions.
		expect(erro).toMatch(/CSRF/i);
	});

	it('presente e válido passa', () => {
		expect(conferirAmbiente({ ...OK, producao: true })).toBeNull();
	});

	it('com barra no fim continua válido', () => {
		expect(conferirAmbiente({ ...OK, origin: 'https://cinetra.com.br/', producao: true })).toBeNull();
	});
});

describe('conferirAmbiente — API_URL (R-A3, o produto inteiro)', () => {
	// Sem ela toda chamada BFF→API vira ECONNREFUSED, `loadMe` falha e o produto vira uma tela de
	// login que não loga — enquanto `/health` segue 200, porque não faz I/O de propósito. É o que
	// o Traefik consulta: o container fica na rotação servindo o nada.
	it('ausente em produção é erro, e a mensagem cita o /health que continua verde', () => {
		const erro = conferirAmbiente({ ...OK, apiUrl: undefined, producao: true });

		expect(erro).toMatch(/API_URL/);
		expect(erro).toMatch(/health/);
	});
});

describe('conferirAmbiente — o furo do R-M20: os dois lados concordam e ambos são inválidos', () => {
	// O caso medido: com `WEB_HOST` indefinido, `args:` e `environment:` do compose derivam ambos
	// a string literal `"https://"`. O `autorizadas.includes(origemRuntime)` do `csp.js` CASA — os
	// dois lados são iguais — e a guarda devolve `null`. Container sobe, CSP servida com host
	// inválido, WebSocket morto, deploy verde.
	//
	// Concordância não é validade. É por isso que a checagem passou a ser `new URL()`, e não
	// comparação de string.
	it('"https://" é recusado mesmo com os dois lados iguais', () => {
		const erro = conferirAmbiente({
			origin: 'https://',
			apiUrl: 'http://api-prod:4000',
			apiPublicOrigin: 'https://',
			producao: true
		});

		expect(erro).not.toBeNull();
	});

	it.each(['https://', 'http://', 'cinetra.com.br', 'nao-e-url', ''])(
		'%s não é uma origem válida',
		(valor) => {
			expect(conferirAmbiente({ ...OK, apiPublicOrigin: valor, producao: true })).not.toBeNull();
		}
	);
});
