import type { ActionResult, SubmitFunction } from '@sveltejs/kit';

/**
 * "Este POST está em voo" — o estado que faltava em quase todo botão de ação do app.
 *
 * O `use:enhance` sem callback não conta nada a quem clicou: o botão fica igual até a resposta
 * chegar, e meio segundo de silêncio lê como "não pegou". A pessoa clica de novo — e onde a ação
 * não é idempotente (converter uma vaga da fila, aplicar massa num pacote) o segundo clique volta
 * como conflito contra o que o primeiro acabou de criar.
 *
 * O bloco que resolve isso é sempre o MESMO — armar antes, desarmar no fim, repassar o `update`.
 * Estava escrito à mão em meia dúzia de arquivos e ausente em quinze; aqui ele mora uma vez.
 *
 * Duas escolhas do contrato:
 *
 *   * o `emVoo` só cai **depois** do `update`, não antes. O `update` faz o `invalidateAll`, e é
 *     ele que traz a tela nova; soltar o botão antes reabre a janela de reclique justamente
 *     enquanto a lista ainda mostra o estado velho;
 *   * `reset` acompanha o default do SvelteKit (limpa o form no sucesso). Passe `reset: false`
 *     quando o erro ficar DENTRO do modal — limpar os campos junto com o 422 apagaria o que a
 *     pessoa precisa corrigir.
 *
 * `aoResponder` é para o que cada tela faz por cima disso (toast, fechar, ressincronizar o
 * rascunho); roda depois do `update`, com o resultado fresco.
 */
export interface OpcoesEnvio {
	reset?: boolean;
	aoResponder?: (result: ActionResult) => void | Promise<void>;
}

/**
 * O que se diz quando o POST não chegou ao servidor.
 *
 * Exportada porque é contrato de tela, não texto solto: os testes a citam, e a frase promete uma
 * coisa que o código precisa cumprir — que **o formulário continua ali**.
 */
export const ERRO_DE_REDE =
	'Sem conexão com o servidor. O que você preencheu continua aqui — tente de novo.';

/**
 * Falha de REDE não pode passar pelo `update`.
 *
 * `update()` chama o `applyAction` do SvelteKit, e para `result.type === 'error'` isso **troca a
 * página inteira** pela tela de erro. Medido no doc 88 (A-10): salvar a ficha com a rede fora
 * levava a `500 — Algo deu errado / Failed to fetch`, e os 31 campos digitados iam junto.
 *
 * Três coisas erradas no mesmo caminho, e todas somem ao não chamar o `update`: o "500" (o
 * servidor não respondeu nada — não houve erro do servidor), a mensagem interna do browser em
 * inglês na cara do usuário, e a perda do trabalho.
 *
 * `aoResponder` também não roda: ele existe para reagir a uma resposta, e aqui não houve nenhuma.
 */
// `result` é opcional de propósito: o `use:enhance` sempre o entrega, mas os testes de componente
// costumam chamar o callback só com o `update` (é o `update` que eles observam). Sem o `?.`, o
// helper passava a explodir dentro de teste que não tinha nada a ver com rede.
function falhouARede(result?: ActionResult): boolean {
	return result?.type === 'error';
}

export function envio(opts: OpcoesEnvio = {}) {
	let emVoo = $state(false);
	let erroRede = $state<string | null>(null);

	const submit: SubmitFunction = () => {
		emVoo = true;
		erroRede = null;
		return async ({ result, update }) => {
			try {
				if (falhouARede(result)) {
					erroRede = ERRO_DE_REDE;
					return;
				}
				await update({ reset: opts.reset ?? true });
				await opts.aoResponder?.(result);
			} finally {
				emVoo = false;
			}
		};
	};

	return {
		get emVoo() {
			return emVoo;
		},
		/** A frase a mostrar quando o POST não chegou ao servidor, ou `null`. */
		get erroRede() {
			return erroRede;
		},
		limparErroRede() {
			erroRede = null;
		},
		submit
	};
}

/**
 * O mesmo, para N forms iguais numa lista — uma linha por item (arquivar um tipo, pausar um
 * pacote, marcar uma notificação como lida).
 *
 * Um booleano só não serve aqui: ele giraria **todos** os botões da lista ao clicar em um. O que
 * se guarda, então, é QUAL item está em voo — a chave costuma ser o id da linha.
 */
export function envioPorItem<K>(opts: OpcoesEnvio = {}) {
	let alvo = $state<K | null>(null);
	let erroRede = $state<string | null>(null);

	return {
		emVoo: (chave: K) => alvo === chave,
		/** A frase a mostrar quando o POST não chegou ao servidor, ou `null`. */
		get erroRede() {
			return erroRede;
		},
		limparErroRede() {
			erroRede = null;
		},
		/** Alguma linha está em voo? Use para travar as vizinhas quando a ação for exclusiva. */
		get algumEmVoo() {
			return alvo !== null;
		},
		submit:
			(chave: K): SubmitFunction =>
			() => {
				alvo = chave;
				return concluir();
			},
		/**
		 * Quando a chave só se conhece NA HORA do clique — o padrão dos forms escondidos que o
		 * drawer da agenda submete por `requestSubmit()`: há um form só para as N linhas, e quem
		 * diz de qual linha se trata são os campos preenchidos no clique.
		 *
		 * Precisa ser função porque o `use:enhance` do SvelteKit não reavalia o parâmetro: o que
		 * for passado no mount fica lá, e uma chave lida ali estaria sempre defasada.
		 */
		submitDinamico:
			(chave: () => K): SubmitFunction =>
			() => {
				alvo = chave();
				return concluir();
			},
		/**
		 * Para um form com MAIS DE UM botão de submit (`name`/`value`) — a página de confirmação do
		 * paciente é assim. A chave sai do **botão clicado**, porque o `use:enhance` mora no form e
		 * não em cada botão; sem isso os dois girariam juntos.
		 */
		submitPeloBotao: ((input) => {
			const botao = input.submitter as HTMLButtonElement | null;
			alvo = (botao?.value ?? null) as K | null;
			return concluir();
		}) as SubmitFunction
	};

	function concluir() {
		erroRede = null;
		return async ({
			result,
			update
		}: {
			result: ActionResult;
			update: (o?: { reset?: boolean }) => Promise<void>;
		}) => {
			try {
				// Mesma razão de `envio`: sem resposta do servidor, não se chama `update` — ele
				// trocaria a lista inteira pela tela de erro.
				if (falhouARede(result)) {
					erroRede = ERRO_DE_REDE;
					return;
				}
				await update({ reset: opts.reset ?? true });
				await opts.aoResponder?.(result);
			} finally {
				alvo = null;
			}
		};
	}
}
