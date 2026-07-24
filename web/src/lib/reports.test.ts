import { describe, it, expect } from 'vitest';
import {
	parsePeriod,
	periodWindow,
	barPct,
	sharePct,
	maxTotal,
	showDaily,
	fmtDayMonth,
	rangeLabel,
	professionalName,
	professionalById,
	typeById,
	type ReportProfessional,
	type ReportType,
	type DayPoint
} from './reports';

// 2026-06-17 é uma quarta; a semana ISO é 15/06 (seg) – 21/06 (dom). O mês é junho inteiro.
const QUARTA = '2026-06-17';

describe('parsePeriod', () => {
	it('aceita os presets e cai em "mes" para lixo/ausente', () => {
		expect(parsePeriod('hoje')).toBe('hoje');
		expect(parsePeriod('semana')).toBe('semana');
		expect(parsePeriod('mes')).toBe('mes');
		expect(parsePeriod('trimestre')).toBe('trimestre');
		expect(parsePeriod('ontem')).toBe('mes');
		expect(parsePeriod(null)).toBe('mes');
	});
});

describe('periodWindow', () => {
	it('hoje é o próprio dia', () => {
		expect(periodWindow('hoje', QUARTA)).toEqual({ from: QUARTA, to: QUARTA });
	});

	it('semana é segunda–sábado (pula o domingo, como o protótipo)', () => {
		expect(periodWindow('semana', QUARTA)).toEqual({ from: '2026-06-15', to: '2026-06-20' });
	});

	it('mes é o mês corrente inteiro', () => {
		expect(periodWindow('mes', QUARTA)).toEqual({ from: '2026-06-01', to: '2026-06-30' });
	});

	it('trimestre é a janela móvel de 90 dias corridos terminando hoje', () => {
		// 2026-06-17 recuado 89 dias = 2026-03-20; `to` é o próprio hoje.
		expect(periodWindow('trimestre', QUARTA)).toEqual({ from: '2026-03-20', to: QUARTA });
	});
});

describe('proporções das barras', () => {
	it('barPct é relativo ao maior valor da série, 0 sem divisão por zero', () => {
		expect(barPct(5, 10)).toBe(50);
		expect(barPct(10, 10)).toBe(100);
		expect(barPct(3, 0)).toBe(0);
	});

	it('sharePct é a fatia do total, 0 quando total é 0', () => {
		expect(sharePct(25, 100)).toBe(25);
		expect(sharePct(1, 3)).toBe(33);
		expect(sharePct(5, 0)).toBe(0);
	});

	it('maxTotal pega o maior total; vazio é 0', () => {
		expect(maxTotal([{ total: 2 }, { total: 9 }, { total: 4 }])).toBe(9);
		expect(maxTotal([])).toBe(0);
	});
});

describe('showDaily', () => {
	it('é por dia só com mais de um dia na janela', () => {
		const um: DayPoint[] = [{ date: '2026-06-17', total: 3, concluidos: 1 }];
		const dois: DayPoint[] = [...um, { date: '2026-06-18', total: 1, concluidos: 0 }];
		expect(showDaily(um)).toBe(false);
		expect(showDaily(dois)).toBe(true);
	});
});

describe('formatação e lookup', () => {
	it('fmtDayMonth vira DD/MM sem tocar em fuso', () => {
		expect(fmtDayMonth('2026-06-01')).toBe('01/06');
	});

	it('rangeLabel mostra um dia só ou o intervalo', () => {
		expect(rangeLabel({ from: '2026-06-17', to: '2026-06-17' })).toBe('17/06');
		expect(rangeLabel({ from: '2026-06-01', to: '2026-06-30' })).toBe('01/06 – 30/06');
	});

	it('professionalName remove o "Dra." e cai num traço se o id sumir', () => {
		const profs: ReportProfessional[] = [{ id: 'p1', nome: 'Dra. Bea', cor_indice: 1 }];
		expect(professionalName(profs, 'p1')).toBe('Bea');
		expect(professionalName(profs, 'x')).toBe('—');
		expect(professionalById(profs, 'p1')?.nome).toBe('Dra. Bea');
	});

	it('typeById acha o tipo pelo id', () => {
		const types: ReportType[] = [{ id: 't1', nome: 'Fisio', cor: '#0FB5A6' }];
		expect(typeById(types, 't1')?.nome).toBe('Fisio');
		expect(typeById(types, 'x')).toBeUndefined();
	});
});
