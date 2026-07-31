import { describe, it, expect } from 'vitest';
import { DOW_LABELS, diaMes, diaSemana, quandoCurto, quandoComAno, quandoSemDia } from './data-hora';

/**
 * Estas cinco funções nasceram como **cinco cópias em cinco componentes** (doc 93 §B-1): duas
 * byte-idênticas (`PatientUpcoming` e `PatientHistory`), duas variantes do formato "dow dd/mm",
 * e três listas de dia da semana com três nomes (`DOW`, `DOW_UTC`, `DOW_CURTO`) — enquanto
 * `DOW_LABELS` já existia e o `PackageCreateModal` chegava a importá-la na linha 33 e declarar a
 * sua própria na 278.
 *
 * O custo não era estético: morando em `.svelte`, nenhuma delas estava no gate de cobertura
 * (`vite.config.ts` inclui `src/lib/**` e exclui `.svelte`). Este arquivo é o que faz a
 * conversão "instante ISO → data e hora no fuso da clínica" passar a ser testada uma vez.
 */

// 30/07/2026 é uma quinta-feira. 11:00Z = 08:00 em São Paulo (UTC-3).
const QUINTA = '2026-07-30T11:00:00.000000Z';
const SP = 'America/Sao_Paulo';

describe('DOW_LABELS', () => {
	it('domingo primeiro, sábado por último — é indexada por getUTCDay()', () => {
		expect(DOW_LABELS).toHaveLength(7);
		expect(DOW_LABELS[0]).toBe('Dom');
		expect(DOW_LABELS[6]).toBe('Sáb');
	});
});

describe('diaSemana', () => {
	it('resolve a partir da data do calendário, não do instante', () => {
		expect(diaSemana('2026-07-30')).toBe('Qui');
		expect(diaSemana('2026-08-02')).toBe('Dom');
	});

	/**
	 * O meio-dia UTC no meio da conversão não é enfeite: `new Date('2026-07-30')` é meia-noite
	 * UTC, e em qualquer fuso a oeste isso ainda é o dia 29 — o rótulo sairia um dia atrasado.
	 */
	it('não escorrega um dia para trás', () => {
		expect(diaSemana('2026-01-01')).toBe('Qui');
		expect(diaSemana('2026-03-01')).toBe('Dom');
	});
});

describe('diaMes', () => {
	it('"AAAA-MM-DD" → "DD/MM"', () => {
		expect(diaMes('2026-07-30')).toBe('30/07');
	});
});

describe('as três formas de dizer "quando"', () => {
	it('quandoSemDia: a ficha do paciente — data cheia, sem dia da semana', () => {
		expect(quandoSemDia(QUINTA, SP)).toBe('30/07/2026 · 08:00');
	});

	it('quandoComAno: o cartão do pacote — dia da semana e ano de dois dígitos', () => {
		expect(quandoComAno(QUINTA, SP)).toBe('Qui 30/07/26 · 08:00');
	});

	it('quandoCurto: a trilha do pacote — sem ano, que a lista inteira compartilha', () => {
		expect(quandoCurto(QUINTA, SP)).toBe('Qui 30/07 · 08:00');
	});

	/** O fuso é da CLÍNICA, não do browser: a mesma linha muda de dia conforme o fuso. */
	it('converte para o fuso pedido antes de formatar', () => {
		expect(quandoSemDia('2026-07-31T02:00:00.000000Z', SP)).toBe('30/07/2026 · 23:00');
		expect(quandoCurto('2026-07-31T02:00:00.000000Z', SP)).toBe('Qui 30/07 · 23:00');
	});
});
