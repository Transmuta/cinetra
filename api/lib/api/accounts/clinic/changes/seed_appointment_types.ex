defmodule Api.Accounts.Clinic.Changes.SeedAppointmentTypes do
  @moduledoc """
  Doc 20 (T3): clínica nova nasce com os 5 tipos de atendimento do protótipo, na mesma
  transação do `onboard`. Sem tipo não se agenda nada — uma clínica com catálogo vazio seria
  um beco sem saída no primeiro acesso.

  Espelha `CreateOwnerMembership`: `after_action`, `authorize?: false` (é ato de sistema, e o
  Membership de owner é criado na mesma transação, então o actor ainda não "é" membro
  quando isto roda).
  """
  use Ash.Resource.Change

  # Verbatim do seed do protótipo ([:69]-[:74]). A capacidade do Pilates não está aqui: sai
  # do `cap_turma_padrao` da própria clínica (ver abaixo).
  @tipos [
    %{nome: "Avaliação", duracao_minutos: 50, cor: "#0072B2", icon: "ClipboardList"},
    %{nome: "Sessão", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
    %{nome: "RPG", duracao_minutos: 50, cor: "#009E73", icon: "StretchHorizontal"},
    %{nome: "Pilates", duracao_minutos: 50, cor: "#CC79A7", icon: "Users", grupo: true},
    %{nome: "Reavaliação", duracao_minutos: 30, cor: "#7A52CC", icon: "RefreshCw"}
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, clinic ->
      # A criação em lote mora no domínio porque precisa setar a GUC de tenant na mão: o
      # `onboard` é ação de recurso global, então a transação aberta não tem tenant e a RLS
      # barraria estes INSERTs. Ver `Api.Directory.seed_appointment_types/2`.
      tipos = Enum.map(@tipos, &with_capacidade(&1, clinic))
      _criados = Api.Directory.seed_appointment_types(clinic.id, tipos)

      {:ok, clinic}
    end)
  end

  # O tipo em grupo herda o teto padrão da clínica em vez do `4` hardcoded do protótipo — o
  # default de `cap_turma_padrao` já é 4, então a clínica-padrão nasce idêntica ao protótipo,
  # e quem onboarda com outro teto não precisa corrigir o Pilates na mão.
  #
  # O `max(_, 2)` é cinto de segurança: `cap_turma_padrao` hoje não tem constraint (só
  # `default: 4`), então um onboard com `cap_turma_padrao: 1` derrubaria a criação do tipo
  # (capacidade mínima 2) e, com ela, o onboard inteiro. Clampar degrada em vez de explodir.
  defp with_capacidade(%{grupo: true} = attrs, clinic),
    do: Map.put(attrs, :capacidade, max(clinic.cap_turma_padrao, 2))

  defp with_capacidade(attrs, _clinic), do: attrs
end
