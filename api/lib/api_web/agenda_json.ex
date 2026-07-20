defmodule ApiWeb.AgendaJSON do
  @moduledoc """
  A serialização da agenda — **uma** forma de bloco para as duas portas por onde ele sai:
  `GET/POST /api/appointments` e o push do `ApiWeb.AgendaChannel`.

  Nasceu na Entrega 3 por necessidade, não por estética: o cliente aplica o evento do canal
  como patch sobre a lista que veio do REST. Se as duas serializações divergirem num campo, o
  bloco muda de forma ao ser atualizado em tempo real — e o defeito só aparece na segunda aba,
  depois da escrita, que é o caminho que nenhum teste de controller percorre.

  `clinic_id` fica de fora de propósito: é o tenant, e omiti-lo é convenção do projeto.
  """

  @doc "O bloco da agenda (doc 25 §5)."
  def appointment(appt) do
    %{
      id: appt.id,
      starts_at: DateTime.to_iso8601(appt.starts_at),
      ends_at: DateTime.to_iso8601(appt.ends_at),
      status: appt.status,
      encaixe: appt.encaixe,
      obs: appt.obs,
      professional_id: appt.professional_id,
      appointment_type_id: appt.appointment_type_id,
      package_id: appt.package_id,
      version: appt.version,
      created_by_id: appt.created_by_id,
      patient_ids: patient_ids(appt)
    }
  end

  @doc "Mínimo para o bloco e o cartão do drawer — nada de ficha clínica aqui (ADR-013/D16)."
  def patient(paciente) do
    %{
      id: paciente.id,
      nome: paciente.nome,
      tel: paciente.tel,
      ativo: paciente.ativo
    }
  end

  @doc "A coluna da agenda."
  def professional(prof) do
    %{
      id: prof.id,
      nome: prof.nome,
      nome_exibicao: prof.nome_exibicao,
      crefito: prof.crefito,
      cor_indice: prof.cor_indice,
      segue_horario_clinica: prof.segue_horario_clinica
    }
  end

  @doc "O tipo de atendimento (cor, ícone, duração — a legenda e o bloco)."
  def appointment_type(tipo) do
    %{
      id: tipo.id,
      nome: tipo.nome,
      duracao_minutos: tipo.duracao_minutos,
      cor: tipo.cor,
      icon: tipo.icon,
      grupo: tipo.grupo,
      capacidade: tipo.capacidade
    }
  end

  defp patient_ids(%{attendances: attendances}) when is_list(attendances),
    do: Enum.map(attendances, & &1.patient_id)

  defp patient_ids(_appt), do: []
end
