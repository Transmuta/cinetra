# 63 — Auditoria completa: a tabela de eventos única

> Fatia derivada de [`61`](61-lacunas-da-auditoria.md), com as quatro decisões tomadas em
> 2026-07-28. Substitui o desenho de trilha do [`25 §11`](25-agenda.md) — que não some, mas
> deixa de ser o modelo de consulta.
>
> **Escopo: tudo.** Os 9 recursos sem rastro, os 2 que já têm, a trilha de leitura de anexo (que
> hoje é gravada e ninguém lê), a leitura de ficha e a autorização negada.

---

## 1. As quatro decisões

| # | Pergunta | Decisão |
|---|---|---|
| **D-Aud3** | Feed por recurso ou tabela única? | **Tabela de eventos única.** Uma linha por evento auditável, `resource` como coluna. Um feed cronológico da clínica inteira, um índice, uma policy, uma poda. |
| **D-Aud4** | O que a trilha guarda de CPF, RG, conta e PIX? | **Só "mudou", sem o valor.** Lista explícita de campos sensíveis por recurso; a linha do diff sai com `redacted: true` e sem `from`/`to`. |
| **D-Aud5** | Retenção? | **90 dias para tudo.** Revoga o P2 (365 dias / "guardar para sempre"). Razão do decisor: volume e custo; revisível com o jurídico. **Um único lugar** define o prazo. |
| **D-Aud6** | Auditar leitura de ficha? | **Sim, com deduplicação de 30 min** por (usuário, paciente). O acesso a anexo já é gravado e passa a ser legível. |

### O que a D-Aud5 exige que a D-Aud3 resolva

Poda em 90 dias **quebra o `:changes_only`**. O diff de hoje se monta *encadeando* a versão
anterior do mesmo registro ([`25 §11.4`](25-agenda.md), A-D13) — e se essa versão anterior foi
podada, o "de X" simplesmente não existe: a tela mostraria "para 09:00" sem dizer de onde.
Silenciosamente, e só nas entradas mais antigas da janela.

A saída não é um remendo, é melhor do que o que existe: **resolver o diff no momento da
escrita**. Dentro do `after_action` o changeset tem `data` (antes) e o resultado (depois) — o par
é gravado pronto. Consequências, todas boas:

- a poda de 90 dias fica **inofensiva** (cada linha é autossuficiente);
- some a segunda leitura que `list_audit_log/2` faz hoje para reconstruir as cadeias;
- some a assimetria do A-D13 ("mudar para `:full_diff` depois não reescreve o histórico");
- a redação da D-Aud4 acontece **antes** de o dado ser gravado — e não como filtro na leitura,
  que seria uma proteção que já chegou tarde.

### Duas pendências que a D-Aud5 encerra de graça

- **D-Aud1** (o feed não tem total): com 90 dias a tabela é **limitada por construção**. O
  `COUNT(*)` volta a caber, e o rodapé pode dizer "X–Y de Z". Fica como opção, não como dívida.
- **D-Aud2** (filtro por autor faz Seq Scan): com uma tabela só, **um** índice
  `(clinic_id, user_id, at DESC)` resolve — e o custo de escrita que assustava se dilui, porque
  a tabela não cresce sem teto.

---

## 2. O modelo — `Api.Audit`

Domínio novo. Não mora em `Api.Scheduling`: a trilha deixou de ser da agenda no momento em que
passou a cobrir equipe, ficha e acesso.

### `Api.Audit.Event` → tabela `audit_events`

| Coluna | Tipo | Papel |
|---|---|---|
| `id` | uuid | |
| `clinic_id` | uuid, FK `on_delete: :delete` | Tenant. **Coluna líder de todo índice** (ADR-017) e o que a RLS filtra |
| `resource` | enum | `:appointment`, `:attendance`, `:patient`, `:professional`, `:membership`, `:clinic`, `:appointment_type`, `:clinic_hours`, `:schedule_exception`, `:package`, `:waitlist_entry`, `:attachment`, `:seguranca` |
| `record_id` | uuid, **sem FK** | O registro tocado |
| `label` | string | O nome do registro **no instante do evento** |
| `action` | string | `schedule`, `revoke_access`, `visualizou`… |
| `action_type` | enum | `:create`, `:update`, `:destroy`, `:read`, `:deny` |
| `user_id` | uuid, **sem FK** | Quem. `nil` = sistema (job, materializador) |
| `user_label` | string | O nome de quem, no instante |
| `at` | utc_datetime_usec | Quando (relógio injetado, ADR-009) |
| `diff` | jsonb | `[{field, from, to, redacted}]` — já resolvido |
| `meta` | jsonb | Contexto para a linha e o link: `patient_id`, `professional_id`, `starts_at`, `appointment_id` |

**Nada aqui é FK além de `clinic_id`, e é de propósito** — a mesma razão já escrita em
[`AttachmentEvent`](../api/lib/api/records/attachment_event.ex): *o registro precisa sobreviver
ao que ele registra*. `CASCADE` apagaria a prova junto com o dado; `RESTRICT` tornaria o dado
indeletável (é o bug (c) do doc 26, que custou `reference_source? false`). Por isso `label` e
`user_label` são gravados: a linha continua legível depois que o registro e o usuário sumiram.

### Índices

```
(clinic_id, at DESC)                    -- o feed
(clinic_id, resource, record_id, at DESC) -- "o histórico deste paciente"
(clinic_id, user_id, at DESC)           -- filtro por autor (fecha o D-Aud2)
```

Três, e não mais: a tabela é a mais escrita do sistema e todo índice é peso em cada `INSERT`.
O filtro por `resource` sozinho anda de carona no segundo; o filtro por `action` fica sem índice
(é sempre combinado com um dos três).

### RLS

Migration própria, no molde de
[`20260719200000_agenda_constraint_and_rls.exs`](../api/priv/repo/migrations/20260719200000_agenda_constraint_and_rls.exs).
**Verificação por `psql` como `movimento_app`** entra no critério de pronto: `mix test` conecta
como `postgres` (BYPASSRLS) e furo aqui passa verde — é a armadilha que já custou 3 bugs na fatia
de Tipos e 1 no doc 58.

### Policies

Ler é **owner·admin** (mesma régua de hoje). Escrever, **ninguém** de fora: o `Capture` grava com
`authorize?: false`, e a policy de escrita é `forbid_if always()` — trilha que a aplicação pode
editar não é trilha.

---

## 3. A captura

### Escrita — `Api.Audit.Capture`

Um `Ash.Resource.Change` só, aplicado nas ações auditadas de cada recurso:

```elixir
change {Api.Audit.Capture, resource: :patient, label: :nome}
```

Roda no `after_action` — **dentro da transação**. Se o evento falhar, a escrita falha junto: uma
auditoria que perde eventos em silêncio é pior do que não ter auditoria.

O diff sai de `changeset.attributes` (o que de fato mudou) cruzado com `changeset.data` (o
antes) e o resultado (o depois). `inserted_at`/`updated_at` fora, como hoje.

### Redação (D-Aud4) — `Api.Audit.Sensiveis`

Fonte única, um mapa `resource → [campos]`:

```
:patient      → [:cpf, :rg]
:professional → [:cpf, :rg, :cnpj, :banco, :agencia, :conta, :conta_tipo, :pix]
```

Campo da lista vira `%{field: "pix", redacted: true}` — **sem `from`, sem `to`**. Não é filtro de
leitura: o valor nunca chega a ser gravado.

> **O que isso custa, dito claramente:** "quem trocou o PIX" fica respondível; "para qual conta"
> não. Foi a escolha explícita da D-Aud4, e é o que separa auditar de duplicar dado sensível numa
> segunda tabela append-only.

### Leitura (D-Aud6) — `Api.Audit.Acesso`

Abrir a ficha completa de um paciente grava `action_type: :read`, `action: "visualizou_ficha"`,
com **dedup de 30 minutos** por `(clinic_id, user_id, record_id)`: antes de gravar, consulta se
já há evento igual dentro da janela. O custo é um índice-hit por abertura de ficha, não um
`INSERT` — e a leitura é a operação mais frequente da recepção, o que era exatamente a objeção.

`Api.Records.AttachmentEvent` **é absorvido** por `audit_events` (`resource: :attachment`,
ações `enviou`/`visualizou`/`renomeou`/`removeu`), com backfill. Manter uma segunda tabela de
eventos contradiria a D-Aud3 — e é a trilha que mais importa ler.

### Autorização negada (§3b do doc 61)

`resource: :seguranca`, `action_type: :deny`. Gravado onde o 403 é montado — o `FallbackController` /
`with_admin_scope`, não em cada controller. Dedup de 30 min pela mesma janela, senão um bot
transforma a trilha em log de acesso.

---

## 4. A migração para fora do AshPaperTrail

Expand-contract, como o projeto já faz em deploy:

1. **Expand** — cria `audit_events`, liga o `Capture` em todos os recursos (incluindo
   `Appointment` e `Attendance`, que passam a escrever nos dois lugares por um deploy);
2. **Backfill** — copia os últimos 90 dias de `appointments_versions` e `attendances_versions`
   (encadeando o diff uma única vez, offline) e **todo** o `attachment_events`;
3. **Vira a leitura** — `list_audit_log/2`, `GET /api/audit` e a tela passam a ler `audit_events`;
4. **Contract** — remove `AshPaperTrail` dos dois recursos, `TrailMixin` morre. As tabelas
   `*_versions` param de receber escrita e a poda as esvazia em 90 dias; um `DROP` entra numa
   migration posterior, junto com a saída da dep `ash_paper_trail` do `mix.exs`.

O `@tabelas` de [`PruneTrail`](../api/lib/api/housekeeping/prune_trail.ex) ganha `audit_events`, e
o prazo passa a vir de **um lugar só** (`Api.Audit.retencao_dias/0`, default 90, sobrescrevível
por config) — para que a revisão com o jurídico seja a mudança de um número, não uma caçada.

---

## 5. O que a tela ganha

Um feed cronológico da clínica, não 12 abas. Os filtros passam a ser **facetas** sobre o mesmo
feed: tipo de registro, autor, período, ação. O `FieldDiff` existente é reaproveitado; a linha
redigida ganha um tratamento próprio (*"alterou o PIX"*, sem os valores).

A tradução (`ACTION_LABELS`/`HEADLINES` em [`web/src/lib/audit.ts`](../web/src/lib/audit.ts))
cresce para os 12 recursos — é o grosso do trabalho de frontend, e é o que impede a recepção de
ver nome de coluna e átomo cru.

---

## 6. O que foi construído (2026-07-28)

As oito etapas, com o que **divergiu** do plano acima e por quê — divergência escondida é o que
transforma um doc de plano em ficção.

| # | Etapa | Estado |
|---|---|---|
| 1 | `Api.Audit` + `Event` + migration + RLS forçada + 3 índices | feito |
| 2 | `Capture` + `Sensiveis` + diff resolvido na escrita | feito |
| 3 | Ligado nos recursos: `Patient`, `Professional`, `Membership`, `Clinic`, `AppointmentType`, `ClinicHours`, `ProfessionalHours`, `ScheduleException`, `Package`, `WaitlistEntry` | feito |
| 4 | Backfill + virada da leitura (`Api.Audit.list_events/2`, `GET /api/audit`) | feito |
| 5 | Tela: feed único, facetas por grupo, linha redigida | feito |
| 6 | `Api.Audit.Acesso` — leitura de ficha com dedup + absorção do `AttachmentEvent` | feito |
| 7 | Autorização negada | feito |
| 8 | Contract: `AshPaperTrail` fora, poda em 90 dias | feito |

### Divergências do plano, todas deliberadas

**(a) O `AshPaperTrail` saiu na MESMA release, sem o deploy de escrita dupla.** O plano previa os
dois gravando por um deploy. Não é preciso: as migrations rodam **em ordem** no mesmo
`release_command`, e o backfill vem antes do `DROP` — se ele falhar, o `DROP` não chega a rodar.
Manter os dois teria um custo medido: o teto de queries da massa por pacote passou de 120 para
**131** com a escrita dupla (16 `INSERT`s a mais por lote). Sem ela, 115.

**(b) Download de anexo NÃO é deduplicado.** A dedup de 30 min vale para a ficha, que a recepção
reabre dezenas de vezes por dia. Baixar um laudo é raro, e *"quantas vezes fulano baixou este
exame"* é pergunta legítima da LGPD que a janela apagaria. Aplicar a dedup ali era eu levando a
decisão além do que ela dizia.

**(c) A retenção de 730 dias da trilha de anexo foi absorvida pelos 90.** `PruneAttachments`
tinha prazo próprio, com o argumento de que *"quem leu o laudo em 2027"* dura mais que *"quem
remarcou a sessão de terça"*. A D-Aud5 é uma retenção só; o argumento fica registrado aqui e em
`Api.Audit` para a revisão com o jurídico.

**(d) `Attachment` não usa o `Capture`.** A trilha dele é escrita pelo caminho de acesso
(`Api.Audit.Acesso`), porque a `:visualizou` não passa por changeset nenhum e a remoção precisa
do nome já carregado. Ligar os dois gravava cada envio **duas vezes** — pego pelo teste da poda
(2 esperados, 4 encontrados).

### Achados durante a construção

- **`changes do` não alcança `destroy`.** O default do Ash é `on: [:create, :update]`. Sem o
  `on:` explícito, `revoke_access` — o evento mais importante da trilha inteira — não seria
  capturado, e nada ficaria vermelho. Já havia precedente escrito em `Api.Records.Attachment`.
- **A regra `*_id` não pega `id`.** A PK aparecia como primeira linha do diff de todo `create`.
- **O teste de contrato de `ON DELETE` tinha uma lista de domínios mantida à mão**, e ela
  envelheceu: `Api.Messaging` nunca foi acrescentado, então as 7 FKs de `messages`/
  `message_opt_outs` estavam fora dos dois contratos — inclusive o que existe para cobrar
  "FK nova exige decisão explícita". Passou a derivar de `ash_domains`.
- **O `at` vem do relógio do escopo** (ADR-009), fixo por requisição. Entre requisições
  diferentes ele não é monotônico com o relógio de parede — o desempate por `id` (uuid_v7) é o
  que dá ordem total ao feed.

### O que a tela ganhou

Um feed cronológico da clínica, com o grupo de registro como **faceta** (Tudo · Agenda ·
Pacientes e profissionais · Equipe e acessos · Configurações · Pacotes e fila · Anexos · Acesso
negado) — não mais um eixo que troca qual tabela é lida. O "de Z" do rodapé voltou (D-Aud1
encerrado pela retenção), e a whitelist de ações mantida à mão **deixou de existir**: `action` é
coluna de texto, então nome desconhecido devolve vazio em vez do feed inteiro.

## 7. Bate-volta (2026-07-28) — o que a auditoria da auditoria achou

Cinco rodadas contra a stack rodando. **A fatia chegou ao bate-volta com a tela em 500** — e
nenhum dos 54 testes de backend nem dos 1637 do web dizia isso. Os achados colapsaram em nove
causas; seis foram consertadas, três ficaram para decisão humana (§8).

### O achado que justifica o método

`GET /api/audit` respondia **500** em toda clínica com histórico migrado. O backfill gerava a PK
com `gen_random_uuid()` — **UUID v4** — numa coluna `uuid_v7_primary_key`, e o `Ash.Type.UUIDv7`
valida a versão **ao carregar**. Uma linha ruim derruba a página inteira, porque o Ash carrega o
conjunto.

    veio_do_backfill | versao_uuid | count
    -----------------+-------------+-------
     f               | 7           |   297     ← escritas pela app
     t               | 4           |   294     ← escritas pelo backfill

A suíte inteira era cega a isso: **todo teste lia linha escrita pela app**, que nasce do `default`
da coluna. Nenhum atravessava a fronteira do SQL cru. Hoje `test/api/audit/backfill_test.exs`
atravessa.

### Uma causa, dois sintomas opostos

`Event.label`/`user_label` têm teto de 200; `User.nome` era o único rótulo do sistema **sem teto**,
e o usuário o edita. O mesmo dado malformado produzia efeitos contrários:

- pelo `Capture` (bang, **dentro** da transação de negócio) a trilha **derrubava a escrita
  observada**: um membro com nome de 201 caracteres não podia ser removido da clínica
  (`DELETE /api/members` → 500, vínculo intacto), e ele mesmo não conseguia editar ficha nenhuma;
- pelo `Acesso` (sem bang, retorno descartado) o evento **sumia**: bastava encher a URL para o 403
  não deixar rastro — a trilha de acesso negado era evadível por padding.

Consertar um lado sem o outro teria sido consertar metade. É o ganho concreto de caçar tudo antes
de encostar no código: os dois só aparecem juntos quando a lista está completa.

### Os demais consertos

| Causa | O que era | Prova |
|---|---|---|
| Dedup do 403 **nunca rodava** | `record_id` é nulo em `:seguranca` e a guarda curto-circuitava; a ação exigia id não-nulo. Dois comentários afirmavam o contrário | 100 requests idênticos → 100 linhas |
| Falha da trilha de leitura **engolida** | retorno descartado, sem `Logger` | evento perdido, log vazio |
| Tenant do evento **invertido** | `changeset.tenant` vencia `tenant_from` → criar 2ª clínica gravava o evento na trilha da 1ª (RLS não pega: a linha entra *legitimamente* no tenant errado) | nome da clínica nova no `/auditoria` da antiga |
| `count: true` no feed | eu justifiquei com "90 dias limita a tabela" — argumento de **tamanho**, não de **custo/request** | 23,9 ms · 191 buffers contra 0,090 ms · 9 da própria página (**265×**), ~99% do tempo de banco |
| `id` fora do índice do feed | o `ORDER BY at DESC, id DESC` caía num nó de `Sort` | 28×; agravado porque `at` vem de `scope.now` e é **estável por request** |
| Documentação mentindo | poda anunciava 365 (o job faz 90), citava `TrailMixin` deletado e `*_versions`; `Sensiveis` apontava um teste **que não existia** | leitura |

### A rede que faltava (e a prova de que agora existe)

Os testes cobriam **exemplares**, não regras. Medido por mutação:

- **6 dos 8 campos sensíveis** podiam parar de ser redigidos em verde (só `cpf` e `pix` tinham
  teste). Hoje `sensiveis_test.exs` — o arquivo que o moduledoc prometia — fecha a lista nos dois
  sentidos; a mesma mutação agora dá **8 falhas**;
- o `:destroy` do `Capture` só tinha rede no `Membership`: tirá-lo de outros **nove** recursos
  deixava 156 testes verdes. Hoje `capture_ligado_test.exs` lê o `on:` do DSL e a mutação dá
  falha **nomeada**;
- a junção enum Elixir ↔ união TypeScript não era amarrada por nada: remover dois recursos de um
  grupo passava verde, e o efeito era sumirem da sidebar. Hoje há tripwire dos dois lados — o
  container da API não enxerga `web/`, então é o mesmo padrão já usado na paleta de
  `AppointmentType`.

### Achado no diff dos próprios consertos (rodada 5)

O `Logger.warning` que eu **acabara de adicionar** para acabar com o silêncio usava
`Exception.message/1` — que num `Ash.Error.Invalid` carrega o **valor** recusado, ou seja o nome
do paciente cuja ficha foi aberta. Um conserto de observabilidade criando um vazamento de PII no
log. Passou a registrar só os **nomes dos campos**.

### Refutado com sonda (estava certo)

RLS de `audit_events` bloqueia leitura e escrita cross-tenant como `movimento_app`
(`new row violates row-level security policy`); IDOR e mass-assignment barrados; sem SQLi na
migration de backfill (toda interpolação vem de literal de módulo); sem XSS; a redação de CPF/RG
de fato não grava o valor; o enriquecimento **não** é N+1 (2 queries constantes de 5 a 200
entradas); a poda usa índice; a cadeia de migrations sobe limpa do zero.

## 8. O que fica em aberto

### Decisões que o bate-volta devolve para você

**(a) `tags`, `medico` e `crm` em claro — DECIDIDO em 2026-07-28: a exposição é aceita.**
As `tags` são "condições clínicas em texto puro" pela decisão da fatia de Pacientes — dado do
Art. 11 —, e o diff as guarda com valor: `{"field":"tags","from":["HIV+"],"to":["hepatite C"]}`.
A assimetria com CPF/RG (que **são** redigidos) foi levantada e aceita. O que a sustenta: não há
escalação de privilégio — a trilha é owner·admin e a ficha é legível por todo membro, então quem
lê o diff já podia ler o campo. O que se aceita é o custo de **minimização**: o valor passa a
existir numa segunda tabela, append-only, sem tela de correção, e a eliminação do titular
(F8/D-1) terá de alcançá-la. Registrado no moduledoc de `Api.Audit.Sensiveis`; reverter é
acrescentar os três à lista, e o teste cobra a mudança nos dois sentidos.

**(b) Backfill lento — DECIDIDO: o índice de apoio entra.** A suspeita era de explosão
quadrática; a medição **derrubou a suspeita e manteve a correção**. Simulei a forma real da
tabela (maioria com 1–3 versões, cauda de 10% com 10–40, mais 20 registros com 500) e rodei a
query exata da migration:

| versões | como estava | com o índice |
|---|---|---|
| 86.010 | 2,75 s | 2,15 s (−22%) |
| 390.000 | 18,97 s | 9,01 s (−53%) |

Criar o índice custa **257 ms**. Não era bloqueador de deploy: o Postgres põe um `Memoize` sobre
o laço correlacionado e cacheia as buscas repetidas, então nem a cauda de 500 versões move o
relógio de forma dramática — foi o que a sonda mostrou e a teoria não previa. O que sobra é
janela de deploy: o ganho **cresce com o volume** e o índice também tira a superlinearidade
(sem ele 4,5× de linhas custavam 6,9× de tempo; com ele, 4,2×).

`CREATE INDEX` comum, **sem `CONCURRENTLY`** — e a exceção à regra do projeto está escrita na
migration: o índice precisa existir dentro da transação que o usa, e `CONCURRENTLY` é
justamente o que não roda em transação. O `ShareLock` não cobra o preço habitual porque as
tabelas já não recebem escrita do app (o `AshPaperTrail` saiu na mesma release) e somem na
migration seguinte. O índice é criado e dropado dentro do próprio `up`.

### Pendências técnicas

- **A revisão da retenção com o jurídico** (D-Aud5). O número está em `Api.Audit.retencao_dias/0`
  e no `config.exs`, num lugar só.
- **O `DROP` da dep `ash_paper_trail`** do `mix.exs`: as tabelas já saíram, a dep continua.
- **`audit_events` no gate `:rls`.** A RLS foi provada à mão como `movimento_app` (leitura
  cross-tenant devolve 0 linhas; `INSERT` cross-tenant é recusado pela policy), mas o arquivo
  `rls_smoke_test.exs` ainda não a exercita como as demais tabelas.
- **`Api.Audit.Acesso.registrar/7`** tem seis posicionais que descrevem a mesma entidade; e
  `Api.Records.registrar_evento/3` e `registrar_evento!/3` ficaram byte a byte idênticas depois do
  refactor — o `!` promete "deixa estourar" e entrega o oposto. Dívida menor, não corrigida para
  não misturar com os consertos de segurança.
- **`list_clinic_attachment_events/2` continua sem consumidor** (só testes). É o mesmo sintoma que
  a fatia diagnosticou no `AttachmentEvent` que removeu: a implementação mudou, o sintoma ficou.
- **A janela de 30 min da dedup não está fixada por teste** — alargá-la para 300 passa verde.
