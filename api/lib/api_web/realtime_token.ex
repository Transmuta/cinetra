defmodule ApiWeb.RealtimeToken do
  @moduledoc """
  O token efêmero do WebSocket (09 §8, ADR-014). Fonte única do salt e da validade: eles
  nasceram no `AuthController` (quem **assina**) e o `UserSocket` (quem **verifica**) precisa
  dos mesmos valores — duplicá-los faria a verificação passar a recusar todo token no dia em
  que um dos dois mudasse, com erro de "token inválido" que não aponta para a causa.

  É o único token que vai ao browser; o resto da autenticação é cookie de sessão. Vida curta
  (15 min) porque ele viaja na query string do WebSocket, que vaza para log de proxy mais
  facilmente que um header.

  O escopo do token é `user_id` + `clinic_id`: o `join` do canal usa o `clinic_id` para
  recusar tópico de outra clínica. Ele **não** carrega papel — quem é o papel é relido do
  `Membership` no join, porque o vínculo pode ter sido revogado depois da emissão.
  """
  @salt "realtime socket"
  @max_age 900

  @doc "Validade do token, em segundos. O cliente renova antes disso."
  def max_age, do: @max_age

  @doc """
  Assina o token para um par usuário/clínica.

  `opts` é repassado a `Phoenix.Token.sign/4` — o teste usa `:signed_at` para produzir um
  token vencido sem esperar 15 minutos.
  """
  def sign(%{user_id: user_id, clinic_id: clinic_id}, opts \\ [])
      when is_binary(user_id) and is_binary(clinic_id) do
    Phoenix.Token.sign(ApiWeb.Endpoint, @salt, %{user_id: user_id, clinic_id: clinic_id}, opts)
  end

  @doc "Verifica e devolve `{:ok, %{user_id:, clinic_id:}}` ou `{:error, motivo}`."
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(ApiWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :missing}
end
