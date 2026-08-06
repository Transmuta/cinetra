defmodule Api.Accounts.MagicLinkFalhaDeEntregaTest do
  @moduledoc """
  O que acontece quando o provedor **recusa** o magic link.

  2026-08-06, achado em produção. `Api.Accounts.User.RequestMagicLink.send_link/7` chamava o
  sender dentro de um `with` e devolvia `:ok` logo abaixo, **descartando o retorno**. Como
  `Api.Mailer.deliver/1` devolve `{:error, _}` em vez de levantar, uma recusa do provedor (403 de
  domínio não verificado, chave inválida, rate limit) virava exatamente nada: resposta 200 para o
  browser, nenhuma linha no log, nenhum e-mail na caixa. Ninguém entrava no sistema e não havia
  por onde começar a procurar.

  A resposta **neutra** é do ADR-015 e continua: o endpoint é público e não pode revelar se o
  e-mail tem conta. Mas neutra para o visitante nunca quis dizer cega para o operador — o
  `Api.Accounts.AccessRevokedEmailJob` já loga a falha dele desde o bate-volta da Onda 4, e este
  caminho é o único que, quando quebra, tranca a porta da frente.

  O que o log **não** pode carregar é o destinatário (doc 62 §7.3), e é a outra metade do que se
  afirma aqui — a mesma barreira que o `Api.Messaging.SendJob` já respeita.
  """
  use Api.DataCase, async: false

  import ExUnit.CaptureLog

  alias Api.Accounts
  alias Api.Support.FailingMailer

  # A recusa que o Resend devolve para remetente de domínio não verificado — o caso real.
  @recusa {403, %{"message" => "The cinetra.local domain is not verified."}}

  test "a recusa do provedor vira log de erro" do
    addr = email_unico("recusado")

    log =
      capture_log(fn ->
        FailingMailer.with_failure(@recusa, fn ->
          assert :ok = Accounts.request_magic_link(addr, %{register?: true})
        end)
      end)

    assert log =~ "magic link"

    # A causa precisa estar no log: sem ela sobra "falhou", e a busca recomeça do zero. A frase é
    # a do `Api.Messaging.Falhas` — a mesma que a recepção lê na timeline, porque o texto cru do
    # provedor não pode ir para o log (ver o terceiro teste).
    assert log =~ "domínio de envio ainda não foi verificado"
  end

  test "a resposta continua NEUTRA — o endpoint público não revela a falha" do
    addr = email_unico("recusado")

    capture_log(fn ->
      FailingMailer.with_failure(@recusa, fn ->
        assert :ok = Accounts.request_magic_link(addr, %{register?: true})
      end)
    end)
  end

  # Doc 62 §7.3: log sai da máquina, e "e-mail" é nome proibido em chamada de log. Não custa
  # diagnóstico — a falha que tranca o login é global, e o motivo do provedor já a nomeia.
  test "e o destinatário NÃO vai para o log" do
    addr = email_unico("recusado")
    [local, _dominio] = String.split(addr, "@")

    # Um bounce que embute o endereço: é assim que o texto cru do provedor chega, e é o caminho
    # pelo qual o destinatário vazaria para o log sem ninguém escrever `identity` em lugar nenhum.
    cru = "550 5.1.1 <#{addr}>: Recipient address rejected: User unknown"

    log =
      capture_log(fn ->
        FailingMailer.with_failure(cru, fn ->
          Accounts.request_magic_link(addr, %{register?: true})
        end)
      end)

    assert log =~ "falhou"
    refute log =~ "@", "o log carregou um endereço de e-mail: #{log}"
    refute log =~ local, "o log carregou o destinatário: #{log}"
  end
end
