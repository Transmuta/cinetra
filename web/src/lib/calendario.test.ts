import { describe, it, expect } from 'vitest';
import { descricaoDaSessao, linkGoogleAgenda, tituloDaSessao, utcCompacto } from './calendario';

/**
 * O link de "adicionar ao Google Agenda", irmão do `.ics`.
 *
 * Ele existe por um motivo medido no celular: o `.ics` é **baixado**, e no Android o arquivo cai
 * em Downloads sem nada abrir — a pessoa toca no botão e não acontece nada visível. O link do
 * Google abre o app direto. O `.ics` continua para quem não é Google (iPhone, Outlook), agora
 * servido `inline` para o Safari oferecer "Adicionar ao Calendário" na hora.
 */

const EVENTO = {
	inicio: '2026-08-05T11:30:00Z',
	fim: '2026-08-05T12:20:00Z',
	titulo: 'Sessão na Clínica Moving',
	descricao: 'Sua sessão na Clínica Moving. Precisa remarcar? Fale com a clínica: (61) 99946-6274.'
};

describe('o texto do evento', () => {
	it('nomeia a clínica no título, que é o que aparece na grade do calendário', () => {
		expect(tituloDaSessao('Clínica Moving')).toBe('Sessão na Clínica Moving');
	});

	it('clínica sem nome não vira "Sessão na null"', () => {
		expect(tituloDaSessao(null)).toBe('Sessão na sua clínica');
	});

	it('põe o telefone na descrição — é a saída de quem não puder vir', () => {
		expect(descricaoDaSessao('Clínica Moving', '(61) 99946-6274')).toContain('(61) 99946-6274');
	});

	it('sem telefone não promete um contato que não existe', () => {
		const texto = descricaoDaSessao('Clínica Moving', null);

		expect(texto).toBe('Sua sessão na Clínica Moving.');
		expect(texto).not.toContain('Fale com a clínica');
	});
});

describe('utcCompacto', () => {
	it('escreve o instante na única forma que dispensa declarar fuso', () => {
		expect(utcCompacto('2026-08-05T11:30:00Z')).toBe('20260805T113000Z');
	});

	it('descarta os milissegundos, que nenhum dos dois formatos aceita', () => {
		expect(utcCompacto('2026-08-05T11:30:00.123Z')).toBe('20260805T113000Z');
	});
});

describe('linkGoogleAgenda', () => {
	it('manda o par de instantes separado por barra, que é o que o Google lê', () => {
		const url = new URL(linkGoogleAgenda(EVENTO)!);

		expect(url.origin + url.pathname).toBe('https://calendar.google.com/calendar/render');
		expect(url.searchParams.get('action')).toBe('TEMPLATE');
		// A barra fica crua de propósito: os dois lados são só dígitos, `T` e `Z`, então não há o
		// que escapar — e `%2F` aqui é o erro clássico que faz o Google abrir um evento sem horário.
		expect(url.searchParams.get('dates')).toBe('20260805T113000Z/20260805T122000Z');
	});

	it('leva o título e a descrição, que é o que a pessoa vê no calendário', () => {
		const url = new URL(linkGoogleAgenda(EVENTO)!);

		expect(url.searchParams.get('text')).toBe('Sessão na Clínica Moving');
		expect(url.searchParams.get('details')).toContain('(61) 99946-6274');
	});

	it('sem instante não há link — evento sem hora é pior que botão nenhum', () => {
		expect(linkGoogleAgenda({ ...EVENTO, inicio: null })).toBeNull();
		expect(linkGoogleAgenda({ ...EVENTO, fim: null })).toBeNull();
		expect(linkGoogleAgenda(null)).toBeNull();
	});

	it('instante que não é data devolve null em vez de explodir a tela', () => {
		// A tela monta este link no browser, dentro de um `$derived`: uma exceção aqui não daria
		// 500 num log — apagaria a página do paciente depois de ela já ter pintado.
		expect(linkGoogleAgenda({ ...EVENTO, inicio: 'nao-e-data' })).toBeNull();
	});
});
