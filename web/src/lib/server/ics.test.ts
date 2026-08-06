import { describe, it, expect } from 'vitest';
import { eventoIcs, uidDeSessao } from './ics';

/**
 * O arquivo que o paciente baixa quando toca em "adicionar à agenda" na tela de confirmação.
 *
 * O formato é chato de um jeito específico: quem lê do outro lado é o app de calendário do
 * celular (Apple Calendar, Google Agenda), e ele **não perdoa** — linha terminada em LF sozinho,
 * vírgula não escapada ou linha longa demais produzem "arquivo inválido" sem dizer onde. Por isso
 * as regras do RFC 5545 estão testadas aqui uma a uma, e não conferidas no olho.
 */

const EVENTO = {
	uid: 'abc123@cinetra',
	inicio: '2026-08-05T11:30:00Z',
	fim: '2026-08-05T12:20:00Z',
	titulo: 'Sessão na Clínica Moving',
	descricao: 'Chegue com 10 minutos de antecedência.',
	agora: '2026-08-04T18:00:00Z'
};

const linhas = (texto: string) => texto.split('\r\n');

describe('eventoIcs', () => {
	it('monta um VCALENDAR mínimo e válido', () => {
		const out = linhas(eventoIcs(EVENTO));

		expect(out[0]).toBe('BEGIN:VCALENDAR');
		expect(out).toContain('VERSION:2.0');
		expect(out).toContain('BEGIN:VEVENT');
		expect(out).toContain('END:VEVENT');
		expect(out[out.length - 1]).toBe('END:VCALENDAR');
	});

	it('escreve os instantes em UTC compacto — sem VTIMEZONE para dar errado', () => {
		// `...Z` é a única forma que dispensa declarar o fuso dentro do arquivo. Como a API já
		// devolve o instante em UTC, declarar um VTIMEZONE aqui seria uma segunda fonte de verdade
		// sobre horário de verão, com o app do celular decidindo qual das duas obedecer.
		const out = linhas(eventoIcs(EVENTO));

		expect(out).toContain('DTSTART:20260805T113000Z');
		expect(out).toContain('DTEND:20260805T122000Z');
		expect(out).toContain('DTSTAMP:20260804T180000Z');
	});

	it('termina toda linha em CRLF — LF sozinho é arquivo inválido', () => {
		const texto = eventoIcs(EVENTO);

		expect(texto).toMatch(/\r\n/);
		// Nenhum LF desacompanhado de CR.
		expect(texto.replace(/\r\n/g, '')).not.toMatch(/\n/);
	});

	it('escapa vírgula, ponto-e-vírgula, contrabarra e quebra de linha do texto livre', () => {
		// Nome de clínica é texto digitado no balcão: "Reabilitar, Corpo & Movimento" já basta.
		const texto = eventoIcs({
			...EVENTO,
			titulo: 'Sessão na Reabilitar, Corpo; Movimento\\Sul',
			descricao: 'Linha 1\nLinha 2'
		});

		expect(texto).toContain('SUMMARY:Sessão na Reabilitar\\, Corpo\\; Movimento\\\\Sul');
		expect(texto).toContain('DESCRIPTION:Linha 1\\nLinha 2');
	});

	it('dobra linha acima de 75 octetos, continuando com espaço', () => {
		const texto = eventoIcs({ ...EVENTO, descricao: 'a'.repeat(200) });

		for (const linha of linhas(texto)) {
			// O limite do RFC é em OCTETOS, não em caracteres: "sessão" ocupa 7 bytes em 6 letras.
			expect(new TextEncoder().encode(linha).length).toBeLessThanOrEqual(75);
		}
		// A continuação é marcada por um espaço no começo da linha seguinte.
		expect(texto).toMatch(/\r\n /);
	});

	it('não dobra no meio de um caractere multibyte', () => {
		// Cortar entre os dois bytes de "ç" produz um arquivo que o app abre como lixo — e o teste
		// acima, que só mede o tamanho, passaria feliz.
		const texto = eventoIcs({ ...EVENTO, descricao: 'çã'.repeat(80) });

		expect(texto).toContain('çã');
		expect(texto).not.toContain('�');
	});

	it('omite o que não existe em vez de escrever campo vazio', () => {
		const texto = eventoIcs({ ...EVENTO, descricao: undefined, local: undefined });

		expect(texto).not.toContain('DESCRIPTION:');
		expect(texto).not.toContain('LOCATION:');
	});
});

describe('uidDeSessao', () => {
	it('é estável para o mesmo link — remarcar ATUALIZA o evento, não cria um segundo', () => {
		expect(uidDeSessao('tok-123')).toBe(uidDeSessao('tok-123'));
	});

	it('não carrega o token dentro — o .ics vai parar em calendário compartilhado', () => {
		const uid = uidDeSessao('tok-123');

		expect(uid).not.toContain('tok-123');
		expect(uid).toMatch(/^[0-9a-f]{16}@cinetra$/);
	});

	it('links diferentes dão uids diferentes', () => {
		expect(uidDeSessao('tok-123')).not.toBe(uidDeSessao('tok-124'));
	});
});
