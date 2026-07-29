defmodule Api.Messaging.MessageStatus do
  @moduledoc """
  A máquina de entrega (doc 52 §4), **única para os dois canais**.

      :pendente → :enviado → :entregue → :lido
           ↓          ↓           ↓
        :falhou   :falhou      :falhou

  `:lido` nunca acontece no e-mail: ele exigiria pixel de rastreio, e o C4 decidiu não usar
  (rastrear leitura de paciente é desproporcional). O estado nasce vazio na fase 1 e ganha valor
  no WhatsApp — e é justamente esse encaixe que faz a fase 2 ser adapter em vez de reescrita.

  **Responder não é estado.** A resposta do paciente (§5) mora em `respondido_em`/`resposta`
  porque pode chegar a qualquer momento — inclusive depois de `:falhou`, quando a confirmação
  falhou no WhatsApp e o paciente respondeu ao e-mail de reserva. Modelá-la como estado obrigaria
  a escolher entre "entregue" e "respondida", e as duas são verdade.

  O avanço é **monotônico** (`ordem/1`): webhook fora de ordem é o caso comum, não a exceção —
  `delivered` e `sent` chegam em milissegundos um do outro e a rede não promete ordem. Sem isso,
  um `sent` atrasado rebaixaria uma mensagem já entregue.

  ## `:descartada` — o estado que a janela de silêncio obrigou a existir

  Adiar (§7) criou uma janela de horas entre "a mensagem foi pedida" e "a mensagem saiu", e nela o
  **fato pode mudar**: o bloco é cancelado ou excluído às 22h45 e a confirmação segue parada até
  as 8h. Sem este estado ela saía assim mesmo, anunciando uma sessão que já não existe — e
  mensagem enviada não volta.

  Não é `:falhou`: nada falhou. Não é apagar a linha: a recepção que clicou "enviar" às 22h
  precisa achar o que aconteceu com aquele clique — silêncio na tela é o pecado que a timeline
  inteira foi desenhada para não cometer (§6).

  **É terminal por construção**, sem precisar de cláusula: `ordem/1` não o conhece, então
  `avanca?/2` devolve `false` nos dois sentidos — um webhook atrasado não ressuscita o que foi
  tirado da fila, e o que já saiu não vira descartado. A mesma propriedade que protege `:falhou`.
  """
  use Ash.Type.Enum, values: [:pendente, :enviado, :entregue, :lido, :falhou, :descartada]

  @ordem %{pendente: 0, enviado: 1, entregue: 2, lido: 3}

  @doc """
  Posição do estado na escada de entrega. `:falhou` e `:descartada` ficam fora (devolvem `nil`):
  nenhum dos dois é "mais adiante" que `:entregue` — são outros ramos, e é essa ausência que os
  torna terminais em `avanca?/2`.
  """
  def ordem(status), do: Map.get(@ordem, status)

  @doc """
  O novo estado deve substituir o atual?

  Regra: só avança na escada. `:falhou` **não** sobrescreve o que já chegou ao destino — um
  `bounce` tardio depois de `delivered` é ruído do provider, não a verdade sobre a entrega; e
  `:falhou` sobre `:pendente`/`:enviado` passa, que é o caso real.
  """
  def avanca?(atual, novo)

  def avanca?(atual, atual), do: false

  def avanca?(atual, :falhou), do: ordem(atual) != nil and ordem(atual) <= ordem(:enviado)

  def avanca?(:falhou, _novo), do: false

  def avanca?(atual, novo) do
    case {ordem(atual), ordem(novo)} do
      {a, n} when is_integer(a) and is_integer(n) -> n > a
      _ -> false
    end
  end
end
