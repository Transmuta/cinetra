defmodule Api.Accounts.Emails do
  @moduledoc """
  E-mails do domínio de contas. São dois, e a régua para um terceiro é alta:

    * **magic link** (ADR-015) — o único fator de autenticação por posse do e-mail. O link aponta
      para o **web** (BFF), não para a API (ADR-005): o SvelteKit em `/auth/callback` valida o
      token via API e assina a sessão no domínio do web. `web_app_url` vem do config (dev:
      http://localhost:5173);
    * **acesso removido** (#50) — o único aviso que a caixa in-app não consegue entregar, porque
      ela é por-tenant e quem saiu perdeu o vínculo que dá acesso a ela.

  O doc 31 §5 manteve e-mail fora da v1 de propósito: e-mail por evento de agenda vira spam em
  uma semana. Os dois acima escapam pelo mesmo critério — não são eventos de agenda, são eventos
  de **acesso**, e o destinatário não tem outro canal no momento em que precisa saber.
  """
  import Swoosh.Email

  # A marca, num lugar só. O `from` continua em `movimento.local` porque é placeholder de dev e
  # trocá-lo é assunto de configuração de domínio, não de copy.
  @marca "Cinetra"
  @remetente {@marca, "nao-responda@movimento.local"}

  @doc """
  Monta e envia o e-mail de magic link. Recebe um `%User{}` (já existe) ou uma string
  de e-mail (ainda não existe — o primeiro acesso cria o `User`).
  """
  def send_magic_link_email(user_or_email, token) do
    address =
      case user_or_email do
        %{email: email} -> to_string(email)
        email -> to_string(email)
      end

    link = Api.web_app_url() <> "/auth/callback?" <> URI.encode_query(token: token)

    new()
    |> to(address)
    |> from(@remetente)
    |> subject("Seu link de acesso ao #{@marca}")
    |> text_body("""
    Olá!

    Use o link abaixo para entrar no #{@marca} (expira em breve):

    #{link}

    Se você não solicitou este acesso, ignore este e-mail.
    """)
    |> Api.Mailer.deliver()
  end

  @doc """
  Avisa quem foi removido de uma clínica (#50). Enviado pelo `Api.Accounts.AccessRevokedEmailJob`,
  fora do request.

  **O nome da clínica é obrigatório no corpo, não decoração.** O usuário é global e pode ser
  membro de várias (ADR-017); "seu acesso foi removido" sem dizer de onde deixaria a pessoa sem
  saber se ainda tem trabalho amanhã.

  Não diz **quem** removeu: isso é conversa entre pessoas, e pôr o nome de um colega num e-mail
  automático de perda de acesso cria atrito que o sistema não tem contexto para mediar.
  """
  def send_access_revoked_email(%{email: address}, clinic_nome) when is_binary(clinic_nome) do
    new()
    |> to(to_string(address))
    |> from(@remetente)
    |> subject("Seu acesso a #{clinic_nome} foi removido")
    |> text_body("""
    Olá!

    Seu acesso à clínica #{clinic_nome} no #{@marca} foi removido, e você não verá mais a agenda
    nem os dados dela.

    Se você é membro de outras clínicas, elas continuam disponíveis normalmente ao entrar.

    Se isso parecer um engano, fale com quem administra a clínica.
    """)
    |> Api.Mailer.deliver()
  end
end
