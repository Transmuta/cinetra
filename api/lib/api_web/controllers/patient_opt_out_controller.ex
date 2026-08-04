defmodule ApiWeb.PatientOptOutController do
  @moduledoc """
  O descadastro do paciente pelo link do rodapé (doc 52 §10) — a segunda rota do projeto que fala
  com quem não tem sessão e não é autenticação, irmã de `ApiWeb.PatientReplyController`.

  ## Por que o link, se já existe o "SAIR" do WhatsApp

  Porque o e-mail não tem palavra-chave: ele sai de `nao-responda@` e ninguém lê a resposta
  (`Api.Messaging.PatientEmails`). Sem link, quem não quer mais receber tem uma saída só — o
  botão de spam do próprio cliente. Ele funciona (o webhook `complained` do Resend registra o
  opt-out), e é o pior caminho possível: leva junto a reputação do domínio de envio, que é
  compartilhada por todas as clínicas.

  ## O descadastro nasce **global** — e a tentativa de fazê-lo por-clínica foi medida

  O desenho óbvio seria gravá-lo com o `clinic_id` da mensagem: diferente do "SAIR" do WhatsApp
  (que nasce global porque o número da v1 é único e a frase do paciente não diz de qual clínica
  ele fala — C10/C11), aqui **se sabe** de qual clínica veio o e-mail. Foi assim que esta rota
  nasceu, e o `Api.Messaging.OptOut` previa exatamente isso ("preenchido = daquela clínica").

  Não dá, ainda, e o motivo não é de gosto — foi medido no `psql` sob o role `cinetra_app`
  (2026-08-03), porque a suíte roda como `postgres` e é cega para isto:

      -- a MESMA linha por-clínica, lida com e sem a GUC de tenant
      com GUC : 1
      sem GUC : 0

  A policy de RLS da tabela é `clinic_id IS NULL OR clinic_id = <GUC>`. Quem lê o opt-out é
  `Api.Messaging.opted_out?/3`, chamada por `Api.Messaging.Dispatch` **fora** do `in_clinic` — de
  propósito, e documentado lá: o outro chamador do módulo é o webhook, que não tem GUC nenhuma.
  Resultado: uma linha por-clínica seria **gravada e nunca vista**. O paciente clicaria em "parar
  de receber", a lista registraria, e o envio seguinte sairia assim mesmo — o exato dano que o §10
  existe para impedir, com a tela mostrando "descadastrado" o tempo todo.

  Global não tem esse modo de falha: a policy aceita `clinic_id IS NULL` com ou sem GUC, e a
  leitura enxerga a linha de qualquer lugar. O preço é silenciar também as outras clínicas do
  mesmo contato — que é o comportamento que o "SAIR" do WhatsApp já tem hoje, e que se desfaz no
  balcão (`Api.Messaging.revoke_patient_opt_outs/2`), com nome e hora.

  Ligar o por-clínica é um débito, não um esquecimento: exige que a leitura passe a rodar com a
  GUC do tenant quando há clínica. Ver `docs/50-debitos-tecnicos.md`.

  ## O GET não descadastra

  Só o POST. Ver `Api.Messaging.OptOutToken` — scanner de antivírus e pré-visualização de webmail
  abrem todo link do e-mail, e um efeito no GET produziria descadastro que o paciente nunca pediu,
  com sintoma meses depois ("a clínica parou de me avisar").
  """
  use ApiWeb, :controller

  alias Api.Messaging
  alias Api.Messaging.OptOutToken

  # GET /api/opt-out/:token
  def show(conn, %{"token" => token}) do
    case carregar(token) do
      {:ok, message} -> json(conn, resumo(message))
      {:error, motivo} -> recusar(conn, motivo)
    end
  end

  # POST /api/opt-out/:token
  def create(conn, %{"token" => token}) do
    case carregar(token) do
      {:ok, message} ->
        registrar(message)
        json(conn, %{resumo(message) | descadastrado: true})

      {:error, motivo} ->
        recusar(conn, motivo)
    end
  end

  # Idempotente pelo banco, não por um `if` daqui: a ação `:registrar` é upsert sobre a identity
  # dos vigentes (doc 96, A-5). Dois cliques no botão, ou o clique somado ao `complained` do
  # Resend, resolvem-se no `ON CONFLICT` — e o instante que fica gravado é o do primeiro pedido.
  #
  # Sem `clinic_id` — global. Ver o moduledoc: a linha por-clínica é invisível para a leitura que
  # decide o envio, e um opt-out que não barra nada é pior que nenhum.
  defp registrar(message) do
    Messaging.opt_out(message.canal, message.destino, "link",
      motivo: "descadastro pelo link da mensagem"
    )
  end

  # O mesmo desenho do `PatientReplyController`: o token resolve a mensagem, e a mensagem resolve
  # o tenant. Sem `with_message/2` a leitura roda sem GUC e a RLS de `messages` não casa linha
  # nenhuma — todo link legítimo responderia "inválido" no servidor real, com a suíte verde.
  defp carregar(token) do
    with {:ok, message_id} <- OptOutToken.verify(token),
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

  # Devolve o mínimo para a página escrever uma frase verdadeira: de qual clínica se trata e se o
  # pedido já estava registrado. **Não** devolve o destino — o link pode ter sido encaminhado, e
  # o endereço de alguém não precisa aparecer para quem abriu a URL.
  defp resumo(message) do
    %{
      clinica: message.vars["clinica"],
      canal: message.canal,
      descadastrado: Messaging.opted_out?(message.canal, message.destino, message.clinic_id)
    }
  end

  # "Expirado" e "inválido" continuam separados pelo motivo do irmão: a página precisa dizer algo
  # acionável. Nenhum dos dois revela se a mensagem existe.
  defp recusar(conn, :expired),
    do: conn |> put_status(:gone) |> json(%{error: "link_expirado"})

  defp recusar(conn, _motivo),
    do: conn |> put_status(:not_found) |> json(%{error: "link_invalido"})
end
