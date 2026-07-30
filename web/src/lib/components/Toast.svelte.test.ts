import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { flushSync } from 'svelte';

import Toast from './Toast.svelte';
import { toast, dismissToast } from '$lib/toast.svelte';

// Estado do toast é de módulo — isola cada teste.
beforeEach(() => dismissToast());
afterEach(() => dismissToast());

/** A pílula visível dentro da região — é ela que aparece e desaparece. */
const pilula = (regiao: HTMLElement) => regiao.firstElementChild as HTMLElement | null;

describe('Toast', () => {
	// ACC-05 (doc 83, WCAG 4.1.3): a região tem de existir VAZIA antes da mensagem. Enquanto o
	// `{#if}` embrulhava o próprio `role="status"`, região e conteúdo nasciam no mesmo instante —
	// e leitor de tela tipicamente não anuncia isso. Como o toast é o feedback de salvar/excluir
	// de todo o app, o efeito era quase nenhuma confirmação audível.
	it('mantém a região de status montada e VAZIA sem toast ativo', () => {
		const { getByRole } = render(Toast);
		const regiao = getByRole('status');
		expect(regiao).toBeInTheDocument();
		expect(regiao).toHaveTextContent('');
		expect(pilula(regiao)).toBeNull();
	});

	it('mostra a mensagem quando toast() é chamado e some no dismiss', () => {
		const { getByRole } = render(Toast);
		const regiao = getByRole('status');

		toast('Convite enviado.');
		flushSync();
		expect(regiao).toHaveTextContent('Convite enviado.');

		dismissToast();
		flushSync();
		// A região continua ali — só o conteúdo sai.
		expect(regiao).toBeInTheDocument();
		expect(pilula(regiao)).toBeNull();
	});

	it('usa o visual invertido do protótipo (primary/on-primary) com o check teal', () => {
		const { getByRole } = render(Toast);

		toast('Acesso removido.');
		flushSync();

		const pill = pilula(getByRole('status'))!;
		expect(pill.className).toContain('bg-primary');
		expect(pill.className).toContain('text-on-primary');
		expect(pill.querySelector('.text-teal')).not.toBeNull();
	});

	it('sucesso mostra o check teal e NÃO o ícone de erro', () => {
		const { getByRole } = render(Toast);

		toast('Horário da clínica salvo', 'success');
		flushSync();

		const pill = pilula(getByRole('status'))!;
		expect(pill.querySelector('.text-teal')).not.toBeNull();
		expect(pill.querySelector('.text-danger')).toBeNull();
	});

	it('erro NÃO usa o check de sucesso — mostra um ícone de erro (danger)', () => {
		// Regressão: um horário inválido devolvia "Dados inválidos" com o check verde de sucesso.
		// Erro e sucesso precisam ser visualmente distintos (o protótipo não distinguia; aqui sim).
		const { getByRole } = render(Toast);

		toast('Dados inválidos. Verifique os campos.', 'error');
		flushSync();

		const pill = pilula(getByRole('status'))!;
		expect(pill).toHaveTextContent('Dados inválidos. Verifique os campos.');
		expect(pill.querySelector('.text-teal')).toBeNull();
		expect(pill.querySelector('.text-danger')).not.toBeNull();
	});
});
