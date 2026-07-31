import { textoSobre } from './contraste';

// Paleta categórica dos avatares da agenda (Cinetra). Índice 1-based; o protótipo faz
// `(ci-1) % 7` (`profColor` :315 / `patientColor` :316). É um **token de design compartilhado**
// entre profissional e paciente — mora aqui, num módulo neutro, para não duplicar a lista nem
// acoplar os dois domínios (`patients.ts` ↔ `professionals.ts`). NÃO é a paleta de Tipos de
// atendimento, que tem 8 cores e validação própria (`appointment-types.ts`).
// A entrada 1 era o teal `#0FB5A6` do protótipo e virou o **sage da marca** na
// [ADR-021](../../../docs/00-decisoes.md) — a mesma troca que tirou o teal do acento de UI.
//
// Trocar cor de uma paleta CATEGÓRICA é diferente de trocar um token: aqui a cor não comunica
// marca, comunica "este não é aquele". Então a pergunta que decide não é estética, é distância
// perceptual — e ela foi medida em OKLab antes da troca:
//
//   par mais parecido da paleta ANTES:  #0FB5A6 ↔ #009E73  ΔE_ok 0,087
//   par mais parecido da paleta DEPOIS: #7fa59a ↔ #009E73  ΔE_ok 0,111
//
// Ou seja: o teal já era a cor mais confundível da lista, e o sage **afasta** o pior par em 28%.
// A intuição contrária (sage e `#009E73` têm matiz quase igual — 163° e 164°) está errada porque
// matiz sozinha não decide: os dois diferem muito em saturação (17% vs 100%) e luminosidade
// (57% vs 31%), e é isso que o olho usa. Mediu-se em vez de supor.
export const AVATAR_PALETTE = ['#7FA59A', '#0072B2', '#009E73', '#CC79A7', '#7A52CC', '#D55E00', '#E69F00'];

/**
 * O slot do **usuário logado** (avatar do menu e da tela de perfil).
 *
 * Diferente de profissional e paciente, a conta não tem `cor_indice` no servidor — o avatar dela
 * sempre foi o azul da posição 2. O valor mora aqui, e não cravado como `bg-[#0072B2]` nas duas
 * telas, porque era exatamente assim que ele ficava para trás quando a paleta mudasse: era o
 * único avatar do app cuja cor de texto não passava pelo `textoSobre` (doc 93 §M-8).
 */
export const COR_DO_USUARIO_LOGADO = 2;

// Cor do avatar para um índice 1-based, com wrap (tolera 0/negativos como o protótipo).
export function avatarColor(corIndice: number): string {
	const n = AVATAR_PALETTE.length;
	return AVATAR_PALETTE[(((corIndice - 1) % n) + n) % n];
}

/**
 * ⚠️ EXCEÇÃO DE CONTRASTE REGISTRADA — sage sempre carrega texto **branco**.
 *
 * Decisão humana de 2026-07-30, a mesma da [ADR-020](../../../docs/00-decisoes.md) estendida ao
 * avatar: branco sobre `#7FA59A` mede **2,71:1**, abaixo do 4,5 de 1.4.3. O `textoSobre` escolheria
 * o escuro (6,46), que é o conforme — e é justamente o que foi recusado.
 *
 * O motivo de estender em vez de deixar o `textoSobre` decidir é **consistência na mesma tela**: o
 * botão primário já é branco sobre este mesmo sage (`--mv-on-primary`). Se o avatar resolvesse para
 * escuro, a mesma cor apareceria com dois tratamentos de texto lado a lado.
 *
 * A exceção é do TAMANHO de uma cor: as outras seis continuam passando pelo `textoSobre` e pelo
 * piso de 4,5. Ela é fixada em `contraste.test.ts`, que crava o 2,71 em vez de fingir que passa.
 */
const SEMPRE_BRANCO = new Set(['#7fa59a']);

/**
 * O `style` de um avatar com iniciais: fundo **e** cor do texto, juntos.
 *
 * Devolve os dois de propósito. Antes cada tela punha `style="background:…"` na marcação e
 * `text-white` na classe, e as duas metades ficavam livres para discordar — que era o defeito:
 * **5 das 7 cores desta paleta reprovam com texto branco** (`#E69F00` fica em 2,25:1), e nenhuma
 * cor de texto única serve para as sete. Escurecer a paleta não é opção: ela é contrato com o
 * `one_of` do servidor (débito D-3). Ver `contraste.ts` e o doc 83.
 *
 * Aceita hex (a cor já resolvida) ou índice. Valor que não seja hex — `var(--color-muted)`, por
 * exemplo — passa direto sem cor de texto: ali quem manda é a classe do elemento.
 */
export function avatarStyle(cor: number | string): string {
	const fundo = typeof cor === 'number' ? avatarColor(cor) : cor;
	const limpo = fundo.trim();
	if (!/^#[0-9a-f]{6}$/i.test(limpo)) return `background:${fundo}`;
	const texto = SEMPRE_BRANCO.has(limpo.toLowerCase()) ? '#ffffff' : textoSobre(limpo);
	return `background:${fundo};color:${texto}`;
}
