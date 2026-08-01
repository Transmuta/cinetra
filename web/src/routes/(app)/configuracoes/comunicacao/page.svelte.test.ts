import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';
import { meFixture, clinicFixture } from '$lib/testing/fixtures';
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

const clinic: Clinic = clinicFixture();

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

	it('não manda mais nem a confirmação automática nem o lembrete', () => {
		// Os dois campos deixaram de existir na API (doc 98 e 2026-08-01). Um payload que ainda os
		// carregasse seria recusado pela ação do Ash, e o sintoma na tela seria "não foi possível
		// salvar" para QUALQUER mudança — inclusive a do interruptor de WhatsApp.
		const fd = enviado(render(Page, { props: { data: data(), form: null } }).container);

		expect(fd.get('msg_confirmacao_auto')).toBeNull();
		expect(fd.get('msg_lembrete_horas')).toBeNull();
	});

	it('com o WhatsApp ligado, manda `whatsapp=on`', () => {
		const comCanal = { ...clinic, telefone: '(11) 3456-7890', msg_whatsapp_ativo: true };
		const fd = enviado(render(Page, { props: { data: data(comCanal), form: null } }).container);

		expect(fd.get('whatsapp')).toBe('on');
	});

	it('com o WhatsApp DESLIGADO, manda `whatsapp` em branco — é assim que se desliga', () => {
		// A armadilha exata do `silencio`: o `SwitchToggle` é `<button role="switch">` e botão não
		// entra no FormData. Sem o hidden, a action leria ausente, e o canal seria impossível de
		// desligar pela tela — com a diferença de que aqui o efeito é uma FATURA, não uma
		// configuração perdida.
		const fd = enviado(render(Page, { props: { data: data(), form: null } }).container);

		expect(fd.get('whatsapp')).toBe('');
	});
});

describe('o WhatsApp só liga com telefone da clínica', () => {
	it('sem telefone, o interruptor fica desabilitado e a página diz onde resolver', () => {
		const { getByLabelText, getByText, getByRole } = render(Page, {
			props: { data: data(), form: null }
		});

		expect(getByLabelText('Falar por WhatsApp')).toBeDisabled();
		expect(getByText(/cadastre antes o/i)).toBeInTheDocument();
		// O link até a tela que resolve: interruptor apagado sem caminho manda procurar em três telas.
		expect(getByRole('link', { name: 'Dados da clínica' })).toHaveAttribute(
			'href',
			'/configuracoes/clinica'
		);
	});

	it('com telefone, o interruptor fica utilizável e o aviso some', () => {
		const comTelefone = { ...clinic, telefone: '(11) 3456-7890' };
		const { getByLabelText, queryByText } = render(Page, {
			props: { data: data(comTelefone), form: null }
		});

		expect(getByLabelText('Falar por WhatsApp')).toBeEnabled();
		expect(queryByText(/cadastre antes o/i)).toBeNull();
	});
});
