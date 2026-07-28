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

  ## `quer_remarcar` não remarca

  Registra o pedido; a recepção resolve. Remarcar sozinho exigiria escolher horário pela pessoa,
  e a agenda tem regras (expediente, conflito, encaixe) que um clique de fora não conhece.
  """
  use ApiWeb, :controller

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
      json(conn, resumo(atualizada))
    else
      {:error, motivo} -> recusar(conn, motivo)
    end
  end

  defp gravar(message, resposta) do
    Api.Repo.with_clinic(message.clinic_id, fn ->
      Messaging.do_record_reply!(message, %{resposta: resposta},
        tenant: message.clinic_id,
        authorize?: false
      )
    end)
    |> elem(1)
  end

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
      respondidoEm: message.respondido_em
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
