import { describe, it, expect } from 'vitest';
import {
	patientColor,
	convLabel,
	idade,
	stripTitle,
	parseFilter,
	parsePage,
	pageLabel,
	prefNomes,
	emailValido,
	nascimentoValido,
	type Patient
} from './patients';

function patient(overrides: Partial<Patient> = {}): Patient {
	return {
		id: 'pac1', nome: 'Mariana Alves', nome_social: null, cpf: null, rg: null, genero: null,
		estado_civil: null, nascimento: null, responsavel: null, tel: null, email: null, cep: null,
		endereco: null, numero: null, complemento: null, bairro: null, cidade: null, uf: null,
		emergencia_nome: null, emergencia_parentesco: null, emergencia_tel: null, profissao: null,
		empresa: null, atend_tipo: 'particular', convenio: null, carteirinha: null,
		convenio_validade: null, medico: null, crm: null, como_conheceu: null, prefs: [], tags: [],
		lgpd: false, comunicacao: false, cor_indice: 1, ativo: true,
		...overrides
	};
}

describe('patientColor', () => {
	it('mapeia o índice 1-based na paleta (mesma do avatar do profissional)', () => {
		// A entrada 1 é o sage da marca desde a ADR-021 (era o teal `#0FB5A6` do protótipo).
		expect(patientColor(1)).toBe('#7FA59A');
		expect(patientColor(2)).toBe('#0072B2');
	});
	it('faz wrap além de 7 e tolera 0/negativos', () => {
		expect(patientColor(8)).toBe(patientColor(1));
		expect(patientColor(0)).toBe(patientColor(7));
	});
});

describe('convLabel', () => {
	it('convênio mostra o nome do plano', () => {
		expect(convLabel(patient({ atend_tipo: 'convenio', convenio: 'Unimed' }))).toBe('Unimed');
	});
	it('convênio sem nome cai no rótulo genérico', () => {
		expect(convLabel(patient({ atend_tipo: 'convenio' }))).toBe('Convênio');
	});
	it('reembolso e particular', () => {
		expect(convLabel(patient({ atend_tipo: 'reembolso' }))).toBe('Reembolso');
		expect(convLabel(patient({ atend_tipo: 'particular' }))).toBe('Particular');
	});
});

describe('idade', () => {
	const hoje = new Date(2026, 5, 30); // 30/06/2026

	it('calcula a idade a partir da data ISO', () => {
		expect(idade('2000-01-15', hoje)).toBe(26);
	});
	it('desconta o ano quando o aniversário ainda não chegou', () => {
		expect(idade('2000-12-15', hoje)).toBe(25);
	});
	it('null/vazio/implausível → null', () => {
		expect(idade(null, hoje)).toBeNull();
		expect(idade('', hoje)).toBeNull();
		expect(idade('15/01/2000', hoje)).toBeNull(); // formato do protótipo, não ISO
	});
});

// Filtro e busca são do SERVIDOR agora (a lista é paginada) — o que sobra aqui é a leitura
// dos parâmetros da URL e o rótulo do rodapé.
describe('parseFilter', () => {
	it('aceita os segmentos conhecidos', () => {
		expect(parseFilter('ativos')).toBe('ativos');
		expect(parseFilter('inativos')).toBe('inativos');
		expect(parseFilter('resp')).toBe('resp');
	});
	it('qualquer outra coisa cai em todos', () => {
		expect(parseFilter('todos')).toBe('todos');
		expect(parseFilter('lixo')).toBe('todos');
		expect(parseFilter(null)).toBe('todos');
		expect(parseFilter(undefined)).toBe('todos');
	});
});

describe('parsePage', () => {
	it('página válida', () => expect(parsePage('3')).toBe(3));
	it('inválida/ausente/zero/negativa → 1', () => {
		expect(parsePage('0')).toBe(1);
		expect(parsePage('-2')).toBe(1);
		expect(parsePage('abc')).toBe(1);
		expect(parsePage('1.5')).toBe(1);
		expect(parsePage(null)).toBe(1);
	});
});

describe('pageLabel', () => {
	it('mostra o intervalo da página dentro do total', () => {
		expect(pageLabel({ limit: 50, offset: 0, total: 214, more: true }, 50)).toBe('1–50 de 214');
		expect(pageLabel({ limit: 50, offset: 50, total: 214, more: true }, 50)).toBe('51–100 de 214');
		expect(pageLabel({ limit: 50, offset: 200, total: 214, more: false }, 14)).toBe('201–214 de 214');
	});
	it('sem resultado devolve vazio', () => {
		expect(pageLabel({ limit: 50, offset: 0, total: 0, more: false }, 0)).toBe('');
		expect(pageLabel({ limit: 50, offset: 0, total: 10, more: false }, 0)).toBe('');
	});
});

describe('stripTitle', () => {
	it('remove Dr./Dra. do começo', () => {
		expect(stripTitle('Dra. Ana Lima')).toBe('Ana Lima');
		expect(stripTitle('Dr. Rui')).toBe('Rui');
		expect(stripTitle('Ana Lima')).toBe('Ana Lima');
	});
});

describe('prefNomes', () => {
	it('resolve ids contra o mapa e some com desconhecidos', () => {
		const p = patient({ prefs: ['p1', 'p2', 'fantasma'] });
		expect(prefNomes(p, { p1: 'Dra. Ana', p2: 'Dr. Rui' })).toEqual(['Dra. Ana', 'Dr. Rui']);
	});
	it('sem prefs → []', () => expect(prefNomes(patient(), {})).toEqual([]));
});

// AN-11 (D10): espelhos da régua do servidor (`CampoValido`) — só validam valor PRESENTE.
describe('emailValido', () => {
	it('aceita a forma mínima nome@dominio.tld', () => {
		expect(emailValido('mari@example.com')).toBe(true);
	});
	it('reprova sem @ ou sem TLD', () => {
		expect(emailValido('mari.example.com')).toBe(false);
		expect(emailValido('mari@example')).toBe(false);
		expect(emailValido('mari @example.com')).toBe(false);
	});
});

describe('nascimentoValido', () => {
	const hoje = new Date(2026, 6, 29); // 2026-07-29 local

	it('passado plausível passa; hoje passa', () => {
		expect(nascimentoValido('1990-05-20', hoje)).toBe(true);
		expect(nascimentoValido('2026-07-29', hoje)).toBe(true);
	});
	it('futuro reprova', () => {
		expect(nascimentoValido('2026-07-30', hoje)).toBe(false);
	});
	it('antes de 1900 reprova (dedo a mais no ano)', () => {
		expect(nascimentoValido('1899-12-31', hoje)).toBe(false);
	});
	it('formato torto reprova', () => {
		expect(nascimentoValido('20-05-1990', hoje)).toBe(false);
	});
});
