defmodule Api.Messaging.PatientEmails do
  @moduledoc """
  O e-mail que vai para o **paciente** (doc 52 §8).

  Separado de `Api.Accounts.Emails` de propósito, e não é organização: aquele módulo tem uma régua
  explícita ("são dois, e a régua para um terceiro é alta") porque e-mail por evento de agenda
  vira spam em uma semana — a decisão do doc 31 §5. Isto aqui é o **outro plano**: destinatário
  sem login, com consentimento, opt-out e rastro de entrega. Misturar os dois faria a régua
  daquele módulo parecer abandonada quando ela continua valendo para o que ela cobre.

  ## Remetente

  Vem do config (`:remetente`), não de constante: o domínio de envio muda quando o DNS do Resend
  é verificado, e isso é configuração de ambiente. Enquanto não houver domínio verificado, o
  default aponta para o mesmo placeholder de dev do resto do projeto — e-mail sai na caixa
  `/dev/mailbox` e ninguém tenta entregar de verdade.

  ## `Reply-To` aponta para a clínica, quando ela tem e-mail

  O paciente **vai** responder o e-mail, mesmo com o link de confirmação ali (§5). Sem
  `Reply-To`, essa resposta cai num endereço que ninguém lê. Com ele, cai na clínica — que é para
  onde a pessoa acha que está escrevendo.
  """
  import Swoosh.Email

  @default_remetente {"Cinetra", "nao-responda@movimento.local"}

  @doc """
  Monta e entrega o e-mail de uma `Message` já renderizada.

  Devolve `{:ok, "resend", id}` ou `{:error, texto}` — o contrato de `Api.Messaging.Transport`.
  O `id` do provider é o que o webhook usa depois para achar a linha; adapters que não devolvem
  id (o `Local` do dev, o `Test` da suíte) rendem `nil`, e a mensagem simplesmente não recebe
  eventos de entrega. É o comportamento certo: em dev não há webhook.
  """
  def entregar(%{destino: destino} = message, %{assunto: assunto, texto: texto}) do
    new()
    |> to(destino)
    |> from(remetente())
    |> maybe_reply_to(message)
    |> subject(assunto)
    |> text_body(texto)
    |> Api.Mailer.deliver()
    |> traduzir()
  end

  defp traduzir({:ok, resposta}), do: {:ok, "resend", id_do_provider(resposta)}

  # A mensagem de erro vai para a coluna `erro` e daí para a tela da recepção. Struct de exceção
  # inspecionada ali seria ilegível — e é exatamente o que o `inspect/1` de um `%Swoosh.Error{}`
  # produziria.
  defp traduzir({:error, {_status, %{"message" => mensagem}}}) when is_binary(mensagem),
    do: {:error, mensagem}

  defp traduzir({:error, {_status, corpo}}), do: {:error, resumir(corpo)}
  defp traduzir({:error, motivo}), do: {:error, resumir(motivo)}

  defp resumir(termo) when is_binary(termo), do: termo
  defp resumir(termo), do: termo |> inspect() |> String.slice(0, 300)

  # O Resend devolve `%{id: "..."}`; adapters locais devolvem mapa vazio ou outra forma.
  defp id_do_provider(%{id: id}) when is_binary(id), do: id
  defp id_do_provider(%{"id" => id}) when is_binary(id), do: id
  defp id_do_provider(_resposta), do: nil

  defp maybe_reply_to(email, %{vars: %{"clinica_email" => endereco}})
       when is_binary(endereco) and endereco != "",
       do: reply_to(email, endereco)

  defp maybe_reply_to(email, _message), do: email

  defp remetente, do: Application.get_env(:api, __MODULE__, [])[:remetente] || @default_remetente
end
