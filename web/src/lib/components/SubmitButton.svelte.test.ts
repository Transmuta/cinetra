import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import { afterEach } from 'vitest';

import SubmitButton from './SubmitButton.svelte';

const rotulo = createRawSnippet(() => ({ render: () => '<span>Salvar</span>' }));

afterEach(cleanup);

describe('SubmitButton', () => {
	it('em repouso é um botão de submit comum', () => {
		const { getByRole } = render(SubmitButton, { props: { children: rotulo } });
		const botao = getByRole('button', { name: 'Salvar' });

		expect(botao).toBeEnabled();
		expect(botao).toHaveAttribute('type', 'submit');
		expect(botao).toHaveAttribute('aria-busy', 'false');
		expect(botao.querySelector('.animate-spin')).toBeNull();
	});

	// O ponto da existência do componente: travar sozinho não basta — um botão só apagado parece
	// quebrado e convida ao segundo clique, que é o que se está tentando evitar.
	it('em voo trava, anuncia e MOSTRA o giro — sem perder o rótulo', () => {
		const { getByRole } = render(SubmitButton, { props: { emVoo: true, children: rotulo } });
		const botao = getByRole('button');

		expect(botao).toBeDisabled();
		expect(botao).toHaveAttribute('aria-busy', 'true');
		expect(botao.querySelector('.animate-spin')).not.toBeNull();
		expect(botao).toHaveTextContent('Salvar');
	});

	// Num botão de 30px só de ícone, somar o giro ao ícone deixaria dois glifos disputando o vão.
	it('com trocaConteudo, o giro entra no LUGAR do conteúdo', () => {
		const { getByRole } = render(SubmitButton, {
			props: { emVoo: true, trocaConteudo: true, children: rotulo }
		});
		const botao = getByRole('button');

		expect(botao.querySelector('.animate-spin')).not.toBeNull();
		expect(botao).not.toHaveTextContent('Salvar');
	});

	it('o disabled do chamador continua valendo sem envio nenhum', () => {
		const { getByRole } = render(SubmitButton, {
			props: { disabled: true, children: rotulo }
		});
		expect(getByRole('button')).toBeDisabled();
	});

	// O botão do rodapé de um modal vive FORA do <form> (o Modal desenha o rodapé em outro nó), e
	// só o atributo `form` o liga de volta. Perder isso deixaria o modal sem salvar.
	it('repassa form, name e value — o que liga o botão ao form e diz qual foi clicado', () => {
		const { getByRole } = render(SubmitButton, {
			props: { form: 'fila-form', name: 'resposta', value: 'confirmou', children: rotulo }
		});
		const botao = getByRole('button');

		expect(botao).toHaveAttribute('form', 'fila-form');
		expect(botao).toHaveAttribute('name', 'resposta');
		expect(botao).toHaveAttribute('value', 'confirmou');
	});
});
