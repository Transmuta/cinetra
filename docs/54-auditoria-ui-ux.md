# Auditoria — redesenho da tela, seção própria e filtros (+ bate-volta)

A tela nasceu na [Fatia F2](30-decisoes-pendentes-agenda.md) sobre o inventário do
[doc 25 §11.4](25-agenda.md) e foi auditada no [doc 32](32-auditoria-bate-volta-tela-auditoria.md).
Este doc registra o **redesenho de 2026-07-27**, que partiu de duas queixas de uso:

> *"está confuso, por exemplo, tá apresentando tudo na mesma linha: «Adam Dias dos Santos entrou
> na turma · Mariana Alves Teste». Não tem nenhum filtro."*

As duas são coisas diferentes: a primeira é um **erro de sujeito** (a frase afirmava algo falso),
a segunda é **filtro que a API já implementava e a tela nunca expôs**.

## 1. A linha dizia o contrário do que aconteceu

O corpo da linha era uma frase única: `{ator} {verbo} · {contexto}`. E os verbos de `attendance`
tinham sido escritos **na perspectiva do paciente** (`create: 'Entrou na turma'`), mas eram
renderizados com o **ator** como sujeito. O resultado literal — *"Adam Dias dos Santos entrou na
turma"* — é falso: quem entrou foi a Mariana. O `·` antes do nome era um separador mudo tentando
carregar sozinho a inversão de papéis.

Dois defeitos no mesmo rótulo:

- **"turma" mente na sessão individual.** `Attendance` é criada para todo participante, inclusive
  o de atendimento individual (`:schedule` recebe `patient_ids` sem olhar se o tipo é grupo,
  [`appointment.ex:225`](../api/lib/api/scheduling/appointment.ex)), e a versão não carrega o
  `grupo` do tipo para decidir. A saída é palavra neutra — "atendimento" —, não um `if`.
- **8 de 17 nomes de ação não tinham rótulo.** Medido no banco de dev: `apply_participant_rollup`
  (5), `set_pkg_hold` (3), `exclude` (2) no bloco; `set_package` (19), `reopen_attendance` (2),
  `mark_present`, `mark_absent`, `justify_absence` na presença — todos exibidos como átomo cru
  para a administração. E `destroy: 'Saiu da turma'` **nunca casava**: a ação se chama `:remove`.

### O desenho novo — três níveis

```
antes:  Adam Dias dos Santos entrou na turma · Mariana Alves Teste   27/07/2026 14:32

depois: ⊕  Adicionou Mariana Alves Teste ao atendimento                       10:09
           Teste · seg 27/07, 13:30
           por Adam Dias dos Santos          Ver na agenda · Ver histórico
```

1. **Verbo sempre de ator, objeto dentro da frase** (`entryHeadline`). O `·` mudo sumiu.
2. **Contexto na 2ª linha** — de qual sessão se fala.
3. **Ator na 3ª** ("por Fulano"): continua auditável, para de competir com o fato.
4. **Ícone semântico como âncora** (`⊕` criar / `↻` alterar / `⊘` destruir) no lugar do avatar do
   ator — que era o dado menos discriminante do feed (num dia típico, todas as linhas têm o mesmo).
5. **Só a hora** dentro do grupo do dia (a data completa em 50 linhas era ruído); carimbo cheio no
   `title`. Cabeçalho com "Hoje ·"/"Ontem ·" e dia da semana.
6. **"Ver histórico"** em toda linha: o filtro `record_id` existia na API e no load desde sempre e
   **não tinha entrada** — só chegava lá quem digitasse a URL.
7. `<del>`/`<ins>` no diff (o riscado e a seta eram pistas só visuais) e vazio com ícone.

## 2. Os filtros existiam; a tela é que não os expunha

O §11.4 foi implementado inteiro. O controller aceita `resource`, `record_id`, `user_id`,
`action`, `from`, `to`; o BFF repassa todos. A tela oferecia **um**: as abas de recurso. `action`
era lido do load e **nenhum controle o escrevia** — três filtros mortos, rodando em toda request.

Agora vivem na **sidebar**, como em Profissionais, Pacientes, Fila, Relatórios e Notificações
(links com `aria-current`, estado na URL):

```
REGISTRO          PERÍODO             AÇÃO           AUTOR
▸ Agendamentos    ▸ Hoje              ▸ Todas        ▸ Todos
  Participantes     Últimos 7 dias      Agendou        Ana Gestora
                    Últimos 30 dias     Remarcou       …
                  ▸ Todo o histórico    Cancelou
```

Decisões que o desenho fixou:

- **Período é preset, não date-picker**: a API valida a janela em **menos de 31 dias**
  (`TenantScope.validate_window`), então 30 dias é o maior recorte legal, e "todo o histórico" é a
  ausência de janela — que além de default é o caminho mais barato.
- **Ação é dependente do recurso** e trocar de registro **zera `acao` e `record_id`**: as duas
  tabelas de ação não se cruzam (`cancel` não existe em presença), e o filtro órfão devolveria um
  feed *legitimamente* vazio, que lê como defeito.
- **Chips no corpo** com `×` individual: filtro que mora fora do corpo precisa de eco dentro dele,
  senão lista curta lê como "não aconteceu nada". Mesma lição do vazio ciente do filtro
  ([doc 53](53-notificacoes-limpar-e-abas.md)).

## 3. Saiu de Configurações

`/auditoria`, seção própria do rail (owner·admin). Auditar não é um **ajuste** da clínica: é
consulta, com filtros próprios e a maior tabela do sistema atrás — e enterrada dois cliques abaixo
não tinha onde pendurar os filtros. A rota antiga responde **308** com a query preservada (os
deep-links `?record_id=` que a própria tela emitia já circulam).

Ícone do rail: `ScrollText`, e não `History` — o relógio-com-seta do `History` é quase idêntico ao
`Clock4` da Fila de espera a 19px, e o rail ficava com dois relógios vizinhos.

## 4. Backend

| # | Mudança | Por quê |
| --- | --- | --- |
| B1 | `member_json` expõe `user_id` | `id` é o do **vínculo**; a trilha grava o do **usuário**. Sem ele não há filtro por autor. |
| B2 | Versão de presença enriquecida com o bloco (`starts_at` + profissional) | A versão não guarda horário nem profissional. Sem isso a linha do participante não diz **de qual sessão** se fala, e não há "ver na agenda". Bloco excluído/segurado degrada para sem-contexto, de propósito: furar o `HideExcluded` aqui reabriria por uma leitura de auditoria o que o [doc 40](40-exclusao-de-agendamento.md) fechou. |
| B3 | Whitelist `@audit_actions` completa (10 nomes faltavam) | Nome fora dela vira filtro **nil**: o feed inteiro volta com 200 e quem filtrou não percebe. |

---

# Bate-volta

Três eixos de caça em paralelo (segurança, performance, refatoração) contra a stack rodando, mais
uma caça adversarial pelo browser. **13 achados, 6 causas-raiz, 0 de segurança.**

## 5. Segurança — 0 confirmados

Provado, não lido: recepção leva **403** na API e no web; RLS confirmada por baixo como
`movimento_app` (NOBYPASSRLS) — `appointments`/`appointments_versions`/`attendances_versions` da
clínica B devolvem **0** com a GUC em A; `user_id` malformado e `' OR 1=1 --` → **422**;
`record_id` de outra clínica → lista vazia; 308 sem open redirect nem header injection (CR/LF sai
percent-encodado); nenhum `{@html}`; `clinic_id` não aparece no payload; log sem query string.

O `authorize?: false` do enriquecimento foi **refutado com sonda**: `OwnAgendaOnly` é
*preparation*, não policy — roda mesmo com autorização desligada, então o recorte A7 sobrevive.
O que o `authorize?: false` desliga ali é só "você é membro deste tenant?", que o
`with_admin_scope` + a GUC já responderam.

## 6. Performance — o que ficou para decisão humana

**Os filtros novos por `acao` e por `autor` não têm índice.** O plano usa o
`clinic_time_idx` e filtra linha a linha até juntar 51. Medido em três volumes:

| Volume da trilha na clínica | Pior caso (ação rara, antiga) |
| --- | --- |
| **30 mil** (~1 ano de clínica cheia) | 2,4 ms · 627 buffers |
| 100 mil | 8,2 ms · 2.085 buffers |
| 250 mil | 65 ms · 7.561 buffers · 249.041 linhas descartadas |

**Não foi corrigido, de propósito.** O `PruneTrail` retém **365 dias**
([`config.exs`](../api/config/config.exs)), o que põe uma clínica cheia em ~30 mil versões — onde
o custo é 2,4 ms. As duas correções medidas são reais mas cobram caro pelo que entregam hoje:

- **índice composto** `(clinic_id, version_action_name, version_inserted_at DESC)` e o par para
  `user_id`: leva 7.561 → **6** buffers, mas são **4 índices novos** na tabela que mais cresce do
  sistema (3× a base), +50% de manutenção por `INSERT`, para poupar 2 ms;
- **exigir janela** quando `acao`/`autor` estão ativos: zero migração, 7.561 → 59 buffers, mas
  reduz a pergunta que a tela existe para responder ("todos os cancelamentos do ano").

**Gatilho para revisitar:** uma clínica passar de ~100 mil versões, ou a retenção do `PruneTrail`
subir. O molde do conserto já existe:
[`20260726210945_indice_fk_package_da_presenca.exs`](../api/priv/repo/migrations/20260726210945_indice_fk_package_da_presenca.exs)
(`CREATE INDEX CONCURRENTLY` + `@disable_ddl_transaction`/`@disable_migration_lock`, com o
moduledoc explicando por que os índices das tabelas `*_versions` são SQL na mão).

### Refutados com medição

N+1 (4 e 6 queries fixas para páginas de 3, 10 ou 50), `chain_diffs` (amplificação 50 → 56 linhas,
usa `(clinic_id, version_source_id)`), waterfall no load (paralelo de fato: 302 ms contra 602 se
serializado) e a janela `from`/`to`, que anexa no índice sem a armadilha do cast — `::timestamp`
sobre coluna `timestamp` é *folded*, e o range entra no `Index Cond`.

### Um conserto que a sonda derrubou

A sugestão de fundir as duas leituras do enriquecimento em uma (`load: [professional: [:nome]]`)
foi **implementada e revertida**: a sonda de SQL mostrou que o Ash emite o segundo `SELECT` de
qualquer forma (belongs_to carrega à parte) e que, sem `strict?` — que não é opção do `query:` da
code interface —, o profissional vinha com as **38 colunas** da ficha (CPF, RG, PIX, conta). Duas
queries enxutas ganham de duas queries, uma delas gorda. Fica registrado no código.

## 7. O que foi corrigido

| Causa-raiz | Conserto | Prova |
| --- | --- | --- |
| **Gate por papel morava só no rail** — a sidebar de filtros renderizava na página **403**, e a fiação do papel nas duas instâncias do rail não tinha teste (a mutação "tira `{papel}` só do mobile" sobrevivia inteira) | `canViewAudit` governa o ramo da sidebar; o par rail+sidebar virou **snippet único** no layout | 2 testes vermelhos primeiro; a classe do bug do CNPJ deixou de existir (não há mais dois lugares para divergir) |
| **Vocabulário de ações sem dono** — 3 cópias (Ash → whitelist → 2 tabelas do web); reduzir a whitelist a 2 nomes deixava 1177 testes verdes, e apagar uma headline deixava 135 verdes | Teste que deriva a verdade de `Ash.Resource.Info.actions/1` + teste de paridade entre as duas tabelas do web | As **duas** mutações repetidas por mim agora falham; revertidas e verdes |
| **Módulos compartilhados ignorados** — `parsePage`/`pageLabel`/`AuditPage` reimplementados apesar de `$lib/pagination`; `entry()` em dobro apesar de `$lib/testing/fixtures` | Reexporta `parsePage`, usa `PageInfo`, renomeia para `auditPageLabel` (a assinatura diverge de propósito); `auditEntryFixture` na casa certa | Sabotar `pagination.ts` deixava 59 testes da Auditoria verdes — as duas implementações estavam desligadas |
| **`/api/members` gordo no caminho quente** — o load da auditoria o chama em toda página e descarta `professionals`, que vinha com 38 colunas + uma query de `professional_hours` | `list_clinic_professionals/2` aceita `opts`; o controller pede `select: [:id, :nome]` — que é tudo o que ele emite | `professional_hours` sumiu; `professionals` caiu para `SELECT id, nome` |
| **Teste frágil** — `cleanup()` no fim do corpo do `it.each`: uma asserção que levanta faz o DOM sobreviver e cascatear | `afterEach(cleanup)` | Visto falhar 3 testes numa execução e passar nas 4 seguintes |
| **Resíduo textual** — import morto, 3 comentários falsos (rota antiga, "professional no attendance vem null" invertido pelo B2, "sete nomes" para uma lista de dez), specs apontando para a rota velha | Removidos/corrigidos; `docs/25 §11.4` e `docs/30 F2` atualizados | — |

## 8. O que fica para você

1. **Os dois índices da §6** — decisão de custo (4 índices na maior tabela × 2 ms hoje), com o
   gatilho medido.
2. **`parse_action` falha em silêncio**: ação desconhecida vira filtro nulo e devolve 200 com o
   feed inteiro, em vez de 422 como `record_id`/`user_id` malformados. Nada cruza fronteira
   (owner·admin já vê o feed da própria clínica) e o `parseAction` do web impede a tela de chegar
   nesse estado — mas o contrato da API é assimétrico. É decisão de produto.
3. **A classe da linha de filtro está escrita 11× no `Sidebar.svelte`** (Configurações,
   Profissionais, Agenda, Pacientes, Fila, Notificações ×2, Relatórios ×3 — e o snippet novo da
   Auditoria). Nenhuma diverge **hoje**; nada impede a próxima. O snippet cobre só o ramo novo, e
   como está não serviria a 4 dos 6 vizinhos (falta o parâmetro de contagem). A correção —
   `SidebarFilterLink.svelte` com `{ href, label, active, icon?, count? }` — mexe em 7 cópias
   fora desta fatia, e por isso não entrou.
