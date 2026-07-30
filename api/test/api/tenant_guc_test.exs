defmodule Api.TenantGucTest do
  @moduledoc """
  O contrato que faltava: **todo `destroy` de recurso por-tenant põe a GUC da RLS na própria
  transação** — ou está na lista de exceções abaixo, com o motivo escrito.

  ## Por que este teste lê a declaração em vez de exercitar a ação

  Porque o comportamento **passa verde com o bug em pé**. O sandbox roda o teste inteiro numa
  transação só; qualquer `in_clinic` anterior (a autorização, o setup) deixa a GUC pendurada, e
  o `DELETE` seguinte a herda de graça. Em produção não há herança: cada request chega numa
  transação nova, sem GUC. Nem o gate `:rls` alcança — ele prova a porta de entrada, não o que
  acontece entre a autorização e a escrita, dentro da ação.

  Ou seja: a única sonda que decide é a declaração. E é onde o bug mora.

  ## O bug que originou este arquivo

  `change SetTenantGuc` num bloco `changes` global roda em `[:create, :update]` — o Ash omite
  `:destroy` de propósito ("most changes don't make sense for a destroy"). O `Attachment`
  declarava assim, e seu `delete_attachment/2` chama a code interface **fora** de `in_clinic`
  (envolvê-la abriria transação por fora e viraria 500 no caminho de erro — ver o moduledoc de
  `Api.Tenancy.SetTenantGuc`). Resultado medido no servidor real: `DELETE` sem GUC, a policy de
  RLS avaliando `''::uuid`, `22P02`, `Sent 400`. Criar e renomear funcionavam — só remover caía.

  A correção de um recurso não impede o próximo. Este contrato impede.
  """
  use Api.DataCase, async: true

  @dominios [
    Api.Accounts,
    Api.Scheduling,
    Api.Directory,
    Api.Records,
    Api.Packages,
    Api.Waitlist,
    Api.Notifications
  ]

  # Os `destroy` que rodam SEM GUC própria **de propósito**, e por quê. Entrar aqui é decisão
  # consciente: significa que a segurança do DELETE depende de quem chama, e que quebrar essa
  # premissa é falha só no servidor real.
  @sem_guc_por_desenho %{
    {Api.Notifications.Notification, :clear} =>
      "ação sem hook nenhum para o `Ash.bulk_destroy!` ir pelo caminho atômico (um DELETE só) " <>
        "e a policy filter-check virar cláusula do WHERE; um `before_action` derrubaria as duas " <>
        "coisas. Quem garante a GUC é o `in_clinic` de `Api.Notifications.clear_all/1`, e o " <>
        "gate `:rls` prova (\"limpar a caixa alcança as linhas sob RLS\").",
    {Api.Scheduling.Attendance, :remove} =>
      "único chamador é `Appointment.Changes.RemoveParticipants`, um `after_action` que roda " <>
        "DENTRO da transação da ação do bloco — onde o `SetTenantGuc` do `Appointment` (update) " <>
        "já setou a GUC. Não é coberto pelo gate `:rls`: se algum dia a remoção de participante " <>
        "ganhar porta própria fora de `in_clinic`, esta exceção deixa de valer."
  }

  defp destroys_por_tenant do
    @dominios
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&(Ash.Resource.Info.multitenancy_strategy(&1) == :attribute))
    |> Enum.flat_map(fn recurso ->
      recurso
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&(&1.type == :destroy))
      |> Enum.map(&{recurso, &1})
    end)
  end

  # A GUC chega por um de dois caminhos, e os dois valem: a change declarada na própria ação, ou
  # a change global cujo `on:` inclui `:destroy`.
  defp seta_guc?(recurso, acao) do
    global = Ash.Resource.Info.changes(recurso, :destroy)
    na_acao = Map.get(acao, :changes) || []

    Enum.any?(global ++ na_acao, fn c ->
      match?({Api.Tenancy.SetTenantGuc, _}, Map.get(c, :change))
    end)
  end

  test "todo destroy por-tenant seta a GUC, ou está declarado como exceção" do
    faltando =
      for {recurso, acao} <- destroys_por_tenant(),
          not seta_guc?(recurso, acao),
          not Map.has_key?(@sem_guc_por_desenho, {recurso, acao.name}),
          do: "#{inspect(recurso)}.#{acao.name}"

    assert faltando == [],
           """
           Estes `destroy` de recurso por-tenant não põem a GUC de tenant na transação:

               #{Enum.join(faltando, "\n    ")}

           Sob RLS o DELETE cai — `''::uuid` (22P02) ou zero linhas, dependendo do caminho — e
           **só no servidor real**: o sandbox conecta como `postgres` (BYPASSRLS) e a suíte passa.

           Conserte declarando `change Api.Tenancy.SetTenantGuc, on: [:create, :update, :destroy]`
           (ou a change dentro da própria ação). Se for deliberado, entre em
           `@sem_guc_por_desenho` com o motivo — e saiba que a garantia passa a ser do chamador.
           """
  end

  test "a lista de exceções não apodrece: quem ganhou GUC sai dela" do
    obsoletas =
      for {recurso, acao} <- destroys_por_tenant(),
          Map.has_key?(@sem_guc_por_desenho, {recurso, acao.name}),
          seta_guc?(recurso, acao),
          do: "#{inspect(recurso)}.#{acao.name}"

    assert obsoletas == [],
           "estes destroy já setam a GUC e não são mais exceção — tire de " <>
             "`@sem_guc_por_desenho`: #{Enum.join(obsoletas, ", ")}"
  end

  test "a lista de exceções não referencia ação que deixou de existir" do
    reais = MapSet.new(destroys_por_tenant(), fn {r, a} -> {r, a.name} end)
    fantasmas = for k <- Map.keys(@sem_guc_por_desenho), not MapSet.member?(reais, k), do: k

    assert fantasmas == [],
           "exceções apontando para destroy que não existe mais: #{inspect(fantasmas)}"
  end
end
