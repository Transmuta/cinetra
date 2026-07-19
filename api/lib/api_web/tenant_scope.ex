defmodule ApiWeb.TenantScope do
  @moduledoc """
  Guardas de escopo e escada de erros compartilhadas pelos controllers de gestão da clínica
  (Horário, Exceções — e o que vier). Extrai o que `MembersController`/`AppointmentTypesController`
  faziam em cópias privadas: resolver o `Api.Scope` da sessão, aplicar o RBAC (leitura para
  todo membro, escrita só owner/admin) e traduzir os erros do Ash na escada 401/403/404/422.

  O `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Api.Scope

  @doc "Escrita: exige owner/admin de uma clínica ativa. Senão 403 (membro) / 401 (sem sessão)."
  def with_admin_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid, papel: papel} = scope
      when not is_nil(cid) and papel in [:owner, :admin] ->
        fun.(scope)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc """
  Agenda (A8): `owner`·`admin`·`recepcao`·`profissional` de uma clínica ativa.

  Nem `with_admin_scope` (exclui recepção, que é justamente quem agenda) nem
  `with_member_scope` (aceita qualquer papel) servem — daí a terceira guarda. O recorte
  *dentro* do papel `profissional` ("só a própria agenda", A7) não é feito aqui e sim na
  preparation `OwnAgendaOnly`, porque é sobre **linhas**, não sobre permissão de entrar.
  """
  def with_scheduling_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid, papel: papel} = scope
      when not is_nil(cid) and papel in [:owner, :admin, :recepcao, :profissional] ->
        fun.(scope)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc "Leitura: qualquer membro de uma clínica ativa, independentemente do papel."
  def with_member_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid} = scope when not is_nil(cid) ->
        fun.(scope)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc "Traduz um erro do Ash na resposta HTTP (403 · 404 · 422 · 400)."
  def error_response(conn, %Ash.Error.Forbidden{}), do: forbidden(conn)

  def error_response(conn, %Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        not_found(conn)

      true ->
        unprocessable(conn, error_messages(error))
    end
  end

  def error_response(conn, _error),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  def not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  @doc """
  409 — **novo nesta fatia**. A regra semântica é a de `09:659`: **422 = "seu pedido está
  errado"; 409 = "seu pedido estava certo, o mundo mudou"**. Reservado a concorrência
  (`version_conflict` na Entrega 4, `slot_held` na 5) — conflito de horário é 422, porque o
  pedido *está* errado no momento em que chega.
  """
  def conflict(conn, code, message) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "conflict", code: code, details: [%{field: nil, message: message}]})
  end

  # 422 com `code` estável no topo (A10). Dois casos precisam de tratamento especial, e os
  # dois são "o campo certo é NENHUM campo":
  #
  #   * conflito de horário — o Ecto exige uma chave para a exclusion constraint e escolhemos
  #     `starts_at`, mas pintar esse input de vermelho **mente**: o horário digitado está
  #     certo, o mundo é que está ocupado. Vira `field: null` + `schedule_conflict`.
  #   * expediente — `CheckAvailability` já emite `field: nil` e manda o código em `vars`.
  defp unprocessable(conn, details) do
    {code, details} = extract_code(details)

    body =
      %{error: "invalid", details: details}
      |> then(fn body -> if code, do: Map.put(body, :code, code), else: body end)

    conn |> put_status(:unprocessable_entity) |> json(body)
  end

  defp extract_code(details) do
    conflict_message = Api.Scheduling.Appointment.schedule_conflict_message()

    Enum.map_reduce(details, nil, fn detail, code ->
      cond do
        detail.message == conflict_message ->
          {%{detail | field: nil}, code || "schedule_conflict"}

        detail[:code] ->
          {Map.delete(detail, :code), code || detail[:code]}

        true ->
          {detail, code}
      end
    end)
    |> then(fn {details, code} -> {code, details} end)
  end

  @doc "401 padrão da fronteira (sem sessão). Fonte única do corpo, reusada fora das guardas."
  def unauthorized(conn),
    do: conn |> put_status(:unauthorized) |> json(%{error: "unauthenticated"})

  @doc """
  Recorta `params` (chaves string, do corpo) aos `fields` permitidos, devolvendo um mapa de
  chaves atom. É a whitelist no espírito do `@papeis` do MembersController: `clinic_id` e
  qualquer chave fora da lista são simplesmente ignorados — o tenant vem do escopo (09 §8).

  O teste é `Map.has_key?`, não truthiness: `capacidade: null` é instrução legítima de limpar,
  e campo ausente do corpo simplesmente não é tocado (update parcial).
  """
  def whitelist(params, fields) when is_map(params) and is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      key = Atom.to_string(field)
      if Map.has_key?(params, key), do: Map.put(acc, field, params[key]), else: acc
    end)
  end

  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

  defp error_messages(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      detail = %{field: error_field(err), message: error_message(err)}

      # `code` viaja em `vars` (é como uma validação de recurso nomeia o erro sem conhecer
      # HTTP). `unprocessable/2` o promove ao topo do corpo e o remove daqui.
      case error_code(err) do
        nil -> detail
        code -> Map.put(detail, :code, code)
      end
    end)
  end

  defp error_messages(_), do: []

  # `Exception.message/1` de um erro Ash devolve texto de **depuração**:
  #
  #     "Bread Crumbs:\n  > Error returned from: Api.Scheduling.Appointment.schedule\n\n\n
  #      Esse horário está fora do expediente (08:00–12:00, 13:00–18:00)."
  #
  # Isso chegava à tela — a recepção lia "Bread Crumbs" no aviso do formulário. O campo
  # `:message` do erro é a mensagem limpa; o `Exception.message/1` fica de fallback, já sem
  # os rastros (eles vêm antes do último parágrafo em branco).
  defp error_message(err) do
    case Map.get(err, :message) do
      message when is_binary(message) and message != "" ->
        interpolate(message, error_vars(err))

      _ ->
        err |> Exception.message() |> strip_bread_crumbs()
    end
  end

  defp strip_bread_crumbs(message) do
    case String.split(message, "\n\n") do
      [_ | _] = parts -> parts |> List.last() |> String.trim()
      _ -> message
    end
  end

  # Mensagens do Ash podem trazer placeholders `%{campo}` resolvidos por `vars`. Só valores
  # escalares entram: `vars` carrega listas e mapas (o próprio `vars` aninhado, por exemplo),
  # e `to_string/1` numa keyword list estoura `ArgumentError`.
  defp interpolate(message, vars) do
    Enum.reduce(vars, message, fn {key, value}, acc ->
      if scalar?(value),
        do: String.replace(acc, "%{#{key}}", to_string(value)),
        else: acc
    end)
  end

  defp scalar?(value) when is_binary(value) or is_number(value) or is_atom(value), do: true
  defp scalar?(_), do: false

  # `Ash.Changeset.add_error/2` com keyword list aninha o que foi passado, então o `vars` do
  # chamador pode chegar como `[vars: [code: ...]]`. Aceitamos as duas formas.
  defp error_vars(err) do
    vars = err |> Map.get(:vars, []) |> List.wrap()

    case Keyword.get(vars, :vars) do
      nested when is_list(nested) -> vars |> Keyword.delete(:vars) |> Keyword.merge(nested)
      _ -> vars
    end
  end

  defp error_code(err) do
    case err |> error_vars() |> Keyword.get(:code) do
      code when is_binary(code) -> code
      _ -> nil
    end
  end

  # O Ash reporta o campo em `:field` (`InvalidAttribute`) OU em `:fields` (`InvalidChanges` —
  # é o caso da identity duplicada). Sem este fallback o 422 chegaria com `field: null` e o
  # form não saberia qual input marcar.
  defp error_field(err) do
    case Map.get(err, :field) do
      nil -> err |> Map.get(:fields) |> List.wrap() |> List.first()
      field -> field
    end
  end
end
