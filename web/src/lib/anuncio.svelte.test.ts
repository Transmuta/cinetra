import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { flushSync } from 'svelte';
import { criarAnunciante } from './anuncio.svelte';

/**
 * As duas armadilhas de live region que o módulo existe para tratar (ACC-06, doc 83): repetir o
 * mesmo texto não é mudança, e rajada não pode virar uma fala por evento.
 */

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('criarAnunciante', () => {
	it('começa vazio e só escreve depois da janela', () => {
		const a = criarAnunciante(400);
		expect(a.texto()).toBe('');

		a.anunciar('Nova notificação.');
		flushSync();
		// Ainda vazio: é o "limpa" do limpa-e-escreve.
		expect(a.texto()).toBe('');

		vi.advanceTimersByTime(400);
		flushSync();
		expect(a.texto()).toBe('Nova notificação.');
	});

	it('reanuncia o MESMO texto — passando por vazio', () => {
		const a = criarAnunciante(400);

		a.anunciar('Nova notificação.');
		vi.advanceTimersByTime(400);
		flushSync();
		expect(a.texto()).toBe('Nova notificação.');

		// Segunda notificação idêntica: sem o zeramento, escrever o mesmo texto não seria mudança
		// nenhuma para o leitor de tela e o anúncio se perderia.
		a.anunciar('Nova notificação.');
		flushSync();
		expect(a.texto()).toBe('');

		vi.advanceTimersByTime(400);
		flushSync();
		expect(a.texto()).toBe('Nova notificação.');
	});

	it('junta a rajada num anúncio só, e o último texto ganha', () => {
		const a = criarAnunciante(400);

		a.anunciar('primeiro');
		vi.advanceTimersByTime(100);
		a.anunciar('segundo');
		vi.advanceTimersByTime(100);
		a.anunciar('terceiro');

		vi.advanceTimersByTime(400);
		flushSync();
		expect(a.texto()).toBe('terceiro');
	});

	it('limpar cancela o que estava pendente', () => {
		const a = criarAnunciante(400);
		a.anunciar('não deve falar');
		a.limpar();

		vi.advanceTimersByTime(1000);
		flushSync();
		expect(a.texto()).toBe('');
	});
});
