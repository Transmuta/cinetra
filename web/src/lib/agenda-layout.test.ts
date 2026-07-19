import { describe, it, expect } from 'vitest';
import { layoutAppts, columnWidth, blockGeometry, type Interval } from './agenda-layout';

// ---------------------------------------------------------------------------
// Utilitários do teste. `clustersOf` recalcula os clusters de forma INDEPENDENTE da
// implementação (varredura ingênua sobre a lista ordenada) — é o que permite afirmar
// "todos do mesmo cluster receberam o mesmo `lanes`" sem só reexecutar o algoritmo.
// ---------------------------------------------------------------------------

function clustersOf(items: Interval[]): Interval[][] {
	const sorted = [...items].sort((a, b) => a.start - b.start || a.end - b.end);
	const out: Interval[][] = [];
	let cur: Interval[] = [];
	let end = -Infinity;
	for (const it of sorted) {
		// Encostar fim-com-início NÃO agrupa (semântica `[)`, protótipo :832).
		if (cur.length && it.start >= end) {
			out.push(cur);
			cur = [];
			end = -Infinity;
		}
		cur.push(it);
		end = Math.max(end, it.end);
	}
	if (cur.length) out.push(cur);
	return out;
}

function overlaps(a: Interval, b: Interval): boolean {
	return a.start < b.end && b.start < a.end;
}

// Máximo de intervalos simultâneos — o número mínimo de raias que um cluster PRECISA.
function maxConcurrent(items: Interval[]): number {
	let best = 0;
	for (const probe of items) {
		const n = items.filter((o) => o.start <= probe.start && probe.start < o.end).length;
		best = Math.max(best, n);
	}
	return best;
}

// LCG determinístico: os casos aleatórios precisam ser reproduzíveis quando um deles falhar.
function rng(seed: number): () => number {
	let s = seed >>> 0;
	return () => {
		s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
		return s / 4294967296;
	};
}

function randomDay(seed: number, n: number): Interval[] {
	const rand = rng(seed);
	return Array.from({ length: n }, (_, i) => {
		const start = 480 + Math.floor(rand() * 40) * 15; // 08:00–18:00, grade de 15min
		const dur = [20, 30, 50, 60, 90][Math.floor(rand() * 5)];
		return { id: `a${i}`, start, end: start + dur };
	});
}

// ---------------------------------------------------------------------------

describe('layoutAppts — casos nomeados', () => {
	it('lista vazia → nenhum slot e maxLanes 1 (a coluna nunca some)', () => {
		expect(layoutAppts([])).toEqual({ byId: {}, maxLanes: 1 });
	});

	it('um agendamento sozinho ocupa a raia 0 de 1', () => {
		const r = layoutAppts([{ id: 'a', start: 480, end: 530 }]);
		expect(r.byId.a).toEqual({ lane: 0, lanes: 1 });
		expect(r.maxLanes).toBe(1);
	});

	it('sequenciais sem toque ficam ambos na raia 0 — colunas não alargam à toa', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 530 },
			{ id: 'b', start: 600, end: 650 }
		]);
		expect(r.byId.a).toEqual({ lane: 0, lanes: 1 });
		expect(r.byId.b).toEqual({ lane: 0, lanes: 1 });
		expect(r.maxLanes).toBe(1);
	});

	// A regra `[)`: 08:00–08:50 e 08:50–09:40 NÃO conflitam e não viram duas raias.
	it('encostar fim-com-início não é sobreposição', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 530 },
			{ id: 'b', start: 530, end: 580 }
		]);
		expect(r.maxLanes).toBe(1);
		expect(r.byId.b.lane).toBe(0);
	});

	it('dois sobrepostos viram duas raias', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 540 },
			{ id: 'b', start: 510, end: 570 }
		]);
		expect(r.byId.a).toEqual({ lane: 0, lanes: 2 });
		expect(r.byId.b).toEqual({ lane: 1, lanes: 2 });
		expect(r.maxLanes).toBe(2);
	});

	// O ponto do algoritmo do protótipo: o `lanes` é do CLUSTER, não do item. `c` não
	// sobrepõe `a`, mas está no mesmo cluster (via `b`) e por isso também vale 1/3 da largura
	// — é o que mantém as colunas alinhadas em vez de escadinha.
	it('todos do cluster recebem o mesmo `lanes`, mesmo quem não sobrepõe todo mundo', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 540 },
			{ id: 'b', start: 520, end: 620 },
			{ id: 'c', start: 600, end: 660 }
		]);
		expect(r.byId.a.lanes).toBe(2);
		expect(r.byId.b.lanes).toBe(2);
		expect(r.byId.c.lanes).toBe(2);
		// `c` reaproveita a raia 0, livre desde 540.
		expect(r.byId.c.lane).toBe(0);
		expect(r.byId.b.lane).toBe(1);
	});

	it('clusters distintos não contaminam o `lanes` um do outro', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 540 },
			{ id: 'b', start: 500, end: 560 }, // cluster 1: 2 raias
			{ id: 'c', start: 700, end: 750 } // cluster 2: 1 raia
		]);
		expect(r.byId.a.lanes).toBe(2);
		expect(r.byId.c.lanes).toBe(1);
		// maxLanes é o da coluna inteira (define a LARGURA da coluna).
		expect(r.maxLanes).toBe(2);
	});

	it('distribui na PRIMEIRA raia livre, não numa nova', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 540 },
			{ id: 'b', start: 490, end: 550 },
			{ id: 'c', start: 545, end: 600 } // raia 0 vagou às 540
		]);
		expect(r.byId.c.lane).toBe(0);
		expect(r.byId.c.lanes).toBe(2);
	});

	it('três simultâneos → três raias', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 600 },
			{ id: 'b', start: 490, end: 600 },
			{ id: 'c', start: 500, end: 600 }
		]);
		expect(r.maxLanes).toBe(3);
		expect(new Set([r.byId.a.lane, r.byId.b.lane, r.byId.c.lane])).toEqual(new Set([0, 1, 2]));
	});

	it('ordem de entrada não altera o resultado (a função ordena)', () => {
		const items: Interval[] = [
			{ id: 'a', start: 480, end: 540 },
			{ id: 'b', start: 510, end: 570 },
			{ id: 'c', start: 700, end: 750 }
		];
		expect(layoutAppts([...items].reverse())).toEqual(layoutAppts(items));
	});

	// A-D8: duração customizada faz bloco longo; ele não pode quebrar o agrupamento.
	it('bloco longo engloba vários curtos e forma um cluster só', () => {
		const r = layoutAppts([
			{ id: 'long', start: 480, end: 720 },
			{ id: 'a', start: 500, end: 530 },
			{ id: 'b', start: 600, end: 630 }
		]);
		expect(r.byId.long.lanes).toBe(2);
		expect(r.byId.a.lanes).toBe(2);
		expect(r.byId.b.lanes).toBe(2);
		expect(r.maxLanes).toBe(2);
	});

	it('duração zero não trava nem cria raia extra', () => {
		const r = layoutAppts([
			{ id: 'a', start: 480, end: 480 },
			{ id: 'b', start: 480, end: 530 }
		]);
		expect(r.byId.a).toBeDefined();
		expect(r.byId.b).toBeDefined();
	});
});

// ---------------------------------------------------------------------------
// Teste de propriedade: 200 dias aleatórios reproduzíveis, cada um verificado contra as
// invariantes que a UI depende. Isto é o que o doc 25 §6 chama de "primeiro teste de fogo
// do port não-mecânico" — o algoritmo é do protótipo, mas a garantia é nossa.
// ---------------------------------------------------------------------------

describe('layoutAppts — propriedades sobre dias aleatórios', () => {
	const dias = Array.from({ length: 200 }, (_, s) => randomDay(s + 1, 1 + (s % 12)));

	it('todo agendamento recebe exatamente um slot', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			expect(Object.keys(byId)).toHaveLength(day.length);
			for (const it of day) expect(byId[it.id]).toBeDefined();
		}
	});

	it('a raia é sempre um índice válido: 0 <= lane < lanes', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			for (const slot of Object.values(byId)) {
				expect(slot.lane).toBeGreaterThanOrEqual(0);
				expect(slot.lane).toBeLessThan(slot.lanes);
				expect(Number.isInteger(slot.lane)).toBe(true);
			}
		}
	});

	// A invariante que o usuário VÊ: dois blocos na mesma raia jamais se cobrem na tela.
	it('dois agendamentos na mesma raia nunca se sobrepõem', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			for (const a of day) {
				for (const b of day) {
					if (a.id >= b.id) continue;
					if (byId[a.id].lane === byId[b.id].lane) expect(overlaps(a, b)).toBe(false);
				}
			}
		}
	});

	it('maxLanes é o maior `lanes` observado', () => {
		for (const day of dias) {
			const { byId, maxLanes } = layoutAppts(day);
			const observed = Math.max(1, ...Object.values(byId).map((s) => s.lanes));
			expect(maxLanes).toBe(observed);
		}
	});

	it('todos os itens de um mesmo cluster compartilham o `lanes`', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			for (const cluster of clustersOf(day)) {
				const valores = new Set(cluster.map((it) => byId[it.id].lanes));
				expect(valores.size).toBe(1);
			}
		}
	});

	// Greedy por ordem de início em intervalos é ÓTIMO: o número de raias do cluster é
	// exatamente a sobreposição máxima. Nem raia desperdiçada, nem bloco espremido.
	it('o cluster usa exatamente tantas raias quanto sua sobreposição máxima', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			for (const cluster of clustersOf(day)) {
				expect(byId[cluster[0].id].lanes).toBe(maxConcurrent(cluster));
			}
		}
	});

	it('cada raia de um cluster é de fato usada por alguém', () => {
		for (const day of dias) {
			const { byId } = layoutAppts(day);
			for (const cluster of clustersOf(day)) {
				const usadas = new Set(cluster.map((it) => byId[it.id].lane));
				expect(usadas.size).toBe(byId[cluster[0].id].lanes);
			}
		}
	});
});

describe('columnWidth', () => {
	it('coluna sem sobreposição usa a largura padrão de 210px', () => {
		expect(columnWidth(1)).toBe(210);
	});

	it('a partir de duas raias a coluna alarga 152px por raia (protótipo :1594)', () => {
		expect(columnWidth(2)).toBe(304);
		expect(columnWidth(3)).toBe(456);
	});
});

describe('blockGeometry', () => {
	it('raia única ocupa a coluna menos a faixa clicável da direita', () => {
		const g = blockGeometry({ lane: 0, lanes: 1 });
		expect(g.left).toBe('4px');
		// Sempre sobra a goteira de 24px para criar-em-vazio numa coluna lotada.
		expect(g.width).toContain('24px');
	});

	it('em várias raias, a largura é dividida e o offset cresce com a raia', () => {
		const g0 = blockGeometry({ lane: 0, lanes: 3 });
		const g2 = blockGeometry({ lane: 2, lanes: 3 });
		expect(g0.width).toBe(g2.width);
		expect(g0.left).not.toBe(g2.left);
		expect(g2.left).toContain('* 2');
	});
});
