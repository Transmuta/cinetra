// Distribuição de agendamentos sobrepostos em RAIAS dentro de uma coluna do grid do dia.
//
// Port do `layoutAppts` do protótipo (interface/Movimento.dc.html :1577). É o único dos
// quatro motores da agenda que fica no CLIENTE (ADR-006 / doc 08:183): não é regra de
// negócio, é geometria de tela — o servidor não tem opinião sobre onde o retângulo é
// desenhado. Mora em arquivo próprio, com teste de propriedade, porque o doc 25 §6 o nomeia
// como "o primeiro teste de fogo do port não-mecânico": transcrever sem provar as
// invariantes produziria blocos que se cobrem sem ninguém perceber.
//
// Funções PURAS, sem Svelte e sem DOM.

/** Intervalo em MINUTOS DO DIA, meio-aberto `[start, end)`. */
export interface Interval {
	id: string;
	start: number;
	end: number;
	/**
	 * Bloco que é DESENHADO mas não disputa a largura da coluna — hoje, o cancelado
	 * (doc 25 §7, traduzido por `ocupaGrade`/`toInterval` em `agenda.ts`).
	 *
	 * Deliberadamente `ghost` e não `cancelado`: este arquivo é geometria e não deve
	 * aprender o vocabulário de status. Se amanhã "bloqueio de agenda" também não puder
	 * alargar a coluna, a regra muda em `agenda.ts` e aqui nada acontece.
	 */
	ghost?: boolean;
}

export interface Slot {
	/** Índice da raia (0-based) dentro do cluster. */
	lane: number;
	/** Quantas raias o CLUSTER inteiro usa — igual para todos os seus membros. */
	lanes: number;
}

export interface Layout {
	byId: Record<string, Slot>;
	/** Maior `lanes` da coluna: é o que define a largura da coluna. Mínimo 1. */
	maxLanes: number;
}

// Por que o `lanes` é do cluster e não do item: se cada bloco usasse a própria contagem de
// vizinhos, dois blocos do mesmo aglomerado teriam larguras diferentes e a coluna viraria
// uma escadinha. O cluster é a unidade visual.
//
// Um CLUSTER é um grupo de intervalos encadeados por toque: dois blocos entram no mesmo
// cluster se algum caminho de sobreposições os liga (A cobre B, B cobre C ⇒ A, B e C juntos,
// mesmo que A e C não se toquem).
export function layoutAppts(appts: Interval[]): Layout {
	const items = [...appts].sort((a, b) => a.start - b.start || a.end - b.end);

	const byId: Record<string, Slot> = {};
	let maxLanes = 1;
	let cluster: Interval[] = [];
	let clusterEnd = -Infinity;

	// Fecha o cluster corrente: aloca as raias e grava o `lanes` comum.
	const flush = () => {
		if (!cluster.length) return;

		// `laneEnds[i]` = instante em que a raia `i` fica livre. Como o cluster já está
		// ordenado por início, escolher a PRIMEIRA raia livre é a alocação ótima para
		// intervalos: o número de raias resultante é exatamente a sobreposição máxima.
		// Duas alocações separadas, porque `lanes` e `maxLanes` respondem a perguntas
		// diferentes e o código antigo as confundia:
		//  - `lane`/`lanes` é a FRAÇÃO da coluna que cada bloco ocupa. Fantasma participa,
		//    senão ele seria desenhado por cima de um bloco vivo e o esconderia.
		//  - `maxLanes` é a LARGURA da coluna. Fantasma NÃO participa: um cancelado não pode
		//    fazer a coluna pedir 304px (era exatamente o bug — largura dobrada, e sem o
		//    aviso de conflito, que já filtrava cancelado do outro lado).
		// Fantasmas recebem raias DEPOIS das vivas, então os vivos nunca são empurrados.
		const alocar = (subset: Interval[], base: number): [number, Array<[string, number]>] => {
			const laneEnds: number[] = [];
			const out: Array<[string, number]> = [];
			for (const it of subset) {
				let lane = laneEnds.findIndex((end) => end <= it.start);
				if (lane === -1) {
					lane = laneEnds.length;
					laneEnds.push(it.end);
				} else {
					laneEnds[lane] = it.end;
				}
				out.push([it.id, base + lane]);
			}
			return [laneEnds.length, out];
		};

		const [liveLanes, liveSlots] = alocar(
			cluster.filter((it) => !it.ghost),
			0
		);
		const [ghostLanes, ghostSlots] = alocar(
			cluster.filter((it) => it.ghost),
			liveLanes
		);

		const lanes = Math.max(1, liveLanes + ghostLanes);
		for (const [id, lane] of [...liveSlots, ...ghostSlots]) byId[id] = { lane, lanes };
		maxLanes = Math.max(maxLanes, liveLanes);

		cluster = [];
		clusterEnd = -Infinity;
	};

	for (const it of items) {
		// `>=` e não `>`: encostar fim-com-início NÃO é sobreposição (semântica `[)`, a
		// mesma do `tsrange` da exclusion constraint no banco — doc 25 §4).
		if (cluster.length && it.start >= clusterEnd) flush();
		cluster.push(it);
		clusterEnd = Math.max(clusterEnd, it.end);
	}
	flush();

	return { byId, maxLanes };
}

/** Largura padrão da coluna, sem sobreposição (protótipo :1594). */
export const COLUMN_WIDTH = 210;
/** Largura de cada raia quando a coluna alarga. */
export const LANE_WIDTH = 152;
/**
 * Faixa clicável reservada à direita da coluna. Existe para que "clicar em vazio" continue
 * possível mesmo numa coluna lotada de blocos (protótipo :1683).
 */
export const RIGHT_GUTTER = 24;

export function columnWidth(maxLanes: number): number {
	return maxLanes > 1 ? maxLanes * LANE_WIDTH : COLUMN_WIDTH;
}

export interface Geometry {
	left: string;
	width: string;
}

// Posição horizontal do bloco dentro da coluna, em `calc()` (a coluna é elástica, então a
// conta tem que acontecer no CSS e não aqui). Espelha o protótipo :1678.
export function blockGeometry(slot: Slot): Geometry {
	const gap = 3;
	const pad = 3;
	const avail = `(100% - ${RIGHT_GUTTER}px)`;

	if (slot.lanes <= 1) return { left: '4px', width: `calc(${avail} - 4px)` };

	const width = `calc((${avail} - ${pad * 2}px - ${(slot.lanes - 1) * gap}px) / ${slot.lanes})`;
	return { left: `calc(${pad}px + (${width} + ${gap}px) * ${slot.lane})`, width };
}
