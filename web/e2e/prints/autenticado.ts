import { test as base, type Clinica } from '../fixtures';

/**
 * A `test` das prints de tela interna — a que **não** deixa esquecer a sessão.
 *
 * As fixtures do Playwright são preguiçosas: `clinica` só é montada quando o teste a pede nos
 * argumentos. Um `test('x', async ({ page }) => …)` que navega para `/configuracoes/excecoes`
 * portanto roda **deslogado**, cai no `/entrar` e fotografa a tela de login — e o modo de falha é
 * o pior possível para esta leva, porque o arquivo é gerado do mesmo jeito, com o nome certo. Só
 * quem abrir a imagem descobre. (Aconteceu: seis prints de configuração saíram assim.)
 *
 * A saída é uma fixture `auto`, que roda em todo teste do arquivo sem ser pedida e que depende de
 * `clinica`. Fazer a própria `page` depender de `clinica` seria o caminho óbvio e é impossível:
 * `clinica` já depende de `page` (é nela que o magic link é consumido), e o Playwright recusa o
 * ciclo na carga do arquivo.
 */
export const test = base.extend<{ autenticada: void }>({
	autenticada: [
		async ({ clinica }, use) => {
			void clinica;
			await use();
		},
		{ auto: true }
	]
});

export { expect, abrirAgenda, blocos } from '../fixtures';
export type { Clinica };
