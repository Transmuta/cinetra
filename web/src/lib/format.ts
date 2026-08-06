// Helpers de formatação de UI compartilhados.

/**
 * Título de tratamento no início do nome. O ponto é OBRIGATÓRIO no padrão: sem ele, "Draco" e
 * "Drika" perderiam a primeira sílaba.
 */
const TITULO = /^dr[ao]?\.\s*/i;

/**
 * Iniciais de um nome (até 2 letras maiúsculas), para avatares.
 *
 * O título é descartado: `nome_exibicao` é o campo onde se escreve "Dra. Marina", então numa
 * clínica com três doutoras `D?` seria o mesmo avatar três vezes. Se o nome for SÓ o título,
 * ele volta a valer — melhor uma inicial fraca que um avatar vazio.
 */
export function initials(nome: string): string {
	const semTitulo = nome.trim().replace(TITULO, '').trim();

	return (semTitulo || nome.trim())
		.split(/\s+/)
		.map((w) => w[0])
		.slice(0, 2)
		.join('')
		.toUpperCase();
}
