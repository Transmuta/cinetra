defmodule Api.Housekeeping.PruneNotifications do
  @moduledoc """
  Poda a caixa de notificações in-app (#54, P3 do doc 32 — "lista sem LIMIT **e tabela sem
  expurgo**"). O LIMIT foi resolvido pela paginação da `:inbox`; o expurgo é este job.

  ## A retenção é assimétrica, e isso é o ponto

    * **lida** — #{Application.compile_env(:api, [__MODULE__, :reter_lidas_dias], 90)} dias. Já
      cumpriu o papel: o usuário viu. O que sobra é histórico do sino, não registro de auditoria
      (esse é a trilha, e tem poda própria em `Api.Housekeeping.PruneTrail`);
    * **não-lida** — #{Application.compile_env(:api, [__MODULE__, :reter_dias], 365)} dias. Uma
      não-lida é trabalho pendente; apagá-la na janela curta seria sumir com um aviso que ninguém
      leu. O teto existe só para que a caixa **abandonada** (usuário que nunca mais entrou)
      também não cresça para sempre.

  Os dois números são decisão humana e moram na config:

      config :api, Api.Housekeeping.PruneNotifications, reter_lidas_dias: 90, reter_dias: 365

  O job aceita `%{"reter_lidas_dias" => n, "reter_dias" => n}` para uma poda pontual (é o que o
  teste usa com `0`).

  ## Como respeita a RLS

  Igual à poda da trilha, e pelo mesmo motivo: varredura **por clínica** dentro de
  `Api.Repo.with_clinic/2`. O mecanismo (lote, `ctid`, GUC) está em `Api.Housekeeping.Poda` —
  esta é a segunda poda do projeto, e ter duas cópias da mesma sutileza é como uma delas
  envelhece errado.

  ## O `AND inserted_at < $4` é redundante de propósito (doc 92, P1-1)

  Logicamente ele não muda nada: quem casa em qualquer um dos dois ramos do `OR` já é mais velho
  que o mais frouxo dos dois cortes. Para o **planejador**, ele é tudo. Sem esse conjunto, o `OR`
  entre dois cortes de `inserted_at` diferentes impede derivar um limite único para a coluna, o
  `Index Cond` fica só com `clinic_id` e a poda varre a caixa inteira da clínica — na tabela que
  este job existe para conter.

  Medido em 40.001 linhas (38.000 recentes + cauda de 2.000 velhas; alvo de 1.466):

      hoje                          Seq Scan      618 buffers   11,55 ms
      com o corte frouxo            Bitmap Scan    73 buffers    2,88 ms

  ## Por que NÃO há índice novo

  O item original propunha, junto, um `(clinic_id, inserted_at)`. Medido no mesmo cenário, ele
  leva de 73 para 37 buffers e de 2,88 para 2,26 ms — **um ganho marginal sobre a reescrita**, em
  troca de um índice a mais para manter em toda escrita de `notifications`, que é a tabela de
  fan-out do projeto (uma linha por destinatário, a cada evento). A poda roda uma vez por dia; a
  escrita, o dia inteiro. O índice existente (`notifications_inbox_index`) já atende.

  Se um dia a poda voltar a doer, o índice está medido e é uma migration de duas linhas — mas
  entra com número novo em mãos, não por suposição (a lição D-A do doc 35).
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Housekeeping.Poda

  @tabela "notifications"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    corte_lidas = corte_lidas(args)
    corte_geral = corte_geral(args)

    apagadas =
      Poda.por_clinica(fn clinic_id ->
        Poda.em_lote(
          @tabela,
          condicao(),
          [Ecto.UUID.dump!(clinic_id), corte_lidas, corte_geral, corte_frouxo(args)],
          clinic_id
        )
      end)

    if apagadas > 0 do
      Logger.info(
        "PruneNotifications: #{apagadas} notificações apagadas " <>
          "(lidas antes de #{NaiveDateTime.to_iso8601(corte_lidas)}, " <>
          "não-lidas antes de #{NaiveDateTime.to_iso8601(corte_geral)})"
      )
    end

    {:ok, %{apagadas: apagadas}}
  end

  @doc """
  O `WHERE` da poda (`$1` = clínica, `$2` = corte das lidas, `$3` = corte geral).

  Exposto pelo mesmo motivo dos cortes abaixo — diagnóstico —, e porque o teste de plano precisa
  medir **este** SQL, não uma cópia dele que envelheceria sozinha.
  """
  @spec condicao() :: String.t()
  def condicao do
    """
    clinic_id = $1
    AND inserted_at < $4
    AND (
      (read_at IS NOT NULL AND inserted_at < $2)
      OR (read_at IS NULL AND inserted_at < $3)
    )
    """
  end

  @doc "O corte das lidas que o job usaria agora — exposto para o doc e para diagnóstico."
  def corte_lidas(args \\ %{}),
    do:
      Poda.corte(args, "reter_lidas_dias",
        modulo: __MODULE__,
        chave: :reter_lidas_dias,
        padrao: 90
      )

  @doc "O corte das não-lidas (o teto absoluto da caixa)."
  def corte_geral(args \\ %{}),
    do: Poda.corte(args, "reter_dias", modulo: __MODULE__, chave: :reter_dias, padrao: 365)

  @doc """
  O corte **frouxo** — o mais recente dos dois —, que existe só para o planejador.

  É `max/2` e não `corte_lidas/1` de propósito. Com a config invertida (reter lida por mais tempo
  que não-lida — esquisito, mas aceito hoje), o corte das lidas passa a ser o mais **antigo** dos
  dois, e fixá-lo aqui excluiria do `DELETE` as não-lidas da faixa entre um corte e outro: a poda
  deixaria de apagar linha que devia apagar, sem erro nenhum. Há teste para esse caso.
  """
  @spec corte_frouxo(map()) :: NaiveDateTime.t()
  def corte_frouxo(args \\ %{}) do
    Enum.max([corte_lidas(args), corte_geral(args)], NaiveDateTime)
  end
end
