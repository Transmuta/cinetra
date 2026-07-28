/**
 * Log estruturado do BFF (doc 62 §7.2).
 *
 * Uma linha JSON por evento no stdout, que é de onde o agente coleta. O formato acompanha o do
 * lado Elixir (`time`/`severity`/`message` + campos) para que uma consulta no Loki não precise
 * saber de qual serviço veio o registro.
 *
 * ## O que NÃO se loga aqui
 *
 * Requisição bem-sucedida. A API já registra uma linha por requisição, e o BFF chama a API a
 * cada navegação — logar os dois lados dobraria o volume por quase nenhuma informação nova. Do
 * BFF sai **erro** e o que mais ninguém vê (crash do browser, via `/api/client-error`).
 */

/** Máximos por campo. O evento do browser vem de fora e não pode ditar o tamanho da linha. */
const LIMITES = { message: 500, stack: 2000, route: 200, extra: 200 } as const;

type Severity = 'info' | 'warning' | 'error';

type Campos = Record<string, string | number | boolean | null | undefined>;

/**
 * Troca por `:id` todo segmento de path que é identificador.
 *
 * Espelha `ApiWeb.RequestLogger.rota/1`. Não é cosmético: `/pacientes/019f7c5b-...` levaria o
 * **id do paciente** para a agregação de log, que é o único identificador que o doc 05 §1.3
 * proíbe exportar — ele liga o registro a um titular de dado de saúde. Também é o que mantém a
 * rota agrupável em vez de virar uma série por paciente.
 */
export function sanitizarRota(caminho: string): string {
	return caminho
		.split('/')
		.map((seg) => (identificador(seg) ? ':id' : seg))
		.join('/');
}

/**
 * Troca UUID por `:id` em texto livre (stack trace, mensagem de exceção).
 *
 * Medido ao subir o pipeline: `sanitizarRota` cobria o campo `route`, mas o **stack** de um erro
 * de browser carrega a URL da página — e passou inteiro, com o id do paciente dentro:
 * `at Agenda (/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177)`. Sanitizar só o campo estruturado
 * dava a impressão de barreira sem a barreira.
 *
 * Por que aqui e não no agente: uma redação de UUID aplicada à linha inteira apagaria também
 * `clinic_id` e `actor_id`, que o doc 05 §1.3 **permite** de propósito — são chave operacional e
 * é com elas que se agrupa incidente por clínica. A troca precisa ser cirúrgica, nos campos de
 * texto livre, e isso só dá para fazer de dentro da aplicação.
 */
export function sanitizarTexto(texto: string): string {
	return texto
		.replace(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, ':id')
		.replace(/\b[0-9a-fA-F]{32}\b/g, ':id');
}

function identificador(seg: string): boolean {
	return (
		/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(seg) ||
		/^[0-9a-fA-F]{32}$/.test(seg) ||
		/^\d+$/.test(seg)
	);
}

/**
 * Corta um texto no limite, marcando que houve corte.
 *
 * Um stack trace de browser pode ter dezenas de KB; sem teto, um único erro em laço encheria a
 * retenção do dia.
 */
export function truncar(valor: unknown, max: number): string {
	const texto = typeof valor === 'string' ? valor : String(valor ?? '');
	return texto.length <= max ? texto : `${texto.slice(0, max)}…[+${texto.length - max}]`;
}

function emitir(severity: Severity, message: string, campos: Campos = {}) {
	const linha = JSON.stringify({
		time: new Date().toISOString(),
		severity,
		service: 'web',
		message: truncar(message, LIMITES.message),
		...campos
	});

	// `console.log` com uma string **já serializada** — não com objeto. A formatação do console
	// (`util.inspect`) só entra quando se passa objeto; com string ele escreve exatamente a linha
	// mais `\n`, que é o que o agente precisa ler. Passar o objeto direto sairia com aspas
	// simples e reticências de profundidade, e nenhum parser de JSON aceitaria.
	//
	// Tudo em stdout, inclusive erro: stderr é capturado igual pelo Docker, mas misturar os dois
	// streams embaralha a ordem dos eventos, e ordem é o que se usa para reconstruir um incidente.
	console.log(linha);
}

export const log = {
	info: (message: string, campos?: Campos) => emitir('info', message, campos),
	warning: (message: string, campos?: Campos) => emitir('warning', message, campos),
	error: (message: string, campos?: Campos) => emitir('error', message, campos)
};

export { LIMITES };
