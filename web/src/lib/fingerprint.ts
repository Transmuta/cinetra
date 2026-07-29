/**
 * Agrupamento de erro: a chave que transforma N linhas soltas em "um problema com N ocorrências".
 *
 * ## Por que existe
 *
 * O pipeline de erro (doc 62 §7.2) captura bem e **não agrupa**. No Loki, cem usuários batendo no
 * mesmo bug viram cem linhas, e não há consulta que responda "é um bug ou cem?", "quantos
 * usuários?" ou — a que mais dói — "isto é novo ou já acontecia semana passada?". Sem "primeira
 * vez visto" não se separa regressão de ruído de fundo, e é a regressão que exige agir hoje.
 *
 * Com um campo estável por problema, o Loki responde as três:
 *
 *     topk(10, sum by (fingerprint) (count_over_time({env="prod"} |= "erro no browser" | json [24h])))
 *
 * ## As três camadas
 *
 * O algoritmo segue a especificação que o Grafana Cloud publica para o Frontend Observability
 * (doc 78 §opção E) — vale porque cada camada existe para um caso que as outras não cobrem:
 *
 *   1. **stack com nomes de função significativos** — normaliza o stack e **filtra os frames de
 *      biblioteca**, para que só o nosso código entre no hash;
 *   2. **stack minificado** (nome de função de uma letra, mas caminho válido) — usa a *sequência
 *      de arquivos* mais a mensagem canônica;
 *   3. **sem stack** (erro de rede, assertion) — tipo/origem mais a mensagem canônica.
 *
 * O passo de **filtrar biblioteca** na camada 1 é o que separa um fingerprint útil de um inútil:
 * sem ele, todo erro que atravessa o runtime do Svelte compartilha os frames de topo e agrupa
 * junto, produzindo um "issue" gigante que engole os outros.
 *
 * ## Roda nos dois lados, de propósito
 *
 * O browser usa isto para **deduplicar antes de enviar**; o servidor **recomputa do zero** a
 * partir dos campos que recebeu. Nada de fingerprint viaja no corpo — a allowlist do endpoint
 * descartaria mesmo, e a barreira não pode depender de código que o usuário consegue editar.
 * Como as duas pontas rodam esta mesma função pura, elas chegam ao mesmo valor sem confiar uma
 * na outra.
 *
 * Por isso também não há `crypto.subtle` aqui: além de assíncrono, seria uma dependência de
 * ambiente. Isto é chave de agrupamento, não primitiva de segurança — um hash não-criptográfico
 * determinístico é exatamente o certo.
 */

/** Caminhos que não são nosso código. Frame daqui não entra no hash da camada 1. */
const BIBLIOTECA = /node_modules|\/svelte\/|\bchunk-|\/@vite\/|\/@fs\/|^node:|internal\//;

type Frame = { fn: string; file: string };

/**
 * Extrai `(função, arquivo)` de cada linha do stack.
 *
 * Dois formatos, porque os dois chegam de usuário real:
 *   * Chrome/Edge — `    at nomeDaFn (https://host/caminho.js:12:34)`
 *   * Firefox/Safari — `nomeDaFn@https://host/caminho.js:12:34`
 *
 * Um parser que só entendesse Chrome devolveria zero frames no Firefox e jogaria aqueles erros
 * na camada 3, agrupando por mensagem coisas que vêm de lugares diferentes — e só para uma
 * fatia dos usuários, que é o tipo de defeito que ninguém procura.
 *
 * Linha e coluna são descartadas de propósito: elas mudam a cada edição do arquivo, e um
 * fingerprint que muda quando o código anda não agrupa nada.
 */
export function _frames(stack?: string): Frame[] {
	if (!stack) return [];

	const frames: Frame[] = [];
	for (const linha of stack.split('\n')) {
		const chrome = linha.match(/^\s*at\s+(.+?)\s+\((.+?):\d+:\d+\)\s*$/);
		if (chrome) {
			frames.push({ fn: chrome[1], file: chrome[2] });
			continue;
		}
		const firefox = linha.match(/^\s*(.+?)@(.+?):\d+:\d+\s*$/);
		if (firefox) frames.push({ fn: firefox[1], file: firefox[2] });
	}
	return frames;
}

/**
 * A mensagem sem as partes que mudam entre ocorrências.
 *
 * `paciente 019fab79-… não achado` e `paciente 019fab68-… não achado` são o **mesmo** problema; o
 * id é o que varia. Idem para número solto e conteúdo entre aspas (`campo "nome" inválido`).
 *
 * Isto também é uma barreira de PII de segunda ordem: o valor canônico é o que vira chave de
 * agrupamento e aparece em painel, e ele nunca carrega o id que estava na mensagem.
 */
export function _canonizar(texto: string): string {
	return (texto ?? '')
		.toLowerCase()
		.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, '<id>')
		.replace(/"[^"]*"|'[^']*'/g, '<v>')
		.replace(/\d+/g, '<n>')
		.replace(/\s+/g, ' ')
		.trim();
}

/** Nome que não identifica nada: minificado (`Ki`), anônimo, ou vazio. */
function nomeUtil(fn: string): boolean {
	if (!fn || fn.length <= 2) return false;
	return !/^(<anonymous>|anonymous|Object\.<anonymous>|eval|\?)$/i.test(fn);
}

/**
 * FNV-1a de 32 bits em base36.
 *
 * Curto o bastante para caber num rótulo e ser lido em voz alta numa conversa, e determinístico
 * em qualquer runtime — que é o requisito real (ver o cabeçalho do módulo).
 */
function hash(texto: string): string {
	let h = 0x811c9dc5;
	for (let i = 0; i < texto.length; i++) {
		h ^= texto.charCodeAt(i);
		h = Math.imul(h, 0x01000193) >>> 0;
	}
	return h.toString(36).padStart(7, '0');
}

/**
 * A chave de agrupamento do erro. Determinística, curta, sem PII.
 *
 * @param origem de onde veio (`kit`, `window`, `promise`, `servidor`) — separa problemas que têm
 *   o mesmo texto mas caminhos diferentes, porque investigá-los é diferente.
 * @param message mensagem do erro.
 * @param stack stack trace, quando houver.
 */
export function fingerprint(origem: string, message: string, stack?: string): string {
	const frames = _frames(stack);
	const nossos = frames.filter((f) => !BIBLIOTECA.test(f.file));

	// Camada 1: temos frames do nosso código com nome de função que diz algo.
	const nomeados = nossos.filter((f) => nomeUtil(f.fn));
	if (nomeados.length > 0) {
		const assinatura = nomeados.map((f) => `${f.fn}@${f.file}`).join('|');
		return hash(`1:${origem}:${assinatura}`);
	}

	// Camada 2: stack minificado — os nomes não servem, a sequência de ARQUIVOS sim.
	if (nossos.length > 0) {
		const arquivos = nossos.map((f) => f.file).join('|');
		return hash(`2:${origem}:${arquivos}:${_canonizar(message)}`);
	}

	// Camada 3: sem stack aproveitável.
	return hash(`3:${origem}:${_canonizar(message)}`);
}
