import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { log, sanitizarRota, truncar } from './log';

describe('sanitizarRota — a barreira de identificador', () => {
	// Espelha `ApiWeb.RequestLoggerTest`. `/pacientes/<uuid>` levaria para a agregação de log o
	// único identificador que o doc 05 §1.3 proíbe exportar: ele liga o registro a um titular de
	// dado de saúde.

	it('troca UUID por :id', () => {
		expect(sanitizarRota('/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177')).toBe(
			'/pacientes/:id'
		);
	});

	it('troca UUID sem hífen', () => {
		expect(sanitizarRota('/pacientes/019f7c5b1bee7a329fadc3d6f0a83177')).toBe('/pacientes/:id');
	});

	it('troca id numérico', () => {
		expect(sanitizarRota('/relatorios/2026/7')).toBe('/relatorios/:id/:id');
	});

	it('nenhum UUID sobrevive, em qualquer posição', () => {
		const uuids = [
			'019f7c5b-1bee-7a32-9fad-c3d6f0a83177',
			'550e8400-e29b-41d4-a716-446655440000'
		];

		for (const uuid of uuids) {
			for (const path of [`/a/${uuid}`, `/${uuid}/b`, `/a/${uuid}/b/c`]) {
				expect(sanitizarRota(path)).not.toContain(uuid);
			}
		}
	});

	it('não come segmento que não é identificador', () => {
		// A barreira não pode destruir a rota: sem isto o log perderia o que justifica existir.
		expect(sanitizarRota('/agenda')).toBe('/agenda');
		expect(sanitizarRota('/configuracoes/equipe')).toBe('/configuracoes/equipe');
		expect(sanitizarRota('/')).toBe('/');
	});
});

describe('truncar', () => {
	it('deixa passar o que cabe', () => {
		expect(truncar('curto', 100)).toBe('curto');
	});

	it('corta e marca quanto sobrou', () => {
		// Um stack trace de browser tem dezenas de KB; sem teto, um erro em laço encheria a
		// retenção do dia.
		const resultado = truncar('x'.repeat(50), 10);
		expect(resultado).toContain('[+40]');
		expect(resultado.length).toBeLessThan(30);
	});

	it('aguenta não-string sem estourar', () => {
		expect(truncar(null, 10)).toBe('');
		expect(truncar(undefined, 10)).toBe('');
		expect(truncar(42, 10)).toBe('42');
	});
});

describe('log', () => {
	let saida: string[];

	beforeEach(() => {
		saida = [];
		vi.spyOn(console, 'log').mockImplementation((linha: string) => void saida.push(linha));
	});

	afterEach(() => vi.restoreAllMocks());

	it('emite UMA linha de JSON válido por evento', () => {
		log.error('deu ruim', { route: '/agenda' });

		expect(saida).toHaveLength(1);
		expect(saida[0]).not.toContain('\n');

		const evento = JSON.parse(saida[0]);
		expect(evento.severity).toBe('error');
		expect(evento.service).toBe('web');
		expect(evento.message).toBe('deu ruim');
		expect(evento.route).toBe('/agenda');
		expect(evento.time).toMatch(/^\d{4}-\d{2}-\d{2}T/);
	});

	it('mensagem gigante não vira linha gigante', () => {
		log.info('y'.repeat(5000));

		const evento = JSON.parse(saida[0]);
		expect(evento.message.length).toBeLessThan(600);
	});
});
