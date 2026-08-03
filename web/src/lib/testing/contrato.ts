import { readFileSync, existsSync } from 'node:fs';

/**
 * O lado TypeScript das **fixtures de contrato BFF↔API** (doc 101, A2).
 *
 * Os arquivos de `contratos/bff/` são gravados por `api/test/api_web/contrato_bff_test.exs`, que
 * atravessa o roteador da API de verdade e guarda o corpo que ela respondeu. Aqui eles entram no
 * lugar do JSON que cada `.test.ts` inventava — porque um mock escrito no próprio teste valida o
 * BFF contra o BFF, e um campo renomeado do lado Elixir chega `undefined` na tela sem quebrar
 * nada em lugar nenhum.
 *
 * O que muda na prática: o corpo do mock passa a vir da API, e o teste **declara** os campos que
 * o BFF e a tela leem. Se a API parar de mandar um deles, a fixture regravada perde a chave e o
 * teste fica vermelho **aqui** — do lado de quem consome, que é onde a exigência mora.
 *
 * Não é codegen: não há tipo derivado nem esquema. É uma fonte só do exemplo, que é a metade
 * barata e a que pega a classe de defeito que morde (renomear, remover, mudar de forma).
 */

// No CI o checkout inteiro está em `../`; no container de dev, onde só `web/` é montado em
// `/app`, o `docker-compose.yml` monta a raiz do repositório em `/repo` só-leitura. Mesma dupla
// de caminhos de `paridade-espelhada.test.ts`, e pelo mesmo motivo.
const RAIZES = ['../contratos/bff', '/repo/contratos/bff'];

interface Amostra {
	rota: string;
	consumido_por: string;
	corpo: unknown;
}

interface Arquivo {
	amostras: Record<string, Amostra>;
}

const cache = new Map<string, Arquivo>();

function ler(recurso: string): Arquivo {
	const emCache = cache.get(recurso);
	if (emCache) return emCache;

	const caminho = RAIZES.map((r) => `${r}/${recurso}.json`).find((c) => existsSync(c));

	// Falha em vez de pular quando a fixture não é alcançável: um contrato que some sozinho no
	// ambiente errado reporta verde sem ter olhado nada. É a mesma regra do contrato de paridade.
	if (!caminho) {
		throw new Error(
			`fixture de contrato \`${recurso}\` não encontrada em nenhum de: ` +
				RAIZES.map((r) => `${r}/${recurso}.json`).join(', ') +
				`. Gere com: mix test test/api_web/contrato_bff_test.exs`
		);
	}

	const arquivo = JSON.parse(readFileSync(caminho, 'utf-8')) as Arquivo;
	cache.set(recurso, arquivo);
	return arquivo;
}

/**
 * O corpo que a API respondeu naquela rota — o que vai no lugar do mock inventado.
 *
 * O tipo é declarado por quem chama (`contrato<AgendaData>('agenda', 'janela')`) e é uma
 * **afirmação**, não uma garantia: se a API deixar de mandar um campo, o TypeScript continua
 * calado e quem acusa é `exigirCampos`. Ter o tipo aqui ainda vale — ele documenta o que se
 * espera e faz o resto do teste compilar contra a forma certa.
 */
export function contrato<T = unknown>(recurso: string, amostra: string): T {
	const arquivo = ler(recurso);
	const encontrada = arquivo.amostras[amostra];

	if (!encontrada) {
		throw new Error(
			`amostra \`${amostra}\` não existe em contratos/bff/${recurso}.json ` +
				`(há: ${Object.keys(arquivo.amostras).join(', ')})`
		);
	}

	return encontrada.corpo as T;
}

/**
 * Os campos que este lado da fronteira **lê** — a asserção que dá sentido à fixture.
 *
 * A lista mora no teste do consumidor de propósito: "a tela lê `usadas`" é afirmação do web, e é
 * aqui que ela precisa estar para o dia em que a API parar de mandar o campo virar vermelho no
 * lugar certo. Campo a mais na resposta é irrelevante (a API pode crescer); campo de menos é o
 * defeito.
 */
export function exigirCampos(valor: unknown, campos: string[], onde: string): void {
	if (valor === null || typeof valor !== 'object') {
		throw new Error(`${onde}: esperava um objeto do contrato, veio ${JSON.stringify(valor)}`);
	}

	const presentes = new Set(Object.keys(valor as Record<string, unknown>));
	const faltando = campos.filter((c) => !presentes.has(c));

	if (faltando.length > 0) {
		throw new Error(
			`${onde}: a API não manda mais ${faltando.map((f) => `\`${f}\``).join(', ')}.\n` +
				`Presentes: ${[...presentes].sort().join(', ')}.\n` +
				`A fixture vem de contratos/bff/ e é regravada por mix test — se o campo saiu de ` +
				`propósito, acerte o BFF e a tela antes de tirar a exigência daqui.`
		);
	}
}

/** O primeiro item de uma lista do contrato, com a garantia de que ela não está vazia. */
export function primeiro<T>(lista: T[], onde: string): T {
	if (!Array.isArray(lista) || lista.length === 0) {
		throw new Error(
			`${onde}: a fixture veio com lista vazia — ela deixaria de exercitar o contrato dos itens`
		);
	}

	return lista[0];
}
