defmodule Api.Accounts.ActiveMembershipTest do
  @moduledoc """
  O resolvedor único da membership ativa (achados (b) e (g) do doc 26).

  Duas propriedades, e elas puxam em direções opostas — é por isso que o módulo existe:

    * **é rápido** — reusa a membership que o `Api.Scope` já carregou, em vez de reconsultar
      o banco a cada avaliação de policy (era 5 queries idênticas por request);
    * **não confia de graça** — a membership do escopo só é aceita se ela é *deste* actor,
      *desta* clínica e está *ativa*. Escopo que não confere cai na consulta.

  A segunda é o que permite unificar leitura e escrita na mesma fonte sem afrouxar a
  escrita: o cache é uma otimização de um valor que seria lido do banco de qualquer jeito,
  não uma nova fonte de verdade.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Accounts.ActiveMembership

  defp create_user do
    email = "user-#{System.unique_integer([:positive])}@example.com"
    :ok = Accounts.request_magic_link(email, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp owner_with_clinic do
    owner = create_user()

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp membership_of(user, clinic) do
    {:ok, membership} = Accounts.get_active_membership(user.id, clinic.id, authorize?: false)
    membership
  end

  describe "sem escopo — cai na consulta" do
    test "acha a membership ativa do actor na clínica" do
      {owner, clinic} = owner_with_clinic()

      assert {:ok, %{papel: :owner, clinic_id: clinic_id, user_id: user_id}} =
               ActiveMembership.fetch(owner, clinic.id, nil)

      assert clinic_id == clinic.id
      assert user_id == owner.id
    end

    test "não-membro dá :error" do
      {_owner, clinic} = owner_with_clinic()
      estranho = create_user()

      assert :error == ActiveMembership.fetch(estranho, clinic.id, nil)
    end

    test "actor nulo e clínica nula dão :error" do
      {owner, clinic} = owner_with_clinic()

      assert :error == ActiveMembership.fetch(nil, clinic.id, nil)
      assert :error == ActiveMembership.fetch(owner, nil, nil)
    end
  end

  describe "com escopo — reusa sem ir ao banco" do
    test "a membership do escopo é devolvida quando confere com actor e tenant" do
      {owner, clinic} = owner_with_clinic()
      scope = Api.Scope.with_membership(owner, membership_of(owner, clinic))

      assert {:ok, %{papel: :owner}} = ActiveMembership.fetch(owner, clinic.id, subject(scope))
    end

    test "e NÃO consulta o banco nesse caminho" do
      {owner, clinic} = owner_with_clinic()
      scope = Api.Scope.with_membership(owner, membership_of(owner, clinic))

      assert {_result, 0} =
               count_queries(fn -> ActiveMembership.fetch(owner, clinic.id, subject(scope)) end)
    end

    test "sem escopo, a mesma resolução custa uma query" do
      {owner, clinic} = owner_with_clinic()

      assert {{:ok, _}, 1} =
               count_queries(fn -> ActiveMembership.fetch(owner, clinic.id, nil) end)
    end

    # O segundo canal, e a razão de ele existir: a query que o Ash monta para um `load:` de
    # relacionamento NÃO herda o contexto da query de cima — só a chave `:shared`. Sem ler
    # daqui, toda leitura carregada por tabela (o `load: [:attendances]` da agenda) voltava ao
    # banco para reresolver a mesma membership.
    #
    # Repare no que este teste afirma e no que NÃO afirma: ele trava a **economia** de query,
    # não a correção do recorte. Quem garante o recorte é o fallback ao banco logo abaixo —
    # tirar o `:shared` deixa o sistema correto e mais lento, não incorreto.
    test "a membership também é reusada pelo canal `:shared`, que é o do `load:` aninhado" do
      {owner, clinic} = owner_with_clinic()
      scope = Api.Scope.with_membership(owner, membership_of(owner, clinic))
      aninhado = %{tenant: clinic.id, context: %{shared: %{scope: scope}}}

      assert {{:ok, %{papel: :owner}}, 0} =
               count_queries(fn -> ActiveMembership.fetch(owner, clinic.id, aninhado) end)
    end

    test "e sem o `:shared`, o mesmo caminho aninhado ainda resolve — pelo banco" do
      {owner, clinic} = owner_with_clinic()
      aninhado = %{tenant: clinic.id, context: %{shared: %{}}}

      assert {{:ok, %{papel: :owner}}, 1} =
               count_queries(fn -> ActiveMembership.fetch(owner, clinic.id, aninhado) end)
    end
  end

  describe "o escopo não é acreditado de graça" do
    # Estes três são o achado (b): se bastasse *ter* escopo, unificar leitura e escrita na
    # membership do escopo teria afrouxado a escrita em vez de endurecer a leitura.

    test "escopo de OUTRO usuário é ignorado — vale o actor da ação" do
      {owner, clinic} = owner_with_clinic()
      estranho = create_user()
      scope = Api.Scope.with_membership(owner, membership_of(owner, clinic))

      # O escopo diz "sou owner desta clínica", mas quem age é o estranho.
      assert :error == ActiveMembership.fetch(estranho, clinic.id, subject(scope))
    end

    test "escopo de OUTRA clínica é ignorado — vale o tenant da ação" do
      {owner, clinic_a} = owner_with_clinic()

      {:ok, clinic_b} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: owner)

      scope_b = Api.Scope.with_membership(owner, membership_of(owner, clinic_b))

      # Escopo da clínica B, ação na clínica A: o cache não serve, e a consulta é que decide.
      assert {:ok, %{clinic_id: resolvido}} =
               ActiveMembership.fetch(owner, clinic_a.id, subject(scope_b))

      assert resolvido == clinic_a.id
    end

    test "membership MONTADA EM MEMÓRIA não passa, ainda que todos os campos confiram" do
      {_owner, clinic} = owner_with_clinic()
      estranho = create_user()

      forjada = %Api.Accounts.Membership{
        user_id: estranho.id,
        clinic_id: clinic.id,
        papel: :owner,
        status: :ativo
      }

      # Este é o teste do `__meta__.state == :loaded`, e é o único. Repare que actor, tenant e
      # status TODOS conferem — o forjador os escolheu. O que a derruba é ela nunca ter vindo
      # do banco (`:built`), e o fallback à consulta desmente o `:owner` inventado.
      #
      # Só é alcançável por chamador interno; via HTTP quem constrói o escopo é o `LoadScope`.
      assert forjada.__meta__.state == :built

      scope = Api.Scope.with_membership(estranho, forjada)

      assert :error == ActiveMembership.fetch(estranho, clinic.id, subject(scope))
    end

    test "membership inativa no escopo não é aceita" do
      {owner, clinic} = owner_with_clinic()
      ativa = membership_of(owner, clinic)
      scope = Api.Scope.with_membership(owner, %{ativa | status: :pendente})

      # Cai na consulta, que acha a ativa de verdade no banco.
      assert {{:ok, %{status: :ativo}}, 1} =
               count_queries(fn -> ActiveMembership.fetch(owner, clinic.id, subject(scope)) end)
    end
  end

  # Um subject no formato que Ash entrega às policies/preparations: contexto com o escopo.
  defp subject(scope), do: %{tenant: scope.clinic_id, context: %{scope: scope}}

  # A prova do achado (g): a diferença entre reusar e reconsultar é observável, não alegação.
  defp count_queries(fun), do: Api.QueryCounter.count(fun, "memberships")
end
