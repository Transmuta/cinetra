defmodule Api.Accounts.WelcomeEmailTest do
  @moduledoc """
  O gatilho das boas-vindas: criar a clínica (`Clinic.onboard`) manda **um** e-mail para quem
  criou, fora do request.

  O que precisa estar provado aqui não é o texto (isso é `Api.Accounts.EmailsTest`) — é o
  encanamento:

    * o job é enfileirado, e **depois** do commit. Enfileirar dentro da transação faria o worker
      de outro nó pegá-lo antes de a clínica existir;
    * uma clínica, um e-mail. O `onboard` roda três outros changes; um deles falhando não pode
      produzir aviso de uma clínica que não nasceu;
    * falhar ao enfileirar não desfaz o cadastro, que é o que a pessoa veio fazer.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  import Swoosh.TestAssertions

  alias Api.Accounts
  alias Api.Accounts.WelcomeEmailJob

  defp usuario do
    Accounts.register_user!("Marina Lopes", email_unico("welcome"), authorize?: false)
  end

  describe "criar a clínica" do
    test "enfileira as boas-vindas para quem criou" do
      user = usuario()

      clinic = Accounts.onboard_clinic!("Clínica Movimento", %{}, actor: user)

      assert_enqueued(
        worker: WelcomeEmailJob,
        args: %{"user_id" => user.id, "clinic_id" => clinic.id}
      )
    end

    test "o e-mail chega com a clínica e o nome de quem criou" do
      user = usuario()
      Accounts.onboard_clinic!("Clínica Movimento", %{}, actor: user)

      Oban.drain_queue(queue: :notifications)

      assert_email_sent(fn mail ->
        assert {_, endereco} = hd(mail.to)
        assert endereco == to_string(user.email)
        assert mail.subject == "Sua conta da Clínica Movimento está pronta"
        assert mail.html_body =~ "Marina"
      end)
    end

    test "só o job das boas-vindas — uma clínica, um e-mail" do
      user = usuario()
      Accounts.onboard_clinic!("Clínica Movimento", %{}, actor: user)

      assert [_um] = all_enqueued(worker: WelcomeEmailJob)
    end

    test "sem actor não enfileira nada — não há para quem escrever" do
      # É o caminho de script e de teste (`authorize?: false` sem ator). Pela fronteira HTTP não
      # acontece: a policy do `onboard` exige `actor_present()`.
      Accounts.onboard_clinic!("Clínica Sem Dono", %{}, authorize?: false)

      assert [] = all_enqueued(worker: WelcomeEmailJob)
    end

    test "o job não quebra se a clínica sumiu antes de ele rodar" do
      user = usuario()
      clinic = Accounts.onboard_clinic!("Clínica Efêmera", %{}, actor: user)

      Api.Repo.query!("DELETE FROM clinics WHERE id = $1", [Ecto.UUID.dump!(clinic.id)])

      assert %{failure: 0} = Oban.drain_queue(queue: :notifications)
      refute_email_sent()
    end
  end

  describe "entrega" do
    test "falha de entrega vira erro do job, para o Oban tentar de novo" do
      # O `Api.Mailer.deliver/1` devolve `{:error, _}` em vez de levantar — foi assim que a falha
      # do aviso de acesso removido passou batida por um bate-volta inteiro. Aqui a saída é
      # `{:error, _}`, que deixa o job visível em `discarded` depois das tentativas.
      user = usuario()
      clinic = Accounts.onboard_clinic!("Clínica Movimento", %{}, actor: user)

      assert {:error, _motivo} =
               Api.Support.FailingMailer.with_failure(fn ->
                 perform_job(WelcomeEmailJob, %{"user_id" => user.id, "clinic_id" => clinic.id})
               end)
    end
  end
end
