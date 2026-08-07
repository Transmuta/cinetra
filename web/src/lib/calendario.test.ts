import { describe, it, expect } from 'vitest';
import {
	descricaoDaSessao,
	ehAndroid,
	linkGoogleAgenda,
	tituloDaSessao,
	utcCompacto
} from './calendario';

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

describe('ehAndroid', () => {
	// A decisão é tomada no SERVIDOR, com o `user-agent` do request: decidir no browser faria o
	// SSR pintar um `href` e a hidratação trocá-lo por outro.
	it('reconhece o Chrome do Android', () => {
		const ua =
			'Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

		expect(ehAndroid(ua)).toBe(true);
	});

	it('não confunde o iPhone com Android — lá o `intent://` não existe', () => {
		const ua =
			'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

		expect(ehAndroid(ua)).toBe(false);
	});

	it('sem `user-agent` assume o caminho seguro (o link normal)', () => {
		expect(ehAndroid(null)).toBe(false);
		expect(ehAndroid(undefined)).toBe(false);
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

	it('no Android, envelopa em `intent://` para abrir o APP em vez do navegador', () => {
		// Medido no celular: o link `https://` normal abre o Google Agenda **web** no Chrome, não o
		// aplicativo. O `intent://` do Chrome for Android endereça o pacote direto.
		const url = linkGoogleAgenda(EVENTO, { android: true })!;

		expect(url.startsWith('intent://calendar.google.com/calendar/render?')).toBe(true);
		expect(url).toContain('package=com.google.android.calendar');
		expect(url).toContain('scheme=https');
		expect(url.endsWith(';end')).toBe(true);
	});

	it('o `intent://` leva a URL de volta como fallback — sem o app, o navegador resolve', () => {
		// Sem `browser_fallback_url`, quem não tem o app instalado (ou não usa Chrome) recebe uma
		// página de erro. Com ela, o pior caso é exatamente o comportamento de hoje.
		const url = linkGoogleAgenda(EVENTO, { android: true })!;

		const fallback = decodeURIComponent(url.match(/S\.browser_fallback_url=([^;]+);/)![1]);

		expect(fallback).toBe(linkGoogleAgenda(EVENTO));
		expect(fallback.startsWith('https://calendar.google.com/')).toBe(true);
	});

	it('fora do Android continua `https://` — `intent://` no iPhone é lixo na barra', () => {
		expect(linkGoogleAgenda(EVENTO, { android: false })!.startsWith('https://')).toBe(true);
		expect(linkGoogleAgenda(EVENTO)!.startsWith('https://')).toBe(true);
	});

	it('instante que não é data devolve null em vez de explodir a tela', () => {
		// A tela monta este link no browser, dentro de um `$derived`: uma exceção aqui não daria
		// 500 num log — apagaria a página do paciente depois de ela já ter pintado.
		expect(linkGoogleAgenda({ ...EVENTO, inicio: 'nao-e-data' })).toBeNull();
	});
});
