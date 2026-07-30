defmodule Api.Messaging.FalhasTest do
  @moduledoc """
  O motivo de falha que a **recepção** lê (doc 52 §6).

  O que este arquivo protege não é tradução: é a tela não devolver inglês técnico para quem está
  no balcão. Texto em inglês ali não informa — gera chamado de suporte sobre uma coisa que a
  própria recepção resolveria em dez segundos se a frase dissesse o que fazer.
  """
  use ExUnit.Case, async: true

  alias Api.Messaging.Falhas

  describe "para_tela/1" do
    test "endereço que não existe vira a AÇÃO, não a tradução literal" do
      # "caixa de correio não existe" seria tradução. A recepção precisa é de "confira a ficha".
      assert Falhas.para_tela("mailbox does not exist") =~ "confira o endereço na ficha"
      assert Falhas.para_tela("550 5.1.1 User unknown") =~ "confira o endereço na ficha"
      assert Falhas.para_tela("Recipient not found") =~ "confira o endereço na ficha"
    end

    test "caixa cheia é problema do paciente, não da ficha" do
      # Distinção que importa: aqui não adianta corrigir cadastro nenhum.
      assert Falhas.para_tela("mailbox full") =~ "cheia"
      assert Falhas.para_tela("552 Quota exceeded") =~ "cheia"
    end

    test "recusa por spam e falha temporária levam a ações diferentes" do
      assert Falhas.para_tela("Message rejected as spam") =~ "spam"
      assert Falhas.para_tela("451 greylisted, try again later") =~ "tente reenviar"
    end

    test "erro de configuração aponta para o suporte, não para a ficha" do
      # A recepção não tem o que corrigir num "Invalid API key" — mandar ela conferir a ficha
      # seria mandá-la procurar defeito onde não há.
      assert Falhas.para_tela("Invalid API key") =~ "suporte"
      assert Falhas.para_tela("The domain is not verified") =~ "domínio"
    end

    test "motivo desconhecido NUNCA vaza o texto cru" do
      cru = "SMTP 554 5.7.1 [XF-091] delivery halted by upstream relay policy engine"

      traduzido = Falhas.para_tela(cru)

      assert traduzido == "Não conseguimos entregar a mensagem"
      refute traduzido =~ "XF-091"
    end

    test "struct inspecionada também não vaza" do
      assert Falhas.para_tela("%Swoosh.Error{reason: :nxdomain}") ==
               "Não conseguimos entregar a mensagem"
    end

    test "o que NÓS escrevemos já é português e passa direto" do
      # Passá-los pelo genérico perderia informação que já estava certa.
      assert Falhas.para_tela("destinatário marcou como spam") == "destinatário marcou como spam"
      assert Falhas.para_tela("template desconhecido: promocao_v7") =~ "template desconhecido"
      assert Falhas.para_tela("canal whatsapp ainda não tem transporte nesta versão") =~ "canal"
    end

    test "sem erro, sem linha de erro" do
      assert Falhas.para_tela(nil) == nil
    end

    test "casa sem depender de maiúsculas" do
      assert Falhas.para_tela("MAILBOX DOES NOT EXIST") =~ "confira o endereço na ficha"
    end
  end

  describe "para_tela/1 como barreira de PII (doc 62 §7.3)" do
    # Esta função ganhou um segundo emprego: além de falar com a recepção, ela é o que torna
    # seguro **logar** o motivo de falha. O `SendJob` loga `para_tela(motivo)`, nunca o cru.
    #
    # A garantia não é vigilância, é construção: toda saída vem de uma lista fechada de frases.
    # O teste abaixo existe para que, se alguém um dia acrescentar uma regra que devolva parte
    # da entrada, a barreira caia com o build junto.

    @bounces_reais [
      "550 5.1.1 <ana.souza@gmail.com>: Recipient address rejected: User unknown",
      "554 5.7.1 <joao@clinica.com.br>: Recipient address rejected: Access denied",
      "552 5.2.2 <maria.silva@hotmail.com>: Mailbox full",
      "Recipient not found: pedro.alves@yahoo.com.br",
      "invalid recipient <contato+tag@dominio.com>"
    ]

    test "nenhum endereço de e-mail do texto cru sobrevive à classificação" do
      for cru <- @bounces_reais do
        saida = Falhas.para_tela(cru)

        refute saida =~ "@",
               "vazou endereço ao classificar #{inspect(cru)} — saiu #{inspect(saida)}"
      end
    end

    test "nenhum trecho do texto cru é ecoado na saída" do
      for cru <- @bounces_reais do
        saida = Falhas.para_tela(cru)

        # Nenhuma palavra de 5+ letras da entrada pode reaparecer na saída. Pega o caso em que
        # uma regra futura interpolasse o motivo original ("falhou: #{motivo}").
        palavras =
          cru
          |> String.split(~r/[^\p{L}\p{N}@._+-]+/u, trim: true)
          |> Enum.filter(&(String.length(&1) >= 5))

        for palavra <- palavras do
          refute String.contains?(String.downcase(saida), String.downcase(palavra)),
                 "eco de #{inspect(palavra)} em #{inspect(saida)}"
        end
      end
    end
  end
end
