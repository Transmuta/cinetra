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
  valor já persistido é que quebra. É por isso que os **aposentados** continuam na lista: eles não
  nascem mais de gatilho nenhum, mas uma linha antiga precisa continuar renderizando. Quem procura
  "quem ainda dispara isto?" olha `Api.Messaging.Notifier` e `ApiWeb.MessagesController`, não aqui.
  """
  use Ash.Type.Enum,
    values: [
      # "Sua sessão foi agendada para <dia> às <hora>" — sai na criação e no botão do drawer.
      :confirmacao,
      # "Sua sessão é amanhã às <hora>" — **aposentado em 2026-08-01**. Havia um cron
      # (`ReminderJob`) e uma coluna (`clinics.msg_lembrete_horas`); os dois saíram. O átomo fica
      # porque linha já gravada precisa continuar renderizando na timeline — remover valor
      # persistido é o que quebra (ver o fim deste moduledoc) — e porque voltar atrás fica barato.
      :lembrete,
      # "Sua sessão mudou para <dia> às <hora>" — C7(b), o gatilho de remarcação.
      :remarcacao,
      # "Sua sessão de <dia> foi cancelada" — C7(b). **Só o cancelamento**: excluir (doc 40) é
      # corrigir um lançamento errado, e dar a esse gesto um efeito fora do sistema seria avisar
      # o paciente por causa de um erro de digitação. Ver `Api.Messaging.Notifier`.
      :cancelamento,
      # Os dois de LOTE, **aposentados em 2026-08-01** pelo mesmo motivo do `:lembrete`. Existiam
      # porque remarcar um pacote de 40 mandaria 40 "sua sessão mudou" ao mesmo paciente (doc 43
      # §5b), e a saída era uma mensagem por massa. Hoje a massa não fala com o paciente — quem
      # avisa é a recepção, pelo telefone que vai dentro de toda mensagem. O que ficou de pé é o
      # aviso na CAIXA do profissional dono da coluna, que é outra coisa e não custa nada.
      :pacote_remarcado,
      :pacote_cancelado
    ]
end
