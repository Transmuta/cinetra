defmodule Api.Messaging.DescarteMotivo do
  @moduledoc """
  Por que uma mensagem foi tirada da fila antes de sair (`Api.Messaging.MessageStatus` →
  `:descartada`).

  Os dois valores têm a mesma forma — **o fato sobre o qual a mensagem falava deixou de existir**
  enquanto ela esperava a janela de silêncio (§7) abrir:

    * `:sessao_cancelada` — o bloco foi cancelado. O paciente recebe o cancelamento; receber
      também a confirmação da mesma sessão, minutos depois, é a clínica se contradizendo;
    * `:agendamento_excluido` — o bloco foi excluído (doc 40). Excluir é corrigir um lançamento
      errado, e a decisão de **não** dar a esse gesto efeito fora do sistema
      (`Api.Messaging.Notifier`) morria na fila: a confirmação da criação saía mesmo assim.

  Vira frase na tela do lado do `web/` (`$lib/messages.ts`), como todo motivo desta fatia: quem lê
  a timeline é a recepção no balcão, e átomo não informa ninguém.

  **Remarcação não está aqui**, e a ausência é decisão: uma confirmação parada quando a sessão é
  remarcada anuncia um horário que mudou, mas descartá-la deixaria o paciente com um "sua sessão
  mudou" sem nunca ter recebido o "sua sessão está marcada" — o aviso ficaria sem antecedente. O
  caso é real e continua aberto; ver `docs/50-debitos-tecnicos.md`.
  """
  use Ash.Type.Enum, values: [:sessao_cancelada, :agendamento_excluido]
end
