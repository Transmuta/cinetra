// A aritmética do arraste (Entrega 4), isolada e pura — a geometria "ponteiro → minuto" que o
// protótipo tinha embutida no `startDrag` (:1231). Fora do `.svelte` para ser testável e para
// os dois clamps (arraste e criar-em-vazio) saírem do MESMO lugar: no protótipo `emptyClick`
// clampava em 1065 e o arraste em `1080 - dur` (doc 25 §10), dois números soltos que discordavam
// sobre onde acaba o dia. Aqui a faixa é a derivada (A12) e o clamp é um só.

export interface DragRange {
	start: number;
	end: number;
}

/**
 * O minuto do dia para o TOPO do bloco, a partir do `y` do ponteiro relativo ao corpo da
 * coluna. Faz o snap de 15 (sugestão, A-D1 — não é regra no servidor) e clampa em
 * `[range.start, range.end - dur]` para o bloco caber inteiro na faixa desenhada.
 *
 * Fiel a duas regras do protótipo: o snap de 15 min ([`:1248`]) e "a data nunca muda" — este
 * cálculo é só do eixo Y (o eixo X troca de coluna, resolvido no componente).
 */
export function dropMinutes(
	y: number,
	bodyTop: number,
	range: DragRange,
	ppm: number,
	pad: number,
	durMin: number,
	snap = 15
): number {
	const bruto = range.start + (y - bodyTop - pad) / ppm;
	const snapped = Math.round(bruto / snap) * snap;
	const teto = Math.max(range.start, range.end - durMin);
	return Math.max(range.start, Math.min(teto, snapped));
}

/**
 * Um movimento vira arraste só depois de passar o limiar (protótipo: um "threshold" implícito
 * pelo `pointermove`). Sem ele, um clique com o dedo trêmulo remarcaria o bloco em vez de abrir
 * o drawer — o clique e o arraste começam com o mesmo `pointerdown`.
 */
export function passouLimiar(dx: number, dy: number, limiar = 4): boolean {
	return Math.abs(dx) > limiar || Math.abs(dy) > limiar;
}
