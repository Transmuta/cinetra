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

  Deixados de fora da v1 (ruído ou dependência aberta, doc 31 §3): mudança de status feita pelo
  próprio autor, "paciente não confirmou" (depende da F7), lembretes por tempo.
  """
  use Ash.Type.Enum,
    values: [
      :appointment_scheduled,
      :appointment_rescheduled,
      :appointment_canceled,
      :slot_opened,
      :member_joined
    ]
end
