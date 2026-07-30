defmodule Api.Audit.ResourceKind do
  @moduledoc """
  Que tipo de registro um evento da trilha descreve — a coluna que faz `audit_events` ser **uma**
  tabela em vez de doze (doc 63, D-Aud3).

  A lista é fechada e explícita. Um recurso novo entra aqui **por decisão**, no mesmo commit em
  que ganha o `Api.Audit.Capture` — do mesmo jeito que o `@tabelas` da poda é escrito à mão. Um
  enum aberto (string livre) tornaria o filtro da tela impossível de validar e deixaria typo
  virar categoria nova em silêncio.

  `:seguranca` é o único valor que não é um recurso do domínio: é onde mora a autorização negada
  (doc 61 §3b), que não descreve mudança em registro nenhum — descreve uma tentativa.
  """
  use Ash.Type.Enum,
    values: [
      :appointment,
      :attendance,
      :patient,
      :professional,
      :membership,
      :clinic,
      :appointment_type,
      :clinic_hours,
      :professional_hours,
      :schedule_exception,
      :package,
      :waitlist_entry,
      :attachment,
      :seguranca
    ]
end
