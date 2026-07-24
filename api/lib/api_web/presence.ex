defmodule ApiWeb.Presence do
  @moduledoc """
  Presença de sockets (`Phoenix.Presence`) — quem está fazendo o quê, **agora**.

  Primeiro uso: "alguém já está oferecendo esta vaga" na fila de espera (doc 39). O que existia
  antes era uma **reserva no banco** (`SlotHold`, 10 min de TTL) que, além de nunca ter sido
  ligada na tela, travava a vaga: quem fechasse o modal deixava o horário preso até expirar.

  Presença resolve a mesma pergunta sem nada disso:

    * **morre sozinha** — o processo do canal cai (aba fechada, rede caiu, logout) e o registro
      some junto. Não há TTL para escolher, nem cron para limpar, nem estado preso;
    * **não bloqueia** — é informação, não trava. Dois atendentes podem estar oferecendo o mesmo
      horário e os dois se veem; quem confirmar por último leva o 422 da exclusion constraint do
      **agendamento**, que sempre foi quem de fato impede a colisão;
    * **não vai ao banco** — nenhuma tabela, nenhuma escrita, nenhuma RLS a atravessar.

  O que ela **não** faz, e é bom deixar escrito: não sobrevive a um F5 (a aba nova rastreia de
  novo, mas há um piscar), e não serve para nada que precise de garantia — para isso existe a
  constraint.
  """
  use Phoenix.Presence,
    otp_app: :api,
    pubsub_server: Api.PubSub
end
