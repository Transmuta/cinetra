defmodule Api.Messaging.TemplatesTest do
  @moduledoc """
  O texto das mensagens, e sobretudo **a ordem das posicionais do WhatsApp** (doc 65 §3).

  O teste que importa aqui é o `render_whatsapp/2` contra o corpo aprovado: a Zernio manda
  `templateParams` como lista plana, sem nomes, e se a ordem divergir do texto aprovado na Meta a
  mensagem sai com a data no lugar do nome — **e a API aceita**, porque a contagem bate. Não há
  código de erro para esse defeito; o sintoma é um paciente confuso, dias depois.

  Por isso a asserção não compara com uma lista literal escrita à mão (que seria a mesma ordem
  copiada, divergindo junto): ela **lê o corpo do template** e confere que o valor de cada `{{n}}`
  é o que aquela posição promete.
  """
  use ExUnit.Case, async: true

  alias Api.Messaging.Templates

  @vars %{
    "clinica" => "Clínica Cinetra",
    "paciente" => "Maria Aparecida da Silva",
    "data" => "28/07/2026",
    "hora" => "14:00",
    "quantas" => "3 sessões",
    "pacote" => "Pilates 10",
    "telefone" => "(11) 3456-7890",
    "token" => "tok123"
  }

  describe "cada kind tem template, e cada template tem kind" do
    test "a ida e a volta fecham" do
      for template <- Templates.conhecidos() do
        kind = Templates.kind_de(template)
        assert kind, "#{template} não tem kind"
        assert Templates.para(kind) == template
      end
    end

    test "todo template conhecido renderiza nos DOIS canais" do
      # Um template que renderiza só no e-mail viraria "template desconhecido" no WhatsApp — uma
      # falha por mensagem, visível só na tela da recepção depois do envio.
      for template <- Templates.conhecidos() do
        assert {:ok, %{assunto: _, texto: _}} = Templates.render_email(template, @vars)
        assert {:ok, %{nome: ^template, params: _}} = Templates.render_whatsapp(template, @vars)
      end
    end
  end

  describe "render_whatsapp/2 — a ordem é contrato" do
    test "cada {{n}} do corpo aprovado recebe o valor que aquela posição promete" do
      for template <- Templates.conhecidos() do
        %{corpo: corpo, vars: nomes, botao?: botao?} = Templates.hsm(template)
        {:ok, %{params: params}} = Templates.render_whatsapp(template, @vars)

        # As posicionais do CORPO, na ordem em que aparecem no texto que a Meta aprovou.
        posicoes =
          Regex.scan(~r/\{\{(\d+)\}\}/, corpo) |> Enum.map(fn [_, n] -> String.to_integer(n) end)

        assert posicoes == Enum.to_list(1..length(nomes)),
               "#{template}: o corpo não usa {{1}}..{{#{length(nomes)}}} em ordem"

        esperados = Enum.map(nomes, &valor_esperado/1)
        do_corpo = Enum.take(params, length(nomes))

        assert do_corpo == esperados, "#{template}: parâmetros fora de ordem"

        # O botão de resposta acrescenta **um** valor no fim: o token, que é o sufixo da URL
        # dinâmica congelada no template.
        if botao? do
          assert List.last(params) == "tok123"
          assert length(params) == length(nomes) + 1
        else
          assert length(params) == length(nomes)
        end
      end
    end

    test "o cumprimento leva só o primeiro nome" do
      {:ok, %{params: [primeiro | _]}} = Templates.render_whatsapp("confirmacao_v1", @vars)

      assert primeiro == "Maria"
    end

    test "variável ausente vira travessão, não some" do
      # Some seria pior: a Meta recusa a mensagem inteira quando a contagem não bate.
      {:ok, %{params: params}} = Templates.render_whatsapp("confirmacao_v1", %{})

      # Derivado da definição, não literal: um número escrito à mão aqui só diria que alguém
      # lembrou de atualizar o teste ao acrescentar uma posicional.
      assert length(params) == length(Templates.hsm("confirmacao_v1").vars) + 1
      assert Enum.all?(params, &is_binary/1)
    end

    test "nome com quebra de linha não vai como está — a Meta recusaria" do
      # A Meta rejeita parâmetro de template com quebra de linha, tab ou 4+ espaços seguidos
      # (família de erro 132xxx). Um nome colado de PDF/planilha carrega `\n` sem ninguém ver, e o
      # efeito seria a mensagem daquele paciente falhar **sempre** — com o texto de erro apontando
      # para o lugar errado ("template não aprovado", quando o template está certo).
      {:ok, %{params: params}} =
        Templates.render_whatsapp("confirmacao_v1", %{
          "paciente" => "Ana\nMaria",
          "clinica" => "Clínica  \t  X",
          "data" => "28/07",
          "hora" => "14:00",
          "token" => "t"
        })

      refute Enum.any?(params, &String.contains?(&1, "\n"))
      refute Enum.any?(params, &String.contains?(&1, "\t"))
      refute Enum.any?(params, &(&1 =~ ~r/\s{4}/))

      # E o conteúdo continua legível — higienizar não é truncar.
      assert "Ana" in params
      assert "Clínica X" in params
    end

    test "o e-mail NÃO é higienizado — a restrição é da Meta, não nossa" do
      {:ok, %{texto: texto}} =
        Templates.render_email("confirmacao_v1", %{@vars | "clinica" => "Clínica\nDois"})

      assert texto =~ "Clínica\nDois"
    end

    test "template desconhecido devolve :error nos dois canais" do
      assert Templates.render_whatsapp("nao_existe_v9", @vars) == :error
      assert Templates.render_email("nao_existe_v9", @vars) == :error
    end
  end

  describe "render_email/2 — o telefone e o aviso de automática" do
    test "todo e-mail diz o telefone da clínica e que não se responde por ali" do
      for template <- Templates.conhecidos() do
        {:ok, %{texto: texto}} = Templates.render_email(template, @vars)

        assert texto =~ "(11) 3456-7890", "#{template}: e-mail sem telefone"
        assert texto =~ "Mensagem automática", "#{template}: e-mail sem o aviso"
      end
    end

    test "sem telefone, a LINHA some — não vira 'ligue para —'" do
      # Aqui o e-mail pode o que o WhatsApp não pode: omitir. No template HSM a contagem de
      # posicionais é fixa e um travessão é o mal menor; no e-mail, texto livre, "Ligue para —"
      # seria defeito visível escrito por nós.
      sem = Map.delete(@vars, "telefone")

      for template <- Templates.conhecidos() do
        {:ok, %{texto: texto}} = Templates.render_email(template, sem)

        refute texto =~ "—", "#{template}: travessão vazou para o e-mail"
        assert texto =~ "Mensagem automática", "#{template}: o aviso não depende do telefone"
      end
    end
  end

  describe "render_email/2 — a parte em HTML" do
    test "todo template conhecido rende HTML, com a clínica no topo e a Cinetra no rodapé" do
      for template <- Templates.conhecidos() do
        {:ok, %{html: html}} = Templates.render_email(template, @vars)

        assert html =~ "<!DOCTYPE html", "#{template}: HTML sem documento"
        # O §9.1.4 no canal que tem cabeçalho: quem fala com o paciente é a clínica.
        assert html =~ "Clínica Cinetra", "#{template}: HTML sem o nome da clínica"
        assert html =~ "Sua clínica", "#{template}: HTML sem o cabeçalho da clínica"
        # E a Cinetra aparece como quem entrega, não como quem fala.
        assert html =~ "CINETRA", "#{template}: HTML sem o crédito no rodapé"
      end
    end

    test "as duas partes saem juntas, e a de texto continua sendo texto" do
      {:ok, corpo} = Templates.render_email("confirmacao_v1", @vars)

      assert corpo.texto =~ "Olá, Maria!"
      refute corpo.texto =~ "<", "a parte de texto não é o HTML raspado"
    end

    test "o botão aparece nos templates que fazem pergunta — e só quando há link" do
      # A autoridade é a MESMA `botao?` do HSM: um template que ganha botão no WhatsApp e não no
      # e-mail é divergência que ninguém vê até um paciente reclamar.
      com_link = Map.put(@vars, "link", "https://app.cinetra.test/confirmar/abc")

      for template <- Templates.conhecidos() do
        {:ok, %{html: html}} = Templates.render_email(template, com_link)
        {:ok, %{html: sem_link}} = Templates.render_email(template, @vars)

        if Templates.hsm(template).botao? do
          assert html =~ "Confirmar ou remarcar", "#{template}: pergunta sem botão"
          assert html =~ "https://app.cinetra.test/confirmar/abc"
        else
          refute html =~ "Confirmar ou remarcar", "#{template}: botão numa mensagem sem pergunta"
        end

        # Sem link não há botão em template nenhum — é o caso da timeline, que renderiza o
        # histórico sem token.
        refute sem_link =~ "Confirmar ou remarcar", "#{template}: botão sem link para onde ir"
      end
    end

    test "o descadastro aparece nas DUAS partes quando há token" do
      url = "https://app.cinetra.test/descadastrar/xyz"
      vars = Map.put(@vars, "descadastro", url)

      for template <- Templates.conhecidos() do
        {:ok, %{html: html, texto: texto}} = Templates.render_email(template, vars)

        assert html =~ url, "#{template}: HTML sem o link de descadastro"
        # Também no texto: quem lê e-mail sem HTML é justamente quem não tem onde clicar.
        assert texto =~ url, "#{template}: texto sem o link de descadastro"
      end
    end

    test "sem token, nenhuma das duas partes promete um link que não existe" do
      for template <- Templates.conhecidos() do
        {:ok, %{html: html, texto: texto}} = Templates.render_email(template, @vars)

        refute html =~ "descadastrar", "#{template}: link de descadastro quebrado no HTML"
        refute texto =~ "descadastrar", "#{template}: link de descadastro quebrado no texto"
      end
    end

    test "o rodapé do paciente não promete página que não existe" do
      {:ok, %{html: html}} = Templates.render_email("confirmacao_v1", @vars)

      # Nenhuma das três existe no produto. Rodapé que aponta para o vazio é pior que rodapé curto.
      refute html =~ "Preferências de e-mail"
      refute html =~ "Central de ajuda"
      refute html =~ "CNPJ"
    end

    test "nome de clínica com & e < sai escapado — não vira marcação" do
      # Texto livre digitado no balcão. O `<script>` é o caso raro; o `&` de "Silva & Filhos" é o
      # de terça, e sozinho já produz HTML inválido.
      vars = %{@vars | "clinica" => "Silva & Filhos <b>Fisio</b>"}

      {:ok, %{html: html}} = Templates.render_email("confirmacao_v1", vars)

      assert html =~ "Silva &amp; Filhos &lt;b&gt;Fisio&lt;/b&gt;"
      refute html =~ "Filhos <b>Fisio"
    end

    test "o cumprimento também é escapado — ele é o outro campo de texto livre" do
      # O nome do paciente entra no parágrafo pelo primeiro nome; o `&` chega ali igual.
      vars = %{@vars | "paciente" => "Ana&Bia Souza"}

      {:ok, %{html: html}} = Templates.render_email("confirmacao_v1", vars)

      assert html =~ "Olá, Ana&amp;Bia."
    end
  end

  describe "assunto/2 — o título da timeline" do
    test "devolve o mesmo assunto do e-mail, sem montar corpo nenhum" do
      for template <- Templates.conhecidos() do
        {:ok, %{assunto: assunto}} = Templates.render_email(template, @vars)

        assert Templates.assunto(template, @vars) == {:ok, assunto}
      end
    end

    test "template desconhecido devolve :error — a timeline não pode cair por causa disso" do
      assert Templates.assunto("nao_existe_v9", @vars) == :error
    end
  end

  describe "o HSM que a mix task submete" do
    test "todo template é pt_BR e não começa nem termina com variável" do
      # Regra da Meta. Reprovação por isso custa dias de fila para descobrir.
      for template <- Templates.conhecidos() do
        %{idioma: idioma, corpo: corpo} = Templates.hsm(template)

        assert idioma == "pt_BR"
        refute String.starts_with?(String.trim(corpo), "{{"), "#{template} começa com variável"
        refute String.ends_with?(String.trim(corpo), "}}"), "#{template} termina com variável"
        refute corpo =~ ~r/\}\}\s*\{\{/, "#{template} tem duas variáveis coladas"
      end
    end

    test "o payload sai como UTILITY, com um exemplo por posicional" do
      for template <- Templates.conhecidos() do
        {:ok, payload} = Templates.hsm_payload(template, "https://cinetra.com.br")

        assert payload.name == template
        # `UTILITY`: a categoria errada muda o preço e sujeita a mensagem operacional ao opt-out
        # de marketing, que é outro consentimento.
        assert payload.category == "UTILITY"

        [%{type: "BODY", example: %{body_text: [exemplos]}} | _] = payload.components
        assert length(exemplos) == length(Templates.hsm(template).vars)
      end
    end

    test "o botão carrega o domínio pedido, e o {{1}} do sufixo" do
      # O domínio fica congelado no template aprovado: trocá-lo depois exige `_v2`.
      {:ok, payload} = Templates.hsm_payload("confirmacao_v1", "https://cinetra.com.br")

      botoes = Enum.find(payload.components, &(&1.type == "BUTTONS"))

      assert [%{type: "URL", url: "https://cinetra.com.br/confirmar/{{1}}"}] = botoes.buttons
    end

    test "template sem pergunta a fazer não ganha botão" do
      {:ok, payload} = Templates.hsm_payload("cancelamento_v1", "https://cinetra.com.br")

      refute Enum.any?(payload.components, &(&1.type == "BUTTONS"))
    end

    test "template desconhecido não vira payload" do
      assert Templates.hsm_payload("nao_existe_v9", "https://cinetra.com.br") == :error
    end

    test "o telefone da clínica está em TODO template" do
      # O canal não tem para onde responder: botão de URL abre o navegador, e uma resposta em
      # texto livre cai no número compartilhado que ninguém lê (`Api.Messaging.Zernio`). Sem um
      # telefone no corpo, "preciso falar com alguém" não tem saída nenhuma.
      for template <- Templates.conhecidos() do
        assert "telefone" in Templates.hsm(template).vars, "#{template} não diz para onde ligar"
      end
    end

    test "o footer é estático, curto e sem variável" do
      # Três regras da Meta numa asserção só, e cada uma reprova o template dias depois de
      # submetido: footer não aceita parâmetro, tem teto de 60 caracteres, e é o MESMO texto para
      # todas as clínicas — é por isso que o telefone teve de ir para o corpo.
      for template <- Templates.conhecidos() do
        {:ok, payload} = Templates.hsm_payload(template, "https://cinetra.com.br")

        footer = Enum.find(payload.components, &(&1.type == "FOOTER"))

        assert footer, "#{template} não tem footer"
        assert String.length(footer.text) <= 60, "#{template}: footer passa de 60 caracteres"
        refute footer.text =~ ~r/\{\{/, "#{template}: footer com variável — a Meta recusa"
      end
    end

    test "o footer vem ANTES dos botões, que é a ordem que a Meta espera" do
      {:ok, payload} = Templates.hsm_payload("confirmacao_v1", "https://cinetra.com.br")

      tipos = Enum.map(payload.components, & &1.type)

      assert tipos == ["BODY", "FOOTER", "BUTTONS"]
    end

    test "o nome da clínica está em TODO template (§9.1.4)" do
      # Com número compartilhado, é a primeira linha dizer de quem é a mensagem que separa
      # "mensagem esperada" de "quem é você?".
      for template <- Templates.conhecidos() do
        assert "clinica" in Templates.hsm(template).vars, "#{template} não diz de quem é"
      end
    end
  end

  defp valor_esperado("paciente"), do: "Maria"
  defp valor_esperado(chave), do: Map.fetch!(@vars, chave)
end
