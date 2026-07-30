import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import Field from './Field.svelte';

// Um `el` qualquer no lugar do input (é o que a tela de tipos passa: swatches de cor/ícone).
const groupChildren = createRawSnippet(() => ({
	render: () => '<button type="button">#0FB5A6</button>'
}));

describe('Field', () => {
	it('associa o label ao input e repassa name/type/required', () => {
		const { getByLabelText } = render(Field, {
			props: { label: 'E-mail', name: 'email', type: 'email', required: true, autocomplete: 'email' }
		});

		const input = getByLabelText('E-mail');
		expect(input).toHaveAttribute('name', 'email');
		expect(input).toHaveAttribute('type', 'email');
		expect(input).toBeRequired();
		expect(input).toHaveAttribute('autocomplete', 'email');
	});

	it('reflete o value inicial', () => {
		const { getByLabelText } = render(Field, {
			props: { label: 'E-mail', name: 'email', value: 'ja@preenchido.com' }
		});
		expect(getByLabelText('E-mail')).toHaveValue('ja@preenchido.com');
	});

	// Variações do inputStyle() do protótipo (:1934): número com limites, fonte mono e
	// largura fixa. Props opcionais em vez de um segundo componente de campo.
	it('repassa min/step e aplica mono e largura ao input numérico', () => {
		const { getByLabelText } = render(Field, {
			props: {
				label: 'Duração (min)',
				name: 'duracao_minutos',
				type: 'number',
				min: 10,
				step: 5,
				mono: true,
				width: 'w-[120px]'
			}
		});

		const input = getByLabelText('Duração (min)');
		expect(input).toHaveAttribute('min', '10');
		expect(input).toHaveAttribute('step', '5');
		expect(input).toHaveClass('font-mono');
		expect(input).toHaveClass('w-[120px]');
		expect(input).not.toHaveClass('w-full');
	});

	it('sem width, o input ocupa a linha', () => {
		const { getByLabelText } = render(Field, { props: { label: 'Nome', name: 'nome' } });
		expect(getByLabelText('Nome')).toHaveClass('w-full');
	});
});

describe('Field com children (o `el` arbitrário do fld(), :1933)', () => {
	it('rotula um grupo em vez de um input — um <label> só pode apontar para UM controle', () => {
		const { getByRole, queryByRole } = render(Field, {
			props: { label: 'Cor', children: groupChildren }
		});

		const grupo = getByRole('group', { name: 'Cor' });
		expect(grupo).toBeInTheDocument();
		expect(grupo).toHaveTextContent('#0FB5A6');
		// nada de input fantasma quando o campo é um grupo de botões
		expect(queryByRole('textbox')).toBeNull();
	});
});
