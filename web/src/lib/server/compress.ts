// Compressão das respostas geradas pelo SSR (doc 57).
//
// O `adapter-node` pré-comprime os arquivos de `_app/` no build (`.gz`/`.br`, servidos pelo
// sirv ANTES do handler do SvelteKit) — mas o HTML do SSR é gerado por request e sai **cru**.
// A landing são 56 KB de HTML: medido no Lighthouse, 42 KB de desperdício por request, e não há
// camada na frente que conserte isso — o Traefik não comprime (só faz o redirect de HTTPS,
// mesma lição do HSTS na Onda 5, doc 46).
//
// `CompressionStream` é padrão web e existe no Node desde a 18: não precisa de dependência nova
// nem de servidor customizado em volta do `build/handler.js`. Por ser *stream*, o SSR em fatias
// (`load` que devolve promessa) continua fluindo — o gzip não bufferiza a resposta inteira.
//
// Brotli comprimiria ~15% melhor, mas o `CompressionStream` do Node 22 só aceita gzip/deflate
// (medido); trocar por `node:zlib` para ganhar isso custaria a compatibilidade do stream web.

/** Tipos que valem comprimir. Imagem/vídeo/fonte já vêm comprimidos — gzipar de novo só gasta CPU. */
const COMPRESSIBLE =
	/^(?:text\/|application\/(?:json|xml|javascript|manifest\+json)|image\/svg\+xml)/i;

/**
 * O cliente aceita gzip?
 *
 * `gzip;q=0` é recusa EXPLÍCITA (RFC 9110 §12.5.3) e precisa ser respeitada: mandar gzip a quem
 * disse que não o lê entrega bytes ilegíveis. O peso é comparado como número, não como texto —
 * `q=0`, `q=0.0` e `q=0.000` são a mesma recusa escrita de três jeitos.
 */
export function acceptsGzip(acceptEncoding: string | null): boolean {
	if (!acceptEncoding) return false;

	return acceptEncoding
		.split(',')
		.map((part) => part.trim().toLowerCase())
		.some((part) => {
			const [encoding, ...params] = part.split(';').map((p) => p.trim());
			if (encoding !== 'gzip' && encoding !== '*') return false;

			const peso = params.find((p) => p.startsWith('q='));
			return peso ? Number(peso.slice(2)) > 0 : true;
		});
}

/** Vale comprimir esta resposta? */
export function compressible(response: Response): boolean {
	// Sem corpo (204, 304, HEAD) não há o que comprimir; já codificada, não se codifica de novo.
	if (!response.body || response.headers.has('content-encoding')) return false;

	return COMPRESSIBLE.test(response.headers.get('content-type') ?? '');
}

/**
 * Devolve a resposta comprimida em gzip — ou a original, quando não vale a pena.
 *
 * `Vary: Accept-Encoding` sai nas duas pontas de propósito: sem ele, um cache intermediário
 * pode entregar a variante gzipada a um cliente que não a pediu (ou o contrário). Vale mesmo
 * quando a resposta não foi comprimida, porque a decisão dependeu do header do cliente.
 */
export function gzipResponse(response: Response, acceptEncoding: string | null): Response {
	if (!compressible(response)) return response;

	const headers = new Headers(response.headers);
	headers.append('vary', 'accept-encoding');

	if (!acceptsGzip(acceptEncoding)) {
		return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
	}

	headers.set('content-encoding', 'gzip');
	// O tamanho do corpo muda; manter o valor antigo faria o cliente truncar a leitura.
	headers.delete('content-length');

	return new Response(response.body!.pipeThrough(new CompressionStream('gzip')), {
		status: response.status,
		statusText: response.statusText,
		headers
	});
}
