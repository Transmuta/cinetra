// Helpers de formatação de UI compartilhados.

// Iniciais de um nome (até 2 letras maiúsculas), para avatares.
export function initials(nome: string): string {
	return nome
		.trim()
		.split(/\s+/)
		.map((w) => w[0])
		.slice(0, 2)
		.join('')
		.toUpperCase();
}
