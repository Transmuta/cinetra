import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { toast, dismissToast, currentToast, TOAST_DURATION_MS } from './toast.svelte';

// Estado é de módulo (um toast global) — zera entre os testes.
beforeEach(() => {
	vi.useFakeTimers();
	dismissToast();
});
afterEach(() => {
	vi.useRealTimers();
});

describe('toast (estado global)', () => {
	it('começa sem mensagem', () => {
		expect(currentToast()).toBeNull();
	});

	it('mostra a mensagem e some sozinho após a duração', () => {
		toast('Convite enviado.');
		expect(currentToast()?.message).toBe('Convite enviado.');

		vi.advanceTimersByTime(TOAST_DURATION_MS - 1);
		expect(currentToast()?.message).toBe('Convite enviado.');

		vi.advanceTimersByTime(1);
		expect(currentToast()).toBeNull();
	});

	it('um toast novo substitui o atual e reinicia o relógio (como no protótipo)', () => {
		toast('primeiro');
		vi.advanceTimersByTime(2000);
		toast('segundo');

		// 2000 + 2000 > duração: se o relógio não tivesse sido reiniciado, já teria sumido.
		vi.advanceTimersByTime(2000);
		expect(currentToast()?.message).toBe('segundo');

		vi.advanceTimersByTime(TOAST_DURATION_MS - 2000);
		expect(currentToast()).toBeNull();
	});

	it('dismissToast esconde imediatamente e cancela o relógio', () => {
		toast('mensagem');
		dismissToast();
		expect(currentToast()).toBeNull();

		// Nenhum timer pendente deve reviver/derrubar nada depois.
		vi.advanceTimersByTime(TOAST_DURATION_MS * 2);
		expect(currentToast()).toBeNull();
	});

	describe('variante', () => {
		it('é "success" por padrão (o caso comum: confirmação)', () => {
			toast('Salvo');
			expect(currentToast()?.variant).toBe('success');
		});

		it('carrega "error" quando pedido — para que a casca visual distinga erro de sucesso', () => {
			toast('Dados inválidos. Verifique os campos.', 'error');
			expect(currentToast()?.variant).toBe('error');
			expect(currentToast()?.message).toBe('Dados inválidos. Verifique os campos.');
		});

		it('a substituição reseta a variante (um erro depois de um sucesso não fica "success")', () => {
			toast('ok');
			toast('falhou', 'error');
			expect(currentToast()?.variant).toBe('error');
		});
	});
});
