defmodule Api.EmailLayoutTest do
  @moduledoc """
  As regras de compatibilidade do HTML de e-mail — as que **não** se vê quebrar.

  Um defeito de e-mail não aparece em teste de unidade nem no navegador: ele aparece na caixa de
  alguém, dias depois, e só se essa pessoa contar. Este arquivo pega a classe de erro que tem
  regra objetiva, aplicada ao HTML **de verdade** que os quatro e-mails do projeto produzem — não
  a um documento sintético que só existe aqui.

  O que ele não cobre, e nenhum teste cobre: se o e-mail está bonito no Outlook 2016. Isso é
  Litmus/Email on Acid, ou uma caixa de verdade.
  """
  use Api.DataCase, async: false

  alias Api.Accounts.Emails
  alias Api.Messaging.Templates

  @vars %{
    "clinica" => "Clínica Movimento",
    "paciente" => "Mariana Alves",
    "data" => "14/07/2026",
    "hora" => "08:00",
    "telefone" => "(11) 3456-7890",
    "link" => "https://app.cinetra.test/confirmar/abc",
    "descadastro" => "https://app.cinetra.test/descadastrar/xyz"
  }

  # Os quatro e-mails do produto, cada um pelo caminho por onde ele realmente sai.
  defp documentos do
    %{
      "magic link" => enviado(fn -> Emails.send_magic_link_email("a@example.com", "tok") end),
      "boas-vindas" =>
        enviado(fn ->
          Emails.send_welcome_email(
            %{email: "a@example.com", nome: "Marina"},
            "Clínica Movimento"
          )
        end),
      "acesso removido" =>
        enviado(fn ->
          Emails.send_access_revoked_email(%{email: "a@example.com"}, "Clínica X")
        end),
      "paciente" => elem(Templates.render_email("confirmacao_v1", @vars), 1).html
    }
  end

  defp enviado(fun) do
    fun.()

    receive do
      {:email, email} -> email.html_body
    after
      0 -> flunk("nenhum e-mail foi enviado")
    end
  end

  # Os valores de todo atributo `style="..."` do documento. O `<style>` do topo NÃO entra — as
  # regras abaixo são sobre o que precisa valer em cliente que descarta a folha.
  defp estilos(html), do: ~r/style="([^"]*)"/ |> Regex.scan(html) |> Enum.map(&List.last/1)

  defp tags(html, palavra), do: ~r/<[^>]*#{palavra}[^>]*>/ |> Regex.scan(html) |> List.flatten()

  describe "Outlook — o motor do Word" do
    test "nenhum <a> carrega padding: o Word ignora, e o botão chega colado nas bordas" do
      # A pegadinha que estraga botão de e-mail. O espaçamento mora no `<td>`, que o Word respeita.
      for {nome, html} <- documentos() do
        assert tags(html, "padding") |> Enum.filter(&String.starts_with?(&1, "<a ")) == [],
               "#{nome}: <a> com padding — invisível no Outlook"
      end
    end

    test "todo line-height vem com mso-line-height-rule" do
      # Sem a regra, o Word usa a entrelinha dele e o texto sai espremido ou esparramado. É o
      # defeito mais comum de e-mail que "ficou estranho só no Outlook".
      for {nome, html} <- documentos(), estilo <- estilos(html), estilo =~ "line-height:" do
        assert estilo =~ "mso-line-height-rule:exactly",
               "#{nome}: line-height sem mso-line-height-rule em #{inspect(estilo)}"
      end
    end

    test "toda tabela reseta border-collapse e o espaçamento do Word" do
      for {nome, html} <- documentos(), tag <- tags(html, "<table") do
        assert tag =~ "border-collapse:collapse", "#{nome}: tabela sem border-collapse"
        assert tag =~ "mso-table-lspace:0pt", "#{nome}: tabela sem o reset de espaço do Word"
      end
    end

    test "o botão tem a versão VML E a versão HTML, e elas se excluem" do
      html = documentos()["magic link"]

      # O VML é o que dá ao Outlook canto arredondado e área clicável inteira.
      assert html =~ "v:roundrect"
      assert html =~ "<w:anchorlock/>"
      assert html =~ ~s(xmlns:v="urn:schemas-microsoft-com:vml")
      # E o `downlevel-revealed` é o que esconde a versão HTML **do Outlook** (comentário
      # condicional comum esconderia dos outros, que é o contrário do que se quer).
      assert html =~ "<!--[if !mso]><!-- -->"
      assert html =~ "<!--<![endif]-->"
    end

    test "cor de fundo também vai em bgcolor, não só em CSS" do
      for {nome, html} <- documentos(), tag <- tags(html, "background-color:") do
        assert tag =~ "bgcolor=", "#{nome}: fundo só em CSS — #{String.slice(tag, 0, 90)}"
      end
    end

    test "a largura é fixa em atributo, porque o Word não entende max-width" do
      for {nome, html} <- documentos() do
        assert html =~ ~s(width="600"), "#{nome}: cartão sem largura em atributo"
      end
    end
  end

  describe "Gmail e o resto" do
    test "nada de CSS que webmail nenhum aplica" do
      # Cada um destes é ignorado por Outlook e/ou Gmail, e o layout que depende deles desmonta.
      proibidos = [
        "display:flex",
        "display:grid",
        "position:absolute",
        "position:fixed",
        "float:",
        "background-image:",
        "@font-face"
      ]

      for {nome, html} <- documentos(), proibido <- proibidos do
        refute html =~ proibido, "#{nome}: usa #{proibido}"
      end
    end

    test "nada de script nem folha externa — os dois são removidos, e cheiram a spam" do
      for {nome, html} <- documentos() do
        refute html =~ "<script", "#{nome}: tem script"
        refute html =~ "<link", "#{nome}: tem folha externa"
        refute html =~ "javascript:", "#{nome}: tem javascript: em link"
      end
    end

    test "o essencial está inline, não só na folha do topo" do
      # O app do Gmail com conta de outro provedor descarta o `<style>` inteiro. O que sobra
      # precisa ser um e-mail legível: fonte, cor e tamanho em cada elemento.
      for {nome, html} <- documentos() do
        sem_folha = String.replace(html, ~r/<style>.*?<\/style>/s, "")

        assert sem_folha =~ "font-family:Arial", "#{nome}: fonte só na folha"
        assert length(estilos(sem_folha)) > 20, "#{nome}: estilo de menos fora da folha"
      end
    end

    test "cabe folgado no limite de recorte do Gmail" do
      # Acima de ~102 KB o Gmail corta a mensagem e mostra "[Mensagem aparada]" — com o rodapé
      # (e o descadastro) do outro lado do corte.
      for {nome, html} <- documentos() do
        assert byte_size(html) < 60_000, "#{nome}: #{byte_size(html)} bytes, perto do corte"
      end
    end

    test "toda imagem tem alt, largura e altura" do
      # Imagem bloqueada é o estado padrão de boa parte das caixas: sem `alt` o cabeçalho fica
      # vazio, e sem `width`/`height` o layout pula quando ela finalmente carrega.
      for {nome, html} <- documentos(), tag <- tags(html, "<img") do
        assert tag =~ ~r/alt="[^"]+"/, "#{nome}: imagem sem alt"
        assert tag =~ ~r/width="\d+"/, "#{nome}: imagem sem width"
        assert tag =~ ~r/height="\d+"/, "#{nome}: imagem sem height"
      end
    end
  end

  describe "o cabeçalho do documento" do
    test "declara charset, viewport e o esquema de cor" do
      for {nome, html} <- documentos() do
        # XHTML 1.0 Transitional, e não HTML5: é o doctype que Outlook.com e os clientes antigos
        # tratam melhor, e o que os frameworks de e-mail (MJML e companhia) emitem. Os elementos
        # vazios saem auto-fechados para bater com o que ele declara.
        assert html =~ ~s(<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"),
               "#{nome}: doctype fora do padrão de e-mail"

        refute html =~ ~r/<(meta|img|br)[^>]*[^\/]>/, "#{nome}: elemento vazio sem auto-fechar"
        assert html =~ ~s(<meta charset="utf-8" />), "#{nome}: sem charset"
        assert html =~ "name=\"viewport\"", "#{nome}: sem viewport"
        # Sem isto o iOS transforma data, hora e telefone em link azul sublinhado.
        assert html =~ "name=\"format-detection\"", "#{nome}: sem format-detection"
        # E o Outlook em tela de DPI alto amplia imagem por conta própria sem o PixelsPerInch.
        assert html =~ "o:PixelsPerInch", "#{nome}: sem o ajuste de DPI do Outlook"
      end
    end

    test "o preheader é o primeiro do corpo, escondido, e não deixa o cliente completar a linha" do
      for {nome, html} <- documentos() do
        assert html =~ "mso-hide:all", "#{nome}: preheader visível no Outlook"
        assert html =~ "&#847;&zwnj;&nbsp;", "#{nome}: preheader sem o rabicho invisível"
      end
    end

    test "o assunto do documento é escapado — nome de clínica é texto livre" do
      Emails.send_access_revoked_email(%{email: "a@example.com"}, ~s(Silva & "Filhos"))
      html = enviado(fn -> :ok end)

      assert html =~ "<title>Seu acesso a Silva &amp; &quot;Filhos&quot; foi removido</title>"
      refute html =~ ~s(<title>Seu acesso a Silva & "Filhos")
    end
  end
end
