defmodule Api.Packages.Sessions do
  @moduledoc """
  Criação de **uma** sessão de pacote — o pedaço compartilhado entre a materialização inicial
  (`Api.Packages.Materializer`) e a reprojeção da retomada (`Api.Packages.resume_package/2`).

  Cria o agendamento via `Api.Scheduling.schedule_appointment/2` (que funde em turma existente
  quando é o caso, A-D4) e carimba o `package_id` na presença do paciente — o vínculo que o
  contador `usadas` conta (D11). `authorize?: false` porque quem autoriza é a ação do pacote; esta
  é escrita de cascata, como `CascadeToAttendances`.
  """

  import Api.Tenancy, only: [in_clinic: 2]

  @doc """
  Cria a sessão em `starts_at` para o paciente do pacote e carimba o `package_id`. `forcar` vira
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
      encaixe: forcar
    }

    {:ok, appt} = Api.Scheduling.schedule_appointment(attrs, tenant: clinic_id, authorize?: false)
    stamp(appt.id, pkg, clinic_id)
    {:ok, appt}
  end

  defp stamp(appointment_id, pkg, clinic_id) do
    # Releitura sob a GUC de tenant (`in_clinic`): o `get_appointment!` cru rodaria fora da RLS e
    # estouraria `""::uuid` (o mesmo furo do job). A escrita seguinte (`set_attendance_package!`)
    # seta a própria GUC via `SetTenantGuc`, então fica fora do `in_clinic`.
    appt =
      in_clinic(clinic_id, fn ->
        Api.Scheduling.get_appointment!(appointment_id,
          tenant: clinic_id,
          authorize?: false,
          load: [:attendances]
        )
      end)

    att = Enum.find(appt.attendances, &(&1.patient_id == pkg.patient_id))

    Api.Scheduling.set_attendance_package!(att, %{package_id: pkg.id},
      tenant: clinic_id,
      authorize?: false
    )
  end
end
