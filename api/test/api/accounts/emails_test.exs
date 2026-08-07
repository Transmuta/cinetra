defmodule Api.Accounts.EmailsTest do
  @moduledoc """
  O modelo **conta** dos e-mails (`Api.EmailLayout`), aplicado aos três que o projeto manda para
  quem tem login: o magic link, as boas-vindas e o aviso de acesso removido.

  O que se afirma aqui não é "o HTML é bonito" — é o que ele **não** pode ter:

    * o link do magic link continua no corpo em **texto**, não só dentro do botão. Meia dúzia de
      testes de autenticação extraem o token de `text_body`, e antes deles há o usuário cujo
      cliente remove `<a>`;
    * o rodapé não promete página que não existe (central de ajuda, preferências de e-mail) nem
      publica endereço e CNPJ que a empresa ainda não pôs em lugar nenhum;
    * a validade anunciada é a **configurada**, não um número escrito na frase.
  """
  use Api.DataCase, async: false

  import Swoosh.TestAssertions

  alias Api.Accounts.Emails

  describe "magic link" do
    setup do
      Emails.send_magic_link_email("ana@example.com", "tok-123")
      :ok
    end

    test "sai nas duas partes, e o link continua legível em texto" do
      assert_email_sent(fn mail ->
        assert mail.subject == "Seu link de acesso ao Cinetra"
        assert mail.text_body =~ "/auth/callback?token=tok-123"
        assert mail.html_body =~ "/auth/callback?token=tok-123"
        # O botão, e a URL escrita por extenso para quem não pode clicar nele.
        assert mail.html_body =~ "Entrar na minha conta"
        assert mail.html_body =~ "Copie e cole este endereço"
      end)
    end

    test "o cabeçalho é só a logo — sem assinatura de marca embaixo" do
      assert_email_sent(fn mail ->
        assert mail.html_body =~ "/email/logo-cinetra.png"
        # O `alt` estilizado é o que segura o cabeçalho quando a imagem é bloqueada, que é o
        # estado padrão de boa parte das caixas.
        assert mail.html_body =~ ~s(alt="Cinetra")
        refute mail.html_body =~ "Sua clínica em movimento"

        # `assert_email_sent/1` filtra pelo retorno da função: um bloco que termina em `refute`
        # devolve `nil` e reprova mesmo com tudo certo.
        true
      end)
    end

    test "a validade anunciada é a configurada na strategy" do
      {n, :minutes} =
        AshAuthentication.Info.strategy!(Api.Accounts.User, :magic_link).token_lifetime

      assert_email_sent(fn mail ->
        assert mail.text_body =~ "é válido por #{n} minutos"
        assert mail.html_body =~ "Este link é válido por #{n} minutos."
      end)
    end

    test "o rodapé não promete página que não existe" do
      assert_email_sent(fn mail ->
        refute mail.html_body =~ "Central de ajuda"
        refute mail.html_body =~ "Preferências de e-mail"
        refute mail.html_body =~ "CNPJ"
        refute mail.html_body =~ "Av. Paulista"
        # E não oferece descadastro: não há do que descadastrar num e-mail de acesso.
        refute mail.html_body =~ "descadastrar"
        true
      end)
    end
  end

  describe "boas-vindas" do
    setup do
      Emails.send_welcome_email(
        %{email: "marina@example.com", nome: "Marina Lopes"},
        "Clínica Movimento"
      )

      :ok
    end

    test "cumprimenta pelo primeiro nome e diz qual clínica nasceu" do
      assert_email_sent(fn mail ->
        assert mail.subject == "Sua conta da Clínica Movimento está pronta"
        assert mail.html_body =~ "Boas-vindas à Cinetra, Marina"
        refute mail.html_body =~ "Marina Lopes"
        assert mail.html_body =~ "Clínica Movimento"
      end)
    end

    test "os três passos apontam para telas que existem" do
      assert_email_sent(fn mail ->
        assert mail.html_body =~ "/configuracoes/horario"
        assert mail.html_body =~ "/profissionais"
        assert mail.html_body =~ "/configuracoes/comunicacao"
        # Numerados a partir da posição, não escritos à mão.
        assert mail.html_body =~ ">01<"
        assert mail.html_body =~ ">03<"
      end)
    end

    test "NÃO leva magic link — quem acabou de criar a clínica está logado" do
      assert_email_sent(fn mail ->
        refute mail.html_body =~ "/auth/callback"
        refute mail.text_body =~ "/auth/callback"
        true
      end)
    end

    test "não promete o que o sistema não faz mais" do
      assert_email_sent(fn mail ->
        # O gatilho de lembrete por relógio saiu em 2026-08-01 (`Api.Messaging.MessageKind`).
        refute mail.html_body =~ "embrete"
        # E o remetente é `nao-responda@`: convidar a responder mandaria a mensagem para o vazio.
        refute mail.html_body =~ "Responda este e-mail"
        assert mail.html_body =~ "contato@cinetra.com.br"
      end)
    end

    # O e-mail transacional não é lugar de condição comercial: o prazo do teste é decisão de
    # negócio que muda sem passar por aqui, e uma frase esquecida no corpo vira promessa que o
    # produto não cumpre. Nas DUAS partes, porque o texto é escrito à mão, separado do HTML.
    test "não anuncia prazo de teste nem condição de pagamento" do
      assert_email_sent(fn mail ->
        for corpo <- [mail.text_body, mail.html_body] do
          refute corpo =~ "14 dias"
          refute corpo =~ "cartão"
          refute corpo =~ "teste"
        end

        true
      end)
    end
  end

  # Fora do `describe` acima de propósito: o `setup` dele já mandou um e-mail, e
  # `assert_email_sent/1` casa o PRIMEIRO da caixa — o teste passaria olhando a mensagem errada.
  describe "boas-vindas sem nome na conta" do
    test "o cumprimento some inteiro, não vira 'Olá, !'" do
      Emails.send_welcome_email(%{email: "sem@example.com", nome: nil}, "Clínica X")

      assert_email_sent(fn mail ->
        assert mail.text_body =~ "Olá!"
        assert mail.html_body =~ "Boas-vindas à Cinetra<"
      end)
    end
  end

  # 2026-08-06, achado ao investigar por que TODO e-mail estava caindo no spam. O corpo mandava
  # escrever para `contato@cinetra.app` — e `cinetra.app` **não existe**: NXDOMAIN, sem SOA, sem
  # NS, não está registrado. Dois estragos de uma vez:
  #
  #   * o cliente que responde ao convite escreve para o vazio e nunca é respondido;
  #   * filtro de spam **resolve os domínios citados no corpo**, e domínio inexistente ali é
  #     sinal negativo — somado ao null MX e ao `v=spf1 -all` que o DNS publicava na época, era
  #     parte do porquê de a caixa de entrada recusar tudo.
  #
  # O endereço agora é do MESMO domínio que assina o e-mail. Não é preferência estética: é o
  # único que o DNS conhece, que o DKIM assina e que o Email Routing do Cloudflare entrega.
  # O par no web é `web/src/lib/legal.ts` (`EMPRESA.emailContato`/`emailPrivacidade`), com o
  # teste gêmeo em `legal.test.ts`.
  describe "endereço de contato" do
    test "os três e-mails só citam domínio que existe" do
      Emails.send_magic_link_email("ana@example.com", "tok-123")
      Emails.send_welcome_email(%{email: "marina@example.com", nome: "Marina"}, "Clínica X")
      Emails.send_access_revoked_email(%{email: "ana@example.com"}, "Clínica X")

      for _ <- 1..3 do
        assert_email_sent(fn mail ->
          for corpo <- [mail.text_body, mail.html_body] do
            refute corpo =~ "cinetra.app"
            refute corpo =~ "cinetra.local"
          end

          true
        end)
      end
    end

    test "as boas-vindas dizem para escrever a uma caixa do domínio de envio" do
      Emails.send_welcome_email(%{email: "marina@example.com", nome: "Marina"}, "Clínica X")

      assert_email_sent(fn mail ->
        for corpo <- [mail.text_body, mail.html_body] do
          assert corpo =~ "contato@cinetra.com.br"
        end

        true
      end)
    end
  end

  # 2026-08-06. Os três e-mails de conta saíam de uma constante do módulo,
  # `nao-responda@cinetra.local`, enquanto `MAIL_FROM` só chegava em `Api.Messaging.PatientEmails`.
  # `cinetra.local` não é domínio verificado em provedor nenhum: em produção o Resend recusa com
  # 403 antes de a mensagem existir. O sintoma era o pior possível — e-mail de paciente saindo
  # normalmente, magic link não chegando, e nenhuma linha de log dizendo por quê (ninguém entrava
  # no sistema). O `from` agora vem do config, como o do paciente sempre veio.
  describe "remetente" do
    setup do
      original = Application.get_env(:api, Emails)
      Application.put_env(:api, Emails, remetente: {"Cinetra", "acesso@cinetra.app"})
      on_exit(fn -> restaurar(Emails, original) end)
      :ok
    end

    test "o magic link sai do endereço CONFIGURADO, não de uma constante do módulo" do
      Emails.send_magic_link_email("ana@example.com", "tok-123")

      assert_email_sent(fn mail ->
        assert mail.from == {"Cinetra", "acesso@cinetra.app"}
      end)
    end

    test "as boas-vindas idem" do
      Emails.send_welcome_email(%{email: "marina@example.com", nome: "Marina"}, "Clínica X")

      assert_email_sent(fn mail -> assert mail.from == {"Cinetra", "acesso@cinetra.app"} end)
    end

    test "o aviso de acesso removido idem" do
      Emails.send_access_revoked_email(%{email: "ana@example.com"}, "Clínica X")

      assert_email_sent(fn mail -> assert mail.from == {"Cinetra", "acesso@cinetra.app"} end)
    end
  end

  describe "remetente sem configuração" do
    test "cai no placeholder de dev — a falta da env não pode derrubar o envio" do
      original = Application.get_env(:api, Emails)
      Application.delete_env(:api, Emails)
      on_exit(fn -> restaurar(Emails, original) end)

      Emails.send_magic_link_email("ana@example.com", "tok-123")

      assert_email_sent(fn mail ->
        assert mail.from == {"Cinetra", "nao-responda@cinetra.local"}
      end)
    end
  end

  describe "acesso removido" do
    test "diz qual clínica nas duas partes" do
      Emails.send_access_revoked_email(%{email: "ana@example.com"}, "Clínica Movimento")

      assert_email_sent(fn mail ->
        assert mail.subject == "Seu acesso a Clínica Movimento foi removido"
        assert mail.text_body =~ "Clínica Movimento"
        assert mail.html_body =~ "Clínica Movimento"
        assert mail.html_body =~ "Seu acesso foi removido"
      end)
    end

    test "nome de clínica com & sai escapado" do
      Emails.send_access_revoked_email(%{email: "ana@example.com"}, "Silva & Filhos")

      assert_email_sent(fn mail ->
        assert mail.html_body =~ "Silva &amp; Filhos"
        # No assunto e no texto puro ele continua sendo o que a clínica se chama.
        assert mail.subject =~ "Silva & Filhos"
      end)
    end
  end

  defp restaurar(modulo, nil), do: Application.delete_env(:api, modulo)
  defp restaurar(modulo, original), do: Application.put_env(:api, modulo, original)
end
