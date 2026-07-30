/**
 * Anúncio para leitor de tela (ACC-06, WCAG 4.1.3).
 *
 * O app muda sozinho em dois lugares — o badge do sino e os blocos da agenda, os dois por
 * WebSocket — e **nada** disso era anunciado: para quem não vê a tela, o app parecia estático
 * (doc 83). Uma live region resolve, mas com duas armadilhas que este módulo existe para tratar:
 *
 *  1. **texto igual não é mudança.** Escrever "Nova notificação" sobre "Nova notificação" não
 *     dispara anúncio nenhum. Daí o limpa-e-escreve: a região vai a vazio e o texto entra no tique
 *     seguinte, o que o leitor enxerga como mudança;
 *  2. **rajada vira ruído.** Cinco pushes em dois segundos não podem virar cinco falas. O
 *     `atrasoMs` junta a rajada num anúncio só — o último texto ganha.
 *
 * A região em si é um `<p class="sr-only" role="status">` no layout; aqui mora só o estado.
 */

export interface Anunciante {
	/** O texto atual da região (vazio = nada a anunciar). Leia num `$derived`/template. */
	texto: () => string;
	/** Enfileira um anúncio, juntando o que vier na mesma janela. */
	anunciar: (texto: string) => void;
	/** Cancela o que estiver pendente (desmontagem). */
	limpar: () => void;
}

export function criarAnunciante(atrasoMs = 400): Anunciante {
	let texto = $state('');
	let timer: ReturnType<typeof setTimeout> | undefined;

	return {
		texto: () => texto,

		anunciar(novo: string) {
			clearTimeout(timer);
			// Zera JÁ: se a região ainda tem a frase anterior (igual ou não), esvaziá-la antes é o
			// que torna a próxima escrita uma mudança observável.
			texto = '';
			timer = setTimeout(() => (texto = novo), atrasoMs);
		},

		limpar() {
			clearTimeout(timer);
			timer = undefined;
			texto = '';
		}
	};
}
