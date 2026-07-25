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
  """

  @doc """
  Cria a sessão em `starts_at` para o paciente do pacote, já vinculada ao pacote. `forcar` vira
  `encaixe: true` (fura conflito/turma cheia; **não** fura expediente — D14). Devolve `{:ok,
  appointment}`; erros de escrita propagam para abortar a transação de quem chama.
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

    Api.Scheduling.schedule_appointment(attrs, tenant: clinic_id, authorize?: false)
  end
end
