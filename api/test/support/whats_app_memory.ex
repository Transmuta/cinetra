defmodule Api.Messaging.WhatsAppMemory do
  @moduledoc """
  Adaptador de WhatsApp em memória — o transporte da suíte (doc 65 §7).

  Mesma razão do `Api.Storage.Memory`: as perguntas que os testes desta fatia fazem ("saiu pelo
  WhatsApp ou pelo e-mail?", "o template levou os parâmetros na ordem certa?", "o que acontece
  quando a Meta recusa?") precisam de resposta sem rede, sem credencial e sem a Zernio de pé. Se
  a suíte falasse com a API real, o gate de cobertura passaria a depender de um terceiro.

  Guarda os envios num `Agent` nomeado, iniciado pelo `test_helper.exs`. `falhar_com/1` faz o
  próximo envio devolver erro — é como se testa o caminho de falha sem simular HTTP.
  """
  @behaviour Api.Messaging.Transport

  @agente __MODULE__

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{enviadas: [], erro: nil} end, name: @agente)

  @doc "Os envios desde o último `limpar/0`, na ordem em que aconteceram."
  def enviadas, do: Agent.get(@agente, & &1.enviadas) |> Enum.reverse()

  @doc "Esvazia entre testes."
  def limpar, do: Agent.update(@agente, fn _ -> %{enviadas: [], erro: nil} end)

  @doc """
  Faz os próximos envios devolverem `{:error, motivo}`.

  O motivo é o texto **cru** que a Zernio devolveria (com o código da Meta dentro), porque é
  exatamente ele que `Api.Messaging.Falhas` tem de saber traduzir — passar uma frase já em
  português testaria o teste, não o código.
  """
  def falhar_com(motivo), do: Agent.update(@agente, &Map.put(&1, :erro, motivo))

  @impl true
  def configurado?, do: true

  @impl true
  def entregar(message, corpo) do
    Agent.get_and_update(@agente, fn estado ->
      registro = %{
        destino: message.destino,
        template: corpo[:nome],
        idioma: corpo[:idioma],
        params: corpo[:params],
        conta: Api.Messaging.Zernio.conta(message),
        # A sonda que o bate-volta do doc 60 deixou sem instrumento: a entrega fala com um
        # terceiro, e fazê-la **dentro** da transação da GUC segura conexão do pool pelo tempo da
        # rede alheia. O `SendJob` sai da transação de propósito; isto é o que impede a correção
        # de ser desfeita sem ninguém ver.
        #
        # Em teste o sandbox roda tudo numa transação, então `true` é o normal — o que se compara é
        # com o caminho de leitura, que abre a **sua**. Ver o teste que consome este campo.
        em_transacao?: Api.Repo.in_transaction?()
      }

      resposta =
        case estado.erro do
          nil -> {:ok, "zernio", "wamid-#{System.unique_integer([:positive])}"}
          motivo -> {:error, motivo}
        end

      {resposta, %{estado | enviadas: [registro | estado.enviadas]}}
    end)
  end
end
