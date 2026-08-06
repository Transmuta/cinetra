// A coluna "SEÇÕES" dos formulários de cadastro: progresso X/Y e qual seção está na tela.
//
// Estava escrita duas vezes, no `PatientForm` e no `ProfessionalForm` (doc 94 §D-1) — junto com
// o resto do esqueleto que os dois compartilham. Morando em `.svelte`, ficava fora do gate de
// cobertura (`vite.config.ts` inclui `src/lib/**` e exclui `.svelte`), então nenhuma das duas
// cópias era exercitada por teste de unidade.
//
// O que vem para cá é a DECISÃO; a medição continua no componente, que é quem tem o DOM. Essa
// divisão é o ponto: `secaoCorrente` recebe números e devolve um id, e por isso dá para provar o
// caso que ninguém testa à mão — a seção que ainda não subiu o suficiente não vale.

export interface Secao {
	id: string;
	/** Quantos campos aquela seção tem, para o denominador do X/Y. */
	total: number;
}

/** O denominador do progresso: quantos campos o formulário inteiro tem. */
export function totalDeChaves(secoes: readonly Secao[]): number {
	return secoes.reduce((a, s) => a + s.total, 0);
}

/** O numerador: quantos foram preenchidos, somando as contagens por seção. */
export function totalPreenchido(counts: Record<string, number>): number {
	return Object.values(counts).reduce((a, b) => a + b, 0);
}

/** Uma seção já medida: o seu topo em relação ao topo do container que rola. */
export interface TopoDaSecao {
	id: string;
	/** `getBoundingClientRect().top` do elemento MENOS o do container. */
	topoRelativo: number;
}

/**
 * Qual seção está "corrente" — a última cujo topo já passou da linha de leitura.
 *
 * A linha de leitura fica `folga` pixels ABAIXO do topo do container, não no topo: a seção vira
 * ativa um pouco ANTES de encostar lá em cima. Os 56px são a altura do cabeçalho fixo — sem
 * eles, a seção só se marcaria ativa quando o título dela já estivesse escondido atrás do
 * cabeçalho, e a coluna lateral ficaria sempre um passo atrás da leitura.
 *
 * A primeira seção é o piso: no topo da página nenhuma passou da linha, e a coluna precisa
 * marcar alguma mesmo assim.
 */
export function secaoCorrente(
	topos: readonly TopoDaSecao[],
	folga = 56,
	padrao = topos[0]?.id ?? ''
): string {
	let corrente = padrao;
	for (const s of topos) {
		if (s.topoRelativo - folga <= 0) corrente = s.id;
	}
	return corrente;
}
