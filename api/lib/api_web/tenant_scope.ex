defmodule ApiWeb.TenantScope do
  @moduledoc """
  Guardas de escopo e escada de erros compartilhadas pelos controllers de gestão da clínica
  (Horário, Exceções — e o que vier). Extrai o que `MembersController`/`AppointmentTypesController`
  faziam em cópias privadas: resolver o `Api.Scope` da sessão, aplicar o RBAC (leitura para
  todo membro, escrita só owner/admin) e traduzir os erros do Ash na escada 401/403/404/422.

  O `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8).
  """
  import Plug.Conn

  # Teto de janela de datas (doc 25 §5): sem ele, `?from=2000-01-01&to=2100-01-01` varre a
  # tabela. Mora aqui, e não em cada controller, porque é a mesma regra de fronteira para
  # qualquer endpoint que aceite intervalo — hoje agenda e disponibilidade.
  @max_dias 31

  import Phoenix.Controller, only: [json: 2]

  alias Api.Scope

  @doc "Escrita: exige owner/admin de uma clínica ativa. Senão 403 (membro) / 401 (sem sessão)."
  def with_admin_scope(conn, fun), do: with_roles_scope(conn, [:owner, :admin], fun)

  @doc """
  Exige que o papel do membro esteja em `roles`. 403 para membro fora da lista, 401 sem sessão.

  A generalização de `with_admin_scope/2`, que virou um caso dela. Nasceu com os anexos (doc 51):
  o acesso ali é **owner·admin·recepção** — nem "todo membro" nem "só quem escreve o cadastro" —,
  e sem esta guarda o `profissional` chegaria à policy do recurso e receberia um
  `Ash.Error.Forbidden` no meio de um `list!`, virando 500 em vez de 403.

  `roles` vem de quem chama (ex.: `Api.Records.Attachment.papeis/0`) para o corte transversal não
  precisar conhecer os domínios.
  """
  def with_roles_scope(conn, roles, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid, papel: papel} = scope when not is_nil(cid) ->
        if papel in roles, do: fun.(scope), else: forbidden(conn)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc """
  Leitura: qualquer membro de uma clínica ativa, independentemente do papel.

  A agenda (A8) usava uma terceira guarda, `with_scheduling_scope`, que enumerava
  `[:owner, :admin, :recepcao, :profissional]` — que é a lista **inteira** de
  `Api.Accounts.Role`. Era `:any` escrito por extenso, e o moduledoc justificava uma
  distinção que não existia. Colapsada aqui, com a divisão de responsabilidade explícita:

    * esta guarda responde **"você é membro de uma clínica ativa?"** (401 · 403);
    * **qual papel pode fazer o quê** é da policy do recurso — para agendamento, a policy de
      `Api.Scheduling.Appointment`, que é fail-closed e continua sendo a autoridade;
    * o recorte *dentro* do papel `profissional` ("só a própria agenda", A7) é da preparation
      `OwnAgendaOnly`, porque é sobre **linhas**, não sobre permissão de entrar.

  Consequência a conhecer: se um papel novo nascer em `Role`, ele entra aqui por default. É o
  mesmo contrato de todos os outros controllers (pacientes, profissionais, clínica), e quem
  barra continua sendo a policy do recurso.
  """
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

  def error_response(conn, _error), do: bad_request(conn)

  @doc """
  400 — **fonte única do corpo**, como `unprocessable/2` é do 422.

  Existia dentro do `error_response/2` e estava copiado à mão em `PackagesController` e
  `AttachmentsController` (doc 96, R-4/H-1): a mesma classe de duplicação que o `unprocessable/2`
  foi criado para eliminar, repetida porque este helper não era público.
  """
  def bad_request(conn), do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  def not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  @doc """
  Marca a resposta como **não armazenável** (`Cache-Control: no-store`).

  O default que saía do `Plug.Session` era `max-age=0, private, must-revalidate` — que permite
  **armazenar** e só exige revalidar. Para a ficha completa do paciente e para a URL assinada de
  um laudo, o correto é não guardar em lugar nenhum (doc 96, S-9). O tráfego passa pelo BFF, o que
  torna o risco indireto — mas `must-revalidate` autoriza o que `no-store` proíbe, e é barato
  fechar.
  """
  def no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  @doc """
  409 — **novo nesta fatia**. A regra semântica é a de `09:659`: **422 = "seu pedido está
  errado"; 409 = "seu pedido estava certo, o mundo mudou"**. Reservado a concorrência
  (`version_conflict` na Entrega 4) — conflito de horário é 422, porque o
  pedido *está* errado no momento em que chega.

  A 4-aridade carrega um `meta` (mapa) no corpo, para o 409 poder explicar a corrida em vez de
  ser um erro seco. `meta` vazio não vai no corpo. (A fila **usou** isso para o `slot_held` da
  reserva de vaga; a reserva foi removida no doc 39 — a 4-aridade fica, o caso de uso saiu.)
  """
  def conflict(conn, code, message, meta \\ %{}) do
    body = %{error: "conflict", code: code, details: [%{field: nil, message: message}]}
    body = if map_size(meta) > 0, do: Map.put(body, :meta, meta), else: body
    conn |> put_status(:conflict) |> json(body)
  end

  @doc """
  Atalho para o 422 de um erro que não é de campo nenhum (parâmetro de query malformado, teto
  de janela). Era o `invalid/2` copiado nos controllers de agenda e disponibilidade.
  """
  def invalid(conn, message), do: unprocessable(conn, [%{field: nil, message: message}])

  @doc """
  **409 do A3/D12** — a mudança de horário é bem formada, mas quebraria agendamentos que já
  existem (`Api.Scheduling.future_conflicts/2`).

  É 409 e não 422 pela regra do `conflict/4` acima: o pedido *está certo*, o mundo é que diz não.
  E é a mesma forma dos outros 409 do projeto — `code` estável + `meta` —, então a tela distingue
  "conflito de agenda" de "dados inválidos" pelo mesmo canal de sempre, e usa o `meta` para
  desenhar a lista do que remarcar antes de reenviar com `confirm: true`.
  """
  def future_conflicts(conn, %{conflicts: conflicts, total: total}) do
    conflict(
      conn,
      "future_conflicts",
      "Há #{total} agendamento(s) futuro(s) que ficariam fora do expediente.",
      %{conflicts: Enum.map(conflicts, &conflict_json/1), total: total}
    )
  end

  @doc """
  A análise do A3 quando ela vem **de dentro de uma ação** (o `CheckFutureConflicts` das
  exceções), embrulhada num `Ash.Error.Invalid`, e não como tupla do domínio.

  Duas portas escrevem por transação própria e devolvem tupla; as outras duas escrevem por uma
  ação do Ash e devolvem erro. A resposta HTTP é a mesma — este casamento é o que faz o cliente
  não precisar saber por qual das duas o pedido passou.
  """
  def future_conflicts_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.find_value(errors, fn erro ->
      vars = Map.get(erro, :vars) || []

      if Keyword.get(vars, :code) == "future_conflicts" do
        %{conflicts: Keyword.fetch!(vars, :conflicts), total: Keyword.fetch!(vars, :total)}
      end
    end)
  end

  def future_conflicts_error(_error), do: nil

  defp conflict_json(conflito) do
    %{
      appointment_id: conflito.appointment_id,
      date: Date.to_iso8601(conflito.date),
      hora: conflito.hora,
      reason: conflito.reason,
      periods_depois: conflito.periods_depois,
      professional: %{id: conflito.professional_id, nome: conflito.professional_nome},
      patients: conflito.patients
    }
  end

  @doc """
  Lê um inteiro **não-negativo** de um query param, ou `nil`.

  `nil` de propósito, e não 422: valor inválido em `?limit=`/`?offset=`/`?page=` deixa o
  **domínio** aplicar o default e o teto (`Api.Pagination`) — a lista nunca quebra por um
  `?limit=abc`. Estava copiada em três controllers, e a cópia mais nova já divergia (aceitava
  negativo), que é o jeito silencioso de a regra deixar de ser uma só.

      iex> ApiWeb.TenantScope.parse_int("50")
      50
      iex> ApiWeb.TenantScope.parse_int("-3")
      nil
      iex> ApiWeb.TenantScope.parse_int("abc")
      nil
      iex> ApiWeb.TenantScope.parse_int(nil)
      nil
  """
  def parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  def parse_int(value) when is_integer(value) and value >= 0, do: value
  def parse_int(_value), do: nil

  @doc """
  Lê e valida uma janela de datas de `params` (`from_key`/`to_key`, ambas `YYYY-MM-DD`).

  Era 27 linhas duplicadas byte a byte entre os controllers de agenda e disponibilidade —
  divergindo só no **nome do parâmetro dentro da mensagem**, que agora é interpolado. `to_key`
  ausente vale como igual a `from_key` (janela de um dia só).

  Retornos: `{:ok, from, to}` · `{:error, message}` (pronto para `invalid/2`).
  """
  def parse_window(params, from_key, to_key, max_dias \\ @max_dias) do
    with {:ok, from} <- parse_date(params[from_key], from_key),
         {:ok, to} <- parse_date(params[to_key] || params[from_key], to_key),
         :ok <- validate_window(from, to, from_key, to_key, max_dias) do
      {:ok, from, to}
    end
  end

  defp parse_date(nil, key), do: {:error, "informe o parâmetro #{key} (YYYY-MM-DD)"}

  defp parse_date(value, _key) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "data inválida: #{value}"}
    end
  end

  defp parse_date(_value, _key), do: {:error, "data inválida"}

  defp validate_window(from, to, from_key, to_key, max_dias) do
    cond do
      Date.compare(to, from) == :lt -> {:error, "#{to_key} não pode ser anterior a #{from_key}"}
      Date.diff(to, from) >= max_dias -> {:error, "janela máxima de #{max_dias} dias"}
      true -> :ok
    end
  end

  @doc """
  **Fonte única do corpo 422** — `{"error":"invalid", "code"?: ..., "details":[...]}`.

  Antes havia cinco lugares montando este corpo à mão, em **dois formatos**: os `invalid/2`
  privados dos controllers nunca emitiam `code`, e esta função sempre promove o que vier — o
  mesmo endpoint respondia 422 em formatos diferentes conforme o caminho que falhasse.
  `code` continua **opcional**: `details` sem código produz exatamente o corpo antigo, que é o
  que professionais/horário-da-clínica já contratam.

  `code` estável no topo (A10). Dois casos precisam de tratamento especial, e os dois são
  "o campo certo é NENHUM campo":

    * conflito de horário — o Ecto exige uma chave para a exclusion constraint e escolhemos
      `starts_at`, mas pintar esse input de vermelho **mente**: o horário digitado está
      certo, o mundo é que está ocupado. Vira `field: null` + `schedule_conflict`.
    * expediente — `CheckAvailability` já emite `field: nil` e manda o código em `vars`.
  """
  def unprocessable(conn, details) do
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

  # Todo 403 do projeto passa por aqui — as três guardas de escopo e o `error_response/2` que
  # traduz `Ash.Error.Forbidden`. Por isso é AQUI que a autorização negada entra na trilha
  # (doc 61 §3b, doc 63): um por controller seria uma lista para esquecer, e é exatamente o que
  # aconteceu com a whitelist de ações da auditoria.
  #
  # Deduplicado em 30 min por (usuário, caminho): sem isso um cliente em laço transforma a trilha
  # num log de acesso, e a poda passa a ser a única coisa que a segura.
  #
  # Sem escopo com tenant (401, ou membro sem clínica ativa) não há onde gravar — a trilha é
  # por-clínica. `Acesso.acesso_negado/2` trata esse caso devolvendo `:ok`.
  defp forbidden(conn) do
    case conn.assigns[:scope] do
      %Scope{} = scope ->
        # A ROTA (com `:id` no lugar dos identificadores) é o que dedupa; o caminho cru vai no
        # `meta` para a investigação. Enquanto o label era o path cru, a dedup nunca casava numa
        # varredura por IDOR — que é exatamente o que este evento existe para detectar (doc 96,
        # B-7). O normalizador é o mesmo do log de requisição: uma definição de "rota" só.
        Api.Audit.Acesso.acesso_negado(
          scope,
          ApiWeb.RequestLogger.rota(conn.request_path),
          conn.request_path
        )

      _ ->
        :ok
    end

    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

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
