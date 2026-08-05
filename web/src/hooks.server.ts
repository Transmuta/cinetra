import type { Handle, HandleServerError } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { conferirOrigem } from '$lib/csp.js';
import { conferirAmbiente } from '$lib/server/boot';
import { apiPublicOrigin } from '$lib/server/api';
import { gzipResponse } from '$lib/server/compress';
import { log, sanitizarRota, sanitizarTexto, truncar, LIMITES } from '$lib/server/log';
import { novoRequestId } from '$lib/server/correlacao';
import { fingerprint } from '$lib/fingerprint';

// D2 (doc 47) — a guarda entre o build e o runtime, no boot do servidor.
//
// A CSP é fixada no BUILD (`kit.csp` → `args:` do compose.dokploy.yml) e a origem do WebSocket é
// lida em RUNTIME (`environment:`). Divergir não dá erro de servidor: dá agenda que para de atualizar
// sozinha, com o motivo só no console do browser de quem está usando — um deploy passa verde
// por cima disso.
//
// **Levanta de propósito, em vez de logar.** Divergência aqui significa que o tempo real já
// está quebrado; recusar subir transforma isso numa release que falha (e o Dokploy não promove) em vez
// de um recurso que some sem ninguém saber. Um log seria a mesma falha silenciosa com uma linha
// a mais, enquanto o projeto ainda não tem agregação de log.
const divergencia = conferirOrigem(__CSP_CONNECT_SRC__, apiPublicOrigin());
if (divergencia) throw new Error(divergencia);

// R-A3 e R-M20 (onda 3 do doc 102) — o mesmo padrão da guarda acima, estendido às três variáveis
// que tinham ficado de fora dele: `ORIGIN` (CSRF e HSTS), `API_URL` (a existência do produto) e a
// VALIDADE do `API_PUBLIC_ORIGIN`, que antes era só comparado por string.
//
// O caso que a comparação de string deixava passar: com `WEB_HOST` indefinido, o compose deriva
// `"https://"` nos dois lados; eles concordam, o `includes` casa, e a guarda de cima devolve
// `null` com a CSP inválida. Concordância não é validade — ver `lib/server/boot.ts`.
//
// `producao` amarrado ao `NODE_ENV` que o `web/Dockerfile.prod` fixa. Em `vite dev` a ausência não
// acusa (o Kit resolve a origem sozinho); no `vite preview` que o Playwright usa, o `NODE_ENV` é
// production, e por isso o `playwright.config.ts` passa as duas envs — a e2e passa a exercitar a
// configuração de produção em vez de uma variante mais frouxa.
const ambiente = conferirAmbiente({
	origin: env.ORIGIN,
	apiUrl: env.API_URL,
	apiPublicOrigin: env.API_PUBLIC_ORIGIN,
	producao: process.env.NODE_ENV === 'production'
});
if (ambiente) throw new Error(ambiente);

// Dark mode sem flash (doc 03 §4.4): estampa `data-theme` no <html> já no HTML servido,
// a partir do cookie `mv-theme`. Sem cookie, NÃO emite o atributo — aí o `prefers-color-scheme`
// do app.css decide. Também troca o `lang` para pt-BR (acessibilidade, §8.5).
export const handle: Handle = async ({ event, resolve }) => {
	// Correlação BFF → API (doc 62 §12), ANTES do `resolve`: os `load` das páginas chamam a API de
	// dentro dele, e um id criado depois não viajaria nas chamadas que mais importam.
	//
	// Um id por REQUEST do BFF, não por chamada à API. Uma navegação dispara várias chamadas, e o
	// que se quer é vê-las juntas; gerar dentro do `apiFetch` daria N ids sem relação entre si.
	event.locals.requestId = novoRequestId();

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

	// R-B5 (onda 5). Eram três headers; faltavam os que fecham SUPERFÍCIE em vez de ataque —
	// nenhum tem gatilho conhecido hoje, e todos custam uma linha.
	//
	// `Permissions-Policy` desliga APIs que este produto não usa. O ganho não é contra o nosso
	// código: é contra script de terceiro que um dia entre (widget, tag de analytics) e contra XSS
	// que passe pela CSP — sem câmera e sem microfone, o alcance do que ele consegue fazer numa
	// clínica encolhe. A lista é vazia (`=()`), que significa "ninguém, nem eu mesmo".
	response.headers.set(
		'Permissions-Policy',
		'camera=(), microphone=(), geolocation=(), payment=(), usb=(), midi=(), magnetometer=()'
	);

	// COOP isola o nosso contexto de navegação de qualquer janela que nos abra: sem ele,
	// `window.opener` cruza a fronteira. É seguro aqui porque o login com Google é **navegação
	// completa**, não popup (ver `apiPublicOrigin`) — com popup, `same-origin` quebraria o fluxo.
	response.headers.set('Cross-Origin-Opener-Policy', 'same-origin');

	// CORP impede que outro site EMBUTA as nossas respostas. Note que é sobre os nossos recursos
	// serem consumidos de fora — não sobre nós consumirmos de fora, então o avatar do R2 continua
	// carregando normalmente.
	//
	// **COEP fica de fora de propósito.** Ele exigiria que todo recurso cross-origin declarasse
	// CORP, e o avatar servido por URL assinada do R2 não declara — ligar COEP quebraria a foto de
	// perfil em troca de um isolamento que este produto não precisa (não usamos `SharedArrayBuffer`).
	response.headers.set('Cross-Origin-Resource-Policy', 'same-origin');

	// O `report-to: csp` da CSP (svelte.config.js) referencia um NOME de grupo, e o grupo é
	// declarado aqui. Sem este header a diretiva é inerte — e inerte em silêncio, que é o modo de
	// falha que o R-B6 existe para fechar. O `report-uri` da CSP continua junto porque é o que os
	// browsers de fato implementam hoje; os dois apontam para o mesmo endpoint.
	response.headers.set('Reporting-Endpoints', 'csp="/api/client-error?csp=1"');

	// HSTS (H59, Onda 5). O proxy da frente faz o **redirect** http→https, e o doc 17 e o
	// prod.exs concluíram daí que o header também saía dele — não sai: nem a edge da Fly
	// (topologia antiga) nem o Traefik do Dokploy emitem `Strict-Transport-Security`. Sem esta
	// linha, o primeiro acesso de cada browser continua passível de downgrade, e o redirect
	// esconde o sintoma.
	//
	// A condição é o protocolo de `event.url`, que sob adapter-node vem do **`ORIGIN`** (setado no
	// `compose.dokploy.yml`) — não do protocolo do fio, que atrás do Traefik é http interno. Medido
	// no bate-volta: sem `ORIGIN`, o adapter-node assume `https` e o header sai até sobre http
	// puro. Isso é inofensivo para o browser (RFC 6797 §8.1 manda ignorar HSTS fora de HTTPS),
	// mas significa que **quem garante a verdade aqui é o `ORIGIN`**, e não esta condição.
	//
	// `max-age` de 2 anos é o valor que a preload list exige; sem `preload` de propósito — entrar
	// na lista é decisão humana e difícil de desfazer.
	if (event.url.protocol === 'https:') {
		response.headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
	}

	// R-A2 (doc 95, onda 1 do doc 102) — nada do grupo `(app)` pode ficar no cache do browser.
	//
	// O SvelteKit já manda `private, no-store` no `__data.json`, mas o **HTML do SSR** de
	// `/pacientes/<id>` saía sem header de cache nenhum. Cenário real, não hipótese: recepção de
	// clínica, computador compartilhado. A profissional abre a ficha e clica em "Sair"; o POST
	// invalida a sessão e apaga o cookie corretamente. O próximo usuário aperta VOLTAR e o browser
	// re-renderiza a ficha do cache — **sem tocar no servidor**, então nem a sessão apagada nem o
	// `redirect(303, '/entrar')` do `+layout.server.ts` chegam a ser consultados. Dado de saúde na
	// tela depois do logout, sem uma requisição que qualquer log pudesse registrar.
	//
	// `Vary: Cookie` porque a resposta DEPENDE de quem está logado; sem ele, um cache intermediário
	// pode servir a página de um usuário para outro. É `append` e não `set` de propósito: o
	// `gzipResponse` acrescenta `accept-encoding` logo abaixo, e um `set` aqui seria sobrescrito
	// por ele (ou o sobrescreveria) — regressão que não apareceria em teste sem gzip.
	//
	// **O que isto NÃO garante:** `no-store` fecha o cache HTTP (disco/memória), que é o caminho do
	// cenário acima. O bfcache é decisão do browser e vem mudando — o Firefox e o Safari respeitam
	// `no-store`, o Chrome vem afrouxando isso. A defesa que não depende de browser continua sendo
	// a sessão do lado do servidor, que já existe; esta camada tira o caso em que o servidor nem
	// chega a ser consultado.
	if (event.route.id?.startsWith('/(app)')) {
		response.headers.set('Cache-Control', 'private, no-store');
		response.headers.append('Vary', 'Cookie');
	}

	// Compressão do HTML do SSR (doc 57). Os assets de `_app/` já saem pré-comprimidos do build
	// e nem chegam aqui (o sirv do adapter-node os serve antes); o que falta é o HTML gerado por
	// request. Fica por ÚLTIMO de propósito: os headers acima precisam ser lidos e escritos na
	// resposta original, e daqui para frente o corpo vira stream de gzip.
	return gzipResponse(response, event.request.headers.get('accept-encoding'));
};

/**
 * Erro **não tratado** no servidor do SvelteKit (doc 62 §7.2).
 *
 * Sem este hook, exceção em `load`, em action ou em endpoint some: o usuário vê a página de erro
 * genérica e não fica registro em lugar nenhum. Era a lacuna mais barata do projeto — a `+error.svelte`
 * já existia e mostrava "Algo deu errado" para uma falha que ninguém jamais investigaria.
 *
 * O retorno vira `page.error` na `+error.svelte`, então ele é **público**: leva só a mensagem
 * genérica e o `errorId`, que é a chave para achar o registro completo no log. Detalhe de
 * exceção não desce para o browser.
 */
export const handleError: HandleServerError = ({ error, event, status, message }) => {
	// 404 é o roteador não achando rota, não uma falha: registrar todos faria de qualquer varredura
	// de robô um evento de erro.
	if (status === 404) return { message };

	const errorId = crypto.randomUUID();

	// Calculados uma vez e reusados: os dois vão para o log **e** alimentam o fingerprint. Duplicar
	// a expressão abriria a porta para o agrupamento ser computado sobre um texto e o log registrar
	// outro — divergência que nenhum teste pegaria, porque os dois lados pareceriam corretos.
	//
	// `sanitizarTexto` nos dois: um stack de servidor cita a URL que estava sendo servida, e
	// `/pacientes/<uuid>` dentro dele levaria o id do paciente para o log tão bem quanto o campo
	// `route` levaria. A mensagem da exceção pode conter o valor que falhou uma validação.
	const detail = sanitizarTexto(
		error instanceof Error ? truncar(error.message, LIMITES.message) : truncar(error, 200)
	);
	const stack =
		error instanceof Error ? sanitizarTexto(truncar(error.stack, LIMITES.stack)) : undefined;

	log.error('erro não tratado no servidor', {
		error_id: errorId,
		// Mesmo agrupamento do erro de browser, e de propósito: um painel só responde "quais
		// problemas existem", sem o leitor precisar saber de que lado da fronteira cada um nasceu.
		// A origem `servidor` é o que os mantém separados quando o texto coincide.
		fingerprint: fingerprint('servidor', detail, stack),
		// O mesmo id que foi para a API em `x-request-id`. Sem ele, este registro e a linha da
		// requisição do lado Elixir são dois fatos sobre a mesma falha sem nada que os ligue.
		request_id: event.locals.requestId,
		route: sanitizarRota(event.url.pathname),
		route_id: event.route.id,
		status,
		stack,
		detail
	});

	return { message: 'Algo deu errado', errorId };
};
