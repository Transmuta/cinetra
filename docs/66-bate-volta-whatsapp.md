# 66 — Bate-volta da fase 2 da comunicação (doc 65)

Auditoria em rodadas contra a **stack rodando**, não contra a leitura do diff. Alvo: o que a fase
2 escreveu — adapter e webhook da Zernio, gatilhos do C7(b), telefone obrigatório, resposta do
paciente no sino e o aviso único da massa por pacote.

**Onde parou:** rodada 5. As duas caças acharam **dois** achados desta fatia; os dois foram
corrigidos e re-sondados. Uma causa estrutural pré-existente e um achado alheio ficam para decisão
humana (§5).

> **Nota de concorrência.** Outra sessão editava a trilha de auditoria e o telefone do profissional
> no mesmo tree durante esta auditoria. Só o que é da fase 2 foi auditado; o que apareceu do lado
> de lá está marcado como tal e **não** foi tocado, exceto duas correções mecânicas de fixture que
> a mudança deles quebrou e que travavam a suíte inteira (§5).

---

## 1. A varredura

### Segurança

| Item | Estado | Sonda |
| --- | --- | --- |
| Rota pública nova (`/webhooks/zernio`) sem assinatura | REFUTADO | `curl` sem header → **401**; com assinatura errada → **401**; corpo sempre `{"error":"assinatura_invalida"}` |
| Fail-closed sem segredo configurado | REFUTADO | Dev não tem `ZERNIO_WEBHOOK_SECRET`: toda chamada responde 401 |
| Estreiteza da exceção da RLS (o webhook lê sem tenant) | REFUTADO | Como `movimento_app`: com a GUC do provider setada, `count(*) = 1`; sem ela, `0` |
| **Amplificação por replay na rota pública de resposta** | 🔴 **CONFIRMADO** | §2, causa A |
| Tenant vindo do cliente | REFUTADO | O webhook resolve o tenant pelo id do provider (uma linha); a resposta, pelo token assinado |
| Mass assignment no campo novo da clínica | REFUTADO | `zernio_account_id` não está em `accept` de nenhuma ação e é `public?=false` |
| `vars` (que agora carrega a conta) vaza pela timeline? | REFUTADO | O serializer devolve `titulo`, não `vars` |
| Segredo em log | REFUTADO | 0 ocorrências de `sk_…`/`whsec_`/`Bearer` em 400 linhas; nenhum `Logger` do diff imprime credencial |
| PII do paciente no log de falha | REFUTADO | 5 erros reais com telefone/e-mail dentro → todas as saídas de `Falhas.para_tela/1` sem `@`, sem 8 dígitos, sem `sk_` |
| Fan-out cross-tenant | REFUTADO | 216 notificações criadas, **100%** com `clinic_id` igual ao da mensagem; destinatários só `owner`/`recepcao` |
| `String.to_atom` em entrada | NÃO SE APLICA | Nenhuma ocorrência no diff |
| CSRF/CORS | NÃO SE APLICA | As rotas novas são POST de provider, sem cookie |
| Auth / magic link / OAuth | NÃO SE APLICA | Sem superfície de autenticação no diff |

### Performance

| Item | Estado | Número medido |
| --- | --- | --- |
| Índice para a query nova da âncora da massa | REFUTADO | `Index Scan using attendances_clinic_id_package_id_index`, **4 buffers, 0,9 ms**, top-N sort sobre 4 linhas |
| N+1 no fan-out da resposta | REFUTADO | 1 POST = 7 queries com tabela (2 `messages`, 1 `memberships`, 1 `appointments`, 1 `patients`, 2 `notifications`) — os 2 últimos são 1 por destinatário, que é o modelo |
| Custo por massa (aviso ao paciente) | CONFIRMADO na 1ª versão, corrigido | 20 → **8 queries por massa**, constante; o teto do `BulkQueriesTest` pegou |
| I/O externo dentro da transação da GUC | REFUTADO | Instrumento novo no duplo: `em_transacao?: false` na entrega |
| FK nova sem índice | NÃO SE APLICA | A migration só acrescenta uma coluna `text` em `clinics` |
| `CREATE INDEX` em tabela quente | NÃO SE APLICA | Nenhum índice novo |
| Listagem sem paginação | NÃO SE APLICA | Nenhuma read nova de coleção |

### Refatoração

| Item | Estado |
| --- | --- |
| DRY entre a caixa e a mensagem (pluralização) | CONFIRMADO na escrita → `Api.Texto`, com o `Fanout` migrado |
| Regra do telefone duplicada no web | REFUTADO como divergência — está documentada como espelho deliberado, e a outra sessão a estendeu com teste que fixa a divergência proposital |
| Comentário que mente | 🔴 **CONFIRMADO** (2, §2 causa C) |
| Rules do Ash/Elixir | REFUTADO — sem `case` aninhado, erros como valor, casamento na cabeça |
| Migration fora de `priv/repo/migrations` | NÃO SE APLICA |
| Duplicação em teste | REFUTADO — as fixtures novas entraram em `Api.Generators`, não copiadas |

### O que a rodada 2 achou que a 1 não tinha achado

A rodada 1 fechou com a checklist toda respondida e **um** confirmado (a amplificação, que caiu
na pergunta "rota pública sem rate limit"). A rodada 2, seguindo o fluxo em vez da lista, achou o
**achado B** — que nenhuma classe de ataque cobre, porque não é ataque: é um nome com quebra de
linha. Foi o ângulo adversarial ("o que eu ganho se eu mentir aqui?" virou "o que o dado real tem
que eu não previ?") que pagou.

---

## 2. As causas-raiz

### A — a rota pública ganhou um efeito colateral não-idempotente

A resposta do paciente sempre foi idempotente por construção: responder duas vezes preserva o
instante da primeira. O fan-out para a caixa da recepção entrou **por cima** dela sem essa
propriedade, numa rota **pública, sem sessão e sem rate limit**.

```
$ for i in 1 2 3 4 5; do curl -s -X POST .../api/reply/$TOKEN -d '{"resposta":"quer_remarcar"}'; done
notificacoes antes=2 depois=12   (5 replays da MESMA resposta)
```

Dez notificações a mais por cinco cliques. O link se encaminha; quem o tiver enche a caixa da
clínica — e cada requisição custa ~26 statements.

É a mesma classe que o moduledoc de `ZernioSignature` nomeia para o webhook ("evento novo com
efeito não-idempotente exige tabela de id visto"). Escrevi o aviso num lugar e cometi o erro no
outro.

### B — parâmetro de template sai com quebra de linha

A Meta recusa parâmetro de template com `\n`, tab ou 4+ espaços seguidos. O valor vem da ficha,
que é texto livre — um nome colado de PDF carrega `\n` sem ninguém ver na tela.

```
SONDA params=["Ana\nMaria", "Clínica  \t X", "28/07", "14:00", "t"]
SONDA tem_quebra=true tem_tab=true
```

O modo de falha é o pior tipo: silencioso e mal-endereçado. A mensagem **daquele** paciente falha
sempre, e o texto que chega à recepção é *"Template de WhatsApp não aprovado ou fora do padrão"* —
que manda olhar o template. O template está certo.

### C — dois comentários que mentiam

Consequência da remoção do gatilho de exclusão (decidida depois da entrega): o `MessageKind` ainda
dizia que `:cancelamento` "vale para cancelar E para excluir", e o filtro de destinatários ainda
explicava o caso `:exclude`. Comentário que descreve o passado como presente é duplicação
apodrecida.

---

## 3. O que foi corrigido

| Causa | Teste vermelho | Conserto | Re-sonda (rodada 5) |
| --- | --- | --- | --- |
| **A** | *"responder DUAS vezes não duplica a caixa"* — falhou com 2 notificações onde se esperava 1 | `avisar_a_recepcao/2` compara o **antes** com o **depois**: avisa na transição, não na chamada | 5 replays → **antes=12 depois=12**. E a transição real (confirmou → quer remarcar) → **+2**, um por destinatário |
| **B** | *"nome com quebra de linha não vai como está"* | `higienizar/1` colapsa whitespace **só no WhatsApp**, e roda **antes** do corte do primeiro nome (senão "Ana\nMaria" não tem espaço para cortar) | `params=["Ana", "Clínica X", "28/07", "14:00", "t"]` |
| **C** | — (comentário) | Reescritos no `MessageKind` e no `Notifier` | — |

Dois testes a mais guardam o que a correção A **não** deve barrar: mudar de ideia avisa de novo, e
confirmar continua sem notificar.

E uma sonda que a caça não conseguiu rodar ficou instrumentada: o duplo de WhatsApp agora registra
`em_transacao?`, e o teste afirma `false` — é o que impede a correção do doc 60 (I/O externo fora
da transação da GUC) de ser desfeita sem ninguém ver.

### Auditoria do diff dos consertos

Superfície nova: nenhuma — sem rota, sem query, sem migration, sem render novo. Os `NÃO SE APLICA`
da rodada 1 continuam valendo. Dois pontos conferidos no código novo:

* a guarda de A trata `resposta` anterior `nil` (primeira resposta de todas) como transição — que é
  o comportamento certo;
* `higienizar/1` roda sobre valor que `nome/2` garante ser binário, e o e-mail **não** passa por
  ela (asseverado por teste).

---

## 4. Provas finais

* **Backend:** 1.459 testes, **90,3 %** (gate 80), `mix format --check-formatted` limpo,
  `mix compile --warnings-as-errors` limpo.
* **Web:** 1.664 testes, 0 falhas.
* **Gate `:rls`** (`movimento_app`, NOBYPASSRLS): verde, exceto as duas falhas do §5.

---

## 5. O que fica para decisão humana

**1. Rotas públicas sem rate limit** — estrutural, pré-existente. **Em construção em outra sessão**
(rate limit global de 200 req/min), então não foi tocado aqui.
`:rate_limited` cobre só o pipeline de auth; `/api/reply/:token` e os dois `/webhooks/*` estão no
`:api` puro. A correção A tirou o ganho do replay (não escreve mais nada), mas cada requisição
ainda custa ~26 statements e ninguém a limita. **Correção seria** estender o `RateLimitAuth` (ou um
irmão dele) ao pipeline público, por IP e por token. Não foi feito porque muda um plug compartilhado
com o fluxo de autenticação, e isso é decisão de infra, não de fatia.

**2. Corrida estreita na guarda de A.**
Dois POSTs simultâneos com `quer_remarcar` leem ambos o estado anterior e ambos notificam — teto de
2 linhas, e só com requisições concorrentes de verdade. **Correção seria** mover a decisão para
dentro da escrita (só notificar se o `UPDATE` mudou a coluna). Não foi feito: o custo é uma ação
Ash devolvendo "mudou?" e o ganho é uma linha duplicada num caso raro.

**3. `bulk_cancel` não notificava a caixa** — ✅ **corrigido depois do relatório**, por decisão de
2026-07-28: notificar o profissional, e **só in-app** (o paciente já recebe a mensagem dele pelo
outro caminho).

Era pré-existente: as notificações por sessão são suprimidas pela marca de lote e o aviso único só
existia no `adjust`. Ficou visível quando o paciente passou a ser avisado — quem ia à sessão sabia,
e quem ia atender, não.

Entrou como `:package_bulk_canceled`, irmão do `:package_bulk_adjusted`, com os dois caminhos
reunidos num fan-out só (`Api.Notifications.Fanout.massa/6`): mesmos destinatários, mesma supressão
de autor, mesma contagem — o que muda é o verbo. Duas cópias de "quem recebe" seria a duplicação
cara, porque regra de destinatário é o que mais muda.

Teste vermelho antes: *"cancelar a série avisa o PROFISSIONAL na caixa, uma vez"*, que falhava com
lista vazia.

**4. Duas falhas do `RlsSmokeTest` que não são desta fatia** — `bulk_adjust` e `bulk_cancel`
continuam vermelhas, com `targets/3` devolvendo vazio antes de qualquer código da fase 2 rodar. É o
mesmo par que o [doc 60 §5](60-bate-volta-comunicacao.md) desatribuiu com cinco sondas.

**5. Duas correções de fixture no território da outra sessão.**
A mudança deles (telefone obrigatório também no profissional) deixou 47 fixtures e o helper
`create_prof` sem telefone, e a suíte inteira vermelha. Corrigi mecanicamente — mesmo padrão que a
fase 2 já tinha aplicado aos pacientes — para poder auditar. Se eles fizerem o mesmo do lado de lá,
é a mesma intenção duas vezes, não um conflito.
