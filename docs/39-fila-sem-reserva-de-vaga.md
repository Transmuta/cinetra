# 39 — A fila não reserva vaga (e por que a reserva saiu)

Decisão tomada em 2026-07-24, com o humano, durante a verificação ao vivo do bate-volta
([`38`](38-bate-volta-frentes-3-e-4.md)). Substitui o desenho de `SlotHold` do
[`09 §6.2`](09-contrato-api.md) e o **F4** do [`30 §2`](30-decisoes-pendentes-agenda.md).

**A decisão em uma linha:** não existe reserva de vaga; existe **aviso de presença**. Quem garante
que dois atendentes não marquem o mesmo horário é — e sempre foi — a exclusion constraint do
**agendamento**.

---

## 1. O que a sonda mostrou

A verificação começou por uma pergunta simples do humano: *"entrei em 2 navegadores com 2 usuários
diferentes e não muda nada"*. Mudou nada mesmo, e o motivo estava no `git`:

```
$ git log --oneline -S'?/oferecer' -- web/src
(vazio)
```

A action que criava a reserva (`?/oferecer` → `POST /api/waitlist/:id/offer` → `SlotHold`)
**nunca foi submetida por nenhum componente, em nenhum commit**. O modal "Oferecer vaga" sempre
foi direto do clique na vaga para `?/converter`, que cria o agendamento. O passo de "segurar a
vaga" foi construído no backend na Entrega 5 e nunca ligado na tela.

Consequência: em produção a tabela `slot_holds` estaria **sempre vazia**. A exclusion constraint
nunca dispararia, o `409 slot_held` nunca aconteceria, o cron de limpeza varreria uma tabela sem
linhas, e o indicador do F4 (construído dias antes) nunca acenderia. As únicas reservas que
existiram foram as que as sondas do bate-volta criaram batendo direto na API com `curl`.

## 2. Por que a reserva não fazia falta

A colisão que ela existia para impedir **já era impossível**:

```sql
appointments_no_overlap
  EXCLUDE USING gist (professional_id WITH =, tsrange(starts_at, ends_at, '[)') WITH &&)
  WHERE (encaixe = false AND status <> 'cancelado')
```

E a conversão nunca dependeu do hold: `Api.Waitlist.convert/3` chama `schedule_appointment/2`
direto e depois tira o item da fila. Hold vencido, hold inexistente — converte igual.

Ou seja, o `SlotHold` **não impedia** a colisão; ele antecipava o aviso, do `Confirmar` para o
`Oferecer`. Uma otimização de UX sobre uma corrida que já era segura — e que cobrava:

| Custo | Detalhe |
| --- | --- |
| vaga presa | 10 min de TTL; fechar o modal não soltava (não havia rota de release — [`38 §5D`](38-bate-volta-frentes-3-e-4.md)) |
| decisão pendente | quem pode soltar o hold de outra pessoa? o Esc conta como desistir? |
| cron | um worker por-clínica varrendo uma tabela vazia (o D-L, otimizado dias antes) |
| superfície | tabela + constraint + rota + caminho 409 no controller, no BFF e na tela |

O julgamento do humano — *"se der problema os atendentes resolvem na agenda; se errou, vai lá e
muda"* — é exatamente o que a constraint garante: o erro possível é "esse horário não está mais
livre", nunca dado corrompido.

## 3. O que ficou no lugar: presença

O que tinha valor real no F4 era a **informação**, não a trava: evitar que a segunda pessoa ligue
para o paciente, combine sexta 8h e só então descubra. Isso virou `Phoenix.Presence`:

- o modal de Oferecer abre → o cliente manda `offering` com o **id do item**;
- o canal rastreia em `ApiWeb.Presence` e todos na clínica veem "Fulana oferecendo" na linha;
- o modal fecha → `stopped_offering`. **A aba morrer também para** — e é esse o ponto.

Três propriedades que a reserva no banco não tinha:

1. **morre sozinha** — sem TTL para escolher, sem cron para limpar, sem estado preso;
2. **não bloqueia** — os chips seguem clicáveis; dois podem oferecer o mesmo horário e se veem;
3. **não vai ao banco** — nenhuma tabela, nenhuma escrita, nenhuma RLS a atravessar.

O nome exibido vem do **servidor** (do vínculo lido no `join`), nunca do corpo da mensagem —
senão qualquer sessão se passaria por outra pessoa. Tem teste dedicado.

### O que a presença não faz

Não sobrevive a um F5 (a aba nova rastreia de novo, com um piscar) e **não é garantia de nada**.
Para garantia existe a constraint. Se um dia a clínica crescer a ponto de a colisão real doer,
o caminho não é voltar a reservar — é a constraint continuar sendo o portão e a tela ficar melhor
em explicar o 422.

## 4. O que foi removido

| Camada | Saiu |
| --- | --- |
| Recurso | `Api.Scheduling.SlotHold` + `changes/` + `validations/` |
| Banco | tabela `slot_holds` (migration `20260724022016_drop_slot_holds`), com a exclusion constraint junto |
| Worker | `SlotHold.CleanupWorker` + o cron do Oban (a fila `housekeeping` fica de pé para a Fatia 3) |
| Domínio | `offer_slot/3`, `live_holds/1`, `hold_meta`, `classify_hold_error` |
| Fronteira | rota `POST /waitlist/:id/offer`, `WaitlistJSON.hold/1`, o caminho `409 slot_held` |
| Notifier | as cláusulas `slot_held`/`slot_released` |
| Web | `offerSlot` (BFF), action `?/oferecer`, tipo `Hold`, `holdForSlot`, `holdLabel`, o chip com cadeado |

Entrou: `ApiWeb.Presence`, o `offering`/`stopped_offering` no `ApiWeb.WaitlistChannel`, e o
`applyPresenceDiff`/`offeringNames` no cliente de tempo real.

## 5. Prova ao vivo

Com a `/fila` aberta num navegador (usuário A) e uma segunda sessão real de outro usuário
(usuário B, conectada ao socket com o token dela):

1. B anuncia `offering` no item → a linha do A ganha **"Prof P1 oferecendo"**, e os chips de vaga
   continuam teal e clicáveis (nada travado);
2. a sessão de B é **morta** (equivale a fechar a aba) → o aviso **some sozinho** na tela do A.

Verde ao fim: api **772/0**, web **1169/1169**, `svelte-check` **0**.

## 6. O que isto invalida nos docs antigos

- [`09 §6.2`](09-contrato-api.md) ("Reserva de vaga (hold)"), a rota `/offer` da tabela de
  endpoints e o `slot_held` da tabela de códigos de erro — **não valem mais**;
- [`30 §2`](30-decisoes-pendentes-agenda.md) **F4** — entregue de outra forma, sem reserva;
- [`30 §4`](30-decisoes-pendentes-agenda.md) **D-L** (o cron do hold) — o worker não existe mais;
- [`30 §5`](30-decisoes-pendentes-agenda.md) **S4** (hold aceitava profissional arquivado) —
  some com o hold;
- [`38 §5D`](38-bate-volta-frentes-3-e-4.md) (falta rota de release) — resolvido por remoção.
