defmodule Api.Scheduling.Appointment.Changes.CheckAvailability do
  @moduledoc """
  Recusa agendamento fora do expediente (A6/RN-14) — a validação que é **independente** da
  checagem de conflito: um slot livre em feriado é 422, e um slot ocupado em dia útil é 422
  com outro `code`. As duas são obrigatórias e separadas.

  Compõe as 4 camadas via `Api.Scheduling.Availability` e exige que a sessão caiba **inteira
  em um** período: 11:30–12:20 atravessando o almoço é recusado, mesmo que os dois períodos
  somados cubram o intervalo.

  **Encaixe não isenta** (A-D2): não há cláusula `where :encaixe` aqui. O protótipo faz o
  mesmo — `canSave` exige `!avail` ([`:2001`], [`:2289`]) — então nem admin agenda em feriado
  (D14, bloqueio absoluto).

  ## Sobre a ordem dos hooks

  O carregamento das fontes seta a GUC de tenant **ele mesmo** (via
  `Api.Scheduling.load_availability_sources/3`) em vez de contar com o `SetTenantGuc`. Os dois
  são `before_action` e a ordem entre eles não é garantida; se este rodasse primeiro, as
  leituras voltariam vazias sob RLS e **todo dia pareceria fechado** — um 422 fantasma que a
  suíte jamais pegaria, porque o sandbox conecta como `postgres` (BYPASSRLS).
  """
  use Ash.Resource.Change

  alias Api.Scheduling.{Availability, CodedError, LocalTime, Warm}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    with %DateTime{} = starts_at <- Ash.Changeset.get_attribute(changeset, :starts_at),
         %DateTime{} = ends_at <- Ash.Changeset.get_attribute(changeset, :ends_at),
         professional_id when is_binary(professional_id) <-
           Ash.Changeset.get_attribute(changeset, :professional_id),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant do
      verify(changeset, to_string(clinic_id), professional_id, starts_at, ends_at)
    else
      # Campo faltando: outra validação reporta. Não inventamos erro de expediente aqui.
      _ -> changeset
    end
  end

  defp verify(changeset, clinic_id, professional_id, starts_at, ends_at) do
    %{timezone: timezone} = clinic = clinic(changeset, clinic_id)
    date = LocalTime.to_local_date(starts_at, timezone)

    case sources(changeset, clinic_id, professional_id, date) do
      {:error, :professional_not_found} ->
        error(changeset, :professional_id, "profissional não encontrado nesta clínica")

      {:ok, professional, sources} ->
        evaluate(changeset, professional, sources, date, {starts_at, ends_at}, timezone, clinic)
    end
  end

  # Num LOTE (a massa por pacote), a clínica e as fontes de expediente são as mesmas para todas as
  # sessões e vêm prontas no contexto — ver `Api.Scheduling.Warm`. Fora do lote, `:miss`, e é a
  # leitura de sempre: o warm é atalho, não autoridade.
  defp clinic(changeset, clinic_id) do
    case Warm.clinic(changeset, clinic_id) do
      {:ok, clinic} -> clinic
      :miss -> Api.Scheduling.load_clinic(clinic_id)
    end
  end

  defp sources(changeset, clinic_id, professional_id, date) do
    case Warm.sources(changeset, clinic_id, professional_id, date) do
      {:ok, professional, sources} ->
        {:ok, professional, sources}

      :miss ->
        Api.Scheduling.load_availability_sources(clinic_id, professional_id, date)
    end
  end

  defp evaluate(changeset, professional, sources, date, range, timezone, _clinic) do
    {starts_at, ends_at} = range

    case Availability.day_periods(date, professional, sources) do
      {:closed, reason} ->
        error(changeset, nil, mensagem_fechado(reason), code(reason))

      {:open, periods} ->
        local = LocalTime.to_local_range(starts_at, ends_at, timezone)

        if Availability.fits?(periods, local) do
          changeset
        else
          error(
            changeset,
            nil,
            "Esse horário está fora do expediente (#{descreve(periods)}).",
            "outside_business_hours"
          )
        end
    end
  end

  # Códigos estáveis do contrato (doc 25 §5): a UI decide o que oferecer a partir deles, não
  # do texto da mensagem.
  defp code(:clinica_fechada_excecao), do: "closed_by_exception"
  defp code(:folga_profissional), do: "closed_by_exception"
  defp code(_), do: "outside_business_hours"

  defp mensagem_fechado(:clinica_fechada_excecao), do: "A clínica está fechada nesta data."
  defp mensagem_fechado(:folga_profissional), do: "O profissional não atende nesta data."
  defp mensagem_fechado(:folga_semanal), do: "O profissional não atende neste dia da semana."
  defp mensagem_fechado(:sem_grade), do: "O profissional não tem horário definido neste dia."
  defp mensagem_fechado(_), do: "A clínica não atende neste dia."

  # Sem cláusula para `[]` de propósito: `Availability.open_or_closed/2` devolve `{:closed, _}`
  # para lista vazia, então `{:open, []}` não existe e o único chamador (acima) já está no ramo
  # `:open`. A cláusula existia e o Elixir 1.20 a apontou como morta — ver o comentário em
  # `availability.ex`, que é onde a invariante mora.
  defp descreve(periods) do
    Enum.map_join(periods, ", ", fn [ini, fim] -> "#{ini}–#{fim}" end)
  end

  # O `code` viaja em `vars` e a exception é montada à mão — ver `Api.Scheduling.CodedError`,
  # que centraliza o porquê (e a armadilha do `add_error/2` aninhando keyword lists).
  defp error(changeset, field, message, code \\ nil)

  defp error(changeset, nil, message, code),
    do: Ash.Changeset.add_error(changeset, CodedError.invalid_changes(message, code))

  defp error(changeset, field, message, code),
    do: Ash.Changeset.add_error(changeset, CodedError.invalid_attribute(field, message, code))
end
