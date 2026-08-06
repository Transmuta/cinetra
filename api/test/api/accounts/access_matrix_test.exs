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

    # A coluna do profissional: com o vínculo, a sonda da agenda mede o caso MAIS permissivo que
    # o papel já teve (agendar na própria coluna). Sem ele mediria o degenerado do "UUID mole",
    # que fecha por outro motivo — e um teste que passa pelo motivo errado não é sonda.
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

  # Até 2026-08-03 esta sonda aceitava `:propria` como escrita — era o profissional agendando na
  # própria coluna. A A8 mudou (doc 103): `:propria` na agenda passou a ser recorte de LEITURA, e
  # a sonda voltou a ser o `escreve?/1` comum a todas as outras. Se alguém devolver o papel à
  # policy sem mexer na matriz, é aqui que quebra.
  test "agenda: escrever é do balcão — o profissional só lê a própria",
       %{clinic: clinic, prof: prof, atores: atores} do
    for {papel, actor} <- atores do
      nivel = AccessMatrix.nivel(:agenda, papel)

      # `professional_id` da própria coluna: o caso mais permissivo que existia para o papel.
      # Se nem ele passa, nenhum outro passa.
      assert Api.Scheduling.can_create_appointment_slot?(actor, %{professional_id: prof.id},
               tenant: clinic.id
             ) == escreve?(nivel),
             "agenda/#{papel}: matriz diz #{nivel}"
    end
  end

  # O irmão da linha acima: a presença é a mesma célula da matriz ("Agenda e presenças"), e sem
  # esta sonda a metade "presenças" ficaria sem tripwire nenhum.
  #
  # O registro é um struct SOLTO, não uma presença do banco: a policy é `HasClinicRole` com
  # `clinic_from: :tenant`, que lê o tenant da ação e não a linha — montar agendamento, tipo e
  # paciente só para perguntar "este papel pode?" seria custo sem sonda a mais. `:prevista` é o
  # status que a `StatusIn` de `mark_present` aceita, para o `can?` medir a policy e não a
  # validação.
  test "presenças seguem a mesma célula da agenda", %{clinic: clinic, atores: atores} do
    presenca = %Api.Scheduling.Attendance{clinic_id: clinic.id, status: :prevista}

    for {papel, actor} <- atores do
      nivel = AccessMatrix.nivel(:agenda, papel)

      assert Api.Scheduling.can_mark_attendance_present?(actor, presenca, tenant: clinic.id) ==
               escreve?(nivel),
             "presenças/#{papel}: matriz diz #{nivel}"
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

  test "fila e pacotes: o profissional lê, mas não opera", %{clinic: clinic, atores: atores} do
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

      assert Api.Directory.can_create_appointment_type?(actor, %{}, tenant: clinic.id) ==
               escreve?(AccessMatrix.nivel(:tipos, papel)),
             "tipos/#{papel}"

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
