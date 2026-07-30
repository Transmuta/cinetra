defmodule ApiWeb.AgendaJSONTest do
  @moduledoc """
  A serialização do bloco (uma forma só para as quatro portas — ver o moduledoc do módulo).

  Aqui só o que **não** depende do banco: o contrato de degradação do selo de pacote. As formas
  cheias (com os calculados carregados) são cobertas pelo caminho HTTP, em
  `ApiWeb.AppointmentsControllerTest`, que é onde elas de fato saem.
  """
  use ExUnit.Case, async: true

  alias ApiWeb.AgendaJSON

  defp presenca(over \\ %{}) do
    Map.merge(
      %{
        patient_id: "pac1",
        status: :prevista,
        falta_justificada: false,
        motivo: nil,
        package_id: nil,
        package_nome: %Ash.NotLoaded{type: :calculation},
        package_total: %Ash.NotLoaded{type: :calculation},
        package_sessao: %Ash.NotLoaded{type: :calculation},
        package_falta_punitiva: %Ash.NotLoaded{type: :calculation}
      },
      over
    )
  end

  defp bloco(attendances) do
    %{
      id: "a1",
      starts_at: ~U[2026-07-20T11:00:00Z],
      ends_at: ~U[2026-07-20T11:50:00Z],
      status: :agendado,
      encaixe: false,
      obs: nil,
      cancel_reason: nil,
      reschedule_reason: nil,
      veio_da_fila: false,
      dias_na_fila: nil,
      professional_id: "prof1",
      appointment_type_id: "t1",
      version: 1,
      created_by_id: nil,
      attendances: attendances
    }
  end

  defp participante(bloco),
    do: bloco |> AgendaJSON.appointment() |> Map.fetch!(:participants) |> hd()

  test "sessão avulsa não tem pacote" do
    assert %{package_id: nil, package: nil} = participante(bloco([presenca()]))
  end

  test "com os calculados carregados, o pacote viaja legível" do
    participante =
      participante(
        bloco([
          presenca(%{
            package_id: "k1",
            package_nome: "Pilates 10",
            package_total: 10,
            package_sessao: 3,
            package_falta_punitiva: true
          })
        ])
      )

    assert participante.package == %{
             nome: "Pilates 10",
             total: 10,
             sessao: 3,
             falta_punitiva: true
           }
  end

  # Só as portas do bloco pedem o `Api.Scheduling.bloco_load/0`. Uma porta lateral que serialize
  # sem ele degrada para o que havia antes — o `package_id` continua lá — em vez de estourar um
  # `%Ash.NotLoaded{}` e transformar "esqueci um load" em 500.
  test "sem o load, o pacote some mas não derruba a resposta" do
    participante = participante(bloco([presenca(%{package_id: "k1"})]))

    assert participante.package_id == "k1"
    assert participante.package == nil
  end

  # O contador desce como agregado: zero significa "nenhuma sessão conta", que só acontece se o
  # vínculo sumiu no meio do caminho. Melhor "pacote sem número" do que "sessão 0 de 10".
  test "posição zero não vira sessão 0" do
    participante =
      participante(
        bloco([
          presenca(%{
            package_id: "k1",
            package_nome: "Pilates 10",
            package_total: 10,
            package_sessao: 0,
            package_falta_punitiva: false
          })
        ])
      )

    assert participante.package == %{
             nome: "Pilates 10",
             total: 10,
             sessao: nil,
             falta_punitiva: false
           }
  end
end
