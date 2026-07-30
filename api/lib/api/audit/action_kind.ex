defmodule Api.Audit.ActionKind do
  @moduledoc """
  A natureza do evento — o eixo grosso pelo qual a tela agrupa e pelo qual a LGPD pergunta.

  Os três primeiros são os tipos de ação do Ash e vêm de graça do changeset. Os dois últimos são
  a razão de a trilha do projeto ter deixado de ser `AshPaperTrail` (doc 63 §3):

    * `:read` — **leitura** de dado de saúde. O `06 §4` cobra isso em letras claras ("não só a
      escrita, a leitura também") e escrita não é o que responde *"quem leu o laudo?"*;
    * `:deny` — **autorização negada**. Não houve mudança nem leitura: houve tentativa. É o
      insumo de detecção de abuso do `06 §8`, e o projeto já achou um IDOR real (T-P1) que
      nenhum registro teria acusado sozinho.
  """
  use Ash.Type.Enum, values: [:create, :update, :destroy, :read, :deny]
end
