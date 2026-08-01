defmodule ApiWeb.PatientReplyController do
  @moduledoc """
  A resposta do paciente (doc 52 §5) — a **única** rota do projeto que fala com quem não tem
  sessão e não é autenticação.

  ## O que autoriza a chamada

  O token assinado, e só ele (`Api.Messaging.ReplyToken`). Ele identifica uma mensagem; tudo o
  mais — paciente, sessão, clínica — é relido do banco a partir dela. Um token vazado permite
  responder por alguém: não ler ficha, não ver agenda, não entrar no sistema.

  ## Por que devolve tão pouco

  O `show` responde só o suficiente para a página dizer de qual sessão se trata: clínica, data,
  hora e primeiro nome. **Não** devolve a ficha, nem os outros participantes de uma turma, nem
  telefone ou e-mail. Quem abre esta página é quem tem o link — e o link pode ter sido
  encaminhado.

  ## `quer_remarcar` não remarca — mas **avisa**

  Registra o pedido; a recepção resolve. Remarcar sozinho exigiria escolher horário pela pessoa,
  e a agenda tem regras (expediente, conflito, encaixe) que um clique de fora não conhece.

  O que faltava era o outro lado disso: até o doc 65, um paciente que pedia remarcação só era
  descoberto por quem abrisse o drawer daquela sessão específica. O pedido agora cai na caixa do
  operacional (`Api.Notifications.Fanout.patient_wants_reschedule/1`) — é a única notificação do
  sistema cujo autor não tem login.

  `confirmou` **não** notifica, e isso é decisão de produto (doc 31 §4): uma linha por sessão
  confirmada afogaria a caixa da recepção numa clínica com milhares de presenças por mês.

  A justificativa escrita aqui era *"a confirmação já aparece no status do bloco"* — e **não
  aparecia**. Nada no projeto escreve `:confirmado` (não há ação `:confirm` em `Appointment`, o
  `statusActions` só oferece "Cancelar", e o rollup apenas *preserva* a fase); o status existe no
  enum e nunca é alcançado. Na prática a resposta só era legível abrindo o drawer daquela sessão,
  um bloco por vez — o mesmo buraco que o `quer_remarcar` tinha antes de cair na caixa.

  Hoje ela aparece **no cartão da agenda**, como estrela, pelo agregado
  `Api.Scheduling.Attendance.resposta_do_paciente`. Por participante, não no bloco: numa turma de
  quatro, "confirmou" no bloco seria falso para os outros três.

  O que continua faltando é o **tempo real**: esta rota não emite evento de agenda, então a estrela
  entra na próxima leitura da tela, não no instante do clique do paciente.
  """
  use ApiWeb, :controller

  require Logger

  alias Api.Messaging
  alias Api.Messaging.ReplyToken

  # GET /api/reply/:token
  def show(conn, %{"token" => token}) do
    case carregar(token) do
      {:ok, message} -> json(conn, resumo(message))
      {:error, motivo} -> recusar(conn, motivo)
    end
  end

  # POST /api/reply/:token
  def create(conn, %{"token" => token} = params) do
    with {:ok, message} <- carregar(token),
         {:ok, resposta} <- ler_resposta(params["resposta"]) do
      atualizada = gravar(message, resposta)

      # **As duas**: a lida e a atualizada. É a `atualizada` que carrega a resposta recém-gravada
      # (passar só a original faria o aviso nunca disparar), e é a **diferença** entre elas que
      # decide se avisa — ver `avisar_a_recepcao/2` e o replay que ela existe para barrar.
      avisar_a_recepcao(message, atualizada)
      json(conn, resumo(atualizada))
    else
      {:error, motivo} -> recusar(conn, motivo)
    end
  end

  # Sem `with_clinic/2` (doc 96, B-11): `:record_reply` carrega `SetTenantGuc`. A transação de fora
  # não punha tenancy nenhuma — e o `|> elem(1)` que ela obrigava era uma das cópias do desembrulho
  # que o doc 96 lista em R-4, com o agravante de que `elem(1)` sobre `{:error, motivo}` devolve o
  # motivo cru como se fosse o registro.
  defp gravar(message, resposta) do
    Messaging.do_record_reply!(message, %{resposta: resposta},
      tenant: message.clinic_id,
      authorize?: false
    )
  end

  # Avisa a recepção **na transição**, não em toda chamada — e essa distinção é de segurança,
  # não de bom gosto.
  #
  # Esta rota é **pública, sem sessão e sem rate limit**, e a resposta em si sempre foi idempotente
  # (o instante da primeira é preservado). O fan-out entrou por cima dela sem essa propriedade, e o
  # bate-volta mediu o efeito: 5 POSTs do mesmo token → **10 notificações** (2 destinatários × 5).
  # Quem tem o link — que se encaminha — enchia a caixa da clínica à vontade.
  #
  # Comparar o antes com o depois é o que devolve a idempotência ao conjunto. Não é "avisar uma vez
  # só": quem confirmou e depois pediu remarcação **mudou de ideia**, e essa transição avisa de
  # novo, porque a recepção precisa saber.
  #
  # **Fora do `with_clinic` de propósito**: o fan-out grava na caixa de N pessoas e faz broadcast,
  # e fazê-lo de dentro da transação da resposta significaria (a) notificação emitida antes do
  # commit — a mesma armadilha que fez o `Api.Notifications.Notifier` existir — e (b) a transação
  # do paciente aberta pelo tempo de escrever a caixa de todo mundo.
  #
  # Best-effort e sem alterar a resposta HTTP: quem clicou no link não pode ver "erro" porque a
  # caixa da recepção falhou. O pedido dele já está gravado, que é o fato que importa.
  defp avisar_a_recepcao(%{resposta: anterior}, %{resposta: :quer_remarcar} = atualizada)
       when anterior != :quer_remarcar do
    Api.Notifications.Fanout.patient_wants_reschedule(atualizada)
  rescue
    erro ->
      Logger.warning("aviso de remarcação falhou (#{atualizada.id}): #{Exception.message(erro)}")
      :ok
  end

  defp avisar_a_recepcao(_antes, _depois), do: :ok

  # O token resolve a mensagem, e a mensagem resolve o tenant — o mesmo desenho do webhook
  # (§10.2), e **pelo mesmo motivo**: aqui não há sessão nem clínica conhecida.
  #
  # O `with_message/2` não é opcional. Sem ele a leitura roda sem GUC, a policy de `messages`
  # compara `clinic_id = NULL` e não casa linha nenhuma: todo link legítimo respondia
  # "link inválido" no servidor real, com os testes desta rota verdes (o sandbox conecta como
  # `postgres`, que bypassa RLS). Foi assim que ela nasceu, e foi o bate-volta ao vivo que pegou.
  defp carregar(token) do
    with {:ok, message_id} <- ReplyToken.verify(token),
         {:ok, {:ok, %{} = message}} <-
           Api.Repo.with_message(message_id, fn ->
             Messaging.get_message(message_id, authorize?: false, not_found_error?: false)
           end) do
      {:ok, message}
    else
      {:error, motivo} when is_atom(motivo) -> {:error, motivo}
      _ -> {:error, :invalid}
    end
  end

  defp ler_resposta("confirmou"), do: {:ok, :confirmou}
  defp ler_resposta("quer_remarcar"), do: {:ok, :quer_remarcar}
  defp ler_resposta(_outra), do: {:error, :resposta_invalida}

  defp resumo(message) do
    %{
      clinica: message.vars["clinica"],
      paciente: primeiro_nome(message.vars["paciente"]),
      data: message.vars["data"],
      hora: message.vars["hora"],
      resposta: message.resposta,
      respondido_em: message.respondido_em
    }
  end

  defp primeiro_nome(nil), do: nil
  defp primeiro_nome(nome), do: nome |> String.split(" ", parts: 2) |> hd()

  # Um motivo só na resposta ao cliente ("expirado" × "inválido"): a página precisa dizer "este
  # link expirou", que é acionável, em vez de um erro técnico. Não vira oráculo porque nenhum dos
  # dois revela se a mensagem existe.
  defp recusar(conn, :expired),
    do: conn |> put_status(:gone) |> json(%{error: "link_expirado"})

  defp recusar(conn, :resposta_invalida),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "resposta_invalida"})

  defp recusar(conn, _motivo),
    do: conn |> put_status(:not_found) |> json(%{error: "link_invalido"})
end
