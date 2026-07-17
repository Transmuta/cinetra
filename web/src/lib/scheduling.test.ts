import { describe, it, expect } from 'vitest';
import {
	WEEKDAYS,
	defaultDayPeriods,
	appendPeriod,
	setPeriodTime,
	removePeriod,
	mirrorWeekdays,
	weekChanged,
	formatPeriods,
	formatDate,
	canManageSchedule,
	type WeekHours
} from './scheduling';

describe('WEEKDAYS', () => {
	it('vai de Segunda a Domingo, com Domingo por último (protótipo :3247)', () => {
		expect(WEEKDAYS.map((d) => d.dow)).toEqual([1, 2, 3, 4, 5, 6, 0]);
		expect(WEEKDAYS[0].label).toBe('Segunda');
		expect(WEEKDAYS[6].label).toBe('Domingo');
	});
});

describe('defaultDayPeriods', () => {
	it('abre manhã e tarde (protótipo :3245)', () => {
		expect(defaultDayPeriods()).toEqual([
			['08:00', '12:00'],
			['13:00', '18:00']
		]);
	});
});

describe('appendPeriod', () => {
	it('parte do fim do último período', () => {
		expect(appendPeriod([['08:00', '12:00']])).toEqual([
			['08:00', '12:00'],
			['12:00', '18:00']
		]);
	});

	it('lista vazia parte de 13:00', () => {
		expect(appendPeriod([])).toEqual([['13:00', '18:00']]);
	});

	it('depois das 18h sugere 19h', () => {
		expect(appendPeriod([['08:00', '19:30']])).toEqual([
			['08:00', '19:30'],
			['19:30', '19:00']
		]);
	});
});

describe('setPeriodTime', () => {
	it('muda o início sem tocar nos outros', () => {
		const p: [string, string][] = [
			['08:00', '12:00'],
			['13:00', '18:00']
		];
		expect(setPeriodTime(p, 0, 0, '09:00')).toEqual([
			['09:00', '12:00'],
			['13:00', '18:00']
		]);
	});

	it('muda o fim', () => {
		expect(setPeriodTime([['08:00', '12:00']], 0, 1, '11:00')).toEqual([['08:00', '11:00']]);
	});
});

describe('removePeriod', () => {
	it('tira o índice indicado', () => {
		expect(
			removePeriod(
				[
					['08:00', '12:00'],
					['13:00', '18:00']
				],
				0
			)
		).toEqual([['13:00', '18:00']]);
	});
});

describe('mirrorWeekdays', () => {
	it('copia segunda para 2..5 sem tocar em sábado/domingo', () => {
		const week: WeekHours = {
			'1': [['07:00', '15:00']],
			'2': [['08:00', '12:00']],
			'6': [['08:00', '10:00']],
			'0': []
		};
		const m = mirrorWeekdays(week);
		expect(m['2']).toEqual([['07:00', '15:00']]);
		expect(m['5']).toEqual([['07:00', '15:00']]);
		expect(m['6']).toEqual([['08:00', '10:00']]);
		expect(m['0']).toEqual([]);
	});

	it('sem segunda, espelha o padrão de abertura', () => {
		expect(mirrorWeekdays({})['3']).toEqual(defaultDayPeriods());
	});
});

describe('weekChanged', () => {
	const saved: WeekHours = { '1': [['08:00', '12:00']], '0': [] };

	it('igual → false', () => {
		expect(weekChanged({ '1': [['08:00', '12:00']], '0': [] }, saved)).toBe(false);
	});

	it('período diferente → true', () => {
		expect(weekChanged({ '1': [['09:00', '12:00']], '0': [] }, saved)).toBe(true);
	});

	it('dia que abriu → true', () => {
		expect(weekChanged({ '1': [['08:00', '12:00']], '0': [['10:00', '12:00']] }, saved)).toBe(true);
	});

	it('dia ausente conta como fechado', () => {
		expect(weekChanged({ '1': [['08:00', '12:00']] }, saved)).toBe(false);
	});
});

describe('formatPeriods', () => {
	it('junta os períodos', () => {
		expect(
			formatPeriods([
				['08:00', '12:00'],
				['13:00', '18:00']
			])
		).toBe('08:00–12:00, 13:00–18:00');
	});

	it('vazio → Fechado', () => {
		expect(formatPeriods([])).toBe('Fechado');
	});
});

describe('formatDate', () => {
	it('ISO → pt-BR sem recuar um dia', () => {
		expect(formatDate('2026-07-09')).toBe('09/07/2026');
	});

	it('data malformada volta como veio', () => {
		expect(formatDate('não-é-data')).toBe('não-é-data');
	});
});

describe('canManageSchedule', () => {
	it('owner/admin gerenciam; recepção/profissional não', () => {
		expect(canManageSchedule('owner')).toBe(true);
		expect(canManageSchedule('admin')).toBe(true);
		expect(canManageSchedule('recepcao')).toBe(false);
		expect(canManageSchedule('profissional')).toBe(false);
		expect(canManageSchedule(null)).toBe(false);
	});
});
