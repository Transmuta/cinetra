defmodule Api.Notifications.NotificationKind do
  @moduledoc """
  Os tipos de notificação in-app da v1 (doc 31 §4 — as três famílias do núcleo). O enum entra
  completo de propósito: acrescentar valor a um `Ash.Type.Enum` já persistido é migration, e o
  fan-out (`Api.Notifications.Fanout`) casa por estes átomos.

    * `:appointment_scheduled`  — alguém agendou na coluna de um profissional (não ele);
    * `:appointment_rescheduled`— um bloco do profissional foi remarcado por outra pessoa;
    * `:appointment_canceled`   — um bloco do profissional foi cancelado por outra pessoa;
    * `:slot_opened`            — falta/cancelamento abriu uma vaga **com fila casando** (→ recepção);
    * `:member_joined`          — um convidado aceitou e entrou na clínica (→ owner/admin).

  A2 (doc 41 etapa 5) destrava as duas que o doc 31 §3a deixou como "🟡 depois", porque as duas
  esperavam a fatia de turma/pacote:

    * `:appointment_missed`     — um paciente **faltou** (por presença, não por bloco: numa turma
      um pode faltar e outro não). O autor segue suprimido, então na prática dispara quando a
      recepção marca a falta na agenda do profissional;
    * `:participant_added`      — alguém entrou numa turma da coluna do profissional.

  O bate-volta da Onda 3 (doc 43 §5b) acrescenta a sexta, que é de **lote**:

    * `:package_bulk_adjusted` — N sessões de um pacote foram remarcadas de uma vez. Existe porque
      a massa por pacote gerava um `:appointment_scheduled` **por sessão** ("Novo agendamento na
      sua agenda", ×40 num pacote de 40) para o que é um evento só — e as sessões foram *movidas*,
      não criadas. Uma linha na caixa, com o número: *"3 sessões do pacote Pilates 10 foram
      remarcadas"*.

  A Onda 4 (Frente 10) destrava o que sobrara da §3 com decisão tomada:

    * `:role_changed`   — o papel de alguém mudou (#50, §3c). Vai ao **próprio afetado**;
    * `:member_removed` — alguém saiu da equipe (#50). Vai a owner/admin, e **não** ao removido:
      a caixa é por-tenant e só se lê com vínculo ativo, então o removido não teria como abri-la
      (o par com `:member_joined` é o que faz sentido chegar);
    * `:waitlist_urgent`— entrou na fila alguém marcado `urgente` (#48, §3b). O limiar é só o
      topo da prioridade — decisão de produto de 2026-07-26, para o sino não virar ruído;
    * `:daily_digest`   — "você tem N atendimentos amanhã" (#51, §3d), por cron;
    * `:session_soon`   — "sessão em 15 min" (#51, §3d), por cron.

  Deixados de fora da v1 (ruído ou dependência aberta, doc 31 §3): mudança de status feita pelo
  próprio autor e "paciente não confirmou" (depende da F7).

  Acrescentar valor aqui **não** é migration: a coluna é `text` (ver a migration de criação), e
  o enum vive no Ash. O que quebra é o contrário — remover um valor que já foi persistido.
  """
  use Ash.Type.Enum,
    values: [
      :appointment_scheduled,
      :appointment_rescheduled,
      :appointment_canceled,
      :appointment_missed,
      :participant_added,
      :package_bulk_adjusted,
      :slot_opened,
      :member_joined,
      :role_changed,
      :member_removed,
      :waitlist_urgent,
      :daily_digest,
      :session_soon
    ]
end
