defmodule Api.Repo.Migrations.MessagesUmaPendentePorPresenca do
  @moduledoc """
  Índice único **parcial** que fecha a corrida da barreira de mensagens (doc 96, B-8).

  ## O que está aberto sem ele

  `Dispatch.barreira/3` lê numa transação (`in_clinic`) e `enqueue_message!` escreve em **outra**.
  Entre as duas há janela: dois pedidos simultâneos para a mesma `(attendance_id, kind)` — duplo
  clique da recepção, retry do cliente HTTP, dois atendentes na mesma ficha — passam os dois pela
  barreira e gravam duas linhas `:pendente`. No WhatsApp, cada duplicata é **paga** e chega ao
  paciente.

  A barreira resolve o caso **sequencial** (medido: "quatro linhas idênticas para o mesmo
  paciente"). Ela não alcança o concorrente, porque quem arbitra concorrência é o banco.

  ## Por que parcial nas DUAS dimensões

  `WHERE status = 'pendente' AND kind IN ('confirmacao','lembrete')`:

    * **por status** — a unicidade vale só enquanto a mensagem está *na fila*. Depois de enviada, a
      mesma presença pode legitimamente receber outra do mesmo tipo (o reenvio da recepção); o teto
      é regra de domínio (`@limite_de_confirmacoes`), não de índice;

    * **por kind** — cobre **exatamente** os tipos que o `Dispatch` põe sob barreira
      (`@com_barreira`). Remarcação e cancelamento ficam de fora de propósito: cada um anuncia um
      **fato novo**, e remarcar duas vezes precisa avisar duas vezes. A primeira versão deste
      índice não tinha esse recorte e quebrou o teste "remarcar duas vezes avisa duas vezes" — o
      banco engolia o segundo aviso. É o índice espelhando a regra de domínio, não inventando uma.

  ## História: este índice já foi revertido uma vez

  Numa primeira tentativa ele derrubou 6 testes de `SendJobTest`, e a leitura na época foi que ele
  proibia mais que a regra de domínio. Estava errada: o que havia era a **confirmação automática na
  criação** do agendamento, removida em `5f1c381` — com ela, a presença já nascia com uma pendente
  e o `dispatch` seguinte batia no índice. Medido depois da remoção: criar um agendamento deixa
  zero pendentes, o primeiro `dispatch(:confirmacao)` grava, e o segundo é barrado pela barreira.
  A suíte inteira passa com o índice de pé.

  ## `CONCURRENTLY`, pela regra 2

  `messages` é tabela quente. Índice comum tomaria `ShareLock`, e como `Api.Release.setup/0` roda
  as migrations no `release_command`, essa janela cairia **no deploy**. Ver
  `.claude/rules/migrations.md` §2. As duas anotações abaixo andam juntas: `CONCURRENTLY` não roda
  dentro de transação, e a migration do Ecto abre uma por padrão.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS messages_uma_pendente_por_presenca
      ON messages (attendance_id, kind)
      WHERE status = 'pendente' AND kind IN ('confirmacao', 'lembrete')
    """
  end

  def down, do: execute("DROP INDEX CONCURRENTLY IF EXISTS messages_uma_pendente_por_presenca")
end
