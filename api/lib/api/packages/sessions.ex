defmodule Api.Packages.Sessions do
  @moduledoc """
  Criação de **uma** sessão de pacote — o pedaço compartilhado entre a materialização inicial
  (`Api.Packages.Materializer`) e a reprojeção da retomada (`Api.Packages.resume_package/2`).

  Cria o agendamento via `Api.Scheduling.schedule_appointment/2` (que funde em turma existente
  quando é o caso, A-D4) **com o `package_id` na entrada** — o vínculo por participante que o
  contador `usadas` conta (D11). `authorize?: false` porque quem autoriza é a ação do pacote; esta
  é escrita de cascata, como `CascadeToAttendances`.

  Até a etapa 2 da A2 (doc 41) o carimbo era um `set_package` **depois** da criação, precedido de
  uma releitura do bloco sob a GUC. Além do custo (uma leitura e uma escrita por sessão), havia a
  janela: entre criar e carimbar, a presença existia sem pacote — e uma falha no meio deixava
  sessão fora da contagem sem sinal nenhum. Hoje as duas coisas são a mesma escrita.

  ## `bulk_pacote` no contexto — a marca que faltava aqui

  Materializar é uma escrita de **lote**: N sessões numa varredura só. A marca diz isso aos dois
  notifiers (`Api.Messaging.Notifier` e `Api.Notifications.Notifier`), que então não falam uma vez
  por sessão.

  Ela existia desde a fatia de comunicação e era posta **só** em `Api.Packages.Bulk` (ajuste e
  cancelamento em massa de pacote já existente). O caminho da criação passava aqui sem contexto
  nenhum, e um pacote de N enfileirava N confirmações para o mesmo paciente — 40 mensagens de
  WhatsApp **pagas** para o mesmo número num pacote de 40 (§9.1.1). Passava despercebido porque as
  mensagens saíam uma a uma; com a janela de silêncio (§7) elas se acumulam e chegam todas juntas
  às 8h, que foi como o defeito apareceu.

  **A criação de pacote não fala com o paciente** — nem uma vez por sessão, nem uma consolidada.
  Diferente da massa (`Api.Packages.Bulk.avisa_o_paciente/6`), que substitui as N por uma:
  remarcar e cancelar anunciam um fato que o paciente **precisa** saber e não pediu; agendar o
  pacote é o que ele acabou de combinar no balcão. O lembrete (se ligado) e o botão do drawer
  continuam de pé para cada sessão.
  """

  @doc """
  Cria a sessão em `starts_at` para o paciente do pacote, já vinculada ao pacote. `forcar` vira
  `encaixe: true` (fura conflito/turma cheia; **não** fura expediente — D14). Devolve `{:ok,
  appointment}`; erros de escrita propagam para abortar a transação de quem chama.

  ## Pacote pausado nasce SEGURADO (A-6, doc 42 → doc 69 §10 B4.6)

  Se o usuário **pausa** dentro da janela entre criar e o job rodar, o pacote está `:pausado` mas as
  sessões ainda não existem — o `pause` seguraria zero. Antes deste guard o job criava, segundos
  depois, sessões **visíveis** num pacote pausado: a agenda mostrava o que a pausa tinha tirado dela.

  Pular a materialização quando `:pausado` seria pior (a retomada reprojeta pelo `count` de
  seguradas, que seria zero → nenhuma sessão volta). Então materializa **e segura**, que é o estado
  em que a pausa as teria deixado.
  """
  @spec create_and_stamp(map(), map(), DateTime.t(), binary(), boolean()) :: {:ok, struct()}
  def create_and_stamp(pkg, tipo, %DateTime{} = starts_at, clinic_id, forcar) do
    attrs = %{
      starts_at: starts_at,
      professional_id: pkg.schedule.professional_id,
      appointment_type_id: tipo.id,
      patient_ids: [pkg.patient_id],
      package_id: pkg.id,
      encaixe: forcar
    }

    with {:ok, appt} <-
           Api.Scheduling.schedule_appointment(attrs,
             tenant: clinic_id,
             authorize?: false,
             context: %{bulk_pacote: true}
           ) do
      if pkg.status == :pausado, do: segura(appt, pkg, clinic_id)
      {:ok, appt}
    end
  end

  # Segurar segue a regra por-presença do resto do pacote (doc 43 §5c): **sozinho no bloco**, segura
  # o bloco; **acompanhado** (a sessão fundiu numa turma que já existia), segura só a presença — o
  # pacote pausado da Maria não pode sumir com o Pilates do João da agenda.
  defp segura(appt, pkg, clinic_id) do
    bloco =
      Api.Scheduling.get_appointment!(appt.id,
        tenant: clinic_id,
        authorize?: false,
        load: [:attendances]
      )

    case Enum.find(bloco.attendances, &(&1.package_id == pkg.id)) do
      nil ->
        :ok

      att ->
        if Api.Packages.Bulk.sozinho?(bloco, att) do
          {:ok, _} =
            Api.Scheduling.set_appointment_pkg_hold(bloco, %{pkg_hold: true},
              tenant: clinic_id,
              authorize?: false
            )
        else
          {:ok, _} =
            Api.Scheduling.set_attendance_pkg_hold(att, %{pkg_hold: true},
              tenant: clinic_id,
              authorize?: false
            )
        end

        :ok
    end
  end
end
