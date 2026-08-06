defmodule ApiWeb.AuditController do
  @moduledoc """
  A trilha de auditoria da clínica ativa (doc 63) — o backend da tela `/auditoria`. Um `GET` só,
  paginado, com os filtros da tela.

  RBAC **owner·admin**: ao contrário das outras leituras de gestão (que são de todo membro), a
  trilha guarda o histórico inteiro da clínica — a agenda, os papéis concedidos, o diff da ficha
  e quem leu qual laudo. A guarda `with_admin_scope` recusa recepção/profissional com **403**
  (não uma lista vazia, que leria como "sem atividade"). É defesa-em-profundidade: as policies do
  `Api.Audit.Event` já filtram para owner·admin de qualquer forma.

  `clinic_id` sempre do escopo (09 §8); a janela `from`/`to` é local à clínica (mesmo fuso da
  agenda, `LocalTime.window!`).

  ## O que mudou com a tabela de eventos única

  O feed **não é mais por recurso**. Antes, `?resource=` trocava qual tabela de versão era
  paginada, e não existia "o que aconteceu na clínica hoje"; agora é uma **faceta** — ausente,
  o feed é da clínica inteira; presente (um valor ou vários), recorta.

  E a whitelist de nomes de ação **deixou de existir**. Ela era obrigatória enquanto o filtro
  virava átomo (`String.to_existing_atom` sobre string de query é como se cria átomo a partir de
  entrada não confiável), e era o ponto frágil documentado: nome fora dela virava filtro `nil`,
  o feed inteiro voltava e quem filtrou não percebia — a primeira versão deixou de fora **dez**
  nomes. Em `audit_events` a coluna `action` é **texto**, então o filtro é comparação de string:
  nome desconhecido devolve zero linhas, que é a resposta honesta, e não há lista para
  desatualizar.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Audit
  alias Api.Scheduling
  alias Api.Scheduling.LocalTime

  @nomes_de_recurso Enum.map(Api.Audit.ResourceKind.values(), &Atom.to_string/1)

  # GET /api/audit?resource=&record_id=&user_id=&action=&from=&to=&limit=&offset=
  def index(conn, params) do
    with_admin_scope(conn, fn scope ->
      case build_opts(scope, params) do
        {:ok, opts} ->
          result = Audit.list_events(scope, opts)

          json(conn, %{
            entries: Enum.map(result.entries, &entry_json/1),
            page: page_json(result.page)
          })

        {:error, message} ->
          invalid(conn, message)
      end
    end)
  end

  # ---- parsing ----

  defp build_opts(scope, params) do
    with {:ok, record_id} <- parse_uuid(params["record_id"], "record_id"),
         {:ok, user_id} <- parse_uuid(params["user_id"], "user_id"),
         {:ok, resource} <- parse_resource(params["resource"]),
         {:ok, from_dt, to_dt} <- audit_window(scope, params) do
      {:ok,
       [
         resource: resource,
         record_id: record_id,
         user_id: user_id,
         action: presence(params["action"]),
         from: from_dt,
         to: to_dt,
         limit: parse_int(params["limit"]),
         offset: parse_int(params["offset"])
       ]}
    end
  end

  # `record_id`/`user_id` são filtros sobre colunas UUID. Sem validar, um valor não-uuid chega
  # cru em `Ash.Query.filter(coluna == ^valor)` e o `Ecto.Query.CastError` sobe até virar **500**
  # (bate-volta doc 32, segurança). Validar aqui devolve 422 — o mesmo contrato de `from`/`to`.
  # Ausente/vazio é filtro nulo (não é erro).
  defp parse_uuid(nil, _label), do: {:ok, nil}
  defp parse_uuid("", _label), do: {:ok, nil}

  defp parse_uuid(value, label) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> {:ok, value}
      :error -> {:error, "#{label} inválido"}
    end
  end

  # Ausente = feed da clínica inteira (o default, e a pergunta que o admin de fato faz). Aceita
  # vários separados por vírgula, para a tela poder agrupar ("cadastros" = paciente+profissional).
  #
  # Valor desconhecido é **422**, não filtro nulo: aqui a lista fechada existe de verdade (é o
  # enum do recurso) e um `?resource=pacinete` que devolvesse o feed inteiro repetiria o erro
  # que a whitelist de ações cometia — a tela mostraria um chip de filtro sobre uma lista não
  # filtrada.
  defp parse_resource(nil), do: {:ok, nil}
  defp parse_resource(""), do: {:ok, nil}

  defp parse_resource(value) when is_binary(value) do
    valores = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case Enum.reject(valores, &(&1 in @nomes_de_recurso)) do
      [] -> {:ok, Enum.map(valores, &String.to_existing_atom/1)}
      [invalido | _] -> {:error, "resource inválido: #{invalido}"}
    end
  end

  # A janela é OPCIONAL (o feed default é offset-paginado, sem recorte de data — o índice
  # `(clinic_id, at DESC)` já limita o que se lê). Quando vem, é local à clínica e limitada a 31
  # dias, reusando `parse_window` (a mesma regra da agenda).
  defp audit_window(scope, params) do
    if is_nil(params["from"]) and is_nil(params["to"]) do
      {:ok, nil, nil}
    else
      with {:ok, from_date, to_date} <- parse_window(params, "from", "to") do
        tz = Scheduling.clinic_timezone(scope.clinic_id)
        {from_dt, to_dt} = LocalTime.window!(from_date, to_date, tz)
        {:ok, from_dt, to_dt}
      end
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  # ---- serialização ----

  # Átomos (`resource`, `action_type`) o Jason emite como string; DateTime vai em ISO-8601
  # explícito (o resto do projeto faz assim). `patient`/`professional` vêm `null` quando a linha
  # não fala de nenhum — é o contexto de `meta`, não um campo de todo recurso.
  defp entry_json(e) do
    %{
      id: e.id,
      resource: e.resource,
      record_id: e.record_id,
      label: e.label,
      action: e.action,
      action_type: e.action_type,
      at: iso(e.at),
      actor: e.actor,
      patient: e.patient,
      professional: e.professional,
      # Quem estava no bloco, nas linhas de agendamento — o `Appointment` não tem paciente
      # (quem tem são as presenças), e sem isto a linha não dizia de quem era a sessão.
      participants: e.participants,
      diff: e.diff,
      meta: e.meta
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
