import { describe, it, expect } from 'vitest';
import {
	VIEWS,
	parseView,
	viewRendersCounts,
	shiftByView,
	viewLabel,
	weekDays,
	monthGrid,
	monthWindow,
	occupancyRate,
	occupancyTone,
	dayTotals,
	type DayCount
} from './agenda-views';

// 2026-06-25 é quinta-feira — a data que o protótipo cravava como "hoje".
const QUI = '2026-06-25';

describe('parseView', () => {
	it('aceita as quatro visões', () => {
		for (const v of VIEWS) expect(parseView(v)).toBe(v);
	});

	it('cai em "dia" para lixo, vazio e ausente', () => {
		expect(parseView('semanal')).toBe('dia');
		expect(parseView('')).toBe('dia');
		expect(parseView(null)).toBe('dia');
		expect(parseView(undefined)).toBe('dia');
	});
});

describe('viewRendersCounts', () => {
	// É o que decide, no tempo real, entre remendar um bloco e recarregar a contagem. Semana e
	// Mês renderizam `data.days` (barras agregadas), não a lista de blocos — um bloco chegando
	// por evento não muda a barra, então o evento tem de virar refetch. Dia e Lista renderizam
	// os blocos e remendam. Errar isto foi o bug: a Semana assinava tópicos de dia, recebia o
	// bloco, o remendava num store que ela não mostra, e a barra ficava congelada.
	it('Semana e Mês renderizam contagem (→ refetch)', () => {
		expect(viewRendersCounts('semana')).toBe(true);
		expect(viewRendersCounts('mes')).toBe(true);
	});

	it('Dia e Lista renderizam blocos (→ patch)', () => {
		expect(viewRendersCounts('dia')).toBe(false);
		expect(viewRendersCounts('lista')).toBe(false);
	});
});

describe('shiftByView', () => {
	it('anda ±1 dia em Dia e em Lista', () => {
		expect(shiftByView(QUI, 'dia', 1)).toBe('2026-06-26');
		expect(shiftByView(QUI, 'lista', -1)).toBe('2026-06-24');
	});

	it('anda ±7 dias na Semana', () => {
		expect(shiftByView(QUI, 'semana', 1)).toBe('2026-07-02');
		expect(shiftByView(QUI, 'semana', -1)).toBe('2026-06-18');
	});

	it('anda ±1 mês no Mês', () => {
		expect(shiftByView(QUI, 'mes', 1)).toBe('2026-07-25');
		expect(shiftByView(QUI, 'mes', -1)).toBe('2026-05-25');
	});

	// O protótipo usava `setMonth`, que transborda: 31/jan + 1 mês vira 03/mar. Uma seta que
	// pula fevereiro inteiro é a diferença entre navegar e se perder.
	it('grampeia no último dia do mês de destino em vez de transbordar', () => {
		expect(shiftByView('2026-01-31', 'mes', 1)).toBe('2026-02-28');
		expect(shiftByView('2026-03-31', 'mes', -1)).toBe('2026-02-28');
		expect(shiftByView('2028-01-31', 'mes', 1)).toBe('2028-02-29');
	});
});

describe('weekDays', () => {
	it('devolve 7 dias, de segunda a domingo (A-D11: domingo existe)', () => {
		expect(weekDays(QUI)).toEqual([
			'2026-06-22',
			'2026-06-23',
			'2026-06-24',
			'2026-06-25',
			'2026-06-26',
			'2026-06-27',
			'2026-06-28'
		]);
	});

	it('trata o próprio domingo como o ÚLTIMO dia da semana, não o primeiro', () => {
		// 2026-06-28 é domingo: a semana dele começa em 22/06, não em 28/06.
		expect(weekDays('2026-06-28')[0]).toBe('2026-06-22');
		expect(weekDays('2026-06-28')[6]).toBe('2026-06-28');
	});

	it('atravessa a virada de mês', () => {
		expect(weekDays('2026-07-01')).toEqual([
			'2026-06-29',
			'2026-06-30',
			'2026-07-01',
			'2026-07-02',
			'2026-07-03',
			'2026-07-04',
			'2026-07-05'
		]);
	});
});

describe('monthGrid', () => {
	it('começa no domingo anterior ao dia 1 e cobre o mês inteiro', () => {
		const grid = monthGrid('2026-06-10');
		expect(grid[0].date).toBe('2026-05-31'); // domingo antes de 01/06 (segunda)
		expect(grid[0].inMonth).toBe(false);
		expect(grid.some((c) => c.date === '2026-06-01' && c.inMonth)).toBe(true);
		expect(grid.some((c) => c.date === '2026-06-30' && c.inMonth)).toBe(true);
	});

	it('devolve sempre semanas inteiras, e só as usadas', () => {
		for (const d of ['2026-02-10', '2026-06-10', '2026-08-10', '2028-02-10']) {
			const grid = monthGrid(d);
			expect(grid.length % 7).toBe(0);
			expect(grid.length).toBeGreaterThanOrEqual(28);
			expect(grid.length).toBeLessThanOrEqual(42);
		}
	});

	it('marca 30 dias no mês para junho e 28 para fevereiro', () => {
		expect(monthGrid('2026-06-10').filter((c) => c.inMonth)).toHaveLength(30);
		expect(monthGrid('2026-02-10').filter((c) => c.inMonth)).toHaveLength(28);
		expect(monthGrid('2028-02-10').filter((c) => c.inMonth)).toHaveLength(29);
	});

	// Fevereiro de 2026 começa num domingo e tem 28 dias: cabe em 4 linhas exatas. É o caso
	// que `usedWeeks` existe para pegar — uma quinta linha inteira fora do mês.
	it('não desenha linha sobrando quando o mês fecha certo', () => {
		expect(monthGrid('2026-02-10')).toHaveLength(28);
	});
});

// A janela que o servidor carrega para o Mês é o MÊS, não a grade — a grade chega a 42
// células e o teto do servidor é 31 dias.
describe('monthWindow', () => {
	it('vai do dia 1 ao último dia do mês', () => {
		expect(monthWindow('2026-07-15')).toEqual({ from: '2026-07-01', to: '2026-07-31' });
		expect(monthWindow('2026-06-10')).toEqual({ from: '2026-06-01', to: '2026-06-30' });
	});

	it('respeita fevereiro, inclusive bissexto', () => {
		expect(monthWindow('2026-02-10')).toEqual({ from: '2026-02-01', to: '2026-02-28' });
		expect(monthWindow('2028-02-10')).toEqual({ from: '2028-02-01', to: '2028-02-29' });
	});

	// O teto do servidor é `Date.diff >= 31` → 422. Um mês de 31 dias dá diff 30 e passa
	// raspando; é a asserção que impede alguém "arredondar" a janela para 32 dias.
	it('nunca ultrapassa o teto de 31 dias do servidor', () => {
		for (const mes of ['2026-01', '2026-02', '2026-04', '2026-07', '2026-12']) {
			const { from, to } = monthWindow(`${mes}-10`);
			const dias = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000;
			expect(dias).toBeLessThan(31);
		}
	});
});

describe('viewLabel', () => {
	it('Dia e Lista mostram o dia por extenso, com sufixo quando é hoje', () => {
		expect(viewLabel(QUI, QUI, 'dia')).toBe('quinta-feira, 25 de junho · hoje');
		expect(viewLabel(QUI, '2026-06-26', 'lista')).toBe('quinta-feira, 25 de junho');
	});

	it('Semana mostra o intervalo de segunda a domingo', () => {
		expect(viewLabel(QUI, '2020-01-01', 'semana')).toBe('22 jun. – 28 jun.');
		expect(viewLabel('2026-07-01', '2020-01-01', 'semana')).toBe('29 jun. – 5 jul.');
	});

	it('Mês mostra mês e ano', () => {
		expect(viewLabel(QUI, '2020-01-01', 'mes')).toBe('junho de 2026');
	});

	// No protótipo o "· hoje" comparava a data exata, então a semana que CONTÉM hoje não
	// ganhava o sufixo — a marca some justamente na visão em que ela mais informa.
	it('marca "· hoje" quando o intervalo contém hoje, não só quando a data bate', () => {
		expect(viewLabel('2026-06-22', QUI, 'semana')).toBe('22 jun. – 28 jun. · hoje');
		expect(viewLabel('2026-06-01', QUI, 'mes')).toBe('junho de 2026 · hoje');
		expect(viewLabel('2026-06-15', '2026-07-01', 'semana')).toBe('15 jun. – 21 jun.');
	});
});

describe('occupancyRate (A-D12)', () => {
	it('é minutos ocupados ÷ minutos de expediente real', () => {
		expect(occupancyRate(240, 480)).toBe(0.5);
		expect(occupancyRate(0, 480)).toBe(0);
	});

	// Sem clamp: sobrecarga é informação. Com clamp em 100% a tela esconde exatamente o dia
	// que precisa de atenção.
	it('passa de 100% sem grampear', () => {
		expect(occupancyRate(600, 480)).toBe(1.25);
		expect(occupancyTone(1.25)).toBe('over');
	});

	it('devolve null quando não há expediente — dia fechado não é dia com 0%', () => {
		expect(occupancyRate(0, 0)).toBeNull();
		expect(occupancyRate(50, 0)).toBeNull();
		expect(occupancyTone(null)).toBe('closed');
	});

	it('separa vazio, normal e sobrecarga', () => {
		expect(occupancyTone(0)).toBe('empty');
		expect(occupancyTone(0.5)).toBe('normal');
		expect(occupancyTone(1)).toBe('normal');
	});
});

describe('dayTotals', () => {
	const dias: DayCount[] = [
		{
			date: QUI,
			professionals: [
				{
					professional_id: 'p1',
					total: 3,
					ocupado_minutos: 150,
					capacidade_minutos: 480
				},
				{
					professional_id: 'p2',
					total: 1,
					ocupado_minutos: 50,
					capacidade_minutos: 240
				}
			]
		},
		{ date: '2026-06-26', professionals: [] }
	];

	it('soma os profissionais do dia', () => {
		const [qui] = dayTotals(dias, []);
		expect(qui).toEqual({
			date: QUI,
			total: 4,
			ocupado_minutos: 200,
			capacidade_minutos: 720,
			rate: 200 / 720
		});
	});

	// É a razão de o endpoint quebrar por profissional (B-D2): ocultar alguém na sidebar tem
	// de mexer na barra, senão a Semana passa a discordar do Dia sobre o mesmo dia.
	it('ignora os profissionais ocultos, no numerador E no denominador', () => {
		const [qui] = dayTotals(dias, ['p2']);
		expect(qui.total).toBe(3);
		expect(qui.ocupado_minutos).toBe(150);
		expect(qui.capacidade_minutos).toBe(480);
	});

	it('dia sem nenhum profissional com expediente vira fechado, não 0%', () => {
		const [, sex] = dayTotals(dias, []);
		expect(sex.total).toBe(0);
		expect(sex.rate).toBeNull();
	});

	it('ocultar todo mundo fecha o dia em vez de zerá-lo', () => {
		const [qui] = dayTotals(dias, ['p1', 'p2']);
		expect(qui.rate).toBeNull();
	});
});
