defmodule ApiWeb.PackagesJSON do
  @moduledoc """
  Serialização dos pacotes (Fatia 3). `clinic_id` fica de fora (é o tenant, convenção do projeto).
  Os derivados (`usadas`/`restantes`/`acabando`) vêm calculados do domínio — a tela não os recomputa.
  """

  @doc "Um pacote com a grade e os contadores derivados, para a ficha do paciente."
  def package(pkg) do
    %{
      id: pkg.id,
      nome: pkg.nome,
      status: pkg.status,
      total: pkg.total,
      usadas: load(pkg, :usadas),
      restantes: load(pkg, :restantes),
      acabando: load(pkg, :acabando),
      falta_punitiva: pkg.falta_punitiva,
      cor: pkg.cor,
      data_inicio: Date.to_iso8601(pkg.data_inicio),
      grade: grade(pkg)
    }
  end

  @doc "A prévia da série (o save-gate): as ocorrências classificadas + se pode salvar."
  def preview(%{ocorrencias: ocorrencias, bloqueios: bloqueios, pode_salvar?: pode?}) do
    %{
      ocorrencias: Enum.map(ocorrencias, &ocorrencia/1),
      bloqueios: bloqueios,
      pode_salvar: pode?
    }
  end

  defp ocorrencia(occ) do
    %{
      data: Date.to_iso8601(occ.data),
      hhmm: occ.hhmm,
      feriado: occ.feriado?,
      issue: occ.issue,
      bloqueia: occ.bloqueia?
    }
  end

  defp grade(%{schedule: %{} = s}),
    do: %{dows: s.dows, horarios: s.horarios, professional_id: s.professional_id}

  defp grade(_), do: nil

  # Os derivados só existem se foram carregados (`load: [...]`); fora disso, `nil` em vez de estourar.
  defp load(pkg, field) do
    case Map.get(pkg, field) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end
end
