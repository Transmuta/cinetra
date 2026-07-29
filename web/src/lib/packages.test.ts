import { describe, it, expect } from 'vitest';
import {
	statusLabel,
	issueLabel,
	DOW_LABELS,
	gradeLabel,
	statusChip,
	isCurrent,
	activeCount,
	nextSessionOf,
	packageCode
} from './packages';

describe('statusLabel', () => {
	it('traduz cada status', () => {
		expect(statusLabel('ativo')).toBe('Ativo');
		expect(statusLabel('pausado')).toBe('Pausado');
		expect(statusLabel('cancelado')).toBe('Cancelado');
		expect(statusLabel('concluido')).toBe('Concluído');
	});

	it('desconhecido cai no próprio valor', () => {
		expect(statusLabel('outro' as never)).toBe('outro');
	});
});

describe('issueLabel', () => {
	it('ok é silencioso (string vazia)', () => {
		expect(issueLabel('ok')).toBe('');
	});

	it('os bloqueantes e o join têm rótulo', () => {
		expect(issueLabel('fora_expediente')).toMatch(/expediente/i);
		expect(issueLabel('conflito')).toMatch(/conflito/i);
		expect(issueLabel('cheia')).toMatch(/cheia/i);
		expect(issueLabel('join')).toMatch(/turma/i);
		expect(issueLabel('feriado')).toMatch(/feriado/i);
	});
});

describe('DOW_LABELS', () => {
	it('0 é domingo, 6 é sábado (convenção do projeto)', () => {
		expect(DOW_LABELS[0]).toBe('Dom');
		expect(DOW_LABELS[6]).toBe('Sáb');
	});
});

// ---------------------------------------------------------------------------
// O cartão da ficha (doc 69 §7). Estas quatro funções são o que faz o cartão RESPONDER
// ("que dias? com quem? quando é a próxima? já acabou?") em vez de só executar.
// ---------------------------------------------------------------------------

const grade = { dows: [1, 3], horarios: { '1': '08:00', '3': '09:00' }, professional_id: 'pr1' };
const profs = [
	{ id: 'pr1', nome: 'Ana Prado' },
	{ id: 'pr2', nome: 'Bruno Reis' }
];

describe('gradeLabel', () => {
	it('lista dia + horário em ordem e termina no profissional', () => {
		expect(gradeLabel(grade, profs)).toBe('Seg 08:00, Qua 09:00 · Ana Prado');
	});

	it('ordena por dia da semana mesmo com a grade fora de ordem', () => {
		const fora = { ...grade, dows: [3, 1] };
		expect(gradeLabel(fora, profs)).toMatch(/^Seg 08:00, Qua 09:00/);
	});

	it('dia sem horário aparece só com o nome do dia', () => {
		const sem = { dows: [1, 5], horarios: { '1': '08:00' }, professional_id: 'pr1' };
		expect(gradeLabel(sem, profs)).toBe('Seg 08:00, Sex · Ana Prado');
	});

	it('profissional desconhecido some do rótulo em vez de virar "undefined"', () => {
		expect(gradeLabel({ ...grade, professional_id: 'zzz' }, profs)).toBe('Seg 08:00, Qua 09:00');
	});

	it('sem grade devolve string vazia', () => {
		expect(gradeLabel(null, profs)).toBe('');
	});
});

describe('statusChip', () => {
	it('"acabando" ganha o tom de aviso e vence o "Ativo"', () => {
		const chip = statusChip({ status: 'ativo', acabando: true, restantes: 2 });
		expect(chip.label).toBe('Acabando');
		expect(chip.tone).toBe('warning');
	});

	it('pausado/cancelado/concluído mantêm o próprio rótulo', () => {
		expect(statusChip({ status: 'pausado', acabando: false, restantes: 5 }).label).toBe('Pausado');
		expect(statusChip({ status: 'cancelado', acabando: null, restantes: 0 }).label).toBe(
			'Cancelado'
		);
		expect(statusChip({ status: 'concluido', acabando: null, restantes: 0 }).label).toBe(
			'Concluído'
		);
	});

	it('ativo com 0 restantes lê "Completo" — D1: o status só muda ao arquivar', () => {
		const chip = statusChip({ status: 'ativo', acabando: false, restantes: 0 });
		expect(chip.label).toBe('Completo');
	});

	it('pausado NÃO vira "acabando" — o aviso é sobre série correndo', () => {
		expect(statusChip({ status: 'pausado', acabando: true, restantes: 1 }).label).toBe('Pausado');
	});
});

describe('isCurrent / activeCount', () => {
	it('ativo e pausado são atuais; cancelado e concluído são histórico', () => {
		expect(isCurrent('ativo')).toBe(true);
		expect(isCurrent('pausado')).toBe(true);
		expect(isCurrent('cancelado')).toBe(false);
		expect(isCurrent('concluido')).toBe(false);
	});

	it('a contagem do cabeçalho ignora os mortos (achado §6.3)', () => {
		const lista = [
			{ status: 'ativo' as const },
			{ status: 'cancelado' as const },
			{ status: 'concluido' as const },
			{ status: 'pausado' as const }
		];
		expect(activeCount(lista)).toBe(2);
	});
});

describe('packageCode', () => {
	const pk = { data_inicio: '2026-07-20', nome: 'Pilates 10' };

	it('é a sigla do tipo + ano/mês de início', () => {
		expect(packageCode(pk, { sigla: 'PIL' })).toBe('PIL-2607');
	});

	it('sem tipo, deriva a sigla do nome do pacote', () => {
		expect(packageCode(pk, undefined)).toBe('PIL-2607');
	});

	it('nome sem letras cai num prefixo estável', () => {
		expect(packageCode({ data_inicio: '2026-01-05', nome: '10' }, undefined)).toBe('PKG-2601');
	});
});

describe('nextSessionOf', () => {
	const upcoming = [
		{ id: 's1', package_id: 'k2', starts_at: '2026-07-29T11:00:00Z' },
		{ id: 's2', package_id: 'k1', starts_at: '2026-07-30T11:00:00Z' },
		{ id: 's3', package_id: 'k1', starts_at: '2026-08-03T11:00:00Z' }
	];

	it('devolve a primeira sessão daquele pacote', () => {
		expect(nextSessionOf(upcoming, 'k1')?.id).toBe('s2');
	});

	it('pacote sem próxima devolve null (e não a de outro pacote)', () => {
		expect(nextSessionOf(upcoming, 'k9')).toBeNull();
	});

	it('sessão avulsa (sem package_id) nunca é confundida com a do pacote', () => {
		const avulsa = [{ id: 'x', package_id: null, starts_at: '2026-07-29T11:00:00Z' }];
		expect(nextSessionOf(avulsa, 'k1')).toBeNull();
	});
});
