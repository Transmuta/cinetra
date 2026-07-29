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

      assert length(params) == 5
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
