import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';
import { meFixture } from '$lib/testing/fixtures';
import type { Clinic } from '$lib/server/clinics';

// A tela de comunicação (doc 52 §7 / doc 98) pelo lado do FORMULÁRIO.
//
// O `page.server.test.ts` ao lado prova o que a action faz com cada campo; este arquivo prova o
// que o formulário de fato **manda**. A distinção não é cerimônia: os dois estavam verdes e a
// janela de silêncio sumia a cada gravação, porque o campo que a liga nunca saía da página. Bug de
// fronteira só aparece atravessando a fronteira.

const owner: Me = meFixture({
	user: { id: 'u1', nome: 'Dona', email: 'dona@ex.com' },
	memberships: []
});

const clinic: Clinic = {
	id: 'c1',
	nome: 'Clínica Vida',
	cnpj: null,
	endereco: null,
	msg_lembrete_horas: 2,
	msg_silencio_inicio: 21,
	msg_silencio_fim: 8
};

function data(c: Clinic = clinic) {
	return { theme: null, unread: 0, me: owner, clinic: c };
}

// O que a action receberia se o usuário clicasse em Salvar agora.
function enviado(container: HTMLElement) {
	const form = container.querySelector('form') as HTMLFormElement;
	return new FormData(form);
}

describe('o que o formulário manda', () => {
	it('com a janela de silêncio LIGADA, manda `silencio` e as duas pontas', () => {
		// Sem o `silencio`, a action lê `null` e grava as duas pontas em nulo — a clínica que só
		// mudou o lembrete perdia o "não incomodar" sem nenhum aviso, e a tela voltava com o
		// controle desligado.
		const fd = enviado(render(Page, { props: { data: data(), form: null } }).container);

		expect(fd.get('silencio')).toBe('on');
		expect(fd.get('msg_silencio_inicio')).toBe('21');
		expect(fd.get('msg_silencio_fim')).toBe('8');
	});

	it('com a janela DESLIGADA, manda `silencio` em branco — é assim que a action a apaga', () => {
		// Em branco, e não ausente: a action compara com `'on'`, então os dois funcionam, mas o campo
		// presente é o que faz o desligar ser uma AFIRMAÇÃO do formulário em vez de uma omissão —
		// que foi exatamente o que confundiu o estado por tanto tempo.
		const semJanela = { ...clinic, msg_silencio_inicio: null, msg_silencio_fim: null };
		const fd = enviado(render(Page, { props: { data: data(semJanela), form: null } }).container);

		expect(fd.get('silencio')).toBe('');
	});

	it('com o lembrete ligado, manda as horas salvas', () => {
		const fd = enviado(render(Page, { props: { data: data(), form: null } }).container);

		expect(fd.get('msg_lembrete_horas')).toBe('2');
	});

	it('com o lembrete DESLIGADO, manda o campo em branco — desligado é null, não zero', () => {
		const semLembrete = { ...clinic, msg_lembrete_horas: null };
		const fd = enviado(render(Page, { props: { data: data(semLembrete), form: null } }).container);

		expect(fd.get('msg_lembrete_horas')).toBe('');
	});

	it('não manda mais a confirmação automática (doc 98)', () => {
		const fd = enviado(render(Page, { props: { data: data(), form: null } }).container);

		expect(fd.get('msg_confirmacao_auto')).toBeNull();
	});
});
