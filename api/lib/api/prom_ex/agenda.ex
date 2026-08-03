defmodule Api.PromEx.Agenda do
  @moduledoc """
  A **amplificação do tempo real da agenda** (doc 101, M6) — três séries que respondem uma
  pergunta que hoje ninguém consegue responder.

  ## A pergunta

  Uma escrita de agenda vira N releituras do bloco no banco: o `ApiWeb.AgendaChannel` relê **uma
  vez por assinante**, com o escopo de cada um, porque é isso que faz o recorte A7 (o papel
  `profissional` só vê a própria coluna) valer também no WebSocket. O custo escala com
  **assinantes × eventos**, não com o dado — e a leitura de cada releitura traz subconsulta
  correlacionada e agregado com sort (`Api.Scheduling.bloco_load/0`).

  Isso é caro ou irrelevante? Depende inteiramente do N, e o N é uma propriedade do **uso**: dois
  recepcionistas com a agenda do dia aberta é uma coisa; a clínica inteira com a Semana na tela
  numa manhã de remarcações é outra. Nenhum log responde isso — é estado, e estado se mede.

  ## As séries, e por que três

      cinetra_agenda_broadcasts_total                        # quantas publicações
      cinetra_agenda_channel_entregas_total{modo,releitura}   # quantos canais trataram
      cinetra_agenda_channel_releitura_duration_milliseconds  # quanto custou cada releitura

  A **razão** entre as duas primeiras é a amplificação: `entregas / broadcasts` = assinantes por
  tópico. Com um contador só não dá para distinguir "muita gente na tela" de "muita escrita na
  agenda" — dois problemas com remédios opostos (um pede leitura compartilhada, o outro pede
  menos evento). O rótulo `releitura` separa quem paga banco de quem só empurra sinal: o modo
  `signal` (Semana e Mês) e o `appointment_excluded` respondem sem ler nada, e contá-los junto
  esconderia o único número que interessa.

  A terceira é o custo unitário. Sem ela, uma amplificação alta não distingue "40 leituras de
  2 ms" de "40 leituras de 60 ms".

  ## O gatilho de agir

  Isto existe para uma decisão que foi **adiada de propósito** — o plano da onda 3 diz "não mexer
  ainda: instrumentar e decidir pela métrica". O que justificaria mexer:

      # p95 da releitura sob carga real
      histogram_quantile(0.95, rate(cinetra_agenda_channel_releitura_duration_milliseconds_bucket[5m]))

      # amplificação média na janela
      rate(cinetra_agenda_channel_entregas_total{releitura="true"}[5m])
        / rate(cinetra_agenda_broadcasts_total[5m])

  Enquanto a amplificação ficar em um dígito baixo, a releitura por assinante é o desenho certo —
  ela custa uma leitura barata e mantém **uma** autoridade para o recorte A7. Se subir, o conserto
  não é "cachear o bloco": é agrupar assinantes com o mesmo recorte efetivo, que são poucos
  (clínica inteira × cada profissional), e aí a métrica dirá quantos grupos existem de verdade.
  """
  use PromEx.Plugin

  alias Api.Scheduling.AgendaNotifier
  alias ApiWeb.AgendaChannel

  @impl true
  def event_metrics(_opts) do
    Event.build(:cinetra_agenda_event_metrics, [
      counter(
        [:cinetra, :agenda, :broadcasts, :total],
        event_name: AgendaNotifier.evento_broadcast(),
        description: "Publicações de evento de agenda no PubSub (uma por tópico afetado).",
        measurement: :count
      ),
      counter(
        [:cinetra, :agenda, :channel, :entregas, :total],
        event_name: AgendaChannel.evento_entrega(),
        description: "Eventos de agenda tratados por um canal, por modo e com/sem releitura.",
        measurement: :count,
        tags: [:modo, :releitura]
      ),
      # Buckets em milissegundos. A faixa vai de 1 ms (o caso saudável, tudo em cache do Postgres)
      # a 1 s (o caso em que a releitura por assinante virou o problema que este plugin existe
      # para detectar) — sem isso o histograma não distingue os dois extremos que decidem a ação.
      distribution(
        [:cinetra, :agenda, :channel, :releitura, :duration, :milliseconds],
        event_name: AgendaChannel.evento_releitura(),
        description: "Tempo de UMA releitura do bloco com o escopo do assinante.",
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:achou],
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      )
    ])
  end
end
