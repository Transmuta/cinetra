defmodule ApiWeb.ClinicController do
  @moduledoc """
  Onboarding do primeiro acesso: cria a clínica e torna o usuário atual o `owner` dela,
  na mesma transação (ação `:onboard`, ADR-016). É a única porta HTTP que faz nascer um
  tenant. Qualquer usuário autenticado pode criar (política `actor_present()`); QUEM vê o
  onboarding — só quem ainda não tem clínica — é decisão do BFF, não deste controller.

  O ator vem sempre do escopo da sessão (nunca do corpo, 09 §8). O `onboard` é um create
  que NÃO exige tenant — ele o cria —, então o escopo sem `clinic_id` (estado "sem clínica")
  é o esperado aqui.
  """
  use ApiWeb, :controller

  alias Api.Accounts
  alias Api.Scope

  # POST /api/clinics {nome} — cria a clínica + o Membership `owner` do usuário atual.
  def onboard(conn, params) do
    case conn.assigns[:scope] do
      %Scope{user: %{}} = scope ->
        case Accounts.onboard_clinic(params["nome"], %{}, scope: scope) do
          {:ok, clinic} ->
            conn |> put_status(:created) |> json(%{clinic: clinic_json(clinic)})

          {:error, error} ->
            error_response(conn, error)
        end

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthenticated"})
    end
  end

  defp clinic_json(clinic), do: %{id: clinic.id, nome: clinic.nome}

  # Com ator presente (o controller garante) e política `actor_present()`, o onboard não é
  # negado: a única falha esperada é validação (nome vazio/ausente → 422). O catch-all cobre
  # o inesperado sem vazar detalhe.
  defp error_response(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid", details: error_messages(error)})
  end

  defp error_response(conn, _error),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  defp error_messages(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{field: Map.get(err, :field), message: Exception.message(err)}
    end)
  end

  defp error_messages(_), do: []
end
