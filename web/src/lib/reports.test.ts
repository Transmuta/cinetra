import { describe, it, expect } from 'vitest';
import {
	parsePeriod,
	periodWindow,
	barPct,
	sharePct,
	maxTotal,
	volumeMode,
	weekdayIndex,
	weekStart,
	calendarGrid,
	firstCell,
	nextCell,
	heatLevel,
	weekdayAverage,
	fmtDayMonth,
	fmtWeekday,
	rangeLabel,
	professionalName,
	professionalById,
	typeById,
	type ReportProfessional,
	type ReportType,
	type DayPoint
} from './reports';
import { shiftDate } from './agenda';

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

// Uma janela de dias corridos a partir de `from`. Domingo fecha (o seed da clínica: `dow 0`
// sem períodos), que é o que separa "fechado" de "aberto e vazio" na grade.
function janela(from: string, dias: number, totals: Record<string, number> = {}): DayPoint[] {
	return Array.from({ length: dias }, (_, i) => {
		const date = shiftDate(from, i);
		const total = totals[date] ?? 0;
		return { date, total, concluidos: total, aberto: weekdayIndex(date) !== 6 };
	});
}

describe('volumeMode', () => {
	it('um dia só degenera e a tela mostra "por profissional"', () => {
		expect(volumeMode(janela('2026-06-17', 1))).toBe('profissional');
	});

	it('janela curta (o preset "semana") são barras por dia', () => {
		expect(volumeMode(janela('2026-06-15', 2))).toBe('semana');
		expect(volumeMode(janela('2026-06-15', 6))).toBe('semana');
		expect(volumeMode(janela('2026-06-15', 8))).toBe('semana');
	});

	// A partir daqui a barra vertical vira fio de cabelo (90 barras num cartão de ~970px dão
	// menos de 5px cada); o calendário tem célula de tamanho fixo e não depende da largura.
	it('janela longa (mês, trimestre) vira calendário', () => {
		expect(volumeMode(janela('2026-06-01', 9))).toBe('calendario');
		expect(volumeMode(janela('2026-06-01', 30))).toBe('calendario');
		expect(volumeMode(janela('2026-03-20', 90))).toBe('calendario');
	});

	it('janela vazia não quebra', () => {
		expect(volumeMode([])).toBe('profissional');
	});
});

describe('semana ISO', () => {
	it('weekdayIndex é 0=segunda … 6=domingo, sem tocar no fuso do browser', () => {
		expect(weekdayIndex('2026-06-15')).toBe(0); // segunda
		expect(weekdayIndex('2026-06-17')).toBe(2); // quarta
		expect(weekdayIndex('2026-06-20')).toBe(5); // sábado
		expect(weekdayIndex('2026-06-21')).toBe(6); // domingo
	});

	it('weekStart é a segunda da semana; domingo recua 6, não 0', () => {
		expect(weekStart('2026-06-17')).toBe('2026-06-15');
		expect(weekStart('2026-06-15')).toBe('2026-06-15');
		expect(weekStart('2026-06-21')).toBe('2026-06-15');
	});
});

describe('calendarGrid', () => {
	it('empilha a janela em colunas de semana e linhas de dia-da-semana', () => {
		// 01/06/2026 é uma segunda; 14 dias fecham duas semanas cheias.
		const grid = calendarGrid(janela('2026-06-01', 14, { '2026-06-03': 7 }));

		expect(grid.weeks.map((w) => w.start)).toEqual(['2026-06-01', '2026-06-08']);
		// Domingo fica de fora: nenhum domingo da janela está aberto nem tem atendimento.
		expect(grid.weekdays).toEqual([0, 1, 2, 3, 4, 5]);
		expect(grid.weeks[0].days).toHaveLength(6);
		expect(grid.weeks[0].days[2]?.date).toBe('2026-06-03');
		expect(grid.max).toBe(7);
	});

	it('a janela que começa no meio da semana deixa buraco ANTES do primeiro dia', () => {
		// Quarta: as células de segunda e terça não existem na janela (≠ existir e estar fechada).
		const grid = calendarGrid(janela('2026-06-17', 10));

		expect(grid.weeks[0].start).toBe('2026-06-15');
		expect(grid.weeks[0].days[0]).toBeNull();
		expect(grid.weeks[0].days[1]).toBeNull();
		expect(grid.weeks[0].days[2]?.date).toBe('2026-06-17');
	});

	it('domingo entra como linha se algum domingo da janela tiver atendimento', () => {
		const dias = janela('2026-06-01', 14, { '2026-06-07': 2 });
		expect(calendarGrid(dias).weekdays).toEqual([0, 1, 2, 3, 4, 5, 6]);
	});

	it('clínica sem expediente nenhum ainda desenha as linhas da janela', () => {
		const dias = janela('2026-06-01', 7).map((d) => ({ ...d, aberto: false }));
		expect(calendarGrid(dias).weekdays).toEqual([0, 1, 2, 3, 4, 5, 6]);
	});

	it('o cabeçalho agrupa as colunas por mês, na ordem das semanas', () => {
		// 25/05 (segunda) a 21/06: a virada de mês cai dentro da semana de 25/05.
		const grid = calendarGrid(janela('2026-05-25', 28));

		expect(grid.months.map((m) => m.label)).toEqual(['mai', 'jun']);
		expect(grid.months.map((m) => m.span)).toEqual([1, 3]);
		expect(grid.months.reduce((n, m) => n + m.span, 0)).toBe(grid.weeks.length);
	});

	it('janela que cruza o ano carimba o ano no rótulo do mês', () => {
		const grid = calendarGrid(janela('2026-12-21', 21));
		expect(grid.months.map((m) => m.label)).toEqual(['dez/26', 'jan/27']);
	});

	it('janela vazia devolve grade vazia, sem divisão por zero', () => {
		expect(calendarGrid([])).toEqual({ weekdays: [], weeks: [], months: [], max: 0 });
	});

	// A janela que COMEÇA num dia escondido da grade. 14/06/2026 é domingo, e domingo é a linha
	// que some quando fica fechado e vazio — então a primeira coluna de semana não tem nenhuma
	// célula visível. Era `undefined.date` em `monthSpans`, e a tela inteira caía em 500: o preset
	// padrão (`mes`) começa num sábado ou domingo em 4 dos 12 meses de 2026, agosto entre eles.
	it('a semana sem nenhuma célula visível não vira coluna — e não derruba a grade', () => {
		const grid = calendarGrid(janela('2026-06-14', 30));

		// A coluna de 08/06 (só o domingo 14/06, escondido) não entra; a grade começa em 15/06.
		expect(grid.weeks[0].start).toBe('2026-06-15');
		expect(grid.weeks.every((w) => w.days.some((d) => d !== null))).toBe(true);
		// O cabeçalho de meses continua somando exatamente as colunas desenhadas.
		expect(grid.months.reduce((n, m) => n + m.span, 0)).toBe(grid.weeks.length);
	});
});

describe('navegação pela grade', () => {
	// Quarta 17/06 a domingo 05/07 — três colunas de semana, e a primeira com buraco em seg e ter.
	const grid = calendarGrid(janela('2026-06-17', 19));

	it('o foco pousa na primeira célula que existe, em ordem de leitura', () => {
		// Linha de segunda (row 0) só existe a partir da segunda coluna.
		expect(firstCell(grid)).toEqual({ week: 1, row: 0 });
	});

	it('a seta anda de semana e de linha, e para na borda', () => {
		expect(nextCell(grid, { week: 1, row: 0 }, 1, 0)).toEqual({ week: 2, row: 0 });
		expect(nextCell(grid, { week: 2, row: 0 }, 1, 0)).toEqual({ week: 2, row: 0 });
		expect(nextCell(grid, { week: 1, row: 0 }, 0, 1)).toEqual({ week: 1, row: 1 });
		expect(nextCell(grid, { week: 1, row: 0 }, 0, -1)).toEqual({ week: 1, row: 0 });
	});

	it('pula o buraco em vez de parar nele — senão o foco se perde', () => {
		// Voltando de qua/semana-2 para a esquerda: qua/semana-1 existe (17/06).
		expect(nextCell(grid, { week: 1, row: 2 }, -1, 0)).toEqual({ week: 0, row: 2 });
		// Mas em seg/ter a primeira coluna é buraco: o passo não tem para onde ir e fica.
		expect(nextCell(grid, { week: 1, row: 0 }, -1, 0)).toEqual({ week: 1, row: 0 });
	});

	it('grade vazia não navega para lugar nenhum', () => {
		const vazia = calendarGrid([]);
		expect(firstCell(vazia)).toEqual({ week: 0, row: 0 });
		expect(nextCell(vazia, { week: 0, row: 0 }, 1, 0)).toEqual({ week: 0, row: 0 });
	});
});

describe('heatLevel', () => {
	it('reparte 1–4 contra o maior dia; zero é nível 0', () => {
		expect(heatLevel(0, 20)).toBe(0);
		expect(heatLevel(1, 20)).toBe(1);
		expect(heatLevel(5, 20)).toBe(1);
		expect(heatLevel(6, 20)).toBe(2);
		expect(heatLevel(15, 20)).toBe(3);
		expect(heatLevel(20, 20)).toBe(4);
	});

	it('um único atendimento no período nunca some no nível 0', () => {
		expect(heatLevel(1, 1)).toBe(4);
		expect(heatLevel(1, 0)).toBe(0); // max 0 é série vazia, não divisão por zero
	});
});

describe('weekdayAverage', () => {
	it('é a média sobre os dias ABERTOS da linha, com uma casa', () => {
		const dias = janela('2026-06-01', 14, { '2026-06-01': 5, '2026-06-08': 2 });
		const grid = calendarGrid(dias);
		// Linha de segunda: 5 e 2 em dois dias abertos.
		expect(weekdayAverage(grid.weeks.map((w) => w.days[0]))).toBe(3.5);
	});

	it('dia fechado não entra no denominador — senão o sábado meia-jornada some', () => {
		const dias: (DayPoint | null)[] = [
			{ date: '2026-06-06', total: 4, concluidos: 4, aberto: true },
			{ date: '2026-06-13', total: 0, concluidos: 0, aberto: false },
			null
		];
		expect(weekdayAverage(dias)).toBe(4);
	});

	it('linha sem nenhum dia aberto não tem média', () => {
		expect(weekdayAverage([null])).toBeNull();
		expect(
			weekdayAverage([{ date: '2026-06-07', total: 0, concluidos: 0, aberto: false }])
		).toBeNull();
	});
});

describe('formatação e lookup', () => {
	it('fmtDayMonth vira DD/MM sem tocar em fuso', () => {
		expect(fmtDayMonth('2026-06-01')).toBe('01/06');
	});

	it('fmtWeekday nomeia o dia da semana em três letras', () => {
		expect(fmtWeekday('2026-06-15')).toBe('seg');
		expect(fmtWeekday('2026-06-20')).toBe('sáb');
		expect(fmtWeekday('2026-06-21')).toBe('dom');
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
