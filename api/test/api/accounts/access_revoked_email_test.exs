defmodule Api.Accounts.AccessRevokedEmailTest do
  @moduledoc """
  O aviso por e-mail de que o acesso a uma clínica foi removido (#50, segunda metade).

  Existe porque a caixa in-app **não alcança** o destinatário certo: ela é por-tenant e só se lê
  com vínculo ativo, então no instante em que o vínculo cai aquela caixa fica inacessível para
  quem saiu (ver `Api.Notifications.Fanout.member_removed/2`). O e-mail é o único canal que
  atravessa a remoção.

  O que se afirma aqui: sai **um** e-mail, para o endereço de quem saiu, dizendo **qual** clínica
  (o usuário é global e pode ser membro de várias — ADR-017), e o job não quebra se a conta sumir
  entre o commit e a execução.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  import Swoosh.TestAssertions

  alias Api.Accounts
  alias Api.Accounts.AccessRevokedEmailJob

  defp args_do_job(membership),
    do: %{"user_id" => membership.user_id, "clinic_id" => membership.clinic_id}

  defp membro(clinic, papel \\ :recepcao) do
    user = Accounts.register_user!("Fulano", email_unico("revoke"), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id},
        authorize?: false
      )

    {:ok, m} = Accounts.accept_invite(m, authorize?: false)
    {user, m}
  end

  describe "remoção de membro" do
    test "enfileira o aviso e manda para quem saiu, dizendo qual clínica" do
      ctx = clinica()
      {user, membership} = membro(ctx.clinic)

      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      assert_enqueued(worker: AccessRevokedEmailJob, args: %{"user_id" => user.id})

      Oban.drain_queue(queue: :notifications)

      assert_email_sent(fn mail ->
        assert {_, endereco} = hd(mail.to)
        assert endereco == to_string(user.email)
        assert mail.text_body =~ ctx.clinic.nome
      end)
    end

    test "o job não quebra se a conta sumiu antes de ele rodar" do
      ctx = clinica()
      {_user, membership} = membro(ctx.clinic)

      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      # Simula a conta apagada entre o commit da remoção e a execução do job.
      Api.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(membership.user_id)])

      assert %{failure: 0} = Oban.drain_queue(queue: :notifications)
    end

    # Bate-volta da Onda 4. O e-mail existe porque é o **único** canal que alcança quem saiu —
    # então uma entrega que falha em silêncio é pior aqui do que em qualquer outro aviso do
    # sistema: não há caixa in-app para servir de segunda chance. O `Api.Mailer.deliver/1`
    # devolve `{:error, _}` (não levanta), então o `rescue` do job nunca via a falha e o Oban
    # marcava a tentativa como concluída.
    test "falha de entrega vira erro do job, para o Oban tentar de novo" do
      ctx = clinica()
      {_user, membership} = membro(ctx.clinic)

      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      Api.Support.FailingMailer.with_failure(fn ->
        assert {:error, _motivo} = perform_job(AccessRevokedEmailJob, args_do_job(membership))
      end)
    end

    # O outro lado da mesma moeda: sumiço de conta/clínica **não** é falha a repetir. Aqui `:ok`
    # é a resposta certa — tentar de novo daria o mesmo nada, três vezes.
    test "conta que sumiu encerra o job sem erro (não é caso de retry)" do
      ctx = clinica()
      {_user, membership} = membro(ctx.clinic)

      :ok = Accounts.revoke_access(membership, actor: ctx.owner)
      Api.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(membership.user_id)])

      assert :ok = perform_job(AccessRevokedEmailJob, args_do_job(membership))
    end

    test "mudar o papel não manda e-mail nenhum" do
      ctx = clinica()
      {_user, membership} = membro(ctx.clinic)

      {:ok, _} = Accounts.update_membership(membership, %{papel: :admin}, actor: ctx.owner)

      refute_enqueued(worker: AccessRevokedEmailJob)
    end
  end
end
