defmodule ApiWeb.PackagesJSON do
  @moduledoc """
  Serialização dos pacotes (Fatia 3). `clinic_id` fica de fora (é o tenant, convenção do projeto).
  Os derivados (`usadas`/`restantes`/`acabando`) vêm calculados do domínio — a tela não os recomputa.
  """

  @doc """
  Um pacote com a grade, os contadores derivados e — quando pedida — a **trilha** (as sessões com o
  estado de cada uma), que é o que o cartão da ficha desenha em bolinhas.

  A trilha é opcional porque só a listagem a carrega: as respostas de transição (pausar, arquivar,
  `+1`…) devolvem o pacote para a tela conferir o estado, e a ficha recarrega logo em seguida.
  """
  def package(pkg, sessoes \\ []) do
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
      # O tipo de atendimento **identifica** o pacote na ficha (nome, duração, cor) — sem ele o
      # cartão só sabia repetir o nome digitado (doc 69 §7 item 8). Vai o id, não o objeto: a ficha
      # já carrega o catálogo de tipos (ativos e arquivados) para o modal de criação, e duplicar
      # nome/cor aqui criaria uma segunda verdade para o mesmo dado.
      appointment_type_id: pkg.appointment_type_id,
      grade: grade(pkg),
      sessoes: Enum.map(sessoes, &session/1)
    }
  end

  @doc """
  Uma sessão da trilha (doc 69 §7 item 9): quando ela é e em que estado está. O `appointment_id`
  viaja para a tela poder levar ao bloco na agenda.
  """
  def session(s) do
    %{
      attendance_id: s.attendance_id,
      appointment_id: s.appointment_id,
      starts_at: DateTime.to_iso8601(s.starts_at),
      estado: s.estado
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
