defmodule Api.ScopeTest do
  @moduledoc """
  O relógio do escopo (25 §4). `Api.Scope` é o único ponto por onde "agora" entra numa ação:
  sem isso, toda regra temporal da agenda (o que já começou, o que é passado) só é testável
  esperando o relógio de parede passar.

  Estes testes fixam o contrato de que o `now` **chega ao changeset**, não só ao struct —
  é isso que faz dele um relógio injetável e não um campo decorativo.
  """
  use ExUnit.Case, async: true

  alias Api.Accounts.User

  @user %User{id: "00000000-0000-0000-0000-000000000001"}
  @clinic_id "00000000-0000-0000-0000-0000000000c1"
  @fixo ~U[2026-07-19 12:00:00Z]

  defp context(scope) do
    {:ok, ctx} = Ash.Scope.ToOpts.get_context(scope)
    ctx
  end

  describe "relógio injetado" do
    test "new/2 aceita um now explícito e o entrega no contexto" do
      assert %{now: @fixo} = context(Api.Scope.new(@user, now: @fixo))
    end

    test "with_membership/3 aceita um now explícito e o entrega no contexto" do
      membership = %Api.Accounts.Membership{
        clinic_id: @clinic_id,
        papel: :recepcao,
        professional_id: nil
      }

      scope = Api.Scope.with_membership(@user, membership, now: @fixo)

      assert %{now: @fixo} = context(scope)
      assert scope.clinic_id == @clinic_id
    end

    test "o now injetado não é substituído pelo relógio de parede" do
      passado = ~U[2020-01-01 00:00:00Z]
      assert %{now: ^passado} = context(Api.Scope.new(@user, now: passado))
    end
  end

  describe "relógio padrão" do
    test "sem now explícito, cai no relógio de parede em UTC" do
      antes = DateTime.utc_now()
      %{now: now} = context(Api.Scope.new(@user))
      depois = DateTime.utc_now()

      assert DateTime.compare(now, antes) in [:eq, :gt]
      assert DateTime.compare(now, depois) in [:eq, :lt]
      assert now.time_zone == "Etc/UTC"
    end

    test "o now do escopo é estável — duas leituras do mesmo escopo dão o mesmo instante" do
      scope = Api.Scope.new(@user)
      assert context(scope).now == context(scope).now
    end
  end

  describe "o contexto chega ao changeset" do
    test "uma ação chamada com scope: enxerga o now em changeset.context" do
      scope = Api.Scope.new(@user, now: @fixo)

      changeset =
        Ash.Changeset.for_create(
          Api.Accounts.Clinic,
          :onboard,
          %{nome: "Clínica do Relógio"},
          scope: scope
        )

      assert changeset.context[:now] == @fixo
    end
  end

  describe "o resto do contrato de escopo continua valendo" do
    test "sem clinic_id não há tenant" do
      assert :error = Ash.Scope.ToOpts.get_tenant(Api.Scope.new(@user))
    end

    test "o actor continua sendo o usuário" do
      assert {:ok, @user} = Ash.Scope.ToOpts.get_actor(Api.Scope.new(@user, now: @fixo))
    end
  end
end
