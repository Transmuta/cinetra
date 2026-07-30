defmodule Api.Accounts.AccessMatrixTest do
  @moduledoc """
  O tripwire do AN-06: a matriz publicada na tela de Equipe **não pode divergir das policies**.
  Cada linha com uma sonda `can_*?` viável é conferida contra os quatro papéis — mudou a policy
  sem mudar a `AccessMatrix`, este teste quebra antes de a tela mentir.

  O que as sondas NÃO pegam (limite documentado): os recortes de LINHA (`OwnAgendaOnly`,
  `summary_scope`) — `can_*?` avalia policies, não preparations. Essas células (`:propria`) são
  garantidas pelos testes de recorte de cada recurso (agenda A7, relatórios, mensagens); aqui
  se confere o eixo papel × pode/não-pode.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Accounts.AccessMatrix

  setup do
    owner = Accounts.register_user!("Dona", email_unico("mx"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    # A coluna do profissional: sem o vínculo, o `OwnProfessionalColumn` (A7 na escrita) fecha e
    # a sonda da agenda mediria o caso degenerado, não a matriz.
    prof =
      Api.Directory.create_professional!("Fisio Matriz", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        authorize?: false
      )

    membros =
      Map.new([:admin, :profissional, :recepcao], fn papel ->
        user = Accounts.register_user!("M #{papel}", email_unico("mx"), authorize?: false)

        vinculo = if papel == :profissional, do: %{professional_id: prof.id}, else: %{}

        {:ok, m} =
          Accounts.invite_member(
            Map.merge(%{papel: papel, user_id: user.id, clinic_id: clinic.id}, vinculo),
            authorize?: false
          )

        {:ok, _} = Accounts.accept_invite(m, authorize?: false)
        {papel, user}
      end)

    %{clinic: clinic, prof: prof, atores: Map.put(membros, :owner, owner)}
  end

  # Cada sonda: {área, o que se espera quando o nível é X}. `escrita?` = níveis que a sonda
  # de escrita deve aprovar; `leitura?` idem. A matriz é o SUJEITO: o assert compara a sonda
  # com `AccessMatrix.nivel/2`.
  defp escreve?(nivel), do: nivel == :total

  test "escrita de pacientes segue a matriz", %{clinic: clinic, atores: atores} do
    for {papel, actor} <- atores do
      esperado = escreve?(AccessMatrix.nivel(:pacientes, papel))

      assert Api.Records.can_create_patient?(actor, %{}, tenant: clinic.id) == esperado,
             "pacientes/#{papel}: matriz diz #{AccessMatrix.nivel(:pacientes, papel)}"
    end
  end

  # Leitura de recurso não serve de sonda: policy de read FILTRA em vez de negar (lição do doc
  # 51), então `can_list_*?` devolve true para todo mundo. A sonda dos anexos é a ESCRITA — e a
  # célula de leitura (`:nao` do profissional) é garantida pelo 403 do controller
  # (`with_roles_scope`), testado em `attachments_controller_test`.
  test "anexos seguem a matriz — inclusive a exceção do profissional", %{
    clinic: clinic,
    atores: atores
  } do
    for {papel, actor} <- atores do
      nivel = AccessMatrix.nivel(:anexos, papel)

      assert Api.Records.can_start_attachment_row?(actor, %{}, tenant: clinic.id) ==
               escreve?(nivel),
             "anexos(escrita)/#{papel}: matriz diz #{nivel}"
    end
  end

  test "agenda: os quatro papéis escrevem (o recorte do profissional é de linha, não de papel)",
       %{clinic: clinic, prof: prof, atores: atores} do
    for {papel, actor} <- atores do
      nivel = AccessMatrix.nivel(:agenda, papel)

      # `professional_id` da própria coluna: para o profissional é o que o A7-na-escrita exige;
      # para os demais papéis a policy nem se aplica.
      assert Api.Scheduling.can_create_appointment_slot?(actor, %{professional_id: prof.id},
               tenant: clinic.id
             ) == nivel in [:total, :propria],
             "agenda/#{papel}: matriz diz #{nivel}"
    end
  end

  test "encaixe: A9 tira o profissional", %{clinic: clinic, prof: prof, atores: atores} do
    for {papel, actor} <- atores do
      nivel = AccessMatrix.nivel(:encaixe, papel)

      assert Api.Scheduling.can_create_appointment_slot?(
               actor,
               %{professional_id: prof.id, encaixe: true},
               tenant: clinic.id
             ) == escreve?(nivel),
             "encaixe/#{papel}: matriz diz #{nivel}"
    end
  end

  test "fila e pacotes: todo papel opera", %{clinic: clinic, atores: atores} do
    for {papel, actor} <- atores do
      assert Api.Waitlist.can_enqueue_waitlist_entry?(actor, %{}, tenant: clinic.id) ==
               escreve?(AccessMatrix.nivel(:fila, papel))

      assert Api.Packages.can_create_package?(actor, %{}, tenant: clinic.id) ==
               escreve?(AccessMatrix.nivel(:pacotes, papel))
    end
  end

  test "diretório, horários e clínica: escrita é de dona/admin", %{
    clinic: clinic,
    atores: atores
  } do
    for {papel, actor} <- atores do
      assert Api.Directory.can_create_professional?(actor, %{}, tenant: clinic.id) ==
               escreve?(AccessMatrix.nivel(:profissionais, papel)),
             "profissionais/#{papel}"

      assert Api.Scheduling.can_set_clinic_hours_day?(actor, %{}, tenant: clinic.id) ==
               escreve?(AccessMatrix.nivel(:horarios, papel)),
             "horarios/#{papel}"

      assert Api.Accounts.can_update_clinic_info?(actor, clinic) ==
               escreve?(AccessMatrix.nivel(:clinica, papel)),
             "clinica/#{papel}"
    end
  end

  test "equipe: convite é de dona/admin", %{clinic: clinic, atores: atores} do
    for {papel, actor} <- atores do
      assert Api.Accounts.can_invite_member?(actor, %{clinic_id: clinic.id}) ==
               escreve?(AccessMatrix.nivel(:equipe, papel)),
             "equipe/#{papel}"
    end
  end

  # A leitura da auditoria (dona/admin) não tem sonda `can_*?` viável (read filtra — ver o
  # comentário dos anexos); quem a garante é o 403 do `audit_controller` (`with_admin_scope`).
  test "auditoria: escrita é de ninguém — nem a dona", %{clinic: clinic, atores: atores} do
    for {_papel, actor} <- atores do
      refute Api.Audit.can_record_event?(actor, %{}, tenant: clinic.id)
    end
  end

  test "toda área tem os quatro papéis e níveis conhecidos" do
    for area <- AccessMatrix.areas() do
      assert Map.keys(area.acesso) |> Enum.sort() == Enum.sort(AccessMatrix.papeis())

      for {_papel, nivel} <- area.acesso do
        assert nivel in [:total, :leitura, :propria, :nao]
      end
    end
  end
end
