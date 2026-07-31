import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import Hospedeiro from './FichaShell.hospedeiro.test.svelte';

afterEach(cleanup);

/**
 * O cromo que `PatientForm` e `ProfessionalForm` compartilhavam por CÓPIA (doc 94 §D-1): 823 +
 * 754 linhas de gêmeos, cuja prova mais direta era a linha 3 dos dois ser o mesmo comentário.
 *
 * Testar aqui é o que fecha o vão de verdade: antes, metade dos testes de um provava o código do
 * outro por cópia, e o `ProfessionalForm` — o de menor cobertura do repo — nunca exercitou nada
 * do cabeçalho, da coluna ou do rodapé.
 */
describe('FichaShell', () => {
	it('mostra o título até alguém digitar o nome — e então o nome ganha', () => {
		render(Hospedeiro);
		expect(screen.getByText('Novo paciente')).toBeInTheDocument();

		cleanup();

		render(Hospedeiro, { nome: 'Mariana Alves' });
		expect(screen.getByText('Mariana Alves')).toBeInTheDocument();
		expect(screen.queryByText('Novo paciente')).not.toBeInTheDocument();
	});

	it('as iniciais saem do nome; sem nome, um ponto de interrogação', () => {
		render(Hospedeiro);
		expect(screen.getByText('?')).toBeInTheDocument();

		cleanup();

		render(Hospedeiro, { nome: 'Mariana Alves' });
		expect(screen.getByText('MA')).toBeInTheDocument();
	});

	it('o progresso soma os campos das seções — 10 é o denominador das duas', () => {
		render(Hospedeiro, { counts: { ident: 3, contato: 1 } });

		expect(screen.getByText('4/10')).toBeInTheDocument();
	});

	it('a coluna lista as seções e marca a corrente', () => {
		render(Hospedeiro);

		const atual = screen.getByRole('button', { name: /Identificação/ });
		expect(atual).toHaveAttribute('aria-current', 'true');
		expect(screen.getByRole('button', { name: /Contato/ })).not.toHaveAttribute('aria-current');
	});

	it('a coluna é navegação nomeada, não um punhado de botões soltos', () => {
		render(Hospedeiro);

		expect(screen.getByRole('navigation')).toHaveAccessibleName('Seções do cadastro');
	});

	it('renderiza os cartões que o chamador passa', () => {
		render(Hospedeiro);

		expect(screen.getByText('Cartão de identificação')).toBeInTheDocument();
		expect(screen.getByText('Cartão de contato')).toBeInTheDocument();
	});

	/**
	 * ACC-04 (doc 83): o problema é `role="alert"` e visível em QUALQUER largura; a dica é
	 * silenciosa e só no desktop — se fosse alert, o leitor de tela a anunciaria a cada toque.
	 */
	describe('o rodapé', () => {
		it('sem problema, mostra a dica e NÃO tem alert', () => {
			render(Hospedeiro);

			expect(screen.queryByRole('alert')).toBeNull();
			expect(screen.getByText(/Nome e telefone são obrigatórios/)).toBeInTheDocument();
		});

		it('com problema, anuncia — e em qualquer largura', () => {
			render(Hospedeiro, { problema: 'Telefone incompleto — use DDD + número.' });

			const aviso = screen.getByRole('alert');
			expect(aviso).toHaveTextContent('Telefone incompleto');
			expect(aviso.className).not.toContain('hidden');
			expect(aviso.className).not.toContain('md:flex');
		});

		it('o salvar respeita o gate do chamador', () => {
			render(Hospedeiro, { acaoDesabilitada: true });

			expect(screen.getByRole('button', { name: 'Cadastrar paciente' })).toBeDisabled();
		});

		it('cancelar é um LINK de volta, não um botão que perde a navegação', () => {
			render(Hospedeiro);

			expect(screen.getByRole('link', { name: 'Cancelar' })).toHaveAttribute('href', '/pacientes');
		});
	});
});
