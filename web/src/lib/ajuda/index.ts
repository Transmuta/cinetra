// A central de ajuda (doc 108): o índice único de tópicos, e as funções que as rotas usam.
//
// Tudo que a página desenha sai daqui — índice, busca, navegação entre tópicos. Nenhuma rota
// monta lista própria: foi assim que o sumário dos documentos legais deixou de divergir do corpo,
// e o problema aqui é o mesmo em escala maior.

import { SECOES, SECAO_POR_ID } from './secoes';
import { textoDoTopico, type Papel, type SecaoId, type Topico } from './tipos';
import { PRIMEIROS_PASSOS } from './conteudo/primeiros-passos';
import { AGENDA } from './conteudo/agenda';
import { PACIENTES } from './conteudo/pacientes';
import { PROFISSIONAIS } from './conteudo/profissionais';
import { CONFIGURACOES } from './conteudo/configuracoes';
import { EQUIPE } from './conteudo/equipe';
import { FILA } from './conteudo/fila';
import { PACOTES } from './conteudo/pacotes';
import { COMUNICACAO } from './conteudo/comunicacao';
import { NOTIFICACOES } from './conteudo/notificacoes';
import { RELATORIOS } from './conteudo/relatorios';
import { AUDITORIA } from './conteudo/auditoria';
import { CELULAR } from './conteudo/celular';
import { PROBLEMAS } from './conteudo/problemas';
import { PRIVACIDADE } from './conteudo/privacidade';

export * from './tipos';
export { SECOES, SECAO_POR_ID } from './secoes';

/**
 * Todos os tópicos, na ordem das seções.
 *
 * A ordem importa: é a do índice, a do "próximo tópico" no pé da página e a que o leitor segue
 * quando está aprendendo em vez de consultando.
 */
export const TOPICOS: readonly Topico[] = [
	...PRIMEIROS_PASSOS,
	...AGENDA,
	...PACIENTES,
	...PROFISSIONAIS,
	...CONFIGURACOES,
	...EQUIPE,
	...FILA,
	...PACOTES,
	...COMUNICACAO,
	...NOTIFICACOES,
	...RELATORIOS,
	...AUDITORIA,
	...CELULAR,
	...PROBLEMAS,
	...PRIVACIDADE
];

const POR_ID = new Map(TOPICOS.map((t) => [t.id, t]));

export function topicoPorId(id: string): Topico | undefined {
	return POR_ID.get(id);
}

export function topicosDaSecao(secao: SecaoId): Topico[] {
	return TOPICOS.filter((t) => t.secao === secao);
}

/** O índice inteiro, agrupado — o que a página `/ajuda` desenha. */
export function indice(): { secao: (typeof SECOES)[number]; topicos: Topico[] }[] {
	return SECOES.map((secao) => ({ secao, topicos: topicosDaSecao(secao.id) })).filter(
		(g) => g.topicos.length > 0
	);
}

/** O tópico anterior e o próximo, na ordem do índice. */
export function vizinhos(id: string): { anterior?: Topico; proximo?: Topico } {
	const i = TOPICOS.findIndex((t) => t.id === id);
	if (i < 0) return {};
	return { anterior: TOPICOS[i - 1], proximo: TOPICOS[i + 1] };
}

/**
 * Normaliza para busca: minúsculas e sem acento.
 *
 * Sem isto, procurar "excecao" não acha "exceção" — e ninguém digita acento numa busca com
 * pressa. `NFD` + remoção da faixa de diacríticos é o caminho que funciona sem tabela própria.
 */
export function normalizar(s: string): string {
	return s
		.normalize('NFD')
		.replace(/[̀-ͯ]/g, '')
		.toLowerCase();
}

// O texto de cada tópico, normalizado uma vez só. São ~90 tópicos e a busca roda a cada tecla:
// normalizar tudo por tecla digitada é trabalho repetido que dá para pagar no carregamento.
const INDICE_BUSCA: { topico: Topico; texto: string; titulo: string }[] = TOPICOS.map((topico) => ({
	topico,
	texto: normalizar(textoDoTopico(topico)),
	titulo: normalizar(topico.titulo)
}));

/**
 * Busca por termos. Todos os termos precisam aparecer (E, não OU) — com OU, "falta pacote"
 * devolveria metade da central.
 *
 * Quem casa no TÍTULO vem antes: quem digita "encaixe" quer o tópico "Encaixe", não os seis
 * outros que o mencionam de passagem.
 */
export function buscar(consulta: string): Topico[] {
	const termos = normalizar(consulta).split(/\s+/).filter(Boolean);
	if (termos.length === 0) return [];

	const achados = INDICE_BUSCA.filter((e) => termos.every((t) => e.texto.includes(t)));
	const noTitulo = achados.filter((e) => termos.every((t) => e.titulo.includes(t)));
	const resto = achados.filter((e) => !noTitulo.includes(e));

	return [...noTitulo, ...resto].map((e) => e.topico);
}

/**
 * O tópico de ajuda de uma rota do sistema — o que o "?" da barra de topo abre.
 *
 * Mapa explícito, e não derivado do `sectionOf` da navegação: as duas coisas concordam hoje, mas
 * a ajuda tem recortes que o menu não tem (a ficha do paciente e a lista são a mesma seção e
 * tópicos diferentes). Derivar amarraria a ajuda a uma decisão de navegação que não é dela.
 */
const AJUDA_POR_ROTA: ReadonlyArray<readonly [string, string]> = [
	['/agenda', 'visoes-da-agenda'],
	['/pacientes/novo', 'cadastrar-paciente'],
	['/pacientes', 'encontrar-um-paciente'],
	['/profissionais/novo', 'cadastrar-profissional'],
	['/profissionais', 'cadastrar-profissional'],
	['/fila', 'fila-o-que-e'],
	['/relatorios', 'os-numeros-da-clinica'],
	['/auditoria', 'quem-mexeu-no-que'],
	['/notificacoes', 'caixa-de-notificacoes'],
	['/perfil', 'seu-perfil-e-o-tema'],
	['/configuracoes/clinica', 'dados-da-clinica'],
	['/configuracoes/tipos', 'tipos-de-atendimento'],
	['/configuracoes/horario', 'horario-de-funcionamento'],
	['/configuracoes/excecoes', 'excecoes'],
	['/configuracoes/comunicacao', 'canal-e-silencio'],
	['/configuracoes/equipe', 'convidar-alguem'],
	['/configuracoes', 'roteiro-do-primeiro-dia']
];

/**
 * O tópico da rota dada, ou `undefined`. O mais específico ganha: `/pacientes/novo` casa com o
 * cadastro, não com a busca — daí a lista estar ordenada do mais longo para o mais curto e a
 * comparação ser por prefixo.
 */
export function ajudaDaRota(pathname: string): Topico | undefined {
	for (const [prefixo, id] of AJUDA_POR_ROTA) {
		if (pathname === prefixo || pathname.startsWith(`${prefixo}/`)) return topicoPorId(id);
	}
	return undefined;
}

/** Os tópicos que um papel alcança — usado para filtrar o índice de quem está logado. */
export function topicosDoPapel(papel: Papel): Topico[] {
	return TOPICOS.filter((t) => t.papeis.includes(papel));
}
