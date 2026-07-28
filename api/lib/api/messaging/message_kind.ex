defmodule Api.Messaging.MessageKind do
  @moduledoc """
  O **motivo** de uma mensagem ao paciente (doc 52 §4) — não o texto dela, que mora no template.

  Todos são **operacionais**: cada um nasce de um agendamento que existe e fala dele. Essa
  fronteira não é estilística, é o que sustenta duas decisões do doc 52:

    * o consentimento padrão autorizado (§11.1) — confirmar uma sessão que o paciente marcou é
      execução do serviço contratado, não marketing;
    * o número único da Cinetra (§9.1.5) — o risco do número compartilhado depende de a clínica
      poder compor texto livre, e o que existe aqui é uma lista fechada que nós escrevemos.

  Acrescentar um `kind` de campanha/aniversário/reengajamento **reabre as duas**. Não é proibido;
  é uma decisão de produto que passa por rever o §9.1.5 e por uma flag de consentimento própria,
  nunca pelo reúso do `comunicacao` da ficha.

  Acrescentar valor aqui não é migration (a coluna é `text` e o enum vive no Ash); remover um
  valor já persistido é que quebra.
  """
  use Ash.Type.Enum,
    values: [
      # "Sua sessão foi agendada para <dia> às <hora>" — sai na criação e no botão do drawer.
      :confirmacao,
      # "Sua sessão é amanhã às <hora>" — o cron, N horas antes (desligado por padrão).
      :lembrete,
      # "Sua sessão mudou para <dia> às <hora>" — C7(b), o gatilho de remarcação.
      :remarcacao,
      # "Sua sessão de <dia> foi cancelada" — C7(b). **Só o cancelamento**: excluir (doc 40) é
      # corrigir um lançamento errado, e dar a esse gesto um efeito fora do sistema seria avisar
      # o paciente por causa de um erro de digitação. Ver `Api.Messaging.Notifier`.
      :cancelamento,
      # Os dois de LOTE, e existem pela mesma razão que o `:package_bulk_adjusted` do sino
      # (doc 43 §5b): remarcar um pacote de 40 mandaria 40 "sua sessão mudou" ao mesmo paciente,
      # e no WhatsApp isso é spam **pago**. Uma mensagem por massa, com o número dentro.
      :pacote_remarcado,
      :pacote_cancelado
    ]
end
