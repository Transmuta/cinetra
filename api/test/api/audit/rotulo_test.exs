defmodule Api.Audit.RotuloTest do
  @moduledoc """
  Texto controlado pelo usuário não pode quebrar a trilha nem a escrita que ela observa
  (bate-volta, causa C2).

  `Api.Audit.Event.label` e `user_label` têm `max_length: 200`. O que chega neles vem de fora:
  o nome do usuário (que ele mesmo edita, e que era o único rótulo do sistema **sem teto**) e o
  caminho da request (que o cliente escolhe). Sem normalizar na fronteira da trilha, o teto da
  coluna decidia — e decidia de dois jeitos opostos e igualmente ruins:

    * no `Capture` (que usa a versão **bang**, dentro da transação de negócio), o rótulo longo
      **derrubava a escrita de negócio**: um membro com nome de 201 caracteres não podia ser
      removido da clínica, e não conseguia sequer editar uma ficha;
    * no `Acesso` (versão não-bang, retorno descartado), o rótulo longo **sumia em silêncio**:
      bastava encher a URL para que o 403 não deixasse rastro.

  A trilha observa; ela não tem direito de vetar a operação nem de calar por conta própria.
  """
  use Api.DataCase, async: false

  alias Api.Audit

  defp nome_longo(n), do: String.duplicate("a", n)

  describe "nome do ator maior que o teto da coluna" do
    test "não impede a escrita de negócio, e o rótulo entra truncado" do
      ctx = clinica(dono: "Dono", paciente: "Paciente")

      {:ok, user} =
        Api.Accounts.update_profile(ctx.owner, %{nome: nome_longo(251)}, actor: ctx.owner)

      scope = %{ctx.scope | user: user}

      assert {:ok, _} = Api.Records.update_patient(ctx.paciente, %{genero: "F"}, scope: scope)

      %{entries: entries} = Audit.list_events(scope, resource: :patient)
      entry = Enum.find(entries, &(&1.action == "update"))

      assert String.length(entry.actor.nome) <= 200
    end

    test "revogar acesso de quem tem nome longo continua possível" do
      ctx = clinica()
      _ = escopo_de_membro!(ctx, :recepcao)

      membership =
        Api.Accounts.list_memberships!(authorize?: false)
        |> Enum.find(&(&1.clinic_id == ctx.clinic.id and &1.papel == :recepcao))

      alvo = Api.Accounts.get_user!(membership.user_id, authorize?: false)
      {:ok, _} = Api.Accounts.update_profile(alvo, %{nome: nome_longo(300)}, actor: alvo)

      # A trilha não pode transformar o mecanismo de auditoria numa trava de remoção de usuário.
      assert :ok = Api.Accounts.revoke_access(membership, actor: ctx.owner)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :membership)
      assert Enum.find(entries, &(&1.action_type == :destroy))
    end
  end

  describe "caminho da request maior que o teto da coluna" do
    test "o acesso negado é registrado mesmo assim (a trilha não é evadível por padding)" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      caminho = "/api/professionals/" <> nome_longo(300)
      :ok = Api.Audit.Acesso.acesso_negado(recep, caminho)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)
      assert [evento] = entries
      assert String.length(evento.label) <= 200
      assert String.starts_with?(evento.label, "/api/professionals/")
    end
  end
end
