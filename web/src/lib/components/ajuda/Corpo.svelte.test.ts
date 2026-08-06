import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import Corpo from './Corpo.svelte';
import Aviso from './Aviso.svelte';
import Print from './Print.svelte';
import type { Bloco } from '$lib/ajuda/tipos';
import { PRINTS } from '$lib/ajuda/prints';

const blocos = (...b: Bloco[]) => ({ props: { blocos: b } });

describe('Corpo', () => {
	it('texto vira parágrafo', () => {
		const { getByText } = render(Corpo, blocos({ tipo: 'texto', texto: 'Marque o horário.' }));
		expect(getByText('Marque o horário.')).toBeInTheDocument();
	});

	it('lista vira <ul> com um item por entrada', () => {
		const { getAllByRole } = render(
			Corpo,
			blocos({ tipo: 'lista', itens: ['Primeiro', 'Segundo'] })
		);
		expect(getAllByRole('listitem')).toHaveLength(2);
	});

	it('passos viram lista ORDENADA — a ordem é a informação', () => {
		const { container, getByText } = render(
			Corpo,
			blocos({
				tipo: 'passos',
				passos: [{ texto: 'Abra a agenda' }, { texto: 'Clique no horário' }]
			})
		);
		expect(container.querySelector('ol')).not.toBeNull();
		expect(getByText('Abra a agenda')).toBeInTheDocument();
		expect(getByText('Clique no horário')).toBeInTheDocument();
	});

	it('passo sem print mas com legenda ainda mostra a legenda', () => {
		const { getByText } = render(
			Corpo,
			blocos({ tipo: 'passos', passos: [{ texto: 'Salve', legenda: 'Vale para todos' }] })
		);
		expect(getByText('Vale para todos')).toBeInTheDocument();
	});

	it('tabela usa a primeira coluna como cabeçalho da linha', () => {
		const { getByRole } = render(
			Corpo,
			blocos({
				tipo: 'tabela',
				colunas: ['Ação', 'Efeito'],
				linhas: [['Cancelar', 'Fica na agenda']]
			})
		);
		expect(getByRole('rowheader', { name: 'Cancelar' })).toBeInTheDocument();
		expect(getByRole('columnheader', { name: 'Efeito' })).toBeInTheDocument();
	});

	it('a tabela rola dentro de si — a página não pode rolar de lado no celular', () => {
		const { container } = render(
			Corpo,
			blocos({ tipo: 'tabela', colunas: ['a', 'b'], linhas: [['1', '2']] })
		);
		// Pelo ESTILO e não pela classe: a central deixou de usar utilitários do app (eles seguem o
		// tema, e a página é papel/navy fixo — ver `paleta.test.ts`), então a rolagem virou estilo
		// embutido. O que o teste guarda continua sendo o comportamento, não a forma de escrevê-lo.
		const caixa = container.querySelector('table')?.parentElement;
		expect(caixa?.getAttribute('style')).toContain('overflow-x:auto');
	});

	it('desenha os blocos na ordem em que o conteúdo os declara', () => {
		const { container } = render(
			Corpo,
			blocos(
				{ tipo: 'texto', texto: 'Primeiro' },
				{ tipo: 'aviso', tom: 'dica', texto: 'Segundo' },
				{ tipo: 'texto', texto: 'Terceiro' }
			)
		);
		const texto = container.textContent ?? '';
		expect(texto.indexOf('Primeiro')).toBeLessThan(texto.indexOf('Segundo'));
		expect(texto.indexOf('Segundo')).toBeLessThan(texto.indexOf('Terceiro'));
	});
});

describe('Aviso', () => {
	it.each([
		['papel', 'Quem pode:'],
		['atencao', 'Atenção:'],
		['dica', 'Dica:']
	] as const)('tom %s traz a PALAVRA %s, não só a cor', (tom, rotulo) => {
		const { getByText } = render(Aviso, { props: { tom, texto: 'Só o dono faz isso.' } });
		expect(getByText(rotulo)).toBeInTheDocument();
	});
});

describe('Print', () => {
	// Nenhum id de teste existe no manifesto, então este é o caminho da print ainda não gerada —
	// que é o que precisa ser visível em vez de virar quadrado vazio.
	it('print inexistente vira nota, e não <img> quebrada', () => {
		const { container, getByText } = render(Print, {
			props: { id: 'nao-gerada-99', alt: 'nada' }
		});
		expect(container.querySelector('img')).toBeNull();
		expect(getByText(/em preparo/i)).toBeInTheDocument();
	});

	it('a legenda aparece mesmo sem a imagem', () => {
		const { getByText } = render(Print, {
			props: { id: 'nao-gerada-99', alt: 'nada', legenda: 'O botão fica no alto' }
		});
		expect(getByText('O botão fica no alto')).toBeInTheDocument();
	});
});

// A ampliação (pedido de 2026-08-06): a print é tirada de uma tela de 1440px e lida numa coluna de
// 760 — sem abrir maior, o botão que o texto cita fica ilegível. O teste usa um id do manifesto de
// verdade, porque a ampliação só existe quando há imagem.
describe('Print — ampliar', () => {
	const id = Object.keys(PRINTS)[0];

	it('a imagem é um botão que anuncia o que faz', () => {
		const { getByRole } = render(Print, { props: { id, alt: 'a agenda no dia' } });
		expect(getByRole('button', { name: /Ampliar imagem: a agenda no dia/ })).toBeInTheDocument();
	});

	it('clicar abre a versão grande, e o Esc fecha', async () => {
		const user = userEvent.setup();
		const { getByRole, queryByRole, getAllByRole } = render(Print, {
			props: { id, alt: 'a agenda no dia' }
		});

		expect(queryByRole('button', { name: 'Fechar imagem ampliada' })).not.toBeInTheDocument();
		await user.click(getByRole('button', { name: /Ampliar imagem/ }));

		expect(getByRole('button', { name: 'Fechar imagem ampliada' })).toBeInTheDocument();
		// Duas imagens: a da página e a ampliada.
		expect(getAllByRole('img')).toHaveLength(2);

		await user.keyboard('{Escape}');
		expect(queryByRole('button', { name: 'Fechar imagem ampliada' })).not.toBeInTheDocument();
	});

	it('a dimensão vai no <img> — sem ela cada print que carrega empurra o texto', () => {
		const { getAllByRole } = render(Print, { props: { id, alt: 'a agenda no dia' } });
		const img = getAllByRole('img')[0];
		expect(img).toHaveAttribute('width', String(PRINTS[id].largura));
		expect(img).toHaveAttribute('height', String(PRINTS[id].altura));
	});
});
