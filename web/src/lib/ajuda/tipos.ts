// O modelo de conteúdo da central de ajuda (doc 108).
//
// **Dado, não markup** — a mesma escolha de `$lib/legal.ts`, pela mesma razão e com um motivo a
// mais. Em `legal.ts` o ganho era o sumário não divergir do corpo; aqui, além disso, é que o
// conteúdo precisa ser INSPECIONÁVEL por teste: quem cita uma print que não existe, quem ficou
// órfão, qual seção do roteiro de QA ainda não tem tópico. Nada disso é possível sobre `.svelte`.
//
// Um tópico é uma TAREFA ("Marcar um atendimento"), nunca uma tela — quem procura ajuda não sabe
// que o que ela quer se chama `NewAppointmentModal`.

/** Os quatro papéis do ADR-016, na mesma ordem do `Api.Accounts.Role`. */
export type Papel = 'owner' | 'admin' | 'profissional' | 'recepcao';

export const PAPEIS: readonly Papel[] = ['owner', 'admin', 'profissional', 'recepcao'];

/** Como o papel é chamado na tela — o texto que o usuário reconhece. */
export const NOME_DO_PAPEL: Record<Papel, string> = {
	owner: 'Dono',
	admin: 'Administrador',
	profissional: 'Profissional',
	recepcao: 'Recepção'
};

export type SecaoId =
	| 'primeiros-passos'
	| 'equipe'
	| 'configuracoes'
	| 'profissionais'
	| 'pacientes'
	| 'agenda'
	| 'pacotes'
	| 'fila'
	| 'comunicacao'
	| 'notificacoes'
	| 'relatorios'
	| 'auditoria'
	| 'celular'
	| 'problemas'
	| 'privacidade';

export type Secao = {
	readonly id: SecaoId;
	readonly titulo: string;
	/** Uma linha no índice, abaixo do título da seção. */
	readonly resumo: string;
};

/**
 * O tom de um aviso. São três porque são três coisas diferentes, e misturá-las custa caro:
 * `papel` é uma restrição do sistema (a pessoa não vai conseguir, e precisa saber antes de
 * tentar), `atencao` é consequência difícil de desfazer, `dica` é atalho.
 */
export type Tom = 'papel' | 'atencao' | 'dica';

/**
 * Um passo de um procedimento. `print` é o **id** de uma imagem (não um caminho): quem resolve id
 * → arquivo é o `prints.json`, gerado por `npm run prints`, e é isso que deixa o gate saber que
 * uma print citada aqui deixou de existir.
 *
 * `alt` é obrigatório junto do `print` porque a descrição depende do CONTEXTO em que a imagem é
 * usada — o gerador, que só sabe fotografar, não teria como escrevê-la.
 */
export type Passo = {
	readonly texto: string;
	readonly print?: string;
	readonly alt?: string;
	/** Legenda visível abaixo da imagem, quando ela precisa apontar para algo específico. */
	readonly legenda?: string;
};

export type Bloco =
	| { readonly tipo: 'texto'; readonly texto: string }
	| { readonly tipo: 'lista'; readonly itens: readonly string[] }
	| { readonly tipo: 'passos'; readonly passos: readonly Passo[] }
	| { readonly tipo: 'aviso'; readonly tom: Tom; readonly texto: string }
	| {
			readonly tipo: 'print';
			readonly print: string;
			readonly alt: string;
			readonly legenda?: string;
	  }
	| {
			readonly tipo: 'tabela';
			readonly colunas: readonly string[];
			readonly linhas: readonly (readonly string[])[];
	  };

export type Topico = {
	/** Vira a URL: `/ajuda/marcar-atendimento`. Kebab-case, sem acento. */
	readonly id: string;
	readonly secao: SecaoId;
	/** A tarefa, do ponto de vista de quem faz. */
	readonly titulo: string;
	/** Uma linha: alimenta o índice, a busca e a `<meta description>`. */
	readonly resumo: string;
	/**
	 * Quem alcança o fluxo. A dúvida mais comum sobre papéis não é "como faço" — é "por que não
	 * vejo esse menu"; declarar isso em todo tópico responde antes de perguntarem.
	 */
	readonly papeis: readonly Papel[];
	readonly blocos: readonly Bloco[];
	/** Ids de outros tópicos. O gate confere que existem. */
	readonly vejaTambem?: readonly string[];
	/**
	 * A seção do roteiro de QA (`docs/82-roteiro-qa-guiado.md`) que cobre o mesmo fluxo.
	 * Rastreabilidade nos dois sentidos: é o que permite perguntar "que fluxo testado não tem
	 * manual?" sem reler os dois documentos.
	 */
	readonly roteiro82?: string;
};

/** Os ids de print citados por um tópico, na ordem em que aparecem. */
export function printsDoTopico(topico: Topico): string[] {
	const ids: string[] = [];
	for (const bloco of topico.blocos) {
		if (bloco.tipo === 'print') ids.push(bloco.print);
		if (bloco.tipo === 'passos') {
			for (const passo of bloco.passos) if (passo.print) ids.push(passo.print);
		}
	}
	return ids;
}

/**
 * Todo o texto de um tópico, achatado — a matéria-prima da busca.
 *
 * Inclui `alt` e `legenda` de propósito: elas costumam carregar o nome do botão que a pessoa está
 * procurando ("Registrar status"), e deixá-las de fora faria a busca falhar exatamente no termo
 * que o usuário leu na tela.
 */
export function textoDoTopico(topico: Topico): string {
	const partes: string[] = [topico.titulo, topico.resumo];
	for (const bloco of topico.blocos) {
		switch (bloco.tipo) {
			case 'texto':
			case 'aviso':
				partes.push(bloco.texto);
				break;
			case 'lista':
				partes.push(...bloco.itens);
				break;
			case 'passos':
				for (const passo of bloco.passos) {
					partes.push(passo.texto);
					if (passo.legenda) partes.push(passo.legenda);
					if (passo.alt) partes.push(passo.alt);
				}
				break;
			case 'print':
				partes.push(bloco.alt);
				if (bloco.legenda) partes.push(bloco.legenda);
				break;
			case 'tabela':
				partes.push(...bloco.colunas, ...bloco.linhas.flat());
				break;
		}
	}
	return partes.join(' ');
}
