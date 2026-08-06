import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import CartaoPaciente from './CartaoPaciente.svelte';

const snippet = (html: string) => createRawSnippet(() => ({ render: () => `<div>${html}</div>` }));

const props = { clinica: 'Clínica Moving', children: snippet('conteúdo') };

/**
 * A moldura das telas de paciente. O que ela carrega não é enfeite: é a continuidade com o e-mail
 * que trouxe a pessoa até aqui — mesmo cabeçalho de clínica, mesma régua, mesma assinatura.
 */
describe('CartaoPaciente', () => {
	it('anuncia a clínica no topo, e não a Cinetra — quem manda a mensagem é ela', () => {
		const { getByText, container } = render(CartaoPaciente, { props });

		expect(getByText('Clínica Moving')).toBeInTheDocument();
		// O h1 é da PERGUNTA que a tela faz; a marca de quem pergunta não disputa esse posto.
		expect(container.querySelector('.cn-paciente-topo h1')).toBeNull();
	});

	it('sem clínica conhecida (link inválido), quem assina o topo é a Cinetra', () => {
		// Um cabeçalho vazio deixaria a página órfã justo no estado em que ela mais precisa
		// parecer confiável.
		const { container } = render(CartaoPaciente, {
			props: { clinica: null, children: snippet('x') }
		});

		expect(container.querySelector('.cn-paciente-topo svg')).not.toBeNull();
	});

	it('o telefone da clínica é discável, em E.164', () => {
		const { getByRole } = render(CartaoPaciente, {
			props: { ...props, telefone: '(61) 99946-6274' }
		});

		expect(getByRole('link', { name: '(61) 99946-6274' })).toHaveAttribute(
			'href',
			'tel:+5561999466274'
		);
	});

	it('telefone que não canoniza vira texto, não um `tel:` que o discador não completa', () => {
		const { queryByRole, getByText } = render(CartaoPaciente, {
			props: { ...props, telefone: 'ramal 22' }
		});

		expect(getByText('ramal 22')).toBeInTheDocument();
		expect(queryByRole('link', { name: 'ramal 22' })).toBeNull();
	});

	it('fixa o tema claro no próprio nó — o paciente não tem cookie de tema', () => {
		// Sem isto a página seguia o `prefers-color-scheme` do aparelho: e-mail em papel creme,
		// página quase preta, a um clique de distância. Mesma decisão do `AuthCard`.
		const { container } = render(CartaoPaciente, { props });

		const raiz = container.querySelector('.cn-root');
		expect(raiz).toHaveAttribute('data-theme', 'light');
		expect(raiz?.getAttribute('style')).toContain('color-scheme:light');
	});

	it('assina como quem entrega, no rodapé — a mesma frase do e-mail', () => {
		const { getByText } = render(CartaoPaciente, { props });

		expect(getByText(/Agenda e confirmações por/)).toBeInTheDocument();
	});

	it('não assina duas vezes: sem clínica, a marca já está no topo', () => {
		const { queryByText } = render(CartaoPaciente, {
			props: { clinica: null, children: snippet('x') }
		});

		expect(queryByText(/Agenda e confirmações por/)).toBeNull();
	});

	it('a nota fica FORA do cartão: é sobre a página, não sobre a sessão', () => {
		const { container, getByText } = render(CartaoPaciente, {
			props: { ...props, nota: snippet('isto não cancela nada') }
		});

		expect(getByText('isto não cancela nada')).toBeInTheDocument();
		expect(container.querySelector('.cn-paciente-cartao .cn-paciente-nota')).toBeNull();
	});
});
