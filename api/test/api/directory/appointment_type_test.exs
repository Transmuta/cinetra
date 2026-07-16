defmodule Api.Directory.AppointmentTypeTest do
  @moduledoc """
  Catálogo de tipos de atendimento da clínica (doc 20). Cobre o que o doc fixa: isolamento
  por-tenant (ADR-017), RBAC (T8/ADR-016), nome único por clínica (T7), capacidade sse grupo,
  a sigla derivada (T4), arquivar/restaurar (T2) e o seed dos 5 tipos no `onboard` (T3).

  Como em `ProfessionalTenantIsolationTest`, a RLS (ADR-018) **não** é exercida aqui: o
  sandbox conecta como `postgres` (BYPASSRLS). Aqui se prova a camada primária (o filtro
  por atributo do Ash) e as regras de domínio.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory

  @seed_siglas %{
    "Avaliação" => "AVA",
    "Sessão" => "SES",
    "RPG" => "RPG",
    "Pilates" => "PIL",
    "Reavaliação" => "REA"
  }

  defp email, do: "tipo-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic(attrs \\ %{}) do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", attrs,
        actor: owner
      )

    {owner, clinic}
  end

  # Um membro ativo da clínica com o papel pedido (sem passar pelo e-mail de convite).
  defp member_with_role(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id},
        authorize?: false
      )

    {:ok, _ativo} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  # Atributos válidos de um tipo novo (nome único para não colidir com o seed).
  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        nome: "Tipo #{System.unique_integer([:positive])}",
        duracao_minutos: 45,
        cor: "#0072B2",
        icon: "Activity",
        grupo: false
      },
      overrides
    )
  end

  describe "seed no onboard (T3)" do
    test "clínica nova nasce com os 5 tipos do protótipo" do
      {owner, clinic} = owner_and_clinic()

      tipos = Directory.list_appointment_types!(tenant: clinic.id, actor: owner)

      assert Enum.map(tipos, & &1.nome) == [
               "Avaliação",
               "Sessão",
               "RPG",
               "Pilates",
               "Reavaliação"
             ]

      assert Enum.all?(tipos, & &1.ativo)
      assert Enum.all?(tipos, &(&1.clinic_id == clinic.id))
    end

    test "o seed reproduz duração, cor, ícone e grupo/capacidade do protótipo" do
      {owner, clinic} = owner_and_clinic()

      tipos =
        [tenant: clinic.id, actor: owner]
        |> Directory.list_appointment_types!()
        |> Map.new(&{&1.nome, &1})

      assert %{duracao_minutos: 50, cor: "#0072B2", icon: "ClipboardList", grupo: false} =
               tipos["Avaliação"]

      assert %{duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity", grupo: false} =
               tipos["Sessão"]

      assert %{duracao_minutos: 50, cor: "#009E73", icon: "StretchHorizontal", grupo: false} =
               tipos["RPG"]

      assert %{duracao_minutos: 50, cor: "#CC79A7", icon: "Users", grupo: true, capacidade: 4} =
               tipos["Pilates"]

      assert %{duracao_minutos: 30, cor: "#7A52CC", icon: "RefreshCw", grupo: false} =
               tipos["Reavaliação"]

      # capacidade só existe no tipo em grupo (regra "sse grupo").
      assert Enum.all?(~w(Avaliação Sessão RPG Reavaliação), &is_nil(tipos[&1].capacidade))
    end

    test "o seed roda com a GUC de tenant setada (regressão: onboard 400 sob RLS)" do
      # O `onboard` é ação de recurso GLOBAL: a transação que ele abre não tem tenant, então
      # o `on_transaction_begin` não injeta GUC nenhuma. Como o seed roda dentro dessa
      # transação, o create por-tenant não abre outra e nunca passa pelo ponto de injeção
      # automático — sem `set_config` explícito, a RLS barra o INSERT e derruba o onboard.
      #
      # Este teste fixa o mecanismo do conserto (`with_clinic` aninhado seta a GUC da
      # transação já aberta). Ele NÃO prova a RLS em si: o sandbox é `postgres` (BYPASSRLS),
      # e por isso a regressão original passou verde na suíte inteira. A prova da RLS é
      # manual, como a de `professionals` (ver moduledoc).
      clinic_id = Ecto.UUID.generate()

      Api.Repo.transaction(fn ->
        {:ok, :verificado} =
          Api.Repo.with_clinic(clinic_id, fn ->
            %{rows: [[guc]]} = Api.Repo.query!("SELECT current_setting('movimento.clinic_id')")
            assert guc == clinic_id
            :verificado
          end)
      end)
    end

    test "a capacidade do Pilates seedado segue o cap_turma_padrao da clínica" do
      {owner, clinic} = owner_and_clinic(%{cap_turma_padrao: 8})

      tipos =
        [tenant: clinic.id, actor: owner]
        |> Directory.list_appointment_types!()
        |> Map.new(&{&1.nome, &1})

      assert tipos["Pilates"].capacidade == 8
    end
  end

  describe "sigla derivada (T4)" do
    test "reproduz exatamente as 5 siglas do seed" do
      {owner, clinic} = owner_and_clinic()

      siglas =
        [tenant: clinic.id, actor: owner, load: [:sigla]]
        |> Directory.list_appointment_types!()
        |> Map.new(&{&1.nome, &1.sigla})

      assert siglas == @seed_siglas
    end

    test "tira não-letras, pega 3 e sobe pra maiúscula" do
      {owner, clinic} = owner_and_clinic()

      for {nome, sigla} <- [
            {"Pilates 2.0", "PIL"},
            {"RPG - avançado", "RPG"},
            {"a", "A"},
            {"Ré", "RÉ"},
            {"drenagem linfática", "DRE"}
          ] do
        tipo =
          Directory.create_appointment_type!(attrs(%{nome: nome}),
            tenant: clinic.id,
            actor: owner,
            load: [:sigla]
          )

        assert tipo.sigla == sigla, "#{nome} deveria virar #{sigla}, veio #{tipo.sigla}"
      end
    end

    test "nome sem nenhuma letra cai no fallback TIP" do
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{nome: "123 - 45"}),
          tenant: clinic.id,
          actor: owner,
          load: [:sigla]
        )

      assert tipo.sigla == "TIP"
    end
  end

  describe "isolamento por-tenant (ADR-017)" do
    test "cada clínica só vê o próprio catálogo" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      tipo_a =
        Directory.create_appointment_type!(attrs(%{nome: "Só da A"}),
          tenant: clinic_a.id,
          actor: owner_a
        )

      tipo_b =
        Directory.create_appointment_type!(attrs(%{nome: "Só da B"}),
          tenant: clinic_b.id,
          actor: owner_b
        )

      nomes_a = clinic_a.id |> nomes_de(owner_a)
      nomes_b = clinic_b.id |> nomes_de(owner_b)

      assert tipo_a.nome in nomes_a
      refute tipo_a.nome in nomes_b
      assert tipo_b.nome in nomes_b
      refute tipo_b.nome in nomes_a
    end

    test "o mesmo nome pode existir em clínicas diferentes (unicidade é por tenant)" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      a =
        Directory.create_appointment_type!(attrs(%{nome: "Ventosaterapia"}),
          tenant: clinic_a.id,
          actor: owner_a
        )

      b =
        Directory.create_appointment_type!(attrs(%{nome: "Ventosaterapia"}),
          tenant: clinic_b.id,
          actor: owner_b
        )

      assert a.nome == b.nome
      refute a.id == b.id
    end

    test "não lê o tipo de outra clínica nem com o id na mão" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      alheio =
        Directory.create_appointment_type!(attrs(), tenant: clinic_b.id, actor: owner_b)

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.get_appointment_type(alheio.id, tenant: clinic_a.id, actor: owner_a)
    end
  end

  describe "RBAC (T8 / ADR-016)" do
    test "owner e admin criam" do
      {owner, clinic} = owner_and_clinic()
      admin = member_with_role(clinic, :admin)

      assert %{} = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)
      assert %{} = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: admin)
    end

    test "recepção e profissional NÃO criam (Forbidden)" do
      {_owner, clinic} = owner_and_clinic()

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.create_appointment_type(attrs(), tenant: clinic.id, actor: user),
               "#{papel} não deveria poder criar"
      end
    end

    test "recepção e profissional NÃO atualizam, arquivam nem restauram (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      tipo = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        opts = [tenant: clinic.id, actor: user]

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.update_appointment_type(tipo, %{nome: "Hackeado"}, opts)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.archive_appointment_type(tipo, %{}, opts)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.restore_appointment_type(tipo, %{}, opts)
      end
    end

    test "todos os membros leem o catálogo" do
      {owner, clinic} = owner_and_clinic()

      Directory.create_appointment_type!(attrs(%{nome: "Visível"}),
        tenant: clinic.id,
        actor: owner
      )

      for papel <- [:admin, :recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        assert "Visível" in nomes_de(clinic.id, user), "#{papel} deveria ler o catálogo"
      end
    end

    test "quem não é membro não lê nada" do
      {_owner, clinic} = owner_and_clinic()
      estranho = Accounts.register_user!("Estranho", email(), authorize?: false)

      assert [] = Directory.list_appointment_types!(tenant: clinic.id, actor: estranho)
    end

    test "membro de outra clínica não escreve na alheia (Forbidden)" do
      {_owner_a, clinic_a} = owner_and_clinic()
      {owner_b, _clinic_b} = owner_and_clinic()

      assert {:error, %Ash.Error.Forbidden{}} =
               Directory.create_appointment_type(attrs(), tenant: clinic_a.id, actor: owner_b)
    end
  end

  describe "nome único por clínica (T7)" do
    test "recusa nome repetido na mesma clínica" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{nome: "Sessão"}),
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "recusa renomear para um nome já usado" do
      {owner, clinic} = owner_and_clinic()
      tipo = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.update_appointment_type(tipo, %{nome: "Pilates"},
                 tenant: clinic.id,
                 actor: owner
               )
    end
  end

  describe "capacidade sse grupo" do
    test "grupo exige capacidade" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{grupo: true}),
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "individual recusa capacidade" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{grupo: false, capacidade: 6}),
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "grupo com capacidade passa" do
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{grupo: true, capacidade: 6}),
          tenant: clinic.id,
          actor: owner
        )

      assert tipo.capacidade == 6
    end

    test "virar grupo sem informar capacidade é recusado" do
      {owner, clinic} = owner_and_clinic()
      tipo = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.update_appointment_type(tipo, %{grupo: true},
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "edita a capacidade de um tipo em grupo sem reenviar o grupo" do
      # O caso real do PATCH parcial: o corpo só traz `capacidade`. A condição `sse grupo`
      # tem que olhar o valor GRAVADO de `grupo`, não só o que veio no changeset.
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{grupo: true, capacidade: 4}),
          tenant: clinic.id,
          actor: owner
        )

      updated =
        Directory.update_appointment_type!(tipo, %{capacidade: 10},
          tenant: clinic.id,
          actor: owner
        )

      assert updated.capacidade == 10
      assert updated.grupo
    end

    test "não zera a capacidade de um tipo em grupo" do
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{grupo: true, capacidade: 4}),
          tenant: clinic.id,
          actor: owner
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.update_appointment_type(tipo, %{capacidade: nil},
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "virar individual limpa a capacidade" do
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{grupo: true, capacidade: 6}),
          tenant: clinic.id,
          actor: owner
        )

      updated =
        Directory.update_appointment_type!(tipo, %{grupo: false, capacidade: nil},
          tenant: clinic.id,
          actor: owner
        )

      refute updated.grupo
      assert is_nil(updated.capacidade)
    end
  end

  describe "constraints dos campos" do
    test "duração fora de 5..480 é recusada" do
      {owner, clinic} = owner_and_clinic()

      for dur <- [0, 4, 481] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Directory.create_appointment_type(attrs(%{duracao_minutos: dur}),
                   tenant: clinic.id,
                   actor: owner
                 ),
               "duração #{dur} deveria ser recusada"
      end
    end

    test "cor fora da paleta é recusada" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{cor: "#123456"}),
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "ícone fora da paleta é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{icon: "Skull"}),
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "capacidade fora de 2..50 é recusada" do
      {owner, clinic} = owner_and_clinic()

      for cap <- [1, 51] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Directory.create_appointment_type(attrs(%{grupo: true, capacidade: cap}),
                   tenant: clinic.id,
                   actor: owner
                 ),
               "capacidade #{cap} deveria ser recusada"
      end
    end

    test "nome com mais de 60 caracteres é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_appointment_type(attrs(%{nome: String.duplicate("a", 61)}),
                 tenant: clinic.id,
                 actor: owner
               )
    end
  end

  describe "arquivar / restaurar (T2)" do
    test "arquivar marca ativo: false sem apagar a linha" do
      {owner, clinic} = owner_and_clinic()
      tipo = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)

      arquivado = Directory.archive_appointment_type!(tipo, %{}, tenant: clinic.id, actor: owner)

      refute arquivado.ativo
      # continua legível (a tela mostra a seção "Arquivados", T5).
      assert arquivado.nome in nomes_de(clinic.id, owner)
    end

    test "restaurar volta ativo: true" do
      {owner, clinic} = owner_and_clinic()
      tipo = Directory.create_appointment_type!(attrs(), tenant: clinic.id, actor: owner)

      restaurado =
        tipo
        |> Directory.archive_appointment_type!(%{}, tenant: clinic.id, actor: owner)
        |> Directory.restore_appointment_type!(%{}, tenant: clinic.id, actor: owner)

      assert restaurado.ativo
    end

    test "arquivar não mexe nos demais campos" do
      {owner, clinic} = owner_and_clinic()

      tipo =
        Directory.create_appointment_type!(attrs(%{grupo: true, capacidade: 6}),
          tenant: clinic.id,
          actor: owner
        )

      arquivado = Directory.archive_appointment_type!(tipo, %{}, tenant: clinic.id, actor: owner)

      assert arquivado.nome == tipo.nome
      assert arquivado.capacidade == 6
      assert arquivado.grupo
    end

    test "não existe destroy no recurso (T2)" do
      refute Enum.any?(
               Ash.Resource.Info.actions(Api.Directory.AppointmentType),
               &(&1.type == :destroy)
             )
    end
  end

  describe "list_clinic_appointment_types/1 (wrapper de leitura do domínio)" do
    test "lista o catálogo da clínica ativa do escopo, com sigla, em ordem de criação" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      Directory.create_appointment_type!(attrs(%{nome: "Último"}), scope: scope)

      tipos = Directory.list_clinic_appointment_types(scope)

      assert Enum.map(tipos, & &1.nome) == [
               "Avaliação",
               "Sessão",
               "RPG",
               "Pilates",
               "Reavaliação",
               "Último"
             ]

      # a sigla vem carregada (o JSON depende dela).
      assert Enum.map(tipos, & &1.sigla) == ~w(AVA SES RPG PIL REA ÚLT)
    end
  end

  defp nomes_de(clinic_id, actor) do
    [tenant: clinic_id, actor: actor]
    |> Directory.list_appointment_types!()
    |> Enum.map(& &1.nome)
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end
end
