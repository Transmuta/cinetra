defmodule Api.Accounts.Clinic.Changes.SeedClinicHours do
  @moduledoc """
  Doc 22 §2: clínica nova nasce com o expediente do protótipo
  ([`:172`](../../../../interface/Movimento.dc.html#L172)), na mesma transação do `onboard`.
  Sem expediente a agenda não sabe quando a clínica atende.

  Espelha `SeedAppointmentTypes`: `after_action`, e a criação em lote mora no domínio
  (`Api.Scheduling.seed_clinic_hours/2`) porque precisa setar a GUC de tenant na mão — o
  `onboard` é ação de recurso global, então a transação aberta não tem tenant e a RLS barraria
  os INSERTs.
  """
  use Ash.Resource.Change

  # Verbatim do seed do protótipo: Seg–Sex manhã e tarde, Sábado só de manhã, Domingo fechado.
  @week [
    %{dow: 1, periods: [["08:00", "12:00"], ["13:00", "18:00"]]},
    %{dow: 2, periods: [["08:00", "12:00"], ["13:00", "18:00"]]},
    %{dow: 3, periods: [["08:00", "12:00"], ["13:00", "18:00"]]},
    %{dow: 4, periods: [["08:00", "12:00"], ["13:00", "18:00"]]},
    %{dow: 5, periods: [["08:00", "12:00"], ["13:00", "18:00"]]},
    %{dow: 6, periods: [["08:00", "12:00"]]},
    %{dow: 0, periods: []}
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, clinic ->
      _linhas = Api.Scheduling.seed_clinic_hours(clinic.id, @week)
      {:ok, clinic}
    end)
  end
end
