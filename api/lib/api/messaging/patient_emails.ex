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

  ## Não há `Reply-To`: a resposta do paciente cai no `nao-responda@`

  Decisão de 2026-08-03 (doc 101, M12). Havia um `maybe_reply_to/2` que lia
  `message.vars["clinica_email"]` — chave que `Api.Messaging.Dispatch.vars/3` **nunca** preencheu,
  em nenhum caminho. `grep` no repositório inteiro devolvia uma ocorrência: a própria linha que a
  lia. Ou seja, o comportamento anunciado aqui nunca aconteceu uma vez sequer, e o parágrafo que
  descrevia esta seção descrevia código morto.

  Mantido o padrão: o canal de volta do paciente é o **link** de confirmação (§5) e a resposta de
  WhatsApp, que têm rastro na timeline e opt-out. E-mail respondido para a caixa da clínica não
  teria nenhum dos dois — chegaria fora do sistema, sem trilha e sem quem o tratasse.

  ## `List-Unsubscribe`, sem `One-Click`

  O cabeçalho vai em toda mensagem: é ele que faz o Gmail e o Apple Mail mostrarem o botão nativo
  de descadastro, ao lado do remetente — o lugar onde a pessoa procura antes de procurar o botão
  de spam. Ele aponta para a mesma página do rodapé (`Api.Messaging.OptOutToken`).

  **Sem `List-Unsubscribe-Post`** (o descadastro em um clique, executado pelo provedor). Ele é
  exigência para remetente de marketing em volume, que não é o nosso caso, e o preço dele aqui
  seria abrir uma rota de escrita que qualquer um pode chamar com um token encaminhado — sem a
  página de confirmação que hoje separa "eu quis sair" de "um scanner abriu meu e-mail".
  """
  import Swoosh.Email

  alias Api.Messaging.OptOutToken

  @default_remetente {"Cinetra", "nao-responda@cinetra.local"}

  @doc """
  Monta e entrega o e-mail de uma `Message` já renderizada.

  Devolve `{:ok, "resend", id}` ou `{:error, texto}` — o contrato de `Api.Messaging.Transport`.
  O `id` do provider é o que o webhook usa depois para achar a linha; adapters que não devolvem
  id (o `Local` do dev, o `Test` da suíte) rendem `nil`, e a mensagem simplesmente não recebe
  eventos de entrega. É o comportamento certo: em dev não há webhook.
  """
  def entregar(%{id: id, destino: destino}, %{assunto: assunto, texto: texto, html: html}) do
    new()
    |> to(destino)
    |> from(remetente())
    |> subject(assunto)
    |> text_body(texto)
    |> html_body(html)
    |> header("List-Unsubscribe", "<#{OptOutToken.url(id)}>")
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

  defp remetente, do: Application.get_env(:api, __MODULE__, [])[:remetente] || @default_remetente
end
